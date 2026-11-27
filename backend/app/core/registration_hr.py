# backend/app/core/registration_hr.py
"""Registration may bind an unowned HR record, never steal another identity."""
from fastapi import HTTPException
from sqlalchemy import select
from app.core.models import Company, Employee


# يتأكد إن موظف الموارد البشرية مش مربوط بحساب تاني قبل ربطه
def require_hr_owner(employee, uid, email):
    old_uid = str(employee.user_uid or '').strip()
    old_email = str(employee.user_email or '').strip().lower()
    if (old_uid and old_uid != uid) or (old_email and old_email != email):
        raise HTTPException(status_code=409, detail='الموظف مرتبط بحساب آخر. راجع الإدارة قبل إكمال التسجيل')


# يربط حساب مسجّل جديد بسجل الموظف بعد قفل الشركة لمنع التسابق
async def link_registration_employee(session, *, company_code, employee_code, uid, email, invited_phone='', assigned_employee_code=''):
    # Company-first lock matches HR creation and serializes competing claims.
    company = await session.scalar(select(Company).where(Company.code == company_code).with_for_update())
    if company is None or not company.is_active:
        raise HTTPException(status_code=403, detail='الشركة غير متاحة')
    employee = await session.scalar(select(Employee).where(
        Employee.company_code == company_code, Employee.code == employee_code,
        Employee.is_deleted.is_(False)).with_for_update())
    if employee is None:
        raise HTTPException(status_code=404, detail='كود الموظف غير موجود في الشركة')
    require_hr_owner(employee, uid, email)
    if not (str(employee.user_uid or '') == uid
            or str(employee.user_email or '').strip().lower() == email
            or str(employee.email or '').strip().lower() == email
            or (invited_phone and str(employee.phone or '').strip() == invited_phone)
            or (assigned_employee_code and employee.code == assigned_employee_code)):
        raise HTTPException(status_code=403, detail='كود الموظف غير مرتبط ببيانات دعوتك. راجع الإدارة')
    employee.user_uid, employee.user_email = uid, email
    await session.commit()
    return {'code': employee.code, 'name': employee.name, 'linked': True,
            'branch_code': employee.branch_code or ''}
