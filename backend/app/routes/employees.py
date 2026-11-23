# backend/app/routes/employees.py

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, and_, or_, true

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.models import (
    Employee,
    HRAttendance,
    HRVacation,
    HRAdjustment,
    HREmployeeSettings,
)
from app.core.permissions import (
    has_section_permission,
    require_any_section_permission,
    require_section_permission,
)
from app.core.schemas import EmployeeModel
from app.core.hr_audience import HRTarget, own_access, amounts_allowed
from app.core.hr_identity import employee_self_clause
from app.core.sync import manager

import datetime


# ------------------------------------------------------------------
# صلاحيات الموظفين والـ HR:
# - سجل الموظفين: عرض أساسي (كود/اسم/فرع) عبر "عرض الموظفين"،
#   والبيانات الشخصية والراتب الأساسي عبر صلاحيات HR فقط.
# ------------------------------------------------------------------
# صلاحيات تؤهّل لرؤية كامل بيانات الموظف (شخصية ووظيفية)،
# مطابقة لاستخدام الواجهة في hr_dashboard/employees_list/profile:
_HR_SECTION = "الموارد البشرية"
_HR_PERMISSIONS = (
    (_HR_SECTION, "canViewEmployees"),
    (_HR_SECTION, "canManageEmployees"),
    (_HR_SECTION, "canOpenAttendancePage"),
    (_HR_SECTION, "canOpenVacationsPage"),
    (_HR_SECTION, "canViewAdjustments"),
    (_HR_SECTION, "canViewBranchSalaryReport"),
)

# من يحق له جلب سجل الموظفين أصلاً:
# - صلاحيات HR أعلاه + canViewOwnHRData (الواجهة تعرض له سجله فقط)
# - أو صلاحية في قسم مستهلك لمرجع الموظفين (كود/اسم/فرع): تحصيلات العملاء
#   والمبيعات تستخدم قوائم اختيار الموظفين.
_EMPLOYEES_VIEW_CHECKS = list(_HR_PERMISSIONS) + [
    (_HR_SECTION, "canViewOwnHRData"),
    ("حسابات العملاء", "إضافة تحصيل"),
    ("حسابات العملاء", "معاينة"),
    ("المبيعات", "إضافة"),
    ("المبيعات", "معاينة"),
]

# حقول العقد المرجعي لمن له "عرض الموظفين" فقط: كود/اسم/فرع/وظيفة
# لأن قوائم الاختيار في الشاشات (المبيعات والتحصيلات والحضور) تعتمد عليها.
_REFERENCE_WORK_FIELDS = {
    "id", "company_code", "code", "name",
    "job_title", "department", "branch_code",
    "status",
    "updated_at", "is_deleted", "action",
}


def _can_view_hr(profile: dict) -> bool:
    return any(
        has_section_permission(profile, category, key)
        for category, key in _HR_PERMISSIONS
    )


def _is_own_only_viewer(profile: dict) -> bool:
    """canViewOwnHRData فقط دون أي صلاحية HR أوسع → يرى سجله فقط."""
    return (
        has_section_permission(profile, _HR_SECTION, "canViewOwnHRData")
        and not _can_view_hr(profile)
    )


def _is_own_doc(profile: dict, doc) -> bool:
    return HRTarget.from_employee(doc).matches_account(profile)


def _employee_payload(
    doc,
    *,
    viewer_can_hr: bool,
    viewer_can_salary: bool = True,
    action: str | None = None,
    viewer_profile: dict | None = None,
) -> dict:
    """حمولة الموظف حسب صلاحية العارض:
    - HR: كامل البيانات، والراتب فقط مع canViewSalaryAmounts.
    - غير HR: العقد المرجعي فقط (كود/اسم/فرع/وظيفة/حالة).
    - سجل العارض نفسه يحتفظ بحقول الهوية (user_uid/user_email) لأن
      العميل يحل بها currentEmployeeCode؛ لا تظهر في سجلات الآخرين.
    """
    data = serialize_employee(doc, action=action)
    if viewer_profile is not None and own_access(viewer_profile, HRTarget.from_employee(doc)):
        return data
    if not viewer_can_hr:
        is_own = viewer_profile is not None and _is_own_doc(viewer_profile, doc)
        keep = set(_REFERENCE_WORK_FIELDS)
        if is_own:
            keep |= {"user_uid", "user_email"}
        data = {
            key: value
            for key, value in data.items()
            if key in keep
        }
    elif not viewer_can_salary:
        data["salary"] = None
    return data


