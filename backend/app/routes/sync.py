# backend/app/routes/sync.py


from app.core.blocking_io import run_blocking
import asyncio
import json
from fastapi import (
    APIRouter,
    WebSocket,
    WebSocketDisconnect,
)
from firebase_admin import auth as admin_auth
from app.core.firebase_setup import db as firebase_db
from app.core.database import AsyncSessionLocal
from app.core.models import Company
from sqlalchemy import select

from app.core.auth_middleware import invalidate_profile_cache, _effective_role, profile_invalidation_revision
from app.core.company_policy_store import load_effective_policy_profile
from app.core.sync import manager

def _profile_signature(data: dict) -> str:
    return json.dumps(
        {
            "role": str(data.get("role", "")),
            "job_code": str(data.get("job_code", "")),
            "permissions": data.get("permissions") or {},
            "allowed_branches": data.get("allowed_branches") or [],
            "is_active": data.get("is_active"),
            "status": str(data.get("status", "active")),
            "hr_viewable_employees": data.get("hr_viewable_employees") or [],
            "company_policy_active": data.get("company_policy_active") is True,
            "company_policy_revision": data.get("company_policy_revision"),
            "delegable_permissions": data.get("delegable_permissions") or {},
            "delegable_branches": data.get("delegable_branches") or [],
        },
        sort_keys=True,
        ensure_ascii=False,
        default=str,
    )


async def _company_active(company_code: str) -> bool:
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(Company).where(Company.code == str(company_code))
        )
        company = result.scalar_one_or_none()
    return bool(company and company.is_active)


async def refresh_socket_profile(websocket: WebSocket, company_code: str, email: str, uid: str) -> None:
    """One explicit recovery check, never scheduled as an idle polling task."""
    try:
        revision = manager.connection_profiles.get(websocket, {}).get(
            "_permissions_revision", 0
        )
        doc = await run_blocking(firebase_db.collection("users").document(email).get)
        if not doc.exists:
            manager.replace_user_profile(company_code, email, None)
            await websocket.close(code=1008)
            return
        fresh = doc.to_dict() or {}
        if (str(fresh.get("uid", "")) != uid
                or str(fresh.get("company_code", "")) != str(company_code)):
            manager.replace_user_profile(company_code, email, None)
            await websocket.close(code=1008)
            return

        status = str(fresh.get("status", "active")).lower()
        blocked = (
            status in ("suspended", "pending")
            or fresh.get("is_active") is False
            or not await _company_active(company_code)
        )
        current = manager.connection_profiles.get(websocket, {})
        # The source was read before an await. A newer explicit account
        # mutation must not be overwritten by that older explicit read.
        if current.get("_permissions_revision", 0) != revision:
            return
        if blocked:
            manager.replace_user_profile(company_code, email, None)
            try:
                await websocket.send_json({
                    "type": "permissions_changed",
                    "data": {"email": email},
                    "suppress_notification": True,
                })
            finally:
                await websocket.close(code=1008)
            return

        fresh['email'] = email
        async with AsyncSessionLocal() as session:
            fresh = await load_effective_policy_profile(session, fresh, role=_effective_role(fresh))
        current = manager.connection_profiles.get(websocket, {})
        if current.get("_permissions_revision", 0) != revision:
            return
        if (current.get("_permissions_invalidated")
                or _profile_signature(current) != _profile_signature(fresh)):
            manager.replace_user_profile(company_code, email, fresh)
            invalidate_profile_cache(email)
            await websocket.send_json({
                "type": "permissions_changed",
                "data": {"email": email},
                "suppress_notification": True,
            })
    except WebSocketDisconnect:
        return
    except Exception as e:
        current = manager.connection_profiles.get(websocket, {})
        was_held = current.get('_permissions_invalidated') is True
        manager.replace_user_profile(company_code, email, None)
        invalidate_profile_cache(email)
        if not was_held:
            try:
                await manager.send_to_user(company_code, email, {
                    'type': 'permissions_changed', 'data': {'email': email},
                    'suppress_notification': True,
                })
            except Exception:
                pass
        # Remain held after an unavailable source. Recovery is event/action based,
        # never an idle timer.
        print(
            f"⚠️ WS profile refresh error | "
            f"company={company_code} | error={e}"
        )

