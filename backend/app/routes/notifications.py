import time
from datetime import datetime, timedelta
from typing import Any, Dict

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.models import Notification, NotificationPreference
from app.core.notification_events import _branch_allowed, _can_view_section

router = APIRouter()
_SECTIONS = {"daily", "purchases", "settlements", "coding", "inventory"}
_ACTIONS = {"add", "edit", "delete"}
_RETENTION = {0, 30, 90, 365}

# ✅ تنظيف الإشعارات القديمة مرة كل 24 ساعة لكل (uid, company_code)
_CLEANUP_CACHE: Dict[tuple[str, str], float] = {}
_CLEANUP_INTERVAL_SECONDS = 24 * 60 * 60  # 24 ساعة


def _should_cleanup(uid: str, company_code: str) -> bool:
    """
    يحدد إذا كان لازم ينفذ DELETE للإشعارات القديمة.
    مرة واحدة كل 24 ساعة لكل (uid, company_code).
    في الذاكرة فقط — بيتصفّر عند إعادة تشغيل السيرفر (وده مقبول).
    """
    key = (uid, company_code)
    now = time.time()
    last = _CLEANUP_CACHE.get(key, 0.0)
    if now - last >= _CLEANUP_INTERVAL_SECONDS:
        _CLEANUP_CACHE[key] = now
        return True
    return False


def _profile(request: Request) -> Dict[str, Any]:
    profile = getattr(request.state, "auth_user", None)
    if not isinstance(profile, dict) or not profile.get("uid"):
        raise HTTPException(status_code=401, detail="يجب تسجيل الدخول")
    return profile


def _settings_json(pref: NotificationPreference | None) -> dict:
    return {
        "sections": pref.sections if pref and isinstance(pref.sections, dict) else {key: True for key in _SECTIONS},
        "actions": pref.actions if pref and isinstance(pref.actions, dict) else {key: True for key in _ACTIONS},
        "retention_days": int(pref.retention_days) if pref else 90,
    }


@router.get("")
async def list_notifications(
    request: Request,
    limit: int = Query(100, ge=1, le=200),
    after_id: int | None = Query(None, ge=0),
    unread_only: bool = Query(False),
    db: AsyncSession = Depends(get_db),
):
    profile = _profile(request)
    pref_result = await db.execute(select(NotificationPreference).where(
        NotificationPreference.user_uid == str(profile["uid"]),
        NotificationPreference.company_code == str(profile["company_code"]),
    ))
    pref = pref_result.scalar_one_or_none()
    retention_days = int(pref.retention_days) if pref else 90

    # ✅ تنظيف كل 24 ساعة فقط (مش في كل طلب)
    if retention_days > 0 and _should_cleanup(
        str(profile["uid"]),
        str(profile["company_code"]),
    ):
        await db.execute(delete(Notification).where(
            Notification.recipient_uid == str(profile["uid"]),
            Notification.company_code == str(profile["company_code"]),
            Notification.created_at < datetime.utcnow() - timedelta(days=retention_days),
        ))
        await db.commit()

    stmt = select(Notification).where(
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
    )
    if unread_only:
        stmt = stmt.where(Notification.is_read.is_(False))
    if after_id is not None and not unread_only:
        stmt = stmt.where(Notification.id > after_id).order_by(Notification.id.asc()).limit(limit)
    else:
        # أول تحميل فقط: آخر الإشعارات، وبعدها يستخدم العميل after_id للمزامنة التزايدية.
        stmt = stmt.order_by(Notification.created_at.desc(), Notification.id.desc()).limit(limit)

    result = await db.execute(stmt)
    rows = result.scalars().all()
    items = []
    for item in rows:
        if not _branch_allowed(profile, item.branch_code) or not _can_view_section(profile, item.section):
            continue
        items.append({
            "id": item.id,
            "event_id": item.event_id,
            "title": item.title,
            "body": item.body,
            "section": item.section,
            "action": item.action,
            "company_code": item.company_code,
            "branch_code": item.branch_code,
            "actor_uid": item.actor_uid,
            "actor_name": item.actor_name,
            "entity_id": item.entity_id,
            "created_at": item.created_at.isoformat() if item.created_at else None,
            "read": bool(item.is_read),
        })

    # المؤشر مبني على كل الصفوف التي تم فحصها، حتى لو استبعدتها صلاحيات الفرع/القسم.
    next_cursor = max((item.id for item in rows), default=after_id or 0)
    return {
        "items": items,
        "unread_count": sum(1 for item in items if not item["read"]),
        "next_cursor": next_cursor,
        "has_more": after_id is not None and len(rows) == limit,
    }