def _check_branch(profile: dict, branch_code) -> None:
    allowed = allowed_branches_for_profile(profile)
    if allowed and branch_code and str(branch_code) not in allowed:
        raise HTTPException(
            status_code=403,
            detail="ليس لديك صلاحية على هذا الفرع",
        )


def _check_tenant(profile: dict, company_code: str) -> None:
    """فحص صريح: شركة المسار = شركة الجلسة (صاحب البرنامج يتجاوز)."""
    from app.core.auth_middleware import _effective_role
    if _effective_role(profile) == "super_admin":
        return
    if str(profile.get("company_code", "")) != str(company_code):
        raise HTTPException(status_code=403, detail="غير مصرح لهذه الشركة")


def _hr_viewable_codes(profile: dict):
    """قائمة الموظفين المرئيين لهذا المستخدم في HR (فارغة/غائبة = الكل)."""
    value = profile.get("hr_viewable_employees")
    if isinstance(value, list) and value:
        return {str(v) for v in value}
    return None


def _branch_filter_clause(profile: dict):
    """فلتر فروع للاستعلامات، None = كل الفروع.

    الموظف بفرع فارغ/غير معيّن يظهر لأي عارض له حق القسم، مطابقة
    سلوك العميل (canViewEmployee يتخطى فحص الفرع عند فرع فارغ).
    """
    allowed = allowed_branches_for_profile(profile)
    if not allowed:
        return None
    from sqlalchemy import or_
    return or_(
        Employee.branch_code.in_(allowed),
        Employee.branch_code.is_(None),
        Employee.branch_code == "",
    )


def _employee_visibility_clause(profile):
    own = employee_self_clause(profile)
    if _is_own_only_viewer(profile):
        return own
    branch = _branch_filter_clause(profile)
    clauses = [branch] if branch is not None else []
    viewable = _hr_viewable_codes(profile)
    if viewable is not None:
        clauses.append(Employee.code.in_(viewable))
    broad = and_(*clauses) if clauses else true()
    if has_section_permission(profile, _HR_SECTION, 'canViewOwnHRData'):
        return or_(broad, own)
    return broad


router = APIRouter()
# ============================================================
# ⭐ Helper: توليد كود الموظف التالي (serial تلقائي)
# ============================================================

async def _get_next_employee_code(
    db: AsyncSession,
    company_code: str,
) -> str:
    """
    يرجع أعلى كود رقمي + 1 (serial تلقائي).
    
    - بيتجاهل الأكواد غير الرقمية (زي "E001")
    - لو مفيش أي كود رقمي → يرجع "1"
    """
    from sqlalchemy import cast, Integer, func
    
    stmt = select(func.max(cast(Employee.code, Integer))).where(
        Employee.company_code == company_code,
        Employee.code.op('~')('^[0-9]+$'),   # PostgreSQL regex
    )
    
    result = await db.execute(stmt)
    max_code = result.scalar()
    
    return str((max_code or 0) + 1)


# ============================================================
# Helper: تحويل التواريخ من نص لـ datetime
# ============================================================

def _parse_date(value):
    """
    يحوّل نص ISO 8601 لـ datetime.
    يرجع None لو القيمة فاضية أو غير صالحة.
    """
    if not value:
        return None

    try:
        # إزالة الـ timezone إذا موجود
        return datetime.datetime.fromisoformat(
            str(value).replace("Z", "+00:00")
        ).replace(tzinfo=None)
    except (ValueError, TypeError):
        return None


def _date_to_iso(value):
    """
    يحوّل datetime لنص ISO 8601.
    يرجع None لو القيمة فاضية.
    """
    if not value:
        return None
    return value.isoformat()


# ============================================================
# Helper: تحويل الموظف لـ JSON
# (نفس شكل CodingSyncModel عشان الواجهة تستخدمه بسهولة)
# ============================================================

def serialize_employee(
    doc: Employee,
    action: str | None = None,
):
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "code": doc.code,
        "name": doc.name,

        # بيانات أساسية
        "phone": doc.phone,
        "email": doc.email,
        "national_id": doc.national_id,
        "address": doc.address,
        "gender": doc.gender,
        "birth_date": _date_to_iso(doc.birth_date),

        # بيانات وظيفية
        "job_title": doc.job_title,
        "department": doc.department,
        "branch_code": doc.branch_code,
        "hire_date": _date_to_iso(doc.hire_date),
        "end_date": _date_to_iso(doc.end_date),
        "salary": doc.salary,
        "contract_type": doc.contract_type,
        "status": doc.status,
        "manager_uid": doc.manager_uid,

        # ربط Firebase
        "user_uid": doc.user_uid,
        "user_email": doc.user_email,

        # إضافي
        "emergency_contact": doc.emergency_contact,
        "bank_account": doc.bank_account,
        "bank_name": doc.bank_name,
        "notes": doc.notes,
        "meta": doc.meta or {},

        # مزامنة
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


# ============================================================
# Helpers — HR data serializers (للـ profile endpoint)
# ============================================================

def _serialize_attendance(doc: HRAttendance):
    return {
        "id": doc.id,
        "date": doc.date,
        "status": doc.status,
        "check_in": doc.check_in,
        "check_out": doc.check_out,
        "late_minutes": doc.late_minutes or 0,
        "early_leave_minutes": doc.early_leave_minutes or 0,
        "overtime_minutes": doc.overtime_minutes or 0,
        "notes": doc.notes,
    }


def _serialize_vacation(doc: HRVacation):
    return {
        "id": doc.id,
        "date": doc.date,
        "name": doc.name,
        "type": doc.type,
        "branch_code": doc.branch_code,
        "employee_code": doc.employee_code,
    }


def _serialize_adjustment(doc: HRAdjustment):
    return {
        "id": doc.id,
        "month": doc.month,
        "date": doc.date,
        "type": doc.type,
        "amount": doc.amount,
        "reason": doc.reason,
        "installment_ref": doc.installment_ref,
        "status": doc.status,
    }


def _serialize_settings(doc: HREmployeeSettings | None):
    if not doc:
        # القيم الافتراضية (مطابقة للفرونت)
        return {
            "company_code": "",
            "employee_code": "",
            "weekly_vacation_day": None,
            "default_check_in": "09:00",
            "default_check_out": "17:00",
            "flexible_hours": False,
            "use_fixed_month_days": True,
            "delay_rules": {},
        }

    return {
        "id": doc.id,
        "company_code": doc.company_code,
        "employee_code": doc.employee_code,
        "weekly_vacation_day": doc.weekly_vacation_day,
        "default_check_in": doc.default_check_in or "09:00",
        "default_check_out": doc.default_check_out or "17:00",
        "flexible_hours": bool(doc.flexible_hours),
        "use_fixed_month_days": bool(doc.use_fixed_month_days),
        "delay_rules": doc.delay_rules or {},
    }


# ============================================================
# 1. حفظ موظف (إضافة أو تحديث)
# ============================================================

