# backend/app/core/notification_events.py

import os
import uuid
import time
from datetime import datetime
from typing import Any, Dict, Optional

from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.core.firebase_setup import db as firebase_db
from app.core.models import AuditLog, Notification, NotificationPreference, Employee
from app.core.request_context import current_user_context
from app.core.fcm_service import send_push_to_user_bg


# ============================================================
# ⭐ SUPER_ADMIN_EMAILS (من .env)
# ============================================================
SUPER_ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.getenv("SUPER_ADMIN_EMAILS", "").split(",")
    if e.strip()
}

_JOB_CODE_TO_ROLE = {
    "99": "super_admin",
    "201": "admin",
    "200": "employee",
    "1": "employee",
}


def _effective_role(profile: Dict[str, Any]) -> str:
    """نفس المنطق في auth_middleware."""
    email = str(profile.get("email", "")).strip().lower()
    if email and email in SUPER_ADMIN_EMAILS:
        return "super_admin"
    role = str(profile.get("role", "")).strip()
    if role in ("super_admin", "admin", "employee"):
        return role
    job_code = str(profile.get("job_code", "1"))
    return _JOB_CODE_TO_ROLE.get(job_code, "employee")


# ============================================================
# Section Map
# ============================================================

_SECTION_MAP = {
    "transaction": ("daily", "اليوميات"),
    "supplier": ("purchases", "المشتريات والموردين"),
    "settlement": ("settlements", "التسويات"),
    "coding": ("coding", "التكويد"),
    "inventory": ("inventory", "الجرد"),
    "sale": ("sales", "المبيعات"),
    "sale_return": ("sales_returns", "مرتجعات المبيعات"),
    "customer_payment": ("customer_payments", "تحصيلات العملاء"),
    "stock_transfer": ("stock_transfers", "التحويلات المخزنية"),
    # ✅ HR
    "hr_attendance": ("hr_attendance", "حضور الموارد البشرية"),
    "hr_vacation": ("hr_vacations", "إجازات الموارد البشرية"),
    "hr_adjustment": ("hr_adjustments", "تسويات الموارد البشرية"),
    "hr_employee_settings": ("hr_employees", "إعدادات الموظفين"),
    "employee": ("hr_employees", "بيانات الموظفين"),
}

_ACTION_NAMES = {"add": "إضافة", "edit": "تعديل", "delete": "حذف"}
_RECIPIENT_CACHE: Dict[str, tuple[float, list[dict]]] = {}
_RECIPIENT_CACHE_SECONDS = 20


def _action_name(action: str, data: Dict[str, Any]) -> str:
    action = (action or "update").lower()
    if data.get("is_deleted") is True or action in {"delete", "remove"}:
        return "delete"
    if action in {"insert", "create", "add"}:
        return "add"
    return "edit"


def _company_recipients(company_code: str) -> list[dict]:
    now = time.monotonic()
    cached = _RECIPIENT_CACHE.get(company_code)
    if cached and now - cached[0] < _RECIPIENT_CACHE_SECONDS:
        return cached[1]
    users = []
    if firebase_db is not None:
        for user_doc in firebase_db.collection("users").where(
            "company_code", "==", str(company_code)
        ).stream():
            profile = user_doc.to_dict() or {}
            profile["uid"] = str(profile.get("uid", ""))
            profile["email"] = str(profile.get("email", user_doc.id)).strip().lower()
            if profile["uid"]:
                users.append(profile)
    _RECIPIENT_CACHE[company_code] = (now, users)
    return users


def _branch_allowed(profile: Dict[str, Any], branch_code: str) -> bool:
    """⭐ يستخدم role بدل job_code."""
    role = _effective_role(profile)
    if role in ("super_admin", "admin"):
        return True
    allowed = profile.get("allowed_branches", ["all"])
    if not branch_code or not allowed or allowed == "all":
        return True
    if isinstance(allowed, str):
        return allowed.lower() == "all" or allowed == branch_code
    return (
        "all" in [str(value).lower() for value in allowed]
        or branch_code in [str(value) for value in allowed]
    )


_HR_SECTION_KEYS = {
    "hr_attendance": ("canOpenAttendancePage",),
    "hr_vacations": ("canOpenVacationsPage",),
    "hr_adjustments": ("canViewAdjustments",),
    "hr_employees": ("canViewEmployees", "canViewOwnHRData"),
}