@router.get("/settings")
async def get_notification_settings(request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    result = await db.execute(select(NotificationPreference).where(
        NotificationPreference.user_uid == str(profile["uid"]),
        NotificationPreference.company_code == str(profile["company_code"]),
    ))
    return _settings_json(result.scalar_one_or_none())


@router.put("/settings")
async def save_notification_settings(
    request: Request,
    data: dict = Body(...),
    db: AsyncSession = Depends(get_db),
):
    profile = _profile(request)
    sections = data.get("sections", {})
    actions = data.get("actions", {})
    retention_days = data.get("retention_days", 90)
    if not isinstance(sections, dict) or not isinstance(actions, dict):
        raise HTTPException(status_code=400, detail="صيغة إعدادات الإشعارات غير صحيحة")
    if not isinstance(retention_days, int) or retention_days not in _RETENTION:
        raise HTTPException(status_code=400, detail="مدة الاحتفاظ غير صحيحة")
    sections = {key: bool(sections.get(key, True)) for key in _SECTIONS}
    actions = {key: bool(actions.get(key, True)) for key in _ACTIONS}
    result = await db.execute(select(NotificationPreference).where(
        NotificationPreference.user_uid == str(profile["uid"]),
        NotificationPreference.company_code == str(profile["company_code"]),
    ))
    pref = result.scalar_one_or_none()
    if pref is None:
        pref = NotificationPreference(
            user_uid=str(profile["uid"]), user_email=str(profile["email"]),
            company_code=str(profile["company_code"]), sections=sections,
            actions=actions, retention_days=retention_days,
        )
        db.add(pref)
    else:
        pref.user_email = str(profile["email"])
        pref.sections = sections
        pref.actions = actions
        pref.retention_days = retention_days
        pref.updated_at = datetime.utcnow()
    await db.commit()
    if retention_days > 0:
        await db.execute(delete(Notification).where(
            Notification.recipient_uid == str(profile["uid"]),
            Notification.company_code == str(profile["company_code"]),
            Notification.created_at < datetime.utcnow() - timedelta(days=retention_days),
        ))
        await db.commit()
        # ✅ بعد تنظيف يدوي في الإعدادات، نصفّر الـ cache
        # حتى لا يتنفذ DELETE تاني في أول طلب /notifications بعد كده
        _CLEANUP_CACHE.pop(
            (str(profile["uid"]), str(profile["company_code"])),
            None,
        )
    return {"status": "success", **_settings_json(pref)}


@router.post("/read-all")
async def mark_all_read(request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    result = await db.execute(select(Notification).where(
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
        Notification.is_read.is_(False),
    ))
    now = datetime.utcnow()
    for item in result.scalars().all():
        item.is_read = True
        item.read_at = now
    await db.commit()
    return {"status": "success"}


@router.post("/event/{event_id}/read")
async def mark_event_read(event_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    result = await db.execute(select(Notification).where(
        Notification.event_id == event_id,
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
    ))
    now = datetime.utcnow()
    for item in result.scalars().all():
        item.is_read = True
        item.read_at = now
    await db.commit()
    return {"status": "success"}


@router.post("/{notification_id}/read")
async def mark_read(notification_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    result = await db.execute(select(Notification).where(
        Notification.id == notification_id,
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
    ))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="الإشعار غير موجود")
    item.is_read = True
    item.read_at = datetime.utcnow()
    await db.commit()
    return {"status": "success"}


@router.delete("")
async def clear_notifications(request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    await db.execute(delete(Notification).where(
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
    ))
    await db.commit()
    return {"status": "success"}


@router.delete("/{notification_id}")
async def delete_notification(notification_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    profile = _profile(request)
    result = await db.execute(select(Notification).where(
        Notification.id == notification_id,
        Notification.recipient_uid == str(profile["uid"]),
        Notification.company_code == str(profile["company_code"]),
    ))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="الإشعار غير موجود")
    await db.delete(item)
    await db.commit()
    return {"status": "success"}