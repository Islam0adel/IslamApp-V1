from app.core.auth_middleware import can_bypass_permissions
# backend/app/core/notification_events.py

import os
import uuid
import time
from functools import partial
from datetime import datetime
from typing import Any, Dict, Optional

from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.core.firebase_setup import db as firebase_db
from app.core.models import AuditLog, Notification, NotificationPreference, Employee, Company, UserFcmToken
from app.core.request_context import current_user_context
from app.core.fcm_service import send_push_to_user_bg
from app.core.branch_scope import active_operating_branches, InvalidOperatingBranchScope
from app.core.company_policy_store import active_policy_configuration, effective_policy_profile


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
    "treasury_transfer": ("treasury_transfers", "تحويلات الخزائن"),
    "treasury_balance_changed": ("treasury_effects", "أرصدة الخزائن"),
    # ✅ HR
    "hr_attendance": ("hr_attendance", "حضور الموارد البشرية"),
    "hr_vacation": ("hr_vacations", "إجازات الموارد البشرية"),
    "hr_adjustment": ("hr_adjustments", "تسويات الموارد البشرية"),
    "hr_employee_settings": ("hr_employees", "إعدادات الموظفين"),
    "employee": ("hr_employees", "بيانات الموظفين"),
}

from app.core.hr_audience import HR_EVENTS, HRTarget, message_target, target_allowed, targets_for_codes, own_access

_ACTION_NAMES = {"add": "إضافة", "edit": "تعديل", "delete": "حذف"}
_RECIPIENT_CACHE: Dict[str, tuple[float, list[dict]]] = {}
_RECIPIENT_CACHE_SECONDS = 20
_RECIPIENT_EPOCH: Dict[str, int] = {}


def company_recipient_epoch(company_code: str) -> int:
    return _RECIPIENT_EPOCH.get(str(company_code), 0)


def invalidate_company_recipients(company_code: str) -> None:
    """Invalidate this process's recipient snapshot after an account mutation."""
    company = str(company_code)
    _RECIPIENT_CACHE.pop(company, None)
    _RECIPIENT_EPOCH[company] = _RECIPIENT_EPOCH.get(company, 0) + 1


def _action_name(action: str, data: Dict[str, Any]) -> str:
    action = (action or "update").lower()
    if data.get("is_deleted") is True or action in {"delete", "remove"}:
        return "delete"
    if action in {"insert", "create", "add"}:
        return "add"
    return "edit"


def _company_recipients(company_code: str, *, force_refresh: bool = False) -> list[dict]:
    now = time.monotonic()
    cached = _RECIPIENT_CACHE.get(company_code)
    if not force_refresh and cached and now - cached[0] < _RECIPIENT_CACHE_SECONDS:
        return cached[1]
    users = []
    if firebase_db is not None:
        for user_doc in firebase_db.collection("users").where(
            "company_code", "==", str(company_code)
        ).stream():
            profile = user_doc.to_dict() or {}
            profile["uid"] = str(profile.get("uid", ""))
            profile["email"] = str(user_doc.id).strip().lower()
            if (profile["uid"] and str(profile.get("company_code", "")) == str(company_code)
                    and profile.get("is_active") is not False
                    and str(profile.get("status", "active")).lower()
                    not in ("pending", "suspended")):
                users.append(profile)
    _RECIPIENT_CACHE[company_code] = (now, users)
    return users


async def _effective_company_recipients(session, company_code: str) -> list[dict]:
    # Reading recipient scope must not flush a caller's queued audit rows.
    with session.no_autoflush:
        configuration, revision = await active_policy_configuration(session, str(company_code))
        if configuration is not None:
            active = await session.scalar(select(Company.is_active).where(Company.code == str(company_code)))
            if active is not True:
                return []
    profiles = _company_recipients(str(company_code), force_refresh=configuration is not None)
    result = []
    for profile in profiles:
        role = _effective_role(profile)
        try:
            effective = effective_policy_profile(profile, configuration if role != 'super_admin' else None,
                revision if role != 'super_admin' else None, role=role)
        except InvalidOperatingBranchScope:
            # One malformed account must neither get company-wide delivery nor
            # prevent correctly scoped coworkers from receiving their updates.
            continue
        effective['role'] = role
        result.append(effective)
    return result


def _quiet_push_allowed_for(recipient_email: str) -> bool:
    """Quiet data-update pushes are on for everyone (decided by the owner, no env var needed)."""
    return True


async def current_push_allowed(tokens: list[str], *, user_uid: str, company_code: str, recipient_email: str,
        section: str, action: str, branch_code: str = '', hr_target=None, require_active_policy: bool = False,
        quiet: bool = False) -> bool:
    """Execution-time check, called after token lookup, not at queue creation.

    SQL state/preferences/HR identity and the exact source account are checked.
    No failure is a reason to reuse the queue's old permission snapshot.
    """
    epoch = company_recipient_epoch(company_code)
    try:
        async with AsyncSessionLocal() as session:
            configuration, revision = await active_policy_configuration(session, str(company_code))
            if require_active_policy and configuration is None:
                return False
            company_active = await session.scalar(select(Company.is_active).where(Company.code == str(company_code)))
            pref = await session.scalar(select(NotificationPreference).where(
                NotificationPreference.company_code == str(company_code),
                NotificationPreference.user_uid == str(user_uid)))
            preference_allowed = _preference_enabled(pref, section, action)
            current_tokens = set((await session.scalars(select(UserFcmToken.fcm_token).where(
                UserFcmToken.company_code == str(company_code), UserFcmToken.user_uid == str(user_uid),
                UserFcmToken.fcm_token.in_(tokens)))).all())
            if not tokens or current_tokens != set(tokens):
                return False
            if hr_target is not None:
                targets = await targets_for_codes(session, str(company_code), [hr_target.code])
                if targets.get(hr_target.code) != hr_target:
                    return False
        # quiet=True: a data-update push for a recipient whose notification preference is off. The
        # preference only controls the visible alert, not whether staged data may be prepared; every
        # other check below (account, company, rights, branch, policy) still applies.
        if not (preference_allowed or quiet) or firebase_db is None:
            return False
        email = str(recipient_email).strip().lower()
        document = firebase_db.collection('users').document(email).get()
        if not document.exists:
            return False
        profile = document.to_dict() or {}
        source_company = str(profile.get('company_code', '') or '')
        if section == 'registration_requests':
            source_company = source_company or '01'
        if (str(profile.get('uid', '')) != str(user_uid) or source_company != str(company_code)
                or profile.get('is_active') is False
                or str(profile.get('status', 'active')).lower() in ('suspended', 'pending')):
            return False
        profile['email'] = email
        profile['company_code'] = source_company
        role = _effective_role(profile)
        if role != 'super_admin' and company_active is not True:
            return False
        profile = effective_policy_profile(profile, configuration if role != 'super_admin' else None,
            revision if role != 'super_admin' else None, role=role)
        profile['role'] = role
        if epoch != company_recipient_epoch(company_code):
            return False
        if section == 'registration_requests':
            return role == 'super_admin'
        return recipient_allowed(profile, section, branch_code, hr_target)
    except Exception as exc:
        print(f'⚠️ Push authorization unavailable | company={company_code} | kind={type(exc).__name__}')
        return False


def _branch_allowed(profile: Dict[str, Any], branch_code: str) -> bool:
    """⭐ يستخدم role بدل job_code."""
    role = _effective_role(profile)
    if can_bypass_permissions(profile):
        return True
    if profile.get('company_policy_active') is True:
        try:
            allowed = active_operating_branches(profile.get('allowed_branches'))
        except InvalidOperatingBranchScope:
            return False
    else:
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


def _can_view_section(profile: Dict[str, Any], section: str, *, data_only: bool = False) -> bool:
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
    if can_bypass_permissions(profile):
        return True

    permissions = profile.get("permissions")
    if not isinstance(permissions, dict) or not permissions:
        # قفل افتراضي: غياب بيانات الصلاحيات = لا إشعارات للموظف
        return False

    global_permissions = permissions.get("صلاحيات عامة", {})
    if profile.get('company_policy_active') is True and not data_only:
        if not isinstance(global_permissions, dict) or global_permissions.get('إظهار الإشعارات') is not True:
            return False
    if isinstance(global_permissions, dict):
        if not data_only and global_permissions.get("إظهار الإشعارات") is False:
            return False

    # HR
    if section in _HR_SECTION_KEYS:
        if not data_only and isinstance(global_permissions, dict):
            if (global_permissions.get("إظهار الموارد البشرية") is False or
                    (profile.get('company_policy_active') is True and global_permissions.get('إظهار الموارد البشرية') is not True)):
                return False
        hr_perms = permissions.get("الموارد البشرية", {})
        if not isinstance(hr_perms, dict):
            return False
        for key in _HR_SECTION_KEYS[section]:
            if hr_perms.get(key) is True:
                return True
        return False

    if section == "treasury_effects":
        from app.core.treasury_permissions import can_view_treasury_effects
        return can_view_treasury_effects(profile)

    # Sections عادية
    category, key, fallback_keys = {
        "daily": ("حركة الخزينة", "المعاينة", ("ادخال اذون",)),
        "purchases": ("حركة الموردين", "المعاينة", ("معاينة",)),
        "settlements": ("تسويات الموردين", "معاينة", ("المعاينة",)),
        "coding": ("التكويد", "معاينة", ("المعاينة",)),
        "inventory": ("حركة الجرد", "المعاينة", ("معاينة",)),
        "sales": ("المبيعات", "معاينة", ("إضافة",)),
        "sales_returns": ("المرتجعات", "معاينة", ("إضافة",)),
        "customer_payments": ("حسابات العملاء", "معاينة", ("إضافة تحصيل",)),
        "stock_transfers": ("التحويلات المخزنية", "معاينة", ("إضافة",)),
        "treasury_transfers": ("تحويلات الخزائن", "معاينة", ()),
    }.get(section, ("", "", ()))

    global_key = {
        "daily": "إظهار حركة الخزينة",
        "purchases": "إظهار حركة الموردين",
        "settlements": "إظهار التسويات",
        "coding": "إظهار التكويد",
        "inventory": "إظهار حركة الجرد",
    }.get(section)

    if (
        not data_only and isinstance(global_permissions, dict)
        and global_key in global_permissions
        and not bool(global_permissions[global_key])
    ):
        return False

    if profile.get('company_policy_active') is True and data_only and section == 'coding':
        from app.routes.coding import _CODING_VIEW_CHECKS
        from app.core.permissions import has_section_permission
        return any(has_section_permission(profile, category, key) for category, key in _CODING_VIEW_CHECKS)
    section_permissions = permissions.get(category)
    if not isinstance(section_permissions, dict):
        # قفل افتراضي: قسم غير موجود في صلاحيات الموظف = لا إشعار
        return False
    keys = (key,) + fallback_keys
    if profile.get('company_policy_active') is True:
        keys = tuple(value for value in keys if value in ('معاينة', 'المعاينة'))
    explicit = [bool(section_permissions[k]) for k in keys if k in section_permissions]
    return any(explicit) if explicit else False


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


def recipient_allowed(profile, section, branch_code, target=None):
    if own_access(profile,target):
        if can_bypass_permissions(profile):
            return True
        general=(profile.get('permissions') or {}).get('صلاحيات عامة',{})
        if profile.get('company_policy_active') is True:
            return isinstance(general, dict) and general.get('إظهار الإشعارات') is True and general.get('إظهار الموارد البشرية') is True
        return not isinstance(general,dict) or (general.get('إظهار الإشعارات') is not False and
            general.get('إظهار الموارد البشرية') is not False)
    return (_branch_allowed(profile,branch_code) and _can_view_section(profile,section) and
        (target is None or target_allowed(profile,target)))


async def prepare_and_persist_event(
    company_code: str, message: dict, *, hr_target: HRTarget | None = None,
) -> dict:
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
    if event_type in HR_EVENTS:
        if hr_target is None:
            try:
                async with AsyncSessionLocal() as target_db:
                    hr_target = await message_target(target_db, str(company_code), event_type, payload)
            except Exception as exc:
                print(f"⚠️ HR target lookup failed | company={company_code} | error={exc}")
                hr_target = HRTarget(code=str(payload.get("employee_code", "") or ""))
        if hr_target.name and not payload.get("employee_name") and event_type != "employee":
            payload["employee_name"] = hr_target.name
    else:
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
    recipient_epoch = _RECIPIENT_EPOCH.get(str(company_code), 0)

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
                    **{key: payload.get(key)
                       for key in (
                           "serial", "code", "name", "supplier_name",
                           "category", "amount", "from_treasury", "to_treasury", "is_deleted",
                           "employee_code", "date", "month",
                       ) if payload.get(key) is not None},
                    **({"hr_employee_code": hr_target.code} if hr_target is not None else {}),
                },
                created_at=now,
            ))

            if firebase_db is not None:
                recipients = await _effective_company_recipients(session, str(company_code))
                recipient_epoch = _RECIPIENT_EPOCH.get(str(company_code), 0)
                for profile in recipients:
                    recipient_uid = str(profile.get("uid", ""))
                    recipient_email = str(profile.get("email", "")).strip().lower()
                    if not recipient_uid:
                        continue
                    if not recipient_allowed(profile,section,branch_code,hr_target):
                        continue
                    pref = preferences.get(recipient_uid)
                    if not _preference_enabled(pref, section, action):
                        # Alert preference is off: no inbox row and no normal alert, but the closed-app
                        # data update still needs a push. It is sent as a generic, collapsed, silent
                        # notice (the service worker mutes it). The viewer still passed recipient_allowed.
                        # Gated: default off so old clients see no change; testers or everyone via env.
                        if recipient_uid != actor_uid and _quiet_push_allowed_for(recipient_email):
                            push_targets.append({
                                "user_uid": recipient_uid,
                                "company_code": str(company_code),
                                "title": "تحديث بيانات",
                                "body": "بيانات جديدة جاهزة في البرنامج",
                                "authorization_check": partial(current_push_allowed, user_uid=recipient_uid,
                                    company_code=str(company_code), recipient_email=recipient_email,
                                    section=section, action=action, branch_code=branch_code, hr_target=hr_target,
                                    require_active_policy=profile.get('company_policy_active') is True,
                                    quiet=True),
                                "data": {
                                    "type": event_type,
                                    "section": section,
                                    "action": action,
                                    "event_id": event_id,
                                    "quiet": "1",
                                },
                            })
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
                            "authorization_check": partial(current_push_allowed, user_uid=recipient_uid,
                                company_code=str(company_code), recipient_email=recipient_email,
                                section=section, action=action, branch_code=branch_code, hr_target=hr_target,
                                require_active_policy=profile.get('company_policy_active') is True),
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

    # A permission mutation can run while commit is awaited. Do not queue a
    # push from that now-invalid recipient snapshot. Historical server rows
    # remain subject to the notification endpoint's current access checks.
    if recipient_epoch != _RECIPIENT_EPOCH.get(str(company_code), 0):
        try:
            if hr_target is not None:
                async with AsyncSessionLocal() as target_db:
                    current_targets = await targets_for_codes(target_db, str(company_code), [hr_target.code])
                if current_targets.get(hr_target.code) != hr_target:
                    push_targets = []
            async with AsyncSessionLocal() as recheck_db:
                current_profiles = await _effective_company_recipients(recheck_db, str(company_code))
            current_recipients = {
                str(profile.get("uid", "")): profile
                for profile in current_profiles
            }
            push_targets = [
                target for target in push_targets
                if (profile := current_recipients.get(target["user_uid"]))
                and recipient_allowed(profile,section,branch_code,hr_target)
            ]
        except Exception as exc:
            print(f"⚠️ Push recipient recheck failed | company={company_code} | error={exc}")
            push_targets = []

    for target in push_targets:
        try:
            send_push_to_user_bg(**target)
        except Exception as _e:
            print(f"⚠️ Failed to schedule push: {_e}")

    return message