def _can_view_section(profile: Dict[str, Any], section: str) -> bool:
    """
    ⭐ يستخدم role بدل job_code.
    
    - super_admin: كل شيء (بما فيهم registration_requests)
    - admin: كل شيء (ما عدا registration_requests)
    - employee: حسب permissions
    """
    role = _effective_role(profile)

    # ⭐ طلبات الانضمام — super_admin فقط
    if section == "registration_requests":
        return role == "super_admin"

    # super_admin + admin يشوفوا كل شيء
    if role in ("super_admin", "admin"):
        return True

    permissions = profile.get("permissions")
    if not isinstance(permissions, dict) or not permissions:
        return True

    global_permissions = permissions.get("صلاحيات عامة", {})
    if isinstance(global_permissions, dict):
        if global_permissions.get("إظهار الإشعارات") is False:
            return False

    # HR
    if section in _HR_SECTION_KEYS:
        if isinstance(global_permissions, dict):
            if global_permissions.get("إظهار الموارد البشرية") is False:
                return False
        hr_perms = permissions.get("الموارد البشرية", {})
        if not isinstance(hr_perms, dict):
            return True
        for key in _HR_SECTION_KEYS[section]:
            if bool(hr_perms.get(key, False)):
                return True
        return False

    # Sections عادية
    category, key, fallback_keys = {
        "daily": ("حركة الخزينة", "المعاينة", ("ادخال اذون", "إظهار حركة الخزينة")),
        "purchases": ("حركة الموردين", "المعاينة", ("معاينة", "إظهار حركة الموردين")),
        "settlements": ("تسويات الموردين", "معاينة", ("المعاينة", "إظهار التسويات")),
        "coding": ("التكويد", "معاينة", ("المعاينة", "إظهار التكويد")),
        "inventory": ("حركة الجرد", "المعاينة", ("معاينة", "إظهار حركة الجرد")),
        "sales": ("المبيعات", "معاينة", ("إضافة",)),
        "sales_returns": ("المرتجعات", "معاينة", ("إضافة",)),
        "customer_payments": ("حسابات العملاء", "معاينة", ("إضافة تحصيل",)),
        "stock_transfers": ("التحويلات المخزنية", "معاينة", ("إضافة",)),
    }.get(section, ("", "", ()))

    global_key = {
        "daily": "إظهار حركة الخزينة",
        "purchases": "إظهار حركة الموردين",
        "settlements": "إظهار التسويات",
        "coding": "إظهار التكويد",
        "inventory": "إظهار حركة الجرد",
    }.get(section)

    if (
        isinstance(global_permissions, dict)
        and global_key in global_permissions
        and not bool(global_permissions[global_key])
    ):
        return False

    section_permissions = permissions.get(category)
    if not isinstance(section_permissions, dict):
        return True
    keys = (key,) + fallback_keys
    explicit = [bool(section_permissions[k]) for k in keys if k in section_permissions]
    return any(explicit) if explicit else True


def _preference_enabled(
    pref: Optional[NotificationPreference], section: str, action: str
) -> bool:
    commercial_sections = {"sales", "sales_returns", "customer_payments", "stock_transfers"}
    default_enabled = section not in commercial_sections
    if pref is None:
        return default_enabled
    sections = pref.sections if isinstance(pref.sections, dict) else {}
    actions = pref.actions if isinstance(pref.actions, dict) else {}
    return (
        sections.get(section, default_enabled) is not False
        and actions.get(action, True) is not False
    )


# ============================================================
# إثراء HR payload باسم الموظف
# ============================================================

async def _enrich_hr_payload(
    company_code: str,
    data: Dict[str, Any],
) -> Dict[str, Any]:
    if not company_code:
        return data

    employee_code = data.get("employee_code")
    if employee_code and not data.get("employee_name"):
        try:
            async with AsyncSessionLocal() as session:
                result = await session.execute(
                    select(Employee.name).where(
                        Employee.company_code == str(company_code),
                        Employee.code == str(employee_code),
                        Employee.is_deleted.is_(False),
                    )
                )
                name = result.scalar_one_or_none()
                if name:
                    data["employee_name"] = str(name)
        except Exception as exc:
            print(f"⚠️ employee lookup failed | code={employee_code} | {exc}")

    return data


