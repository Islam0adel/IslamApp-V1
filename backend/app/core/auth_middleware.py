import json
import time
from typing import Any, Dict, Optional

from fastapi import Request
from fastapi.responses import JSONResponse
from firebase_admin import auth as admin_auth
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.core.firebase_setup import db as firebase_db
from app.core.models import Company
from app.core.request_context import current_user_context

# ذاكرة قصيرة لتقليل قراءات Firestore المتكررة، مع إعادة التحقق من Firebase ID token في كل طلب.
_PROFILE_CACHE: Dict[str, tuple[float, Dict[str, Any]]] = {}
_COMPANY_CACHE: Dict[str, tuple[float, bool]] = {}
_CACHE_SECONDS = 15
_PUBLIC_PATHS = {
    "/",
    "/auth/verify-user",
    "/auth/verify-reset",
}
_COMPANY_PATH_PREFIXES = (
    "/transactions/", "/coding/", "/inventory/", "/supplier/",
    "/supplier-settlement/", "/sync/",
)


def _profile_for(email: str, uid: str) -> Optional[Dict[str, Any]]:
    now = time.monotonic()
    cached = _PROFILE_CACHE.get(email)
    if cached and now - cached[0] < _CACHE_SECONDS and cached[1].get("uid") == uid:
        return cached[1]
    if firebase_db is None:
        return None
    document = firebase_db.collection("users").document(email).get()
    if not document.exists:
        return None
    data = document.to_dict() or {}
    if str(data.get("uid", "")) != uid:
        return None
    data["email"] = email
    _PROFILE_CACHE[email] = (now, data)
    return data


async def _company_is_active(company_code: str) -> bool:
    now = time.monotonic()
    cached = _COMPANY_CACHE.get(company_code)
    if cached and now - cached[0] < _CACHE_SECONDS:
        return cached[1]
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(Company).where(Company.code == company_code))
        company = result.scalar_one_or_none()
        active = bool(company and company.is_active)
    _COMPANY_CACHE[company_code] = (now, active)
    return active


def _allowed_branches(profile: Dict[str, Any]) -> list[str]:
    value = profile.get("allowed_branches", ["all"])
    if value is None:
        return ["all"]
    if isinstance(value, str):
        return ["all"] if value.lower() == "all" else [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return ["all"]


def allowed_branches_for_profile(profile: Dict[str, Any]) -> Optional[list[str]]:
    if str(profile.get("job_code", "1")) == "99":
        return None
    branches = _allowed_branches(profile)
    if not branches or "all" in [branch.lower() for branch in branches]:
        return None
    return branches


async def authenticate_http_request(request: Request, call_next):
    if request.method == "OPTIONS" or request.url.path in _PUBLIC_PATHS or request.url.path.startswith(("/docs", "/redoc", "/openapi.json")):
        return await call_next(request)

    authorization = request.headers.get("authorization", "")
    if request.url.path == "/auth/register":
        if not authorization.lower().startswith("bearer "):
            return JSONResponse(status_code=401, content={"detail": "يجب توثيق حساب Firebase لإتمام التسجيل"})
        try:
            decoded_register = admin_auth.verify_id_token(authorization.split(" ", 1)[1].strip(), clock_skew_seconds=60)
            raw_body = await request.body()
            register_data = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            if not isinstance(register_data, dict):
                raise ValueError("Invalid registration body")
            async def receive_register_body():
                return {"type": "http.request", "body": raw_body, "more_body": False}
            request._receive = receive_register_body
        except Exception as exc:
            print(f"⚠️ رفض تسجيل غير موثق: {exc}")
            return JSONResponse(status_code=401, content={"detail": "تعذر توثيق حساب Firebase للتسجيل"})
        if str(decoded_register.get("uid", "")) != str(register_data.get("uid", "")) or str(decoded_register.get("email", "")).strip().lower() != str(register_data.get("email", "")).strip().lower():
            return JSONResponse(status_code=403, content={"detail": "بيانات حساب Firebase لا تطابق بيانات التسجيل"})
        return await call_next(request)

    if not authorization.lower().startswith("bearer "):
        return JSONResponse(status_code=401, content={"detail": "يجب تسجيل الدخول لإكمال الطلب"})

    try:
        decoded = admin_auth.verify_id_token(authorization.split(" ", 1)[1].strip(), clock_skew_seconds=60)
        uid = str(decoded.get("uid", ""))
        email = str(decoded.get("email", "")).strip().lower()
        if not uid or not email:
            raise ValueError("Firebase token does not include uid/email")
        profile = _profile_for(email, uid)
    except Exception as exc:
        print(f"⚠️ رفض طلب API غير موثق: {exc}")
        return JSONResponse(status_code=401, content={"detail": "انتهت الجلسة أو التوكن غير صالح، سجل الدخول مرة أخرى"})

    if profile is None:
        return JSONResponse(status_code=401, content={"detail": "الحساب غير مسجل أو غير صالح"})

    company_code = str(profile.get("company_code", ""))
    job_code = str(profile.get("job_code", "1"))
    if not company_code:
        return JSONResponse(status_code=403, content={"detail": "الحساب غير مرتبط بشركة"})
    try:
        if job_code != "99" and not await _company_is_active(company_code):
            return JSONResponse(status_code=403, content={"detail": "الشركة غير موجودة أو موقوفة"})
    except Exception as exc:
        print(f"⚠️ تعذر التحقق من حالة الشركة: {exc}")
        return JSONResponse(status_code=503, content={"detail": "تعذر التحقق من حالة الشركة مؤقتًا"})

    # قراءة جسم JSON وإعادته كما هو حتى تتمكن FastAPI من تحليله لاحقًا.
    body: Dict[str, Any] = {}
    content_type = request.headers.get("content-type", "").lower()
    if "application/json" in content_type:
        raw_body = await request.body()
        if raw_body:
            try:
                parsed = json.loads(raw_body.decode("utf-8"))
                if isinstance(parsed, dict):
                    body = parsed
            except (UnicodeDecodeError, json.JSONDecodeError):
                body = {}

        async def receive_body():
            return {"type": "http.request", "body": raw_body, "more_body": False}
        request._receive = receive_body

    if job_code != "99":
        supplied_company = body.get("company_code")
        if supplied_company is not None and str(supplied_company) != company_code:
            return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى بيانات شركة أخرى"})

        # المسارات التي تحمل كود الشركة في عنوان URL.
        parts = [part for part in request.url.path.split("/") if part]
        if parts and parts[0] in {"transactions", "coding", "inventory", "supplier", "supplier-settlement", "sync"}:
            for marker in ("list", "changes", "updates", "last_serial", "summary", "ws", "delete"):
                if marker in parts:
                    idx = parts.index(marker) + 1
                    if idx < len(parts) and parts[idx] != company_code:
                        return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى بيانات شركة أخرى"})
                    break

        branches = _allowed_branches(profile)
        if branches and "all" not in [branch.lower() for branch in branches]:
            parts = [part for part in request.url.path.split("/") if part]
            if len(parts) >= 5 and parts[0] == "transactions" and parts[1] == "delete" and parts[3] not in branches:
                return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى هذا الفرع"})
            requested_branch = body.get("branch_code") or request.query_params.get("branch_code")
            if requested_branch:
                requested_branch = str(requested_branch)
                is_all_query = request.method == "GET" and requested_branch.lower() in {"all", "الكل", "كل الفروع"}
                if not is_all_query and (requested_branch.lower() in {"all", "الكل", "كل الفروع"} or requested_branch not in branches):
                    return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى هذا الفرع"})

    profile["uid"] = uid
    profile["email"] = email
    profile["company_code"] = company_code
    profile["job_code"] = job_code
    request.state.auth_user = profile
    token = current_user_context.set(profile)
    try:
        return await call_next(request)
    finally:
        current_user_context.reset(token)
