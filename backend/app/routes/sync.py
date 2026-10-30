# backend/app/routes/sync.py


import asyncio
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

from app.core.sync import manager


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

        decoded = admin_auth.verify_id_token(
            token,
            clock_skew_seconds=60,
        )

        email = (decoded.get("email") or "").strip().lower()
        uid = str(decoded.get("uid") or "")

        if not email or not uid:
            await websocket.close(code=1008)
            return

        user_doc = (
            firebase_db.collection("users")
            .document(email)
            .get()
        )

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

        user_data["uid"] = uid
        user_data["email"] = email

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
            await websocket.receive_text()

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
