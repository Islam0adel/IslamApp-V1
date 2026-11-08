# backend/app/core/fcm_service.py

"""
خدمة إرسال إشعارات FCM (Firebase Cloud Messaging).

المبادئ:
- تبعث فقط إلى من مرّوا فحوصات الصلاحيات والتفضيلات في notification_events.py
- Fire-and-forget (لا تعطل الويب سوكيت)
- تحذف الرموز الفاشلة تلقائياً من Neon
"""

import asyncio
from typing import Optional

from sqlalchemy import delete, select

from app.core.database import AsyncSessionLocal
from app.core.models import UserFcmToken
from app.core.firebase_setup import firebase_app

# ─── استيراد messaging بشكل آمن ────────────────────────────
try:
    from firebase_admin import messaging as _fb_messaging
    _MESSAGING_IMPORTED = True
except ImportError:
    _fb_messaging = None
    _MESSAGING_IMPORTED = False


def is_fcm_enabled() -> bool:
    """هل FCM جاهز للإرسال؟ (يحتاج Admin SDK + app initialized)"""
    return _MESSAGING_IMPORTED and firebase_app is not None


# ============================================================
# 1. قراءة الرموز من Neon
# ============================================================

async def get_user_tokens(user_uid: str, company_code: str) -> list[str]:
    """جلب كل رموز FCM للمستخدم في شركة معينة (كل أجهزته)"""
    if not user_uid or not company_code:
        return []

    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(UserFcmToken.fcm_token).where(
                UserFcmToken.user_uid == str(user_uid),
                UserFcmToken.company_code == str(company_code),
            )
        )
        return [row[0] for row in result.all()]


async def delete_tokens(tokens: list[str]) -> None:
    """حذف الرموز الفاشلة (invalid/unregistered) من Neon"""
    if not tokens:
        return

    async with AsyncSessionLocal() as session:
        await session.execute(
            delete(UserFcmToken).where(UserFcmToken.fcm_token.in_(tokens))
        )
        await session.commit()


# ============================================================
# 2. الإرسال المتزامن (في executor)
# ============================================================

def _send_sync(
    tokens: list[str],
    title: str,
    body: str,
    data: Optional[dict] = None,
) -> list[str]:
    """
    إرسال إشعار إلى قائمة رموز.
    Returns: قائمة الرموز التي فشل إرسالها (لحذفها).
    """
    if not is_fcm_enabled() or not tokens:
        return []

    # ⚠️ مهم: نستخدم `data` فقط (مش `notification`)
    # كده الـ Service Worker / التطبيق هو اللي يعرض الإشعار،
    # وده يعطينا تحكم كامل في المحتوى والأيقونة.
    message = _fb_messaging.MulticastMessage(
        tokens=tokens,
        data={
            "title": title or "",
            "body": body or "",
            **{str(k): str(v) for k, v in (data or {}).items()},
        },
    )

    failed_tokens: list[str] = []
    try:
        # استخدم send_each_for_multicast لو موجود، وإلا send_multicast (للإصدارات القديمة)
        if hasattr(_fb_messaging, "send_each_for_multicast"):
            response = _fb_messaging.send_each_for_multicast(message)
        else:
            response = _fb_messaging.send_multicast(message)

        for idx, resp in enumerate(response.responses):
            if not resp.success:
                failed_tokens.append(tokens[idx])
                print(
                    f"⚠️ FCM send failed | token={tokens[idx][:20]}... | "
                    f"error={resp.exception}"
                )
    except Exception as exc:
        print(f"❌ FCM multicast error: {exc}")
        return tokens  # نعتبر الكل فشل — يُحذف في المرة الجاية

    return failed_tokens


# ============================================================
# 3. الإرسال غير المتزامن (async)
# ============================================================

async def send_push_to_user(
    user_uid: str,
    company_code: str,
    title: str,
    body: str,
    data: Optional[dict] = None,
) -> None:
    """
    إرسال إشعار Push لمستخدم معين (كل أجهزته).
    آمن للاستدعاء من background tasks.
    """
    if not is_fcm_enabled():
        return

    try:
        tokens = await get_user_tokens(user_uid, company_code)
        if not tokens:
            return

        loop = asyncio.get_running_loop()
        failed = await loop.run_in_executor(
            None, _send_sync, tokens, title, body, data
        )

        if failed:
            await delete_tokens(failed)

        success = len(tokens) - len(failed)
        if success > 0:
            print(
                f"📤 FCM sent | user={user_uid} | "
                f"devices={success}/{len(tokens)}"
            )
    except Exception as exc:
        print(f"❌ send_push_to_user failed for {user_uid}: {exc}")


# ============================================================
# 4. Fire-and-forget scheduling
# ============================================================

def send_push_to_user_bg(
    user_uid: str,
    company_code: str,
    title: str,
    body: str,
    data: Optional[dict] = None,
) -> None:
    """
    جدولة إرسال Push في الخلفية.
    لا يوقف تنفيذ الكود المُستدعي.
    """
    try:
        loop = asyncio.get_running_loop()
        loop.create_task(
            send_push_to_user(
                user_uid=user_uid,
                company_code=company_code,
                title=title,
                body=body,
                data=data,
            )
        )
    except RuntimeError:
        # لا يوجد event loop (نادر جداً) — تجاهل
        pass
    except Exception as exc:
        print(f"⚠️ Could not schedule push for {user_uid}: {exc}")