def _summary(data: Dict[str, Any]) -> str:
    parts = []
    for key, label in (
        ("name", "الاسم"),
        ("employee_name", "الموظف"),
        ("supplier_name", "المورد"),
        ("statement", "البيان"),
        ("category", "التصنيف"),
        ("serial", "رقم الحركة"),
        ("code", "الكود"),
        ("store_code", "المخزن"),
        ("date", "التاريخ"),
        ("month", "الشهر"),
    ):
        value = data.get(key)
        if value is not None and str(value).strip():
            parts.append(f"{label}: {value}")
        if len(parts) >= 2:
            break
    return " • ".join(parts)


async def prepare_and_persist_event(company_code: str, message: dict) -> dict:
    event_type = str(message.get("type", ""))
    if event_type not in _SECTION_MAP:
        return message
    payload = message.get("data") if isinstance(message.get("data"), dict) else {}
    event_id = str(message.get("event_id") or uuid.uuid4())
    message["event_id"] = event_id
    section, section_title = _SECTION_MAP[event_type]
    action = _action_name(str(message.get("action", "update")), payload)
    context = current_user_context.get() or {}
    actor_uid = str(context.get("uid", ""))
    actor_email = str(context.get("email", ""))
    actor_name = str(
        context.get("name", "")
        or payload.get("employee")
        or payload.get("userName")
        or payload.get("created_by")
        or payload.get("updated_by")
        or "مستخدم"
    )
    message["actor_uid"] = actor_uid
    message["actor_name"] = actor_name
    payload["actor_uid"] = actor_uid
    payload["actor_name"] = actor_name

    # ⭐ إثراء HR payload باسم الموظف
    payload = await _enrich_hr_payload(str(company_code), payload)
    message["data"] = payload

    branch_code = str(payload.get("branch_code", "") or "")
    entity_id = str(
        payload.get("id")
        or payload.get("doc_id")
        or payload.get("serial")
        or payload.get("code")
        or ""
    )
    body = _summary(payload)
    title = f"{_ACTION_NAMES[action]} في {section_title}"
    now = datetime.utcnow()

    push_targets: list[dict] = []

    async with AsyncSessionLocal() as session:
        try:
            preferences_result = await session.execute(
                select(NotificationPreference).where(
                    NotificationPreference.company_code == str(company_code)
                )
            )
            preferences = {row.user_uid: row for row in preferences_result.scalars().all()}

            session.add(AuditLog(
                event_id=event_id,
                company_code=str(company_code),
                branch_code=branch_code,
                actor_uid=actor_uid,
                actor_email=actor_email,
                actor_name=actor_name,
                section=section,
                action=action,
                entity_id=entity_id,
                details={
                    key: payload.get(key)
                    for key in (
                        "serial", "code", "name", "supplier_name",
                        "category", "amount", "is_deleted",
                        "employee_code", "date", "month",
                    )
                    if payload.get(key) is not None
                },
                created_at=now,
            ))

            if firebase_db is not None:
                for profile in _company_recipients(str(company_code)):
                    recipient_uid = str(profile.get("uid", ""))
                    recipient_email = str(profile.get("email", "")).strip().lower()
                    if not recipient_uid:
                        continue
                    if not _branch_allowed(profile, branch_code) or not _can_view_section(profile, section):
                        continue
                    pref = preferences.get(recipient_uid)
                    if not _preference_enabled(pref, section, action):
                        continue

                    session.add(Notification(
                        event_id=event_id,
                        recipient_uid=recipient_uid,
                        recipient_email=recipient_email,
                        company_code=str(company_code),
                        branch_code=branch_code,
                        section=section,
                        action=action,
                        actor_uid=actor_uid,
                        actor_name=actor_name,
                        title=title,
                        body=body,
                        entity_id=entity_id,
                        created_at=now,
                        is_read=recipient_uid == actor_uid,
                        read_at=now if recipient_uid == actor_uid else None,
                    ))

                    if recipient_uid != actor_uid:
                        push_targets.append({
                            "user_uid": recipient_uid,
                            "company_code": str(company_code),
                            "title": title,
                            "body": body,
                            "data": {
                                "type": event_type,
                                "section": section,
                                "action": action,
                                "event_id": event_id,
                            },
                        })

            await session.commit()
        except Exception as exc:
            await session.rollback()
            print(f"⚠️ تعذر حفظ الإشعار/سجل التدقيق في Neon | company={company_code} | error={exc}")
            push_targets = []

    for target in push_targets:
        try:
            send_push_to_user_bg(**target)
        except Exception as _e:
            print(f"⚠️ Failed to schedule push: {_e}")

    return message
