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
from app.services.hr_salary_calculator import calculate_salary

import datetime


router = APIRouter()


# ============================================================
# Helper: تحويل since (نص ISO 8601) إلى datetime UTC (naive)
#
# جدول updated_at عندنا = TIMESTAMP WITHOUT TIME ZONE
# فالازم نشيل الـ timezone بعد ما نحول لـ UTC.
# ============================================================

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


# ------------------------------------------------------------
# 1.1 حفظ / تحديث حضور
#
# المفتاح الفريد: (company_code, employee_code, date)
# ------------------------------------------------------------

@router.post("/attendance/save")
async def save_attendance(
    data: HRAttendanceModel,
    db: AsyncSession = Depends(get_db),
):
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

        # ---------- تعديل موجود ----------
        if existing:
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

@router.get("/attendance/list/{company_code}")
async def list_attendance(
    company_code: str,
    date: str | None = Query(None, description="YYYY-MM-DD (يوم واحد)"),
    from_date: str | None = Query(None, description="YYYY-MM-DD (بداية النطاق)"),
    to_date: str | None = Query(None, description="YYYY-MM-DD (نهاية النطاق)"),
    branch_code: str | None = Query(None),
    employee_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

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

@router.get("/attendance/employee/{company_code}/{employee_code}")
async def list_employee_attendance(
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
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

@router.delete("/attendance/delete/{company_code}/{attendance_id}")
async def delete_attendance(
    company_code: str,
    attendance_id: int,
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/attendance/changes/{company_code}")
async def get_attendance_changes(
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

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


# ============================================================
# ================ 2. VACATIONS (الإجازات) ====================
# ============================================================


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


# ------------------------------------------------------------
# 2.1 حفظ / تحديث إجازة
#
# أنواع الإجازات:
# - عامة (لكل الشركة): branch_code=None, employee_code=None
# - لفرع معين:         branch_code=X,    employee_code=None
# - لموظف معين:        employee_code=Y   (branch_code يبقى None تلقائيًا)
# ------------------------------------------------------------

@router.post("/vacations/save")
async def save_vacation(
    data: HRVacationModel,
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/vacations/list/{company_code}")
async def list_vacations(
    company_code: str,
    from_date: str | None = Query(None, description="YYYY-MM-DD"),
    to_date: str | None = Query(None, description="YYYY-MM-DD"),
    branch_code: str | None = Query(None),
    employee_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

        return [serialize_vacation(doc) for doc in docs]

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 2.3 حذف إجازة (Soft Delete)
# ------------------------------------------------------------

@router.delete("/vacations/delete/{company_code}/{vacation_id}")
async def delete_vacation(
    company_code: str,
    vacation_id: int,
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/vacations/changes/{company_code}")
async def get_vacation_changes(
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

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

@router.get("/employee-settings/changes/{company_code}")
async def get_employee_settings_changes(
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/employee-settings/{company_code}/{employee_code}")
async def get_employee_settings(
    company_code: str,
    employee_code: str,
    db: AsyncSession = Depends(get_db),
):
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

@router.post("/employee-settings/save")
async def save_employee_settings(
    data: HREmployeeSettingsModel,
    db: AsyncSession = Depends(get_db),
):
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


# ------------------------------------------------------------
# 4.1 حفظ / إضافة تسوية (خصم / مكافأة / سلفة)
#
# ملاحظة:
# - للأقساط، الفرونت بيبعت صف منفصل لكل شهر (زي ما هو في vacations_page)
# - هنا بنسجل صف واحد بس، والتكرار بيحصل على مستوى الفرونت
# ------------------------------------------------------------

@router.post("/adjustments/save")
async def save_adjustment(
    data: HRAdjustmentModel,
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/adjustments/list/{company_code}")
async def list_adjustments(
    company_code: str,
    month: str = Query(..., description="YYYY-MM"),
    branch_code: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

        return [serialize_adjustment(doc) for doc in docs]

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

@router.get("/adjustments/employee/{company_code}/{employee_code}")
async def list_employee_adjustments(
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
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

        return [serialize_adjustment(doc) for doc in docs]

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ------------------------------------------------------------
# 4.4 حذف تسوية (Soft Delete)
# ------------------------------------------------------------

@router.delete("/adjustments/delete/{company_code}/{adjustment_id}")
async def delete_adjustment(
    company_code: str,
    adjustment_id: int,
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/adjustments/changes/{company_code}")
async def get_adjustment_changes(
    company_code: str,
    since: str = Query(..., description="ISO 8601"),
    db: AsyncSession = Depends(get_db),
):
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
        docs = result.scalars().all()

        results = []
        for doc in docs:
            action = "delete" if doc.is_deleted else "update"
            results.append(serialize_adjustment(doc, action=action))

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

@router.get("/reports/salary/{company_code}/{employee_code}")
async def get_salary_report(
    company_code: str,
    employee_code: str,
    month: str = Query(..., description="YYYY-MM"),
    db: AsyncSession = Depends(get_db),
):
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

@router.get("/reports/branches/salaries")
async def get_branch_salaries_totals(
    company_code: str = Query(..., description="كود الشركة"),
    month: str = Query(..., description="YYYY-MM"),
    branch_code: Optional[str] = Query(
        None,
        description="كود الفرع (null = كل الشركة)",
    ),
    db: AsyncSession = Depends(get_db),
):
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
            stmt = stmt.where(Employee.branch_code == branch_code)

        result = await db.execute(stmt)
        employees = result.scalars().all()

        if not employees:
            return {
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
            }

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

        return {
            "company_code": company_code,
            "month": month,
            "branch_code": branch_code or "all",
            "totals": totals_rounded,
            "employees": employees_data,
        }

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