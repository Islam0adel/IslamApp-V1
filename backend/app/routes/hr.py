# backend/app/routes/hr.py

"""
مسارات الموارد البشرية (HR) - موحدة
=====================================

الملف ده بيجمع كل مسارات HR في مكان واحد بنفس نمط باقي الوحدات
(زي inventory.py و supplier.py).

المسارات المتاحة:
------------------
1. ATTENDANCE       → /hr/attendance/*
2. VACATIONS        → /hr/vacations/*
3. EMPLOYEE SETTINGS → /hr/employee-settings/*
4. ADJUSTMENTS      → /hr/adjustments/*
5. REPORTS          → /hr/reports/*

كل مسار بيبث تحديث WebSocket للأجهزة المتصلة بعد أي تغيير.

الإضافات عن النسخة القديمة:
---------------------------
- GET /hr/attendance/list يقبل from_date + to_date (جلب نطاق زمني)
  بالإضافة للسلوك القديم (date= لجلب يوم واحد)
- GET /hr/employee-settings/changes (جديد - كان ناقص)
"""

from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, or_, and_

from fastapi import Request

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.models import (
    Employee,
    HRAttendance,
    HRVacation,
    HRAdjustment,
    HREmployeeSettings,
)
from app.core.schemas import (
    HRAttendanceModel,
    HRVacationModel,
    HRAdjustmentModel,
    HREmployeeSettingsModel,
)
from app.core.sync import manager
from app.core.hr_identity import HRTarget, own_employee_codes, resolve_own_employee_code
from app.core.hr_audience import own_access, amounts_allowed, targets_for_codes
from app.core.permissions import (
    has_section_permission,
    require_any_section_permission,
    require_section_permission,
)
from app.services.hr_salary_calculator import calculate_salary

import datetime

# اسم قسم الموارد البشرية في الصلاحيات
_HR_SECTION = "الموارد البشرية"


# يتأكد إن المستخدم عنده أي صلاحية من المفاتيح المطلوبة (مقفول افتراضيًا)
def _require_hr(request: Request, *keys: str):
    """صلاحية HR: يكفي أي مفتاح من المفاتيح المعطاة (قفل افتراضي)."""
    return require_any_section_permission(
        request, [(_HR_SECTION, key) for key in keys]
    )


# يفحص هل البروفايل عنده أي مفتاح من المفاتيح
def _hr_has(profile: dict, *keys: str) -> bool:
    return any(
        has_section_permission(profile, _HR_SECTION, key) for key in keys
    )


# Existing nullable creator column, reserved marker for new server-owned writes.
# It never comes from a client payload and is not returned as a display email.
# بادئة علامة منشئ السجل (بتتخزن في عمود المنشئ الموجود)
_HR_CREATOR_PREFIX = "urn:islamapp:creator:"


# يبني علامة منشئ السجل من هوية المستخدم
def _creator_marker(profile):
    uid = str(profile.get("uid") or "").strip()
    return _HR_CREATOR_PREFIX + uid if uid else None


# يرجّع اسم المنشئ للعرض ويخفي العلامة الداخلية
def _public_creator(value):
    if isinstance(value, str) and value.startswith(_HR_CREATOR_PREFIX):
        return None
    return value


# يرد بنجاح لو العملية متحققة بالفعل من غير ما يعدّل حاجة
async def _unchanged_hr_ack(db, profile, company_code, existing, fields, read_keys):
    """Acknowledge an already achieved intent, never perform an edit.

    Either this authenticated actor created the record through this server, or
    the existing read grant and employee/branch visibility permit seeing it.
    Equality alone is not proof of ownership or a grant to read another record.
    """
    if existing is None or existing.is_deleted:
        return None
    if any(getattr(existing, key) != value for key, value in fields.items()):
        return None
    _check_hr_branch(profile, existing.branch_code)
    marker = _creator_marker(profile)
    own_create = marker is not None and existing.created_by == marker
    if not own_create:
        if not _hr_has(profile, *read_keys):
            return None
        visible = await _filter_docs(db, [existing], company_code, profile)
        if not visible:
            return None
    return {"status": "success", "id": existing.id, "action": "unchanged"}


# يتحقق إن الفرع مسموح للمستخدم
def _check_hr_branch(profile: dict, branch_code) -> None:
    allowed = allowed_branches_for_profile(profile)
    if allowed and branch_code and str(branch_code) not in allowed:
        raise HTTPException(
            status_code=403,
            detail="ليس لديك صلاحية على هذا الفرع",
        )


# يتحقق إن شركة المسار هي شركة الجلسة (صاحب البرنامج مستثنى)
def _check_tenant(profile: dict, company_code: str) -> None:
    """فحص صريح: شركة المسار = شركة الجلسة (صاحب البرنامج يتجاوز)."""
    from app.core.auth_middleware import _effective_role
    if _effective_role(profile) == "super_admin":
        return
    if str(profile.get("company_code", "")) != str(company_code):
        raise HTTPException(status_code=403, detail="غير مصرح لهذه الشركة")


# يرجّع أكواد الموظفين اللي المستخدم مسموح له يشوفهم في الموارد البشرية
def _hr_viewable_codes(profile: dict):
    value = profile.get("hr_viewable_employees")
    if isinstance(value, list) and value:
        return {str(v) for v in value}
    return None


# يفحص هل الموظف المستهدف مسموح للمستخدم
def _target_employee_allowed(profile: dict, employee_code: str) -> bool:
    viewable = _hr_viewable_codes(profile)
    return viewable is None or str(employee_code) in viewable


# يحدد كود الموظف المرتبط بحساب المستخدم
async def _resolve_own_employee_code(db, company_code: str, profile: dict):
    return await resolve_own_employee_code(db, company_code, profile)


# يرجّع أكواد الموظفين الظاهرين لفروع المستخدم (None = الكل)
async def _visible_employee_codes(db, company_code: str, profile: dict):
    """أكواد الموظفين الظاهرين لفروع المستخدم (None = كل الفروع).

    منح "كل الفروع" تمثيلها الدقيق هو عدم وجود فلتر. الموظف بفرع
    فارغ/غير معيّن يظهر لأي عارض له حق القسم (مطابقة سلوك العميل).
    """
    allowed = allowed_branches_for_profile(profile)
    if not allowed:
        return None
    result = await db.execute(
        select(Employee.code).where(
            Employee.company_code == company_code,
            or_(
                Employee.branch_code.in_(allowed),
                Employee.branch_code.is_(None),
                Employee.branch_code == "",
            ),
        )
    )
    return {str(code) for code in result.scalars().all()}


# يتحقق من صلاحية المستخدم على موظف معين (وعلى الراتب لو مطلوب)
async def _authorize_employee_target(request: Request, db, company_code: str, employee_code, *, salary: bool = False):
    profile = request.state.auth_user
    _check_tenant(profile, company_code)
    result = await db.execute(select(Employee.code, Employee.user_uid, Employee.user_email,
        Employee.branch_code, Employee.is_deleted).where(Employee.company_code == str(company_code),
        Employee.code == str(employee_code)))
    row = result.one_or_none()
    target = HRTarget.from_employee(row) if row is not None else HRTarget()
    request.state.hr_target = target
    if own_access(profile, target):
        return profile
    broad_keys = (('canViewSalaryAmounts', 'canOpenReportPage', 'canViewBranchSalaryReport', 'canManageEmployees')
        if salary else ('canOpenAttendancePage', 'canOpenVacationsPage', 'canViewAdjustments',
            'canViewBranchSalaryReport', 'canViewEmployees', 'canManageEmployees', 'canEditWeeklyDay',
            'canEditWorkSchedule', 'canEditDelayRules'))
    if _hr_has(profile, *broad_keys):
        if not _target_employee_allowed(profile, employee_code):
            raise HTTPException(status_code=403, detail='ليس لديك صلاحية عرض هذا الموظف')
        _check_hr_branch(profile, getattr(row, 'branch_code', None))
        return profile
    raise HTTPException(status_code=403, detail='ليس لديك صلاحية الوصول لبيانات الموظف')