@router.post("/save")
async def save_employee(
    data: EmployeeModel,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _profile = request.state.auth_user
    # إضافة أو تعديل حسب وجود السجل
    _existing_stmt = select(Employee).where(
        Employee.company_code == data.company_code,
        Employee.code == (data.code or "").strip(),
    )
    _existing_result = await db.execute(_existing_stmt)
    _existing_doc = _existing_result.scalar_one_or_none()
    require_section_permission(request, _HR_SECTION, "canManageEmployees")
    _check_tenant(_profile, data.company_code)
    _check_branch(_profile, data.branch_code)
    if _existing_doc is not None:
        # الفرع المخزَّن أيضاً: منع تعديل/نقل سجل فرع غير مسموح
        _check_branch(_profile, _existing_doc.branch_code)
    try:
        company_code = data.company_code
        code = (data.code or "").strip()

        # ------------------------------------------------------
        # ⭐ توليد كود تلقائي لو مش معبأ أو "auto"
        # ------------------------------------------------------

        if not code or code.lower() in ("auto", "0", "new"):
            code = await _get_next_employee_code(db, company_code)

        if not data.name or not data.name.strip():
            raise HTTPException(
                status_code=400,
                detail="اسم الموظف مطلوب",
            )

        # ------------------------------------------------------
        # البحث عن السجل حتى لو Soft Deleted
        # ------------------------------------------------------

        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.code == code,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        # ------------------------------------------------------
        # تعديل موجود
        # ------------------------------------------------------

        _old_link_email = str(existing.user_email or "").strip().lower() if existing else ""
        _old_link_uid = str(existing.user_uid or "") if existing else ""
        if existing:
            existing.name = data.name
            existing.phone = data.phone
            existing.email = data.email
            existing.national_id = data.national_id
            existing.address = data.address
            existing.gender = data.gender
            existing.birth_date = _parse_date(data.birth_date)

            existing.job_title = data.job_title
            existing.department = data.department
            existing.branch_code = data.branch_code
            existing.hire_date = _parse_date(data.hire_date)
            existing.end_date = _parse_date(data.end_date)
            existing.salary = data.salary or 0.0
            existing.contract_type = data.contract_type
            existing.status = data.status or "active"
            existing.manager_uid = data.manager_uid

            existing.user_uid = data.user_uid
            existing.user_email = data.user_email

            existing.emergency_contact = data.emergency_contact
            existing.bank_account = data.bank_account
            existing.bank_name = data.bank_name
            existing.notes = data.notes
            existing.meta = data.meta or {}

            existing.updated_at = datetime.datetime.utcnow()

            was_deleted = bool(existing.is_deleted)
            existing.is_deleted = False

            action = "insert" if was_deleted else "update"
            tx = existing

        # ------------------------------------------------------
        # إضافة جديدة
        # ------------------------------------------------------

        else:
            tx = Employee(
                company_code=company_code,
                code=code,
                name=data.name,
                phone=data.phone,
                email=data.email,
                national_id=data.national_id,
                address=data.address,
                gender=data.gender,
                birth_date=_parse_date(data.birth_date),

                job_title=data.job_title,
                department=data.department,
                branch_code=data.branch_code,
                hire_date=_parse_date(data.hire_date),
                end_date=_parse_date(data.end_date),
                salary=data.salary or 0.0,
                contract_type=data.contract_type,
                status=data.status or "active",
                manager_uid=data.manager_uid,

                user_uid=data.user_uid,
                user_email=data.user_email,

                emergency_contact=data.emergency_contact,
                bank_account=data.bank_account,
                bank_name=data.bank_name,
                notes=data.notes,
                meta=data.meta or {},

                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )

            db.add(tx)
            action = "insert"

        _link_changed = (
            _old_link_email != str(data.user_email or "").strip().lower()
            or _old_link_uid != str(data.user_uid or "")
        )

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        await db.commit()
        await db.refresh(tx)

        # ------------------------------------------------------
        # WebSocket broadcast
        # ------------------------------------------------------

        # Reconcile both explicit account links before delivering new HR data.
        # UID-only links are included; an email cannot override a different UID.
        if _link_changed:
            from app.core.auth_middleware import invalidate_profile_cache
            for email in {_old_link_email, str(data.user_email or "").strip().lower()} - {""}:
                invalidate_profile_cache(email)
            await manager.notify_hr_link_changed(company_code, [
                HRTarget(code=code, uid=_old_link_uid, email=_old_link_email),
                HRTarget(code=code, uid=str(data.user_uid or ""),
                         email=str(data.user_email or "")),
            ])

        await manager.broadcast(
            company_code,
            {
                "type": "employee",
                "action": action,
                "data": serialize_employee(tx, action=action),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ الموظف بنجاح",
            "code": code,
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


# ============================================================
# 2. جلب قائمة الموظفين (غير المحذوفين)
# ============================================================

@router.get("/list/{company_code}")
async def list_employees(
    company_code: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _profile = require_any_section_permission(request, _EMPLOYEES_VIEW_CHECKS)
    _check_tenant(_profile, company_code)
    _can_hr = _can_view_hr(_profile)
    _viewable = _hr_viewable_codes(_profile)
    try:
        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.is_deleted.is_(False),
            )
            .order_by(Employee.code)
        )
        stmt = stmt.where(_employee_visibility_clause(_profile))

        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = [
            _employee_payload(
                doc,
                viewer_can_hr=_can_hr,
                viewer_can_salary=has_section_permission(
                    _profile, _HR_SECTION, "canViewSalaryAmounts"
                ),
                viewer_profile=_profile,
            )
            for doc in docs
        ]

        # ترتيب حسب الكود (رقمي لو ممكن)
        results.sort(
            key=lambda x: (
                int(x.get("code", 0))
                if str(x.get("code", "")).isdigit()
                else str(x.get("code", ""))
            )
        )

        return results

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 3. جلب موظف واحد بالتفصيل (للـ HR profile)
# ============================================================

@router.get("/get/{company_code}/{code}")
async def get_employee(
    company_code: str,
    code: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _profile = require_any_section_permission(request, _EMPLOYEES_VIEW_CHECKS)
    _check_tenant(_profile, company_code)
    _can_hr = _can_view_hr(_profile)
    try:
        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.code == code,
                Employee.is_deleted.is_(False),
            )
        )

        result = await db.execute(stmt)
        doc = result.scalar_one_or_none()

        if not doc:
            raise HTTPException(
                status_code=404,
                detail="الموظف غير موجود",
            )

        if not own_access(_profile, HRTarget.from_employee(doc)):
            if _is_own_only_viewer(_profile):
                raise HTTPException(status_code=403, detail="يمكنك عرض بياناتك فقط")
            _check_branch(_profile, doc.branch_code)
            _viewable = _hr_viewable_codes(_profile)
            if _viewable is not None and str(doc.code) not in _viewable:
                raise HTTPException(status_code=403, detail="ليس لديك صلاحية عرض هذا الموظف")
        return _employee_payload(
            doc,
            viewer_can_hr=_can_hr,
            viewer_can_salary=has_section_permission(
                _profile, _HR_SECTION, "canViewSalaryAmounts"
            ),
            viewer_profile=_profile,
        )

    except HTTPException:
        raise

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 4. حذف موظف (Soft Delete)
# ============================================================

@router.delete("/delete/{company_code}/{code}")
async def delete_employee(
    company_code: str,
    code: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _profile = require_section_permission(request, _HR_SECTION, "canManageEmployees")
    _check_tenant(_profile, company_code)
    try:
        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.code == code,
            )
        )

        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="الموظف غير موجود",
            )

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "الموظف محذوف بالفعل",
            }

        _check_branch(_profile, existing.branch_code)

        # Soft Delete
        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        # WebSocket broadcast
        # Deletion removes own-HR access, so send only a control invalidation
        # to that linked account, not the deleted employee's private payload.
        await manager.notify_hr_link_changed(company_code, [HRTarget(
            code=code, uid=str(existing.user_uid or ""),
            email=str(existing.user_email or ""), deleted=True,
        )])
        await manager.broadcast(
            company_code,
            {
                "type": "employee",
                "action": "delete",
                "data": {
                    "id": existing.id,
                    "company_code": company_code,
                    "code": code,
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
            "message": "تم حذف الموظف بنجاح",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )
# ============================================================
# 4.5 ⭐ بروفايل الموظف الشامل (لصفحة Profile)
#
# يجيب كل بيانات الموظف في طلب واحد:
# - Employee (كامل)
# - Attendance (ملخص الشهر + القائمة)
# - Vacations (المطبقة على الموظف)
# - Adjustments (الشهر)
# - Settings (مواعيد + delay_rules)
# ============================================================

@router.get("/profile/{company_code}/{code}")
async def get_employee_profile(
    company_code: str,
    code: str,
    request: Request,
    month: str = Query(
        None,
        description="YYYY-MM (افتراضي: الشهر الحالي)",
    ),
    db: AsyncSession = Depends(get_db),
):
    _profile = request.state.auth_user
    _check_tenant(_profile, company_code)
    _can_hr = _can_view_hr(_profile)
    try:
        # ---------- 1) الموظف ----------
        stmt = select(Employee).where(
            Employee.company_code == company_code,
            Employee.code == code,
            Employee.is_deleted.is_(False),
        )
        result = await db.execute(stmt)
        employee = result.scalar_one_or_none()

        if not employee:
            raise HTTPException(
                status_code=404,
                detail="الموظف غير موجود",
            )

        target = HRTarget.from_employee(employee)
        personal = own_access(_profile, target)
        if not personal:
            if not _can_hr:
                raise HTTPException(status_code=403, detail="ليس لديك صلاحية عرض ملف الموظف")
            _check_branch(_profile, employee.branch_code)
            _viewable = _hr_viewable_codes(_profile)
            if _viewable is not None and str(employee.code) not in _viewable:
                raise HTTPException(status_code=403, detail="ليس لديك صلاحية عرض هذا الموظف")
        can_amounts = amounts_allowed(_profile, target)

        # ---------- 2) الشهر (افتراضي: الحالي) ----------
        if not month:
            now = datetime.datetime.now()
            month = f"{now.year}-{now.month:02d}"

        if len(month) != 7 or "-" not in month:
            raise HTTPException(
                status_code=400,
                detail="صيغة الشهر يجب أن تكون YYYY-MM",
            )

        # ---------- 3) Attendance ----------
        att_stmt = (
            select(HRAttendance)
            .where(
                HRAttendance.company_code == company_code,
                HRAttendance.employee_code == code,
                HRAttendance.date.like(f"{month}-%"),
                HRAttendance.is_deleted.is_(False),
            )
            .order_by(HRAttendance.date)
        )
        att_result = await db.execute(att_stmt)
        attendance_docs = att_result.scalars().all()

        # ملخص
        present_days = 0
        absent_days = 0
        vacation_days = 0
        permission_days = 0
        late_minutes_total = 0
        overtime_minutes_total = 0

        for a in attendance_docs:
            if a.status in ("present", "late"):
                present_days += 1
            elif a.status == "absent":
                absent_days += 1
            elif a.status == "vacation":
                vacation_days += 1
            elif a.status == "permission":
                permission_days += 1
                present_days += 1

            late_minutes_total += a.late_minutes or 0
            overtime_minutes_total += a.overtime_minutes or 0

        # ---------- 4) Vacations ----------
        vac_stmt = (
            select(HRVacation)
            .where(
                HRVacation.company_code == company_code,
                HRVacation.is_deleted.is_(False),
            )
            .order_by(HRVacation.date)
        )
        vac_result = await db.execute(vac_stmt)
        vacations_all = vac_result.scalars().all()

        branch = employee.branch_code or "1"
        applicable_vacations = []
        for v in vacations_all:
            if v.employee_code is not None:
                if v.employee_code == code:
                    applicable_vacations.append(v)
            elif v.branch_code is not None:
                if v.branch_code == branch:
                    applicable_vacations.append(v)
            else:
                applicable_vacations.append(v)

        # ---------- 5) Adjustments ----------
        adj_stmt = (
            select(HRAdjustment)
            .where(
                HRAdjustment.company_code == company_code,
                HRAdjustment.employee_code == code,
                HRAdjustment.month == month,
                HRAdjustment.is_deleted.is_(False),
            )
            .order_by(HRAdjustment.id)
        )
        adj_result = await db.execute(adj_stmt)
        adjustment_docs = adj_result.scalars().all()

        bonuses_total = sum(
            a.amount for a in adjustment_docs
            if a.type == "bonus"
        )
        deductions_total = sum(
            a.amount for a in adjustment_docs
            if a.type == "deduction"
        )
        loans_total = sum(
            a.amount for a in adjustment_docs
            if a.type == "loan"
        )

        # ---------- 6) Settings ----------
        set_stmt = select(HREmployeeSettings).where(
            HREmployeeSettings.company_code == company_code,
            HREmployeeSettings.employee_code == code,
        )
        set_result = await db.execute(set_stmt)
        settings_doc = set_result.scalar_one_or_none()

        # ---------- 7) Response ----------
        return {
            "employee": _employee_payload(employee, viewer_can_hr=_can_hr,
                viewer_can_salary=can_amounts, viewer_profile=_profile),
            "month": month,
            "attendance": {
                "records": [
                    _serialize_attendance(a)
                    for a in attendance_docs
                ],
                "summary": {
                    "present_days": present_days,
                    "absent_days": absent_days,
                    "vacation_days": vacation_days,
                    "permission_days": permission_days,
                    "late_minutes_total": late_minutes_total,
                    "overtime_minutes_total": overtime_minutes_total,
                },
            },
            "vacations": [
                _serialize_vacation(v)
                for v in applicable_vacations
            ],
            "adjustments": {
                "records": [
                    {**_serialize_adjustment(a), **({"amount": None} if not can_amounts else {})}
                    for a in adjustment_docs
                ],
                "summary": {
                    "bonuses_total": bonuses_total if can_amounts else None,
                    "deductions_total": deductions_total if can_amounts else None,
                    "loans_total": loans_total if can_amounts else None,
                },
            },
            "settings": _serialize_settings(settings_doc),
        }

    except HTTPException:
        raise

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"خطأ في السيرفر: {str(e)}",
        )


# ============================================================
# 5. جلب التحديثات التزايدية للموظفين (للمزامنة)
#
# مهم:
# لا نستبعد is_deleted هنا.
# الجهاز Offline يحتاج يعرف أن السجل تم حذفه.
# ============================================================

@router.get("/changes/{company_code}")

# ============================================================
# 5. جلب التحديثات التزايدية للموظفين (للمزامنة)
#
# مهم:
# لا نستبعد is_deleted هنا.
# الجهاز Offline يحتاج يعرف أن السجل تم حذفه.
# ============================================================

@router.get("/changes/{company_code}")
async def get_employee_changes(
    company_code: str,
    request: Request,

    since: str = Query(
        ...,
        description=(
            "وقت آخر مزامنة بصيغة ISO 8601 "
            "مثال: 2026-08-11T14:30:00Z"
        ),
    ),

    db: AsyncSession = Depends(get_db),
):
    _profile = require_any_section_permission(request, _EMPLOYEES_VIEW_CHECKS)
    _check_tenant(_profile, company_code)
    _can_hr = _can_view_hr(_profile)
    try:
        # ------------------------------------------------------
        # تحويل since
        # ------------------------------------------------------

        since_dt = datetime.datetime.fromisoformat(
            since.replace("Z", "+00:00")
        )

        # ------------------------------------------------------
        # توحيد UTC
        # ------------------------------------------------------

        if since_dt.tzinfo is not None:
            since_dt = since_dt.astimezone(datetime.timezone.utc)
            since_dt = since_dt.replace(tzinfo=None)

        # ------------------------------------------------------
        # جلب كل التغييرات (بما فيها المحذوف)
        # ------------------------------------------------------

        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.updated_at >= since_dt,
            )
            .order_by(Employee.updated_at)
        )

        stmt = stmt.where(_employee_visibility_clause(_profile))

        result = await db.execute(stmt)
        docs = result.scalars().all()

        _can_salary = has_section_permission(
            _profile, _HR_SECTION, "canViewSalaryAmounts"
        )
        results = []

        for doc in docs:
            if doc.is_deleted:
                action = "delete"
            else:
                action = "update"

            results.append(
                _employee_payload(
                    doc,
                    viewer_can_hr=_can_hr,
                    viewer_can_salary=_can_salary,
                    action=action,
                    viewer_profile=_profile,
                )
            )

        return results

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=(
                "صيغة `since` غير صحيحة، "
                "استخدم ISO 8601"
            ),
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )