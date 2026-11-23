# backend/app/core/auth_middleware.py

import json
import os
import time
from typing import Any, Dict, Optional

from app.core.blocking_io import run_blocking
from fastapi import Request
from fastapi.responses import JSONResponse
from firebase_admin import auth as admin_auth
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.core.firebase_setup import db as firebase_db
from app.core.models import Company
from app.core.request_context import current_user_context
from app.core.branch_scope import active_operating_branches
from app.core.company_policy_store import active_policy_configuration, effective_policy_profile, CompanyReviewRequired


# ============================================================
# ⭐ SUPER_ADMIN_EMAILS (من .env) — للتحقق الفوري
# ============================================================
SUPER_ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.getenv("SUPER_ADMIN_EMAILS", "").split(",")
    if e.strip()
}


# ============================================================
# ⭐ الأدوار
# ============================================================

_JOB_CODE_TO_ROLE = {
    "99": "super_admin",
    "201": "admin",
    "200": "employee",
    "1": "employee",
}


def _effective_role(profile: Dict[str, Any]) -> str:
    """
    يحسب الدور الفعلي:
      1. لو email في SUPER_ADMIN_EMAILS → super_admin (الأولوية)
      2. وإلا: role من Firestore
      3. وإلا: من job_code (توافق خلفي)
      4. وإلا: employee
    """
    email = str(profile.get("email", "")).strip().lower()
    if email and email in SUPER_ADMIN_EMAILS:
        return "super_admin"

    role = str(profile.get("role", "")).strip()
    if role in ("super_admin", "admin", "employee"):
        return role

    job_code = str(profile.get("job_code", "1"))
    return _JOB_CODE_TO_ROLE.get(job_code, "employee")


# ============================================================
# Cache
# ============================================================

_PROFILE_CACHE: Dict[str, tuple[float, Dict[str, Any]]] = {}
_COMPANY_CACHE: Dict[str, tuple[float, bool]] = {}
_CACHE_SECONDS = 15
_PROFILE_INVALIDATION = 0

_PUBLIC_PATHS = {
    "/",
    "/auth/verify-user",
    "/auth/verify-reset",
    # ⭐ Endpoints عامة (قبل الدخول)
    "/auth/resolve-identifier",
    "/auth/check-phone",
    "/auth/check-email",              # ⭐ جديد
    "/auth/complete-registration",
    "/auth/cancel-registration",
    "/auth/request-registration",
}

_COMPANY_PATH_PREFIXES = (
    "/transactions/", "/coding/", "/inventory/", "/supplier/",
    "/supplier-settlement/", "/sync/", "/employees/", "/hr/", "/commercial/",
)


def invalidate_company_cache(company_code: str) -> None:
    _COMPANY_CACHE.pop(str(company_code), None)


def invalidate_profile_cache(email: str) -> None:
    """إبطال الكاش فور تعديل الصلاحيات/الحالة حتى يسري التغيير
    في أول طلب تالٍ بدلاً من انتظار انتهاء مدة الكاش."""
    global _PROFILE_INVALIDATION
    _PROFILE_INVALIDATION += 1
    _PROFILE_CACHE.pop(str(email or "").strip().lower(), None)


def profile_invalidation_revision() -> int:
    return _PROFILE_INVALIDATION


def _profile_for(email: str, uid: str, *, force_refresh: bool = False) -> Optional[Dict[str, Any]]:
    now = time.monotonic()
    cached = _PROFILE_CACHE.get(email)
    if not force_refresh and cached and now - cached[0] < _CACHE_SECONDS and cached[1].get("uid") == uid:
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


def can_bypass_permissions(profile: Dict[str, Any]) -> bool:
    """Only platform admin, or legacy company admin before reviewed activation."""
    role = _effective_role(profile)
    return role == "super_admin" or (
        role == "admin" and profile.get("company_policy_active") is not True
    )


def _allowed_branches(profile: Dict[str, Any]) -> list[str]:
    if profile.get('company_policy_active') is True:
        # Projected requests normally arrive prevalidated. Direct consumers
        # must also fail closed rather than treating an empty list as all.
        return active_operating_branches(profile.get('allowed_branches'))
    value = profile.get("allowed_branches", ["all"])
    if value is None:
        return ["all"]
    if isinstance(value, str):
        return ["all"] if value.lower() == "all" else [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return ["all"]


def allowed_branches_for_profile(profile: Dict[str, Any]) -> Optional[list[str]]:
    """None = كل الفروع مسموحة، list = فروع محددة."""
    role = _effective_role(profile)
    if can_bypass_permissions(profile):
        return None
    branches = _allowed_branches(profile)
    if not branches or "all" in [branch.lower() for branch in branches]:
        return None
    return branches


# ============================================================
# Middleware
# ============================================================

async def authenticate_http_request(request: Request, call_next):
    return await _authenticate_http_request(request, call_next)


async def _authenticate_http_request(request: Request, call_next):
    if (
        request.method == "OPTIONS"
        or request.url.path in _PUBLIC_PATHS
        or request.url.path.startswith(("/docs", "/redoc", "/openapi.json"))
    ):
        return await call_next(request)

    authorization = request.headers.get("authorization", "")

    # ============================================================
    # /auth/register (خاص — يتحقق من تطابق token مع البيانات)
    # ============================================================
    if request.url.path == "/auth/register":
        if not authorization.lower().startswith("bearer "):
            return JSONResponse(status_code=401, content={"detail": "يجب توثيق حساب Firebase لإتمام التسجيل"})
        try:
            decoded_register = await run_blocking(admin_auth.verify_id_token,
                authorization.split(" ", 1)[1].strip(), clock_skew_seconds=60
            )
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

        if (
            str(decoded_register.get("uid", "")) != str(register_data.get("uid", ""))
            or str(decoded_register.get("email", "")).strip().lower()
            != str(register_data.get("email", "")).strip().lower()
        ):
            return JSONResponse(status_code=403, content={"detail": "بيانات حساب Firebase لا تطابق بيانات التسجيل"})
        return await call_next(request)

    # ============================================================
    # التحقق من Firebase token
    # ============================================================
    if not authorization.lower().startswith("bearer "):
        return JSONResponse(status_code=401, content={"detail": "يجب تسجيل الدخول لإكمال الطلب"})

    try:
        decoded = await run_blocking(admin_auth.verify_id_token,
            authorization.split(" ", 1)[1].strip(), clock_skew_seconds=60
        )
        uid = str(decoded.get("uid", ""))
        email = str(decoded.get("email", "")).strip().lower()
        if not uid or not email:
            raise ValueError("Firebase token does not include uid/email")
        # A concurrent explicit revocation must not be overwritten by a read
        # that started before it. Retry fresh, fail closed under continuous churn.
        for attempt in range(3):
            revision = _PROFILE_INVALIDATION
            profile = await run_blocking(_profile_for, email, uid, force_refresh=True)
            if revision == _PROFILE_INVALIDATION:
                break
        else:
            return JSONResponse(status_code=503, content={"detail": "تعذر تثبيت صلاحيات الحساب مؤقتًا"})
    except Exception as exc:
        print(f"⚠️ رفض طلب API غير موثق: {exc}")
        return JSONResponse(status_code=401, content={"detail": "انتهت الجلسة أو التوكن غير صالح، سجل الدخول مرة أخرى"})

    if profile is None:
        return JSONResponse(status_code=401, content={"detail": "الحساب غير مسجل أو غير صالح"})

    # ⭐ التحقق من حالة الحساب
    user_status = str(profile.get("status", "active")).lower()
    if user_status == "pending":
        return JSONResponse(
            status_code=403,
            content={"detail": "حسابك قيد المراجعة. يرجى إكمال التسجيل."},
        )
    if user_status == "suspended":
        return JSONResponse(
            status_code=403,
            content={"detail": "تم إيقاف حسابك. يرجى التواصل مع الإدارة."},
        )

    # ⭐ الحظر الفوري (is_active بتتكتب من صفحة المستخدمين)
    # الحقل الناقص (حسابات قديمة) لا يؤثر
    if profile.get("is_active") is False:
        return JSONResponse(
            status_code=403,
            content={"detail": "تم حظر حسابك. يرجى التواصل مع الإدارة."},
        )

    if profile.get('requires_email_verification') is True and decoded.get('email_verified') is not True:
        return JSONResponse(status_code=403, content={'detail': 'يجب التحقق من البريد الإلكتروني أولاً'})

    # ⭐ الدور الفعلي
    role = _effective_role(profile)

    company_code = str(profile.get("company_code", ""))
    if not company_code:
        return JSONResponse(status_code=403, content={"detail": "الحساب غير مرتبط بشركة"})

    # ⭐ الشركة موقوفة؟ (super_admin معفي)
    if role != "super_admin":
        try:
            company_active = await _company_is_active(company_code)
            if not company_active:
                return JSONResponse(status_code=403, content={"detail": "الشركة غير موجودة أو موقوفة"})
        except Exception as exc:
            print(f"⚠️ تعذر التحقق من حالة الشركة: {exc}")
            return JSONResponse(status_code=503, content={"detail": "تعذر التحقق من حالة الشركة مؤقتًا"})

    # The database, not a client/profile flag, determines reviewed activation.
    # The initial identity read is current for all companies. Do not duplicate
    # that source read when projecting the active company policy.
    try:
        configuration, policy_revision = None, None
        if role != "super_admin":
            async with AsyncSessionLocal() as policy_session:
                configuration, policy_revision = await active_policy_configuration(policy_session, company_code)
            if configuration is not None:
                fresh = profile
                if fresh is None:
                    return JSONResponse(status_code=401, content={"detail": "الحساب غير صالح"})
                if str(fresh.get("company_code", "")) != company_code:
                    return JSONResponse(status_code=409, content={"detail": "تغير نطاق الحساب. أعد تحميل الجلسة"})
                if fresh.get("is_active") is False or str(fresh.get("status", "active")).lower() in ("pending", "suspended"):
                    return JSONResponse(status_code=403, content={"detail": "الحساب غير متاح للاستخدام"})
                profile = fresh
                role = _effective_role(profile)
        profile = effective_policy_profile(profile, configuration, policy_revision, role=role)
    except CompanyReviewRequired:
        return JSONResponse(status_code=403, content={"detail":"تحتاج الشركة مراجعة صلاحياتها قبل الاستخدام", "code":"company_review_required"})
    except Exception as exc:
        print(f"⚠️ Company authorization unavailable: {exc}")
        return JSONResponse(status_code=503, content={"detail": "تعذر التحقق من صلاحيات الشركة مؤقتًا"})

    # ============================================================
    # قراءة الـ JSON body وإعادته كما هو
    # ============================================================
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

    # ============================================================
    # فحوصات الشركة/الفرع (لمستخدمي الشركة فقط — Super Admin معفي)
    # ============================================================
    if role != "super_admin":
        supplied_company = body.get("company_code")
        if supplied_company is not None and str(supplied_company) != company_code:
            return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى بيانات شركة أخرى"})

        # فحص URL
        parts = [part for part in request.url.path.split("/") if part]
        if parts and parts[0] in {
            "transactions", "coding", "inventory", "supplier",
            "supplier-settlement", "sync", "employees", "hr",
            "commercial",
        }:
            for marker in ("list", "changes", "updates", "last_serial", "summary", "ws", "delete", "customer-balances", "cash-balances", "returnable", "stock-events"):
                if marker in parts:
                    idx = parts.index(marker) + 1
                    if idx < len(parts) and parts[idx] != company_code:
                        return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى بيانات شركة أخرى"})
                    break

        # فحص الفرع
        branches = _allowed_branches(profile)
        if branches and "all" not in [branch.lower() for branch in branches]:
            parts = [part for part in request.url.path.split("/") if part]
            if len(parts) >= 5 and parts[0] == "transactions" and parts[1] == "delete" and parts[3] not in branches:
                return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى هذا الفرع"})

            requested_branch = body.get("branch_code") or request.query_params.get("branch_code")
            # Here branch_code is the target's startup preference, not the
            # actor's business-data filter. The route locks policy/company/
            # branches and verifies the target scope in its source transaction.
            account_startup = (configuration is not None and request.method == 'PUT'
                and request.url.path == '/auth/admin/edit-user')
            if requested_branch and not account_startup:
                requested_branch = str(requested_branch)
                is_all_query = request.method == "GET" and requested_branch.lower() in {
                    "all", "الكل", "كل الفروع",
                }
                if not is_all_query and (
                    requested_branch.lower() in {"all", "الكل", "كل الفروع"}
                    or requested_branch not in branches
                ):
                    return JSONResponse(status_code=403, content={"detail": "غير مسموح بالوصول إلى هذا الفرع"})

    # ============================================================
    # إعداد profile للاستخدام في الـ endpoints
    # ============================================================
    profile["uid"] = uid
    profile["email"] = email
    profile["company_code"] = company_code
    profile["role"] = role            # ⭐ جديد
    profile["job_code"] = str(profile.get("job_code", "1"))  # توافق خلفي
    request.state.auth_user = profile
    token = current_user_context.set(profile)
    try:
        response = await call_next(request)
        return response
    finally:
        current_user_context.reset(token)