# عرض المرتب لمن يملك فتح التقرير دون حق مبالغ: قائمة سماح صريحة
# بالحقول غير المالية فقط (مطابقة لعقد calculate_salary الفعلي)
# قائمة الحقول غير المالية المسموح عرضها لمن يفتح التقرير من غير حق المبالغ
_SALARY_SAFE_KEYS = {
    "employee_code", "employee_name", "branch_code", "company_code",
    "month", "elapsed_days", "future_days", "absent_days",
    "permission_days", "deduction_days", "absence_deduction_days",
    "delay_deduction_days", "absence", "absence_with_permission",
    "permission", "late_minutes", "late_minutes_total",
    "early_leave_minutes_total", "overtime_minutes",
    "overtime_minutes_total", "overtime_multiplier", "grace_minutes",
    "attendance_details", "default_check_in", "default_check_out",
    "flexible_hours", "check_in", "check_out", "date", "status",
    "work_days", "present_days", "vacation_days",
    "use_fixed_month_days", "weekly_vacation_day",
}
_SALARY_LINE_SAFE_KEYS = {"label", "note", "date", "type"}


# يشيل كل الحقول المالية من التقرير ويبقي غير المالية بس
def _redact_salary_amounts(report):
    """إسقاط كل الحقول المالية عبر قائمة سماح بالحقول غير المالية فقط."""
    if not isinstance(report, dict):
        return report
    out = {k: v for k, v in report.items() if k in _SALARY_SAFE_KEYS}
    lines = report.get("adjustment_lines")
    if isinstance(lines, list):
        out["adjustment_lines"] = [
            {k: v for k, v in line.items() if k in _SALARY_LINE_SAFE_KEYS}
            for line in lines
            if isinstance(line, dict)
        ]
    return out


# الحقول المسموحة في تقرير الفروع من غير مبالغ
_BRANCH_REPORT_SAFE_KEYS = {'company_code', 'month', 'branch_code'}
_BRANCH_TOTAL_SAFE_KEYS = {'employees_count'}


# يجهّز بيانات تقرير الفروع حسب حق المستخدم في المبالغ
def _branch_report_payload(profile, report):
    if _hr_has(profile, 'canViewSalaryAmounts'):
        return report
    totals = report.get('totals') or {}
    return {
        **{key: value for key, value in report.items() if key in _BRANCH_REPORT_SAFE_KEYS},
        'totals': {key: value for key, value in totals.items() if key in _BRANCH_TOTAL_SAFE_KEYS},
        'employees': [_redact_salary_amounts(row) for row in report.get('employees', [])],
    }


# يفحص هل المستند ظاهر للمستخدم حسب الفروع والموظفين
def _doc_visible(doc, allowed, visible_codes) -> bool:
    if allowed is None:
        return True
    branch = getattr(doc, "branch_code", None)
    if branch and str(branch) in allowed:
        return True
    if not branch and visible_codes is not None:
        return str(getattr(doc, "employee_code", "")) in visible_codes
    return False


# يفلتر المستندات حسب فروع المستخدم والموظفين المرئيين
async def _filter_docs(db, docs, company_code: str, profile: dict):
    allowed = allowed_branches_for_profile(profile)
    viewable = _hr_viewable_codes(profile)
    visible_codes = await _visible_employee_codes(db, company_code, profile) if allowed else None
    own_codes = (await own_employee_codes(db, company_code, profile)
        if (allowed or viewable is not None) and _hr_has(profile, 'canViewOwnHRData') else set())
    return [doc for doc in docs if str(getattr(doc, 'employee_code', '')) in own_codes or (
        (not allowed or _doc_visible(doc, allowed, visible_codes)) and
        (viewable is None or str(getattr(doc, 'employee_code', '')) in viewable))]


# يفحص هل المستند يخص الموظف نفسه
def _is_own(profile: dict, doc_employee_code: str) -> bool:
    return str(doc_employee_code) == str(
        profile.get("employee_code", "")
    )


# راوتر الموارد البشرية (حضور وإجازات وتسويات وتقارير)
router = APIRouter()


# ============================================================
# Helper: تحويل since (نص ISO 8601) إلى datetime UTC (naive)
#
# جدول updated_at عندنا = TIMESTAMP WITHOUT TIME ZONE
# فالازم نشيل الـ timezone بعد ما نحول لـ UTC.
# ============================================================


# يحلّل وقت since ويحوّله لتاريخ ووقت
def _parse_since(since: str) -> datetime.datetime:
    """
    يحوّل نص ISO 8601 إلى datetime UTC بدون timezone.

    أمثلة صحيحة:
        2026-08-11T14:30:00Z
        2026-08-11T14:30:00+00:00
        2026-08-11T14:30:00.123456
    """
    since_dt = datetime.datetime.fromisoformat(
        since.replace("Z", "+00:00")
    )

    if since_dt.tzinfo is not None:
        since_dt = since_dt.astimezone(datetime.timezone.utc)
        since_dt = since_dt.replace(tzinfo=None)

    return since_dt


# ============================================================
# ================ 1. ATTENDANCE (الحضور) ====================
# ============================================================


# يحوّل سجل الحضور إلى JSON للإرسال للعميل
def serialize_attendance(
    doc: HRAttendance,
    action: str | None = None,
):
    """تحويل سجل الحضور إلى JSON للإرسال للعميل"""
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "branch_code": doc.branch_code,
        "employee_code": doc.employee_code,
        "date": doc.date,

        "status": doc.status,
        "check_in": doc.check_in,
        "check_out": doc.check_out,

        "late_minutes": doc.late_minutes,
        "early_leave_minutes": doc.early_leave_minutes,
        "overtime_minutes": doc.overtime_minutes,

        "notes": doc.notes,
        "created_by": _public_creator(doc.created_by),

        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if action is not None:
        data["action"] = action

    return data


# ------------------------------------------------------------
# 1.1 حفظ / تحديث حضور
#
# المفتاح الفريد: (company_code, employee_code, date)
# ------------------------------------------------------------


# مسار حفظ الحضور (إضافة أو تعديل)
@router.post("/attendance/save")
async def save_attendance(
    request: Request,
    data: HRAttendanceModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canAddAttendance", "canEditAttendance")
    _check_tenant(_profile, data.company_code)
    _check_hr_branch(_profile, data.branch_code)

    try:
        company_code = data.company_code
        employee_code = data.employee_code
        date = data.date

        # ---------- التحقق ----------
        if not employee_code:
            raise HTTPException(
                status_code=400,
                detail="كود الموظف مطلوب",
            )

        if not date:
            raise HTTPException(
                status_code=400,
                detail="التاريخ مطلوب",
            )

        # ---------- البحث عن السجل ----------
        stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.employee_code == employee_code,
                HRAttendance.date == date,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if existing is not None and not _hr_has(_profile, "canEditAttendance"):
            ack = await _unchanged_hr_ack(db, _profile, company_code, existing,
                {
                "branch_code": data.branch_code,
                "status": data.status or "present", "check_in": data.check_in,
                "check_out": data.check_out, "late_minutes": data.late_minutes or 0,
                "early_leave_minutes": data.early_leave_minutes or 0,
                "overtime_minutes": data.overtime_minutes or 0, "notes": data.notes,
            }, ("canOpenAttendancePage", "canViewBranchSalaryReport"))
            if ack is not None:
                return ack
        _require_hr(request, "canEditAttendance" if existing is not None else "canAddAttendance")

        # ---------- تعديل موجود ----------
        if existing:
            # الفرع المخزَّن أيضاً: منع تعديل سجل فرع غير مسموح
            _check_hr_branch(_profile, existing.branch_code)
            existing.branch_code = data.branch_code
            existing.status = data.status or "present"
            existing.check_in = data.check_in
            existing.check_out = data.check_out
            existing.late_minutes = data.late_minutes or 0
            existing.early_leave_minutes = data.early_leave_minutes or 0
            existing.overtime_minutes = data.overtime_minutes or 0
            existing.notes = data.notes
            existing.updated_at = datetime.datetime.utcnow()

            was_deleted = bool(existing.is_deleted)
            existing.is_deleted = False

            action = "insert" if was_deleted else "update"
            tx = existing

        # ---------- إضافة جديدة ----------
        else:
            tx = HRAttendance(
                created_by=_creator_marker(_profile),
                company_code=company_code,
                branch_code=data.branch_code,
                employee_code=employee_code,
                date=date,
                status=data.status or "present",
                check_in=data.check_in,
                check_out=data.check_out,
                late_minutes=data.late_minutes or 0,
                early_leave_minutes=data.early_leave_minutes or 0,
                overtime_minutes=data.overtime_minutes or 0,
                notes=data.notes,
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )
            db.add(tx)
            action = "insert"

        # ---------- حفظ ----------
        await db.commit()
        await db.refresh(tx)

        # ---------- WebSocket ----------
        await manager.broadcast(
            company_code,
            {
                "type": "hr_attendance",
                "action": action,
                "data": serialize_attendance(tx, action=action),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ الحضور بنجاح",
            "id": tx.id,
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في السيرفر: {str(e)}",
        )


# ------------------------------------------------------------
# 1.2 جلب حضور (يوم واحد أو نطاق)
#
# طريقتان للاستخدام:
#
# 1) GET /hr/attendance/list/{company}?date=2026-11-10
#    → يجيب حضور يوم واحد (السلوك القديم - متوافق)
#
# 2) GET /hr/attendance/list/{company}?from_date=2026-06-01&to_date=2026-11-10
#    → يجيب حضور نطاق زمني (للمزامنة الكاملة - جديد)
#
# إذا مرر from_date/to_date بس، بيرجع كل السجلات في النطاق
# لكل الموظفين (بما فيهم الموظف اللي في branch_code لو موجود).
# ------------------------------------------------------------


# مسار قائمة الحضور للشركة
@router.get("/attendance/list/{company_code}")
async def list_attendance(
    request: Request,
    company_code: str,
    date: str | None = Query(None, description="YYYY-MM-DD (يوم واحد)"),
    from_date: str | None = Query(None, description="YYYY-MM-DD (بداية النطاق)"),
    to_date: str | None = Query(None, description="YYYY-MM-DD (نهاية النطاق)"),
    branch_code: str | None = Query(None),
    employee_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canOpenAttendancePage", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.is_deleted.is_(False),
            )
        )

        # ---------- فلترة التاريخ ----------
        if date:
            # نمط اليوم الواحد (السلوك القديم)
            stmt = stmt.where(HRAttendance.date == date)
        else:
            # نمط النطاق (للمزامنة الكاملة)
            if from_date:
                stmt = stmt.where(HRAttendance.date >= from_date)
            if to_date:
                stmt = stmt.where(HRAttendance.date <= to_date)

        # ---------- فلترة الفرع ----------
        if branch_code:
            stmt = stmt.where(HRAttendance.branch_code == branch_code)

        # ---------- فلترة الموظف ----------
        if employee_code:
            stmt = stmt.where(HRAttendance.employee_code == employee_code)

        # ---------- ترتيب ----------
        stmt = stmt.order_by(HRAttendance.date, HRAttendance.employee_code)

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        return [serialize_attendance(doc) for doc in docs]

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 1.3 جلب حضور موظف في شهر معين
#
# month = "2026-11" → يجيب كل أيام الشهر
# ------------------------------------------------------------


# مسار حضور موظف معين
@router.get("/attendance/employee/{company_code}/{employee_code}")
async def list_employee_attendance(
    request: Request,
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
    _profile = await _authorize_employee_target(
        request, db, company_code, employee_code
    )

    try:
        stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.employee_code == employee_code,
                HRAttendance.date.like(f"{month}-%"),
                HRAttendance.is_deleted.is_(False),
            )
            .order_by(HRAttendance.date)
        )

        result = await db.execute(stmt)
        docs = result.scalars().all()

        return [serialize_attendance(doc) for doc in docs]

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 1.4 حذف حضور (Soft Delete)
# ------------------------------------------------------------


# مسار حذف سجل حضور
@router.delete("/attendance/delete/{company_code}/{attendance_id}")
async def delete_attendance(
    request: Request,
    company_code: str,
    attendance_id: int,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canDeleteAttendance")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.id == attendance_id,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="السجل غير موجود",
            )

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "السجل محذوف بالفعل",
            }

        # Soft Delete
        _check_hr_branch(_profile, existing.branch_code)

        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        # WebSocket
        await manager.broadcast(
            company_code,
            {
                "type": "hr_attendance",
                "action": "delete",
                "data": {
                    "id": existing.id,
                    "company_code": company_code,
                    "employee_code": existing.employee_code,
                    "date": existing.date,
                    "updated_at": (
                        existing.updated_at.isoformat()
                        if existing.updated_at
                        else None
                    ),
                    "is_deleted": True,
                },
            },
        )

        return {
            "status": "success",
            "message": "تم حذف السجل بنجاح",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 1.5 المزامنة التزايدية للحضور
#
# important: لا نستبعد is_deleted هنا.
# الجهاز Offline لازم يعرف إن السجل اتحذف.
# ------------------------------------------------------------


# مسار التغييرات منذ آخر مزامنة للحضور
@router.get("/attendance/changes/{company_code}")
async def get_attendance_changes(
    request: Request,
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canOpenAttendancePage", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        since_dt = _parse_since(since)

        stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.updated_at >= since_dt,
            )
            .order_by(HRAttendance.updated_at)
        )

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        results = []
        for doc in docs:
            action = "delete" if doc.is_deleted else "update"
            results.append(serialize_attendance(doc, action=action))

        return results

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="صيغة since غير صحيحة، استخدم ISO 8601",
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# الدالة المشتركة لفيد التغييرات v2 لسجلات الموارد البشرية (تجريبي)
async def _hr_feed_v2(Model, table, feed, serialize, request, company_code, cursor, limit, scope, db, *keys, fp_extra=None, company_wide=False, mask=None):
    """EXPERIMENT. Commit-safe HR feed. HR visibility is not a row property: it also depends on the
    viewer's visible/viewable/own employee code sets (employee branch moves, user links). Those sets
    are hashed into the scope fingerprint, so any effective visibility change answers invalid:scope
    and the client must run a replace-mode full sync. Needs migration 009+."""
    import hashlib, json
    from sqlalchemy import true, text as _text
    from app.core import feed_v2
    from app.core.changes_v2 import feed_epoch, parse_cursor
    profile = _require_hr(request, *keys)
    _check_tenant(profile, company_code)
    allowed = allowed_branches_for_profile(profile)
    viewable = _hr_viewable_codes(profile)
    visible_codes = await _visible_employee_codes(db, company_code, profile) if allowed else None
    # With a mask (amounts) the own set is always needed: own rows keep their amounts. Rows are already
    # all visible when no branch/employee restriction applies, so this widens nothing.
    own = (await own_employee_codes(db, company_code, profile)
           if (allowed or viewable is not None or mask is not None) and _hr_has(profile, "canViewOwnHRData") else set())
    epoch = await feed_epoch(db, feed)
    basis = {
        "co": company_code, "feed": feed, "branches": sorted(allowed or []),
        "visible": None if visible_codes is None else sorted(visible_codes),
        "viewable": None if viewable is None else sorted(viewable), "own": sorted(own),
        "extra": fp_extra(profile) if fp_extra else None,
    }
    # access = who may read what; fp = access + feed epoch. A client can tell an access change from a
    # feed re-apply (epoch only) by comparing "access".
    access = hashlib.sha256(json.dumps(basis, sort_keys=True).encode()).hexdigest()[:16]
    fp = hashlib.sha256(json.dumps({**basis, "epoch": epoch}, sort_keys=True).encode()).hexdigest()[:16]
    if cursor == "latest":
        xmin = int((await db.execute(_text("select pg_snapshot_xmin(pg_current_snapshot())::text"))).scalar())
        from app.core.changes_v2 import MAX_ID
        return {"invalid": False, "items": [], "has_more": False, "scope": fp, "epoch": epoch,
                "access": access, "next_cursor": f"{xmin - 1}:{MAX_ID}"}
    if scope and scope != fp:
        return {"invalid": True, "reason": "scope", "items": [], "has_more": False,
                "next_cursor": cursor, "scope": fp, "epoch": epoch, "access": access}
    try:
        parse_cursor(cursor)
    except Exception:
        raise HTTPException(status_code=400, detail="bad cursor")
    if company_wide:
        # Same as the existing /changes route for this table: no row filter beyond the HR right.
        branch_ok = true()
        allowed_for_fetch = None
    elif allowed:
        allowed_for_fetch = allowed
        empty = or_(Model.branch_code.is_(None), Model.branch_code == "")
        branch_ok = or_(Model.branch_code.in_(allowed),
                        and_(empty, Model.employee_code.in_(sorted(visible_codes or []))))
    else:
        branch_ok = true()
        allowed_for_fetch = None
    if company_wide:
        visibility = true()
    else:
        view_ok = true() if viewable is None else Model.employee_code.in_(sorted(viewable))
        visibility = or_(Model.employee_code.in_(sorted(own)), and_(branch_ok, view_ok)) if own else and_(branch_ok, view_ok)

    # يحوّل المستند للشكل المرسل مع حالة الحذف
    def _ser(d):
        item = serialize(d, action="delete" if getattr(d, "is_deleted", False) else "update")
        return mask(item, d, own, profile) if mask else item
    out = await feed_v2.fetch(
        db, Model, table, company_code, cursor, limit, visibility, allowed_for_fetch, _ser,
        lambda d: {"id": d.id, "company_code": d.company_code, "action": "delete", "tombstone": True,
                   "is_deleted": True, "updated_at": d.updated_at.isoformat() if d.updated_at else None})
    out["scope"] = fp
    out["epoch"] = epoch
    out["access"] = access
    return out


# مسار فيد v2 للحضور
@router.get("/attendance/changes-v2/{company_code}")
async def get_attendance_changes_v2(
    request: Request, company_code: str,
    cursor: str = Query("0:0"), limit: int = Query(200, ge=1, le=500), scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    return await _hr_feed_v2(HRAttendance, "hr_attendance", "hr_attendance", serialize_attendance,
                             request, company_code, cursor, limit, scope, db,
                             "canOpenAttendancePage", "canViewBranchSalaryReport")


# مسار فيد v2 للإجازات
@router.get("/vacations/changes-v2/{company_code}")
async def get_vacation_changes_v2(
    request: Request, company_code: str,
    cursor: str = Query("0:0"), limit: int = Query(200, ge=1, le=500), scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    return await _hr_feed_v2(HRVacation, "hr_vacations", "hr_vacations", serialize_vacation,
                             request, company_code, cursor, limit, scope, db,
                             "canOpenVacationsPage", "canViewBranchSalaryReport")


# ============================================================
# ================ 2. VACATIONS (الإجازات) ====================
# ============================================================


# يحوّل سجل الإجازة إلى JSON
def serialize_vacation(
    doc: HRVacation,
    action: str | None = None,
):
    """تحويل سجل الإجازة إلى JSON"""
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "branch_code": doc.branch_code,
        "employee_code": doc.employee_code,
        "date": doc.date,
        "name": doc.name,
        "type": doc.type,
        "created_by": _public_creator(doc.created_by),

        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if action is not None:
        data["action"] = action

    return data


# ------------------------------------------------------------
# 2.1 حفظ / تحديث إجازة
#
# أنواع الإجازات:
# - عامة (لكل الشركة): branch_code=None, employee_code=None
# - لفرع معين:         branch_code=X,    employee_code=None
# - لموظف معين:        employee_code=Y   (branch_code يبقى None تلقائيًا)
# ------------------------------------------------------------


# مسار حفظ إجازة (إضافة أو تعديل)
@router.post("/vacations/save")
async def save_vacation(
    request: Request,
    data: HRVacationModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canAddVacation", "canEditVacation")
    _check_tenant(_profile, data.company_code)
    _check_hr_branch(_profile, data.branch_code)

    try:
        company_code = data.company_code
        date = data.date
        branch_code = data.branch_code
        employee_code = data.employee_code

        # ---------- التحقق ----------
        if not date:
            raise HTTPException(
                status_code=400,
                detail="التاريخ مطلوب",
            )

        if not data.name or not data.name.strip():
            raise HTTPException(
                status_code=400,
                detail="اسم الإجازة مطلوب",
            )

        # لو موظف محدد، الفرع يبقى None (الموظف عنده فرعه في Employee)
        if employee_code:
            branch_code = None

        # ---------- البحث عن السجل ----------
        stmt = select(HRVacation).where(
            HRVacation.company_code == company_code,
            HRVacation.date == date,
        )

        if employee_code:
            # إجازة موظف معين
            stmt = stmt.where(
                HRVacation.employee_code == employee_code
            )
        elif branch_code is None:
            # إجازة كل الفروع وكل الموظفين
            stmt = stmt.where(
                HRVacation.branch_code.is_(None),
                HRVacation.employee_code.is_(None),
            )
        else:
            # إجازة فرع معين (لكل موظفيه)
            stmt = stmt.where(
                HRVacation.branch_code == branch_code,
                HRVacation.employee_code.is_(None),
            )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if existing is not None and not _hr_has(_profile, "canEditVacation"):
            ack = await _unchanged_hr_ack(db, _profile, company_code, existing,
                {
                "branch_code": branch_code, "employee_code": employee_code,
                "name": data.name, "type": data.type or "official",
            }, ("canOpenVacationsPage", "canViewBranchSalaryReport"))
            if ack is not None:
                return ack
        _require_hr(request, "canEditVacation" if existing is not None else "canAddVacation")

        # ---------- تعديل / إضافة ----------
        if existing:
            existing.name = data.name
            existing.type = data.type or "official"
            existing.branch_code = branch_code
            existing.employee_code = employee_code
            existing.updated_at = datetime.datetime.utcnow()

            was_deleted = bool(existing.is_deleted)
            existing.is_deleted = False

            action = "insert" if was_deleted else "update"
            tx = existing

        else:
            tx = HRVacation(
                created_by=_creator_marker(_profile),
                company_code=company_code,
                branch_code=branch_code,
                employee_code=employee_code,
                date=date,
                name=data.name,
                type=data.type or "official",
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )
            db.add(tx)
            action = "insert"

        await db.commit()
        await db.refresh(tx)

        # ---------- WebSocket ----------
        await manager.broadcast(
            company_code,
            {
                "type": "hr_vacation",
                "action": action,
                "data": serialize_vacation(tx, action=action),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ الإجازة بنجاح",
            "id": tx.id,
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في السيرفر: {str(e)}",
        )


# ------------------------------------------------------------
# 2.2 جلب قائمة الإجازات
#
# منطق الفلترة:
# - employee_code محدد: إجازات الموظف + إجازات فرعه + إجازات كل الفروع
# - branch_code محدد: إجازات الفرع + إجازات كل الفروع
# - الاثنين None: كل الإجازات
#
# مثال:
# GET /hr/vacations/list/01?from_date=2026-06-01&to_date=2026-11-30
# GET /hr/vacations/list/01?employee_code=E001&branch_code=B01
# ------------------------------------------------------------


# مسار قائمة الإجازات
@router.get("/vacations/list/{company_code}")
async def list_vacations(
    request: Request,
    company_code: str,
    from_date: str | None = Query(None, description="YYYY-MM-DD"),
    to_date: str | None = Query(None, description="YYYY-MM-DD"),
    branch_code: str | None = Query(None),
    employee_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canOpenVacationsPage", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRVacation)
            .where(
                HRVacation.company_code == company_code,
                HRVacation.is_deleted.is_(False),
            )
        )

        # ---------- فلترة التاريخ ----------
        if from_date:
            stmt = stmt.where(HRVacation.date >= from_date)

        if to_date:
            stmt = stmt.where(HRVacation.date <= to_date)

        # ---------- فلترة النطاق ----------
        if employee_code:
            # إجازات الموظف + إجازات الفرع (بتاعه) + إجازات كل الفروع
            conditions = [
                HRVacation.employee_code == employee_code,
                and_(
                    HRVacation.employee_code.is_(None),
                    HRVacation.branch_code.is_(None),
                ),
            ]

            if branch_code:
                conditions.append(
                    and_(
                        HRVacation.employee_code.is_(None),
                        HRVacation.branch_code == branch_code,
                    )
                )

            stmt = stmt.where(or_(*conditions))

        elif branch_code:
            # إجازات الفرع + إجازات كل الفروع
            stmt = stmt.where(
                or_(
                    and_(
                        HRVacation.employee_code.is_(None),
                        HRVacation.branch_code == branch_code,
                    ),
                    and_(
                        HRVacation.employee_code.is_(None),
                        HRVacation.branch_code.is_(None),
                    ),
                )
            )

        stmt = stmt.order_by(HRVacation.date)

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        return [serialize_vacation(doc) for doc in docs]

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 2.3 حذف إجازة (Soft Delete)
# ------------------------------------------------------------


# مسار حذف إجازة
@router.delete("/vacations/delete/{company_code}/{vacation_id}")
async def delete_vacation(
    request: Request,
    company_code: str,
    vacation_id: int,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canDeleteVacation")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRVacation)
            .where(
                HRVacation.company_code == company_code,
                HRVacation.id == vacation_id,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="الإجازة غير موجودة",
            )

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "الإجازة محذوفة بالفعل",
            }

        _check_hr_branch(_profile, existing.branch_code)

        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        await manager.broadcast(
            company_code,
            {
                "type": "hr_vacation",
                "action": "delete",
                "data": {
                    "id": existing.id,
                    "company_code": company_code,
                    "date": existing.date,
                    "updated_at": (
                        existing.updated_at.isoformat()
                        if existing.updated_at
                        else None
                    ),
                    "is_deleted": True,
                },
            },
        )

        return {
            "status": "success",
            "message": "تم حذف الإجازة بنجاح",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 2.4 المزامنة التزايدية للإجازات
# ------------------------------------------------------------


# مسار التغييرات منذ آخر مزامنة للإجازات
@router.get("/vacations/changes/{company_code}")
async def get_vacation_changes(
    request: Request,
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canOpenVacationsPage", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        since_dt = _parse_since(since)

        stmt = (
            select(HRVacation)
            .where(
                HRVacation.company_code == company_code,
                HRVacation.updated_at >= since_dt,
            )
            .order_by(HRVacation.updated_at)
        )

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        results = []
        for doc in docs:
            action = "delete" if doc.is_deleted else "update"
            results.append(serialize_vacation(doc, action=action))

        return results

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="صيغة since غير صحيحة",
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# ========== 3. EMPLOYEE SETTINGS (إعدادات الموظف) ===========
# ============================================================


# يحوّل إعدادات الموظف إلى JSON
def serialize_employee_settings(
    doc: HREmployeeSettings,
    action: str | None = None,
):
    """تحويل إعدادات الموظف إلى JSON"""
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "employee_code": doc.employee_code,
        "weekly_vacation_day": doc.weekly_vacation_day,
        "default_check_in": doc.default_check_in or "09:00",
        "default_check_out": doc.default_check_out or "17:00",
        "flexible_hours": bool(doc.flexible_hours),
        "delay_rules": doc.delay_rules or {},
        "use_fixed_month_days": bool(doc.use_fixed_month_days),
        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
    }

    if action is not None:
        data["action"] = action

    return data


# ------------------------------------------------------------
# 3.1 المزامنة التزايدية لإعدادات الموظفين
#
# ⚠️ مهم: هذا الـ route **يجب** أن يكون أول واحد في القسم
#
# السبب: FastAPI يطابق الـ routes بالترتيب.
# الـ route /employee-settings/{company_code}/{employee_code} عام
# ولو اتعرف قبل /changes/{company_code}، هيمطابق "changes"
# كـ company_code → ويرجع Map بدل List.
#
# الجديد — كان ناقص في النسخة القديمة.
# لما HR Admin يعدل delay_rules لموظف من جهاز A،
# جهاز B لازم يعرف التغيير ده تلقائيًا.
# ------------------------------------------------------------


# مسار فيد v2 لإعدادات الموظفين
@router.get("/employee-settings/changes-v2/{company_code}")
async def get_employee_settings_changes_v2(
    request: Request, company_code: str,
    cursor: str = Query("0:0"), limit: int = Query(200, ge=1, le=500), scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    # Same audience as the existing /employee-settings/changes route (HR right only, company wide).
    return await _hr_feed_v2(HREmployeeSettings, "hr_employee_settings", "hr_employee_settings",
                             serialize_employee_settings, request, company_code, cursor, limit, scope, db,
                             "canEditWeeklyDay", "canEditWorkSchedule", "canEditDelayRules", "canOpenAttendancePage",
                             company_wide=True)


# مسار التغييرات منذ آخر مزامنة لإعدادات الموظفين
@router.get("/employee-settings/changes/{company_code}")
async def get_employee_settings_changes(
    request: Request,
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canEditWeeklyDay", "canEditWorkSchedule", "canEditDelayRules", "canOpenAttendancePage")
    _check_tenant(_profile, company_code)

    try:
        since_dt = _parse_since(since)

        stmt = (
            select(HREmployeeSettings)
            .where(
                HREmployeeSettings.company_code == company_code,
                HREmployeeSettings.updated_at >= since_dt,
            )
            .order_by(HREmployeeSettings.updated_at)
        )

        result = await db.execute(stmt)
        docs = result.scalars().all()

        # ملاحظة: HREmployeeSettings مفيهاش is_deleted،
        # لأنها settings دائمًا موجودة (مفيش حذف).
        # فكل التغييرات تعتبر update/insert.
        return [
            serialize_employee_settings(doc, action="update")
            for doc in docs
        ]

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="صيغة since غير صحيحة",
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 3.2 جلب إعدادات الموظف
#
# ⚠️ يجب أن يكون **بعد** /changes
# (لأنه route عام بيطابق أي segment)
#
# لو مفيش سجل، بيرجع قيم افتراضية (مش 404)
# عشان الفرونت يقدر يشتغل من غير مشاكل.
# ------------------------------------------------------------


# مسار قراءة إعدادات موظف معين
@router.get("/employee-settings/{company_code}/{employee_code}")
async def get_employee_settings(
    request: Request,
    company_code: str,
    employee_code: str,
    db: AsyncSession = Depends(get_db),
):
    _profile = await _authorize_employee_target(
        request, db, company_code, employee_code
    )

    try:
        stmt = select(HREmployeeSettings).where(
            HREmployeeSettings.company_code == company_code,
            HREmployeeSettings.employee_code == employee_code,
        )

        result = await db.execute(stmt)
        settings = result.scalar_one_or_none()

        if not settings:
            # قيم افتراضية (متوافقة مع DEFAULT_DELAY_RULES في الباك)
            return {
                "company_code": company_code,
                "employee_code": employee_code,
                "weekly_vacation_day": None,
                "default_check_in": "09:00",
                "default_check_out": "17:00",
                "flexible_hours": False,
                "delay_rules": {},
                "use_fixed_month_days": True,
            }

        return serialize_employee_settings(settings)

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 3.3 حفظ إعدادات الموظف
#
# POST — مش بيتعارض مع GET routes، فترتيبه مش مهم
# ------------------------------------------------------------


# مسار حفظ إعدادات موظف (يوم الإجازة والجدول والخصومات)
@router.post("/employee-settings/save")
async def save_employee_settings(
    request: Request,
    data: HREmployeeSettingsModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canEditWeeklyDay", "canEditWorkSchedule", "canEditDelayRules")
    _check_tenant(_profile, company_code)

    try:
        stmt = select(HREmployeeSettings).where(
            HREmployeeSettings.company_code == data.company_code,
            HREmployeeSettings.employee_code == data.employee_code,
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if existing:
            existing.weekly_vacation_day = data.weekly_vacation_day
            existing.default_check_in = data.default_check_in or "09:00"
            existing.default_check_out = data.default_check_out or "17:00"
            existing.flexible_hours = data.flexible_hours or False
            existing.delay_rules = data.delay_rules or {}
            existing.use_fixed_month_days = (
                data.use_fixed_month_days
                if data.use_fixed_month_days is not None
                else True
            )   # ⭐ جديد
            existing.updated_at = datetime.datetime.utcnow()

            tx = existing
            action = "update"

        else:
            tx = HREmployeeSettings(
                company_code=data.company_code,
                employee_code=data.employee_code,
                weekly_vacation_day=data.weekly_vacation_day,
                default_check_in=data.default_check_in or "09:00",
                default_check_out=data.default_check_out or "17:00",
                flexible_hours=data.flexible_hours or False,
                delay_rules=data.delay_rules or {},
                use_fixed_month_days=(
                    data.use_fixed_month_days
                    if data.use_fixed_month_days is not None
                    else True
                ),   # ⭐ جديد
                updated_at=datetime.datetime.utcnow(),
            )
            db.add(tx)
            action = "insert"

        await db.commit()
        await db.refresh(tx)

        # WebSocket — عشان الفرونت يعرف الإعدادات اتغيرت فورًا
        await manager.broadcast(
            data.company_code,
            {
                "type": "hr_employee_settings",
                "action": action,
                "data": serialize_employee_settings(tx, action=action),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ الإعدادات بنجاح",
            "id": tx.id,
            "action": action,
        }

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# ============ 4. ADJUSTMENTS (التسويات المالية) =============
# ============================================================

# أنواع التسويات:
# - deduction : خصم
# - bonus     : مكافأة
# - loan      : سلفة (تُنشأ كأقساط شهرية في صفوف متعددة)


# يحوّل سجل التسوية إلى JSON
def serialize_adjustment(
    doc: HRAdjustment,
    action: str | None = None,
):
    """تحويل سجل التسوية إلى JSON"""
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "branch_code": doc.branch_code,
        "employee_code": doc.employee_code,
        "month": doc.month,
        "date": doc.date,
        "type": doc.type,
        "amount": doc.amount,
        "reason": doc.reason,
        "installment_ref": doc.installment_ref,
        "status": doc.status,
        "created_by": doc.created_by,

        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if action is not None:
        data["action"] = action

    return data


# يجهّز حمولة التسويات مع إخفاء المبالغ حسب صلاحية المستخدم
async def _adjustment_payloads(db, company_code, docs, profile, *, target=None, changes=False):
    docs = list(docs)
    targets = {target.code:target} if target is not None else {}
    if not _hr_has(profile, 'canViewSalaryAmounts') and _hr_has(profile, 'canViewOwnHRData') and target is None:
        targets = await targets_for_codes(db, company_code, [doc.employee_code for doc in docs])
    result = []
    for doc in docs:
        payload = serialize_adjustment(doc, action=('delete' if doc.is_deleted else 'update') if changes else None)
        if not amounts_allowed(profile, targets.get(str(doc.employee_code))):
            payload['amount'] = None
        result.append(payload)
    return result


# ------------------------------------------------------------
# 4.1 حفظ / إضافة تسوية (خصم / مكافأة / سلفة)
#
# ملاحظة:
# - للأقساط، الفرونت بيبعت صف منفصل لكل شهر (زي ما هو في vacations_page)
# - هنا بنسجل صف واحد بس، والتكرار بيحصل على مستوى الفرونت
# ------------------------------------------------------------


# مسار حفظ تسوية مالية (خصم أو مكافأة أو سلفة)
@router.post("/adjustments/save")
async def save_adjustment(
    data: HRAdjustmentModel,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    # صلاحية الإضافة حسب نوع التسوية فقط (الواجهة تعرض كل نوع بمفتاحه):
    # مكافأة → canAddBonus، سلفة → canAddLoan، خصم مباشر → canAddDirectDiscount
    _ADD_BY_TYPE = {
        "bonus": "canAddBonus",
        "loan": "canAddLoan",
        "deduction": "canAddDirectDiscount",
    }
    _key = _ADD_BY_TYPE.get(data.type)
    if _key is None:
        raise HTTPException(
            status_code=403,
            detail="نوع تسوية غير معروف وليس لديك صلاحية الإضافة عليه",
        )
    _profile = _require_hr(request, _key, "canEditAdjustment")
    _check_tenant(_profile, data.company_code)
    _check_hr_branch(_profile, data.branch_code)
    try:
        company_code = data.company_code
        employee_code = data.employee_code
        month = data.month
        adj_type = data.type

        # ---------- التحقق ----------
        if not employee_code:
            raise HTTPException(
                status_code=400,
                detail="كود الموظف مطلوب",
            )

        if not month or len(month) != 7:
            raise HTTPException(
                status_code=400,
                detail="الشهر يجب أن يكون بصيغة YYYY-MM",
            )

        if adj_type not in ("deduction", "bonus", "loan"):
            raise HTTPException(
                status_code=400,
                detail="النوع يجب أن يكون: deduction / bonus / loan",
            )

        if not data.amount or data.amount <= 0:
            raise HTTPException(
                status_code=400,
                detail="المبلغ يجب أن يكون أكبر من صفر",
            )

        # ---------- إنشاء التسوية ----------
        tx = HRAdjustment(
            company_code=company_code,
            branch_code=data.branch_code,
            employee_code=employee_code,
            month=month,
            date=data.date,
            type=adj_type,
            amount=data.amount,
            reason=data.reason,
            installment_ref=data.installment_ref,
            status=data.status or "approved",
            updated_at=datetime.datetime.utcnow(),
            is_deleted=False,
        )

        db.add(tx)
        await db.commit()
        await db.refresh(tx)

        # ---------- WebSocket ----------
        await manager.broadcast(
            company_code,
            {
                "type": "hr_adjustment",
                "action": "insert",
                "data": serialize_adjustment(tx, action="insert"),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ التسوية بنجاح",
            "id": tx.id,
            "action": "insert",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في السيرفر: {str(e)}",
        )


# ------------------------------------------------------------
# 4.2 جلب تسويات شهر معين (كل الموظفين)
#
# مثال:
# GET /hr/adjustments/list/01?month=2026-11
# GET /hr/adjustments/list/01?month=2026-11&branch_code=B01
# ------------------------------------------------------------


# مسار قائمة التسويات
@router.get("/adjustments/list/{company_code}")
async def list_adjustments(
    request: Request,
    company_code: str,
    month: str = Query(..., description="YYYY-MM"),
    branch_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canViewAdjustments", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRAdjustment)
            .where(
                HRAdjustment.company_code == company_code,
                HRAdjustment.month == month,
                HRAdjustment.is_deleted.is_(False),
            )
        )

        if branch_code:
            stmt = stmt.where(
                HRAdjustment.branch_code == branch_code
            )

        stmt = stmt.order_by(
            HRAdjustment.employee_code,
            HRAdjustment.id,
        )

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        return await _adjustment_payloads(db, company_code, docs, _profile)

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 4.3 جلب تسويات موظف في شهر معين
#
# مثال:
# GET /hr/adjustments/employee/01/E001?month=2026-11
# ------------------------------------------------------------


# مسار تسويات موظف معين
@router.get("/adjustments/employee/{company_code}/{employee_code}")
async def list_employee_adjustments(
    request: Request,
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
    _profile = await _authorize_employee_target(
        request, db, company_code, employee_code
    )

    try:
        stmt = (
            select(HRAdjustment)
            .where(
                HRAdjustment.company_code == company_code,
                HRAdjustment.employee_code == employee_code,
                HRAdjustment.month == month,
                HRAdjustment.is_deleted.is_(False),
            )
            .order_by(HRAdjustment.id)
        )

        result = await db.execute(stmt)
        docs = result.scalars().all()

        return await _adjustment_payloads(db, company_code, docs, _profile, target=getattr(request.state, 'hr_target', None))

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 4.4 حذف تسوية (Soft Delete)
# ------------------------------------------------------------


# مسار حذف تسوية
@router.delete("/adjustments/delete/{company_code}/{adjustment_id}")
async def delete_adjustment(
    request: Request,
    company_code: str,
    adjustment_id: int,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canDeleteAdjustment")
    _check_tenant(_profile, company_code)

    try:
        stmt = (
            select(HRAdjustment)
            .where(
                HRAdjustment.company_code == company_code,
                HRAdjustment.id == adjustment_id,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="التسوية غير موجودة",
            )

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "التسوية محذوفة بالفعل",
            }

        # Soft Delete
        _check_hr_branch(_profile, existing.branch_code)

        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        # WebSocket
        await manager.broadcast(
            company_code,
            {
                "type": "hr_adjustment",
                "action": "delete",
                "data": {
                    "id": existing.id,
                    "company_code": company_code,
                    "employee_code": existing.employee_code,
                    "month": existing.month,
                    "updated_at": (
                        existing.updated_at.isoformat()
                        if existing.updated_at
                        else None
                    ),
                    "is_deleted": True,
                },
            },
        )

        return {
            "status": "success",
            "message": "تم حذف التسوية بنجاح",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 4.5 المزامنة التزايدية للتسويات
# ------------------------------------------------------------


# يحسب بصمة إضافية لفيد التسويات حسب صلاحية المبالغ للمشاهد
def _adjustment_fp_extra(profile):
    # Amounts are masked per viewer: the effective salary-amount privilege (which already folds in the
    # company policy for non-bypass roles) and the policy flag itself are part of the fingerprint.
    return {"amounts": bool(_hr_has(profile, "canViewSalaryAmounts")),
            "policy": profile.get("company_policy_active") is True}


# يخفي مبلغ التسوية لو المشاهد ملوش حق المبالغ
def _adjustment_mask(item, doc, own, profile):
    if not (_hr_has(profile, "canViewSalaryAmounts") or str(doc.employee_code) in own):
        item["amount"] = None
    return item


# مسار فيد v2 للتسويات
@router.get("/adjustments/changes-v2/{company_code}")
async def get_adjustment_changes_v2(
    request: Request, company_code: str,
    cursor: str = Query("0:0"), limit: int = Query(200, ge=1, le=500), scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    return await _hr_feed_v2(HRAdjustment, "hr_adjustments", "hr_adjustments", serialize_adjustment,
                             request, company_code, cursor, limit, scope, db,
                             "canViewAdjustments", "canViewBranchSalaryReport",
                             fp_extra=_adjustment_fp_extra, mask=_adjustment_mask)


# مسار التغييرات منذ آخر مزامنة للتسويات
@router.get("/adjustments/changes/{company_code}")
async def get_adjustment_changes(
    request: Request,
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canViewAdjustments", "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    try:
        since_dt = _parse_since(since)

        stmt = (
            select(HRAdjustment)
            .where(
                HRAdjustment.company_code == company_code,
                HRAdjustment.updated_at >= since_dt,
            )
            .order_by(HRAdjustment.updated_at)
        )

        result = await db.execute(stmt)
        docs = await _filter_docs(
            db, result.scalars().all(), company_code, _profile
        )

        return await _adjustment_payloads(db, company_code, docs, _profile, changes=True)

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="صيغة since غير صحيحة",
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# ============ 5. REPORTS (تقارير الرواتب) ===================
# ============================================================


# ------------------------------------------------------------
# 5.1 تقرير راتب موظف في شهر
#
# مثال:
# GET /hr/reports/salary/01/E001?month=2026-11
#
# ملاحظات:
# - الحساب بيحصل بالكامل في الباك (calculate_salary)
# - الفرونت بيستخدم نفس المنطق محليًا للعرض السريع (local-first)
# - الباك هو المرجع الرسمي (official source of truth) عند الاختلاف
# ------------------------------------------------------------


# مسار تقرير راتب موظف لشهر معين
@router.get("/reports/salary/{company_code}/{employee_code}")
async def get_salary_report(
    request: Request,
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
    _profile = await _authorize_employee_target(
        request, db, company_code, employee_code, salary=True
    )

    try:
        # ---------- التحقق ----------
        if len(month) != 7 or "-" not in month:
            raise HTTPException(
                status_code=400,
                detail="صيغة الشهر يجب أن تكون YYYY-MM",
            )

        # ---------- الحساب ----------
        report = await calculate_salary(
            db=db,
            company_code=company_code,
            employee_code=employee_code,
            month=month,
        )

        # عقد صفحة التقرير: من فتحها بـ canOpenReportPage فقط (بدون
        # canViewSalaryAmounts وبدون أن يكون صاحب السجل) يرى بنية
        # التقرير مع إخفاء المبالغ، كما تفعل الواجهة عند العرض.
        if not amounts_allowed(_profile, getattr(request.state, 'hr_target', None)):
            report = _redact_salary_amounts(report)

        return report

    except HTTPException:
        raise

    except ValueError as e:
        raise HTTPException(
            status_code=404,
            detail=str(e),
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في حساب الراتب: {str(e)}",
        )


# ============================================================
# 6. تقرير إجمالي الرواتب لكل فرع
# ============================================================


# مسار إجمالي رواتب الفروع لشهر معين
@router.get("/reports/branches/salaries")
async def get_branch_salaries_totals(
    request: Request,
    company_code: str = Query(..., description="كود الشركة"),
    month: str = Query(..., description="YYYY-MM"),
    branch_code: Optional[str] = Query(
        None,
        description="كود الفرع (null = كل الشركة)",
    ),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_hr(request, "canViewBranchSalaryReport")
    _check_tenant(_profile, company_code)

    """
    يجيب إجمالي رواتب كل الموظفين في فرع/شركة لشهر محدد.
    - branch_code = null → كل الشركة
    - branch_code = "B01" → فرع محدد
    """
    try:
        if not month or len(month) != 7 or "-" not in month:
            raise HTTPException(
                status_code=400,
                detail="صيغة الشهر يجب أن تكون YYYY-MM",
            )

        # 1) جلب الموظفين
        stmt = select(Employee).where(
            Employee.company_code == company_code,
            Employee.is_deleted.is_(False),
        )
        if branch_code:
            # طلب فرع محدد: لازم يكون ضمن فروع العارض
            _check_hr_branch(_profile, branch_code)
            stmt = stmt.where(Employee.branch_code == branch_code)

        # تقييد التقرير بفروع العارض والموظفين المرئيين له
        _allowed = allowed_branches_for_profile(_profile)
        if _allowed:
            stmt = stmt.where(
                or_(
                    Employee.branch_code.in_(_allowed),
                    Employee.branch_code.is_(None),
                    Employee.branch_code == "",
                )
            )
        _viewable = _hr_viewable_codes(_profile)
        if _viewable is not None:
            stmt = stmt.where(Employee.code.in_(_viewable))

        result = await db.execute(stmt)
        employees = result.scalars().all()

        if not employees:
            return _branch_report_payload(_profile, {
                "company_code": company_code,
                "month": month,
                "branch_code": branch_code or "all",
                "totals": {
                    "employees_count": 0,
                    "total_base_pay": 0.0,
                    "total_absence_deduction": 0.0,
                    "total_delay_deduction": 0.0,
                    "total_overtime_bonus": 0.0,
                    "total_bonuses": 0.0,
                    "total_deductions": 0.0,
                    "total_loans": 0.0,
                    "total_net_salary": 0.0,
                },
                "employees": [],
            })

        # 2) حساب راتب كل موظف (chunks of 5)
        import asyncio

        employees_data = []
        totals = {
            "employees_count": 0,
            "total_base_pay": 0.0,
            "total_absence_deduction": 0.0,
            "total_delay_deduction": 0.0,
            "total_overtime_bonus": 0.0,
            "total_bonuses": 0.0,
            "total_deductions": 0.0,
            "total_loans": 0.0,
            "total_net_salary": 0.0,
        }

        # يحسب راتب موظف واحد ضمن تقرير الفروع
        async def _calc_one(emp):
            try:
                report = await calculate_salary(
                    db=db,
                    company_code=company_code,
                    employee_code=emp.code,
                    month=month,
                )
                return (emp, report, None)
            except Exception as e:
                return (emp, None, str(e))

        for i in range(0, len(employees), 5):
            chunk = employees[i:i + 5]
            results = await asyncio.gather(
                *[_calc_one(e) for e in chunk],
                return_exceptions=False,
            )

            for emp, report, error in results:
                if report is None:
                    print(f"⚠️ فشل حساب راتب {emp.code}: {error}")
                    continue

                totals["employees_count"] += 1
                totals["total_base_pay"] += report.get("base_pay", 0.0)
                totals["total_absence_deduction"] += report.get("absence_deduction", 0.0)
                totals["total_delay_deduction"] += report.get("late_deduction", 0.0)
                totals["total_overtime_bonus"] += report.get("overtime_bonus", 0.0)
                totals["total_bonuses"] += report.get("bonuses_total", 0.0)
                totals["total_deductions"] += report.get("deductions_total", 0.0)
                totals["total_loans"] += report.get("loans_total", 0.0)
                totals["total_net_salary"] += report.get("net_salary", 0.0)

                employees_data.append({
                    "employee_code": emp.code,
                    "employee_name": emp.name,
                    "branch_code": emp.branch_code or "",
                    "base_pay": report.get("base_pay", 0.0),
                    "absence_deduction": report.get("absence_deduction", 0.0),
                    "delay_deduction": report.get("late_deduction", 0.0),
                    "overtime_bonus": report.get("overtime_bonus", 0.0),
                    "bonuses_total": report.get("bonuses_total", 0.0),
                    "deductions_total": report.get("deductions_total", 0.0),
                    "loans_total": report.get("loans_total", 0.0),
                    "net_salary": report.get("net_salary", 0.0),
                    "present_days": report.get("present_days", 0),
                    "absent_days": report.get("absent_days", 0),
                    "vacation_days": report.get("vacation_days", 0),
                })

        totals_rounded = {
            k: round(v, 2) if isinstance(v, float) else v
            for k, v in totals.items()
        }

        employees_data.sort(
            key=lambda x: (
                int(x["employee_code"]) if x["employee_code"].isdigit() else 999999
            )
        )

        return _branch_report_payload(_profile, {
            "company_code": company_code,
            "month": month,
            "branch_code": branch_code or "all",
            "totals": totals_rounded,
            "employees": employees_data,
        })

    except HTTPException:
        raise

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في حساب إجمالي الرواتب: {str(e)}",
        )
#
# المسارات المتاحة (كلها تحت prefix="/hr"):
# ------------------------------------------------------------
# ATTENDANCE:
#   POST   /attendance/save
#   GET    /attendance/list/{company}
#   GET    /attendance/employee/{company}/{emp}
#   GET    /attendance/changes/{company}
#   DELETE /attendance/delete/{company}/{id}
#
# VACATIONS:
#   POST   /vacations/save
#   GET    /vacations/list/{company}
#   GET    /vacations/changes/{company}
#   DELETE /vacations/delete/{company}/{id}
#
# EMPLOYEE SETTINGS:
#   GET    /employee-settings/{company}/{emp}
#   POST   /employee-settings/save
#   GET    /employee-settings/changes/{company}     ← جديد
#
# ADJUSTMENTS:
#   POST   /adjustments/save
#   GET    /adjustments/list/{company}
#   GET    /adjustments/employee/{company}/{emp}
#   GET    /adjustments/changes/{company}
#   DELETE /adjustments/delete/{company}/{id}
#
# REPORTS:
#   GET    /reports/salary/{company}/{emp}
# ============================================================
