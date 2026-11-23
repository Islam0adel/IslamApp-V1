# backend/app/core/fcm_service.py

"""
خدمة إرسال إشعارات FCM (Firebase Cloud Messaging).

المبادئ:
- تبعث فقط إلى من مرّوا فحوصات الصلاحيات والتفضيلات في notification_events.py
- Fire-and-forget (لا تعطل الويب سوكيت)
- تحذف فقط الرموز المؤكد انتهاء تسجيلها، لا رموز أخطاء الشبكة أو الحصة
"""

import asyncio
from dataclasses import dataclass
from typing import Optional, Callable, Awaitable

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

@dataclass(frozen=True)
class FcmSendResult:
    invalid_tokens: tuple[str, ...] = ()
    success_count: int = 0


def _send_sync(
    tokens: list[str],
    title: str,
    body: str,
    data: Optional[dict] = None,
) -> FcmSendResult:
    """Report confirmed successes and expired devices separately.

    Network, quota, payload and sender-configuration failures do not establish
    that a stored device token is invalid.
    """
    if not is_fcm_enabled() or not tokens:
        return FcmSendResult()

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

    invalid_tokens: list[str] = []
    success_count = 0
    try:
        # استخدم send_each_for_multicast لو موجود، وإلا send_multicast (للإصدارات القديمة)
        if hasattr(_fb_messaging, "send_each_for_multicast"):
            response = _fb_messaging.send_each_for_multicast(message)
        else:
            response = _fb_messaging.send_multicast(message)

        responses = list(response.responses)
        if len(responses) != len(tokens):
            print('⚠️ FCM response/device count mismatch; no devices removed')
            return FcmSendResult()
        expired_type = getattr(_fb_messaging, 'UnregisteredError', None)
        for idx, resp in enumerate(responses):
            if resp.success is True:
                success_count += 1
            else:
                error = resp.exception
                if isinstance(expired_type, type) and isinstance(error, expired_type):
                    invalid_tokens.append(tokens[idx])
                print(f'⚠️ FCM send failed | device_index={idx} | kind={type(error).__name__}')
    except Exception as exc:
        print(f'❌ FCM multicast error | kind={type(exc).__name__}')
        return FcmSendResult()

    return FcmSendResult(tuple(invalid_tokens), success_count)


# ============================================================
# 3. الإرسال غير المتزامن (async)
# ============================================================

async def send_push_to_user(
    user_uid: str,
    company_code: str,
    title: str,
    body: str,
    data: Optional[dict] = None,
    authorization_check: Optional[Callable[[list[str]], Awaitable[bool]]] = None,
) -> None:
    """
    إرسال إشعار Push لمستخدم معين (كل أجهزته).
    آمن للاستدعاء من background tasks.
    """
    if not is_fcm_enabled() or authorization_check is None:
        return

    try:
        tokens = await get_user_tokens(user_uid, company_code)
        if not tokens:
            return

        if not await authorization_check(tokens):
            return
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            None, _send_sync, tokens, title, body, data
        )

        if result.invalid_tokens:
            await delete_tokens(list(result.invalid_tokens))

        success = result.success_count
        if success > 0:
            print(
                f"📤 FCM sent | user={user_uid} | "
                f"devices={success}/{len(tokens)}"
            )
    except Exception as exc:
        print(f"❌ send_push_to_user failed | user={user_uid} | kind={type(exc).__name__}")


# ============================================================
# 4. Fire-and-forget scheduling
# ============================================================

def send_push_to_user_bg(
    user_uid: str,
    company_code: str,
    title: str,
    body: str,
    data: Optional[dict] = None,
    authorization_check: Optional[Callable[[list[str]], Awaitable[bool]]] = None,
) -> asyncio.Task | None:
    """
    جدولة إرسال Push في الخلفية.
    لا يوقف تنفيذ الكود المُستدعي.
    """
    try:
        loop = asyncio.get_running_loop()
        return loop.create_task(
            send_push_to_user(
                user_uid=user_uid,
                company_code=company_code,
                title=title,
                body=body,
                data=data,
                authorization_check=authorization_check,
            )
        )
    except RuntimeError:
        # لا يوجد event loop (نادر جداً) — تجاهل
        pass
    except Exception as exc:
        print(f"⚠️ Could not schedule push | user={user_uid} | kind={type(exc).__name__}")