router = APIRouter()


# ============================================================
# WebSocket
# ============================================================

@router.websocket("/ws/{company_code}")
async def websocket_endpoint(
    websocket: WebSocket,
    company_code: str,
):
    """
    فتح اتصال WebSocket لجهاز تابع للشركة.

    WebSocket يستخدم للتحديث الفوري للأجهزة المتصلة.

    أما الأجهزة Offline فتعتمد على:
        /changes/{company_code}?since=...

    للحصول على التحديثات التي فاتتها.
    """

    # قبول القناة مؤقتًا لاستقبال رسالة المصادقة فقط.
    await websocket.accept()

    if firebase_db is None:
        await websocket.close(code=1011)
        return

    try:
        auth_message = await asyncio.wait_for(
            websocket.receive_json(),
            timeout=10,
        )

        token = (
            auth_message.get("token")
            if isinstance(auth_message, dict)
            and auth_message.get("type") == "auth"
            else None
        )

        if not token:
            await websocket.close(code=1008)
            return

        decoded = await run_blocking(admin_auth.verify_id_token,
            token,
            clock_skew_seconds=60,
        )

        email = (decoded.get("email") or "").strip().lower()
        uid = str(decoded.get("uid") or "")

        if not email or not uid:
            await websocket.close(code=1008)
            return

        for attempt in range(3):
            revision = profile_invalidation_revision()
            user_doc = await run_blocking(
                firebase_db.collection("users").document(email).get
            )
            if revision == profile_invalidation_revision():
                break
        else:
            await websocket.close(code=1013)
            return

        if not user_doc.exists:
            await websocket.close(code=1008)
            return

        user_data = user_doc.to_dict() or {}

        if (
            str(user_data.get("uid", "")) != uid
            or str(user_data.get("company_code", "")) != str(company_code)
        ):
            await websocket.close(code=1008)
            return

        # حالة الحساب عند الاتصال: الموقوف/المحظور/المعلّق لا يتصل
        _status = str(user_data.get("status", "active")).lower()
        if (
            (user_data.get("requires_email_verification") is True and decoded.get("email_verified") is not True)
            or _status in ("suspended", "pending")
            or user_data.get("is_active") is False
        ):
            await websocket.close(code=1008)
            return

        async with AsyncSessionLocal() as session:
            result = await session.execute(
                select(Company).where(
                    Company.code == str(company_code)
                )
            )
            company = result.scalar_one_or_none()

            if company is None or not company.is_active:
                await websocket.close(code=1008)
                return

            user_data['uid'] = uid
            user_data['email'] = email
            user_data = await load_effective_policy_profile(
                session, user_data, role=_effective_role(user_data),
            )

    except Exception as e:
        print(
            f"⚠️ رفض WebSocket غير موثق | "
            f"company={company_code} | error={e}"
        )
        try:
            await websocket.close(code=1008)
        except Exception:
            pass
        return

    # تسجيل الاتصال بعد نجاح المصادقة فقط.
    await manager.connect(
        company_code,
        websocket,
        accept_connection=False,
        profile=user_data,
    )

    try:
        # تأكيد صريح للعميل أن المصادقة نجحت
        # وأن الاتصال أصبح مسجلًا لدى مدير الاتصالات.
        await websocket.send_json({
            "type": "auth_success",
            "company_code": str(company_code),
        })

        print(
            f"✅ WebSocket authenticated | "
            f"company={company_code} | uid={uid}"
        )

        while True:
            # استقبال أي رسالة من العميل للمحافظة على الاتصال.
            message = await websocket.receive_text()
            if message == 'verify_profile':
                await refresh_socket_profile(websocket, str(company_code), email, uid)

    except WebSocketDisconnect:
        manager.disconnect(
            company_code,
            websocket,
        )

    except Exception as e:
        print(
            f"⚠️ خطأ في WebSocket | "
            f"company={company_code} | error={e}"
        )

        manager.disconnect(
            company_code,
            websocket,
        )
