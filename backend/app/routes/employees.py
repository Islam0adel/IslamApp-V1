# backend/app/routes/employees.py

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.core.models import (
    Employee,
    HRAttendance,
    HRVacation,
    HRAdjustment,
    HREmployeeSettings,
)
from app.core.schemas import EmployeeModel
from app.core.sync import manager

import datetime


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
    db: AsyncSession = Depends(get_db),
):
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

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        await db.commit()
        await db.refresh(tx)

        # ------------------------------------------------------
        # WebSocket broadcast
        # ------------------------------------------------------

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
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(Employee)
            .where(
                Employee.company_code == company_code,
                Employee.is_deleted.is_(False),
            )
            .order_by(Employee.code)
        )

        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = [serialize_employee(doc) for doc in docs]

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
    db: AsyncSession = Depends(get_db),
):
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

        return serialize_employee(doc)

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
    db: AsyncSession = Depends(get_db),
):
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

        # Soft Delete
        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        # WebSocket broadcast
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
    month: str = Query(
        None,
        description="YYYY-MM (افتراضي: الشهر الحالي)",
    ),
    db: AsyncSession = Depends(get_db),
):
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
            "employee": serialize_employee(employee),
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
                    _serialize_adjustment(a)
                    for a in adjustment_docs
                ],
                "summary": {
                    "bonuses_total": bonuses_total,
                    "deductions_total": deductions_total,
                    "loans_total": loans_total,
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

    since: str = Query(
        ...,
        description=(
            "وقت آخر مزامنة بصيغة ISO 8601 "
            "مثال: 2026-08-11T14:30:00Z"
        ),
    ),

    db: AsyncSession = Depends(get_db),
):
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

        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = []

        for doc in docs:
            if doc.is_deleted:
                action = "delete"
            else:
                action = "update"

            results.append(
                serialize_employee(doc, action=action)
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