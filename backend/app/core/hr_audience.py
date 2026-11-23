"""Employee-target checks shared by HR reads and notification delivery.

Explicit own-HR access survives broader branch/list exclusions for the linked
record only. Other records still require the existing section and scope grants.
"""
from app.core.hr_identity import HRTarget

from sqlalchemy import select

from app.core.models import Employee
from app.core.permissions import has_section_permission

HR_EVENTS = frozenset({'employee', 'hr_employee_settings', 'hr_attendance', 'hr_vacation', 'hr_adjustment'})
HR_SECTIONS = frozenset({'hr_employees', 'hr_attendance', 'hr_vacations', 'hr_adjustments'})
HR_VIEW_KEYS = (
    'canViewEmployees', 'canManageEmployees', 'canOpenAttendancePage',
    'canOpenVacationsPage', 'canViewAdjustments', 'canViewBranchSalaryReport',
)


def own_only(profile: dict) -> bool:
    return (
        has_section_permission(profile, 'الموارد البشرية', 'canViewOwnHRData')
        and not any(has_section_permission(profile, 'الموارد البشرية', key) for key in HR_VIEW_KEYS)
    )


def own_access(profile: dict, target: HRTarget | None) -> bool:
    return bool(target is not None and target.code and target.is_self(profile) and
        has_section_permission(profile, 'الموارد البشرية', 'canViewOwnHRData'))


def amounts_allowed(profile: dict, target: HRTarget | None) -> bool:
    return own_access(profile,target) or has_section_permission(profile,'الموارد البشرية','canViewSalaryAmounts')


def target_allowed(profile: dict, target: HRTarget) -> bool:
    if own_access(profile,target):
        return True
    if own_only(profile):
        return False
    viewable = profile.get('hr_viewable_employees')
    if isinstance(viewable, list) and viewable:
        return bool(target.code) and target.code in {str(code) for code in viewable}
    return True


def _from_employee(row) -> HRTarget:
    return HRTarget.from_employee(row)


async def targets_for_codes(db, company: str, codes) -> dict[str, HRTarget]:
    wanted = {str(code) for code in codes if str(code)}
    if not wanted:
        return {}
    result = await db.execute(select(Employee).where(
        Employee.company_code == str(company), Employee.code.in_(wanted),
    ))
    found = {_from_employee(row).code: _from_employee(row) for row in result.scalars().all()}
    return {code: found.get(code, HRTarget(code=code)) for code in wanted}


async def message_target(db, company: str, event_type: str, payload: dict) -> HRTarget | None:
    if event_type not in HR_EVENTS:
        return None
    if event_type == 'employee':
        # This is the server serializer's post-commit employee record, including
        # its explicit account link. No link is inferred from a name/phone.
        return HRTarget(
            code=str(payload.get('code', '') or ''),
            uid=str(payload.get('user_uid', '') or ''),
            email=str(payload.get('user_email', '') or ''),
            name=str(payload.get('name', '') or ''),
            deleted=payload.get('is_deleted') is True,
        )
    code = str(payload.get('employee_code', '') or '')
    targets = await targets_for_codes(db, company, [code])
    return targets.get(code, HRTarget())


def stored_target_code(details: dict) -> str:
    if not isinstance(details, dict):
        return ''
    explicit = details.get('hr_employee_code')
    if explicit is not None:
        return str(explicit)
    # Historical audit payloads have canonical code fields, unlike the generic
    # entity_id or free-form notification body. Disagreement is unresolved.
    candidates = {str(details[key]) for key in ('employee_code', 'code')
                  if details.get(key) is not None and str(details[key])}
    return next(iter(candidates)) if len(candidates) == 1 else ''
