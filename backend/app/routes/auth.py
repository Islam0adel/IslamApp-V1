# backend/app/routes/auth.py
import os
import re
import time
import uuid
from datetime import datetime
from typing import Dict

from fastapi import APIRouter, HTTPException, Header, Body, Query, Depends, Request
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db, get_realtime_database  # Firestore + RTDB Admin
from google.cloud import firestore
from firebase_admin import auth as admin_auth
from typing import Optional, List
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.core.database import get_db, AsyncSessionLocal
from app.core.models import Company, Employee, Notification, AuditLog, Branch, CodingRecord
from app.core.schemas import CompanyModel
from app.core.fcm_service import send_push_to_user_bg

router = APIRouter()


# ============================================================
# ⭐ السوبر أدمن (SaaS Owner) — من .env فقط
# ============================================================
# الباك هو الوحيد اللي بيحدد job_code = "99"، مش المستخدم
# ============================================================

SUPER_ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.getenv("SUPER_ADMIN_EMAILS", "").split(",")
    if e.strip()
}

if SUPER_ADMIN_EMAILS:
    print(f"✅ SUPER_ADMIN_EMAILS loaded: {len(SUPER_ADMIN_EMAILS)} account(s)")
else:
    print("⚠️ WARNING: SUPER_ADMIN_EMAILS is empty — no one can be '99'")


# ============================================================
# ⭐ Role System — الأدوار الجديدة
# ============================================================

ROLE_TITLES = {
    "super_admin": "صاحب البرنامج",
    "admin": "مدير",
    "employee": "موظف",
}

ROLE_TO_JOB_CODE = {
    "super_admin": "99",
    "admin": "201",
    "employee": "1",
}

JOB_CODE_TO_ROLE = {
    "99": "super_admin",
    "201": "admin",
    "200": "employee",  # المشرف بيتحول لموظف
    "1": "employee",
}


def _default_role_for_job_code(job_code: str) -> str:
    """يحول job_code القديم لـ role جديد."""
    return JOB_CODE_TO_ROLE.get(str(job_code or "1"), "employee")


def _effective_role(profile: dict) -> str:
    """
    يحسب الدور الفعلي:
      - لو email في SUPER_ADMIN_EMAILS → super_admin (يتفوق)
      - وإلا: role من Firestore
      - وإلا: من job_code (توافق خلفي)
    """
    email = str(profile.get("email", "")).strip().lower()
    if email and email in SUPER_ADMIN_EMAILS:
        return "super_admin"
    role = str(profile.get("role", "")).strip()
    if role in ROLE_TITLES:
        return role
    return _default_role_for_job_code(str(profile.get("job_code", "1")))


def _require_program_admin(request: Request):
    """للـ endpoints القديمة — يفضل يعمل بـ job_code، لكن يقبل role كمان."""
    actor = getattr(request.state, "auth_user", {})
    role = _effective_role(actor)
    if role != "super_admin":
        raise HTTPException(status_code=403, detail="هذه الصلاحية خاصة بصاحب البرنامج فقط")


def _default_employee_permissions() -> dict:
    """
    ⭐ الصلاحيات الافتراضية للموظف الجديد.
    
    الفلسفة: يرى أيقونات كل الصفحات + مفيش صلاحيات داخلية.
    (Admin يمكنه منح صلاحيات لاحقاً من صفحة Permissions)
    """
    return {
        "حركة الخزينة": {
            "شاشات الارصدة": False, "ادخال اذون": False,
            "المعاينة": False, "التعديل": False, "الحذف": False,
            "استيراد من اكسل": False, "تصدير": False, "فلترة": False,
        },
        "التكويد": {
            "معاينة": False, "اضافة صنف": False, "سعر الشراء": False,
            "اضافة فرع": False, "اضافة خزينة": False, "اضافة مورد": False,
            "اضافة مخزن": False, "اضافة عملاء": False, "اضافة طرق دفع": False,
            "اضافة بنك": False, "اضافة موظف": False,
        },
        "حسابات الموردين": {
            "اضافة": False, "تعديل": False, "حذف": False,
            "معاينة": False, "تصدير": False,
        },
        "تسويات الموردين": {
            "إضافة": False, "تعديل": False, "حذف": False,
            "معاينة": False, "تصدير": False,
        },
        "حركة الجرد": {
            "اضافة": False, "تعديل": False, "حذف": False,
            "معاينة": False, "استيراد": False, "تصدير": False,
        },
        "التقارير": {
            "تقرير المبيعات": False, "تقرير فترة": False, "مشاركة": False,
            "تقرير التدفق النقدي": False, "تحليل هيكل المصروفات": False,
            "الربحية الصافية لكل فرع": False, "تحليل حجم الفاتورة": False,
            "تحليل الخزائن النقدية": False, "الأصناف بطيئة الحركة": False,
            "تحليل دقة الجرد": False, "تقييم المخزون و ABC": False,
            "تحليل أداء الموردين": False, "تحليل العوائد والخصومات": False,
            "تحليل الاتجاهات الموسمية": False, "تحليل هامش الربح الفعلي": False,
            "تحليل تجميع المنتجات": False,
            "تحليل المصروفات بالنسبة للمبيعات": False,
            "التقرير الموسع (صافي الجرد)": False,
        },
        "رصيد المخزون": {
            "معاينة": False, "عرض سعر الجملة": False, "تصدير": False,
        },
        "صلاحيات عامة": {
            "تغيير الفرع(صفحة الهوم)": False,
            "صفحة الصلاحيات(الاعدادات)": False,
            # ⭐ كل "إظهار X" = true → الأيقونات تظهر على HomePage
            "إظهار حركة الخزينة": True,
            "إظهار التكويد": True,
            "إظهار التقارير": True,
            "إظهار حركة الموردين": True,
            "إظهار حركة الجرد": True,
            "إظهار الإشعارات": True,
            "إظهار البحث عن المنتجات": True,
            "إظهار المستخدمين المتصلين": False,
            "إظهار الموارد البشرية": True,
        },
        "الموارد البشرية": {
            # ⭐ View-Only: يرى صفحته فقط
            "canViewOwnHRData": True,
            "canOpenAttendancePage": False,
            "canOpenVacationsPage": False,
            "canOpenReportPage": False,
            "canAddAttendance": False, "canEditAttendance": False, "canDeleteAttendance": False,
            "canAddVacation": False, "canEditVacation": False, "canDeleteVacation": False,
            "canViewAdjustments": False, "canAddBonus": False, "canAddLoan": False,
            "canEditAdjustment": False, "canDeleteAdjustment": False,
            "canEditWeeklyDay": False, "canEditWorkSchedule": False, "canEditDelayRules": False,
            "canAddDirectDiscount": False, "canViewSalaryAmounts": False,
            "canExportReport": False, "canViewEmployees": False,
            "canManageEmployees": False, "canViewBranchSalaryReport": False,
        },
    }

# ============================================================
# ⭐ Helper: إنشاء موظف تلقائياً عند التسجيل
# ============================================================

async def _get_next_employee_code(
    db: AsyncSession,
    company_code: str,
) -> str:
    """الحصول على كود الموظف التالي للشركة (1, 2, 3...)."""
    try:
        from sqlalchemy import func, cast, Integer as SAInteger

        stmt = select(func.max(cast(Employee.code, SAInteger))).where(
            Employee.company_code == str(company_code),
        )
        result = await db.execute(stmt)
        last_code = result.scalar() or 0
        return str(int(last_code) + 1)
    except Exception as e:
        print(f"⚠️ _get_next_employee_code: {e}")
        return "1"


async def _auto_create_employee_if_needed(
    db: AsyncSession,
    user_email: str,
    user_uid: str,
    user_name: str,
    user_phone: str,
    company_code: str,
    branch_code: str,
) -> dict | None:
    """
    ينشئ سجل موظف تلقائياً لو المستخدم مش مربوط بموظف موجود.

    ⭐ الأمان:
      1) يتحقق إن company_code موجود ومش فاضي
      2) يتحقق إن الشركة موجودة في DB و is_active=True
      3) يتحقق إن branch_code (لو موجود) تابع للشركة فعلاً
      4) لو branch_code مش صالح → يستخدم "" (كل الفروع)
      5) الربط بالـ phone بيتحقق من نفس company_code

    Returns: dict {code, name, linked, branch_code} أو None
    """
    email_clean = (user_email or "").strip().lower()
    phone_clean = (user_phone or "").strip()
    company_clean = str(company_code or "").strip()
    branch_clean = str(branch_code or "").strip()

    # ============================================================
    # ⭐ 0. حماية: شركة مطلوبة
    # ============================================================
    if not email_clean or not company_clean:
        print(f"⚠️ [Auto-Link] skipped: email='{email_clean}' company='{company_clean}'")
        return None

    try:
        # ============================================================
        # ⭐ 1. تحقق: الشركة موجودة ونشطة
        # ============================================================
        company_stmt = select(Company).where(
            Company.code == company_clean,
            Company.is_active.is_(True),
        )
        company_result = await db.execute(company_stmt)
        company = company_result.scalar_one_or_none()

        if not company:
            print(
                f"⚠️ [Auto-Link] skipped: company '{company_clean}' "
                f"غير موجودة أو موقوفة"
            )
            return None

        # ============================================================
        # ⭐ 2. تحقق: branch_code (لو موجود) تابع للشركة
        # ============================================================
        final_branch_code = branch_clean
        if branch_clean and branch_clean.lower() not in ("all", "الكل", "كل الفروع"):
            # ابحث في جدول الفروع (Branch أو CodingRecord)
            branch_stmt = select(Branch).where(
                Branch.company_code == company_clean,
                Branch.code == branch_clean,
            )
            branch_result = await db.execute(branch_stmt)
            existing_branch = branch_result.scalar_one_or_none()

            if not existing_branch:
                # جرب CodingRecord (احتياطي — بعض الأنظمة تخزن الفروع هناك)
                try:
                    
                    coding_branch_stmt = select(CodingRecord).where(
                        CodingRecord.company_code == company_clean,
                        CodingRecord.category == "branches",
                        CodingRecord.code == branch_clean,
                        CodingRecord.is_deleted.is_(False),
                    )
                    coding_branch_result = await db.execute(coding_branch_stmt)
                    existing_coding_branch = coding_branch_result.scalar_one_or_none()

                    if not existing_coding_branch:
                        print(
                            f"⚠️ [Auto-Link] branch '{branch_clean}' مش موجود "
                            f"في شركة '{company_clean}' — استخدام '' (كل الفروع)"
                        )
                        final_branch_code = ""
                except Exception as e:
                    print(f"⚠️ [Auto-Link] branch check failed: {e} — استخدام ''")
                    final_branch_code = ""
        else:
            # "all" أو "" أو "كل الفروع" → كل الفروع
            final_branch_code = ""

        branch_display = final_branch_code or "(all)"
        print(
            f"🔍 [Auto-Link] final company='{company_clean}' "
            f"branch='{branch_display}'"
        )

        # ============================================================
        # 3) موظف مربوط بنفس user_email (نفس الشركة)
        # ============================================================
        stmt = select(Employee).where(
            Employee.company_code == company_clean,   # ✅ فرض الشركة
            Employee.user_email == email_clean,
            Employee.is_deleted.is_(False),
        )
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if existing:
            if user_uid and not existing.user_uid:
                existing.user_uid = user_uid
                existing.updated_at = datetime.utcnow()
                await db.commit()
                print(f"🔗 [Auto-Link] ربط موظف موجود #{existing.code} بـ uid")
            return {
                "code": existing.code,
                "name": existing.name,
                "linked": True,
                "branch_code": existing.branch_code or "",
            }

        # ============================================================
        # 4) موظف بنفس phone (نفس الشركة، بدون user_email)
        # ============================================================
        if phone_clean:
            stmt = select(Employee).where(
                Employee.company_code == company_clean,   # ✅ فرض الشركة
                Employee.phone == phone_clean,
                Employee.user_email.is_(None) | (Employee.user_email == ""),
                Employee.is_deleted.is_(False),
            )
            result = await db.execute(stmt)
            existing_by_phone = result.scalar_one_or_none()

            if existing_by_phone:
                existing_by_phone.user_email = email_clean
                existing_by_phone.user_uid = user_uid or ""
                existing_by_phone.updated_at = datetime.utcnow()
                await db.commit()
                print(
                    f"🔗 [Auto-Link] ربط موظف #{existing_by_phone.code} "
                    f"بالإيميل {email_clean} (بواسطة phone في شركة {company_clean})"
                )
                return {
                    "code": existing_by_phone.code,
                    "name": existing_by_phone.name,
                    "linked": True,
                    "branch_code": existing_by_phone.branch_code or "",
                }

        # ============================================================
        # 5) إنشاء موظف جديد — داخل شركة محددة + فرع محقق
        # ============================================================
        next_code = await _get_next_employee_code(db, company_clean)

        new_emp = Employee(
            company_code=company_clean,          # ✅ شركة محددة
            code=next_code,
            name=(user_name or email_clean or "موظف جديد").strip(),
            phone=phone_clean,
            email=email_clean,
            user_uid=user_uid or "",
            user_email=email_clean,
            branch_code=final_branch_code,       # ✅ فرع محقق أو "" (كل الفروع)
            status="active",
            updated_at=datetime.utcnow(),
        )
        db.add(new_emp)
        await db.commit()
        await db.refresh(new_emp)

        print(
            f"✅ [Auto-Create] موظف جديد #{next_code} — "
            f"{new_emp.name} | company={company_clean} "
            f"| branch={final_branch_code or '(all)'} "
            f"({email_clean})"
        )
        return {
            "code": new_emp.code,
            "name": new_emp.name,
            "linked": False,
            "branch_code": final_branch_code,
        }

    except Exception as e:
        print(f"❌ _auto_create_employee_if_needed: {e}")
        try:
            await db.rollback()
        except Exception:
            pass
        return None


# ============================================================
# ⭐ Helper: البحث عن مستخدم بالموبايل (في Firestore)
# ============================================================

def find_user_by_phone(phone_number: str):
    """
    يبحث في users collection عن مستخدم عنده phone_number.
    Firestore مش بيدعم OR queries عادي، فبنعمل where بسيط.
    """
    if not phone_number or not phone_number.strip():
        return None
    try:
        results = db.collection("users").where(
            "phone_number", "==", phone_number.strip()
        ).limit(1).stream()
        for doc in results:
            return doc
    except Exception as e:
        print(f"⚠️ find_user_by_phone error: {e}")
    return None

def _email_doc_id(email: str) -> str:
    """doc id مؤقت للـ email-only users (قبل إكمال التسجيل)"""
    return f"email_{email.replace('@', '_at_').replace('/', '_')}"


def find_pending_user(phone: str = "", email: str = ""):
    """
    يبحث عن المستخدم المؤقت (pending) بـ:
      1. phone_number
      2. doc_id = email_XXX (email-only)
      3. doc_id = email (لو اتنقل)
    """
    phone = (phone or "").strip()
    email = (email or "").strip().lower()

    # 1) بالـ phone
    if phone:
        doc = find_user_by_phone(phone)
        if doc is not None:
            return doc

    # 2) email_XXX doc
    if email:
        try:
            doc = db.collection("users").document(_email_doc_id(email)).get()
            if doc.exists:
                return doc
        except Exception:
            pass

        # 3) email doc (لو اتنقل أو مكمل)
        try:
            doc = db.collection("users").document(email).get()
            if doc.exists:
                return doc
        except Exception:
            pass

    return None

def find_user_by_identifier(identifier: str):
    """
    يبحث بـ (إيميل / موبايل / يوزرنيم).
    Returns: (doc, type) where type is "email" | "phone" | "username" | None
    """
    identifier = (identifier or "").strip()
    if not identifier:
        return None, None

    # 1) إيميل
    if "@" in identifier:
        doc = db.collection("users").document(identifier.lower()).get()
        if doc.exists:
            return doc, "email"
        return None, "email"

    # 2) موبايل (أرقام فقط)
    if identifier.isdigit() and 8 <= len(identifier) <= 15:
        doc = find_user_by_phone(identifier)
        if doc is not None:
            return doc, "phone"
        return None, "phone"

    # 3) يوزرنيم
    try:
        results = (
            db.collection("users")
            .where("username", "==", identifier.lower())
            .limit(1)
            .stream()
        )
        for doc in results:
            return doc, "username"
    except Exception as e:
        print(f"⚠️ find_user_by_identifier username error: {e}")

    return None, None


# ============================================================
# ⭐ الأدوار المسموح للأدمن بإضافتها (بدون 99 و 201)
# ============================================================

ADMIN_ADDABLE_ROLES = {
    "1": "موظف عادي",
    "200": "مشرف",
}


# ============================================================
# ⭐ resolve-identifier — الدخول بـ (إيميل / موبايل / يوزرنيم)
# ============================================================

class IdentifierResolveModel(BaseModel):
    identifier: str  # إيميل أو موبايل أو يوزرنيم


# Rate limiting بسيط (in-memory, كافي لـ 1 process)
_IDENTIFIER_ATTEMPTS: Dict[str, list] = {}
_MAX_IDENTIFIER_ATTEMPTS = 10  # 10 محاولات
_IDENTIFIER_WINDOW_SECONDS = 60  # في الدقيقة


def _check_identifier_rate_limit(client_key: str) -> bool:
    """يرجع True لو مسموح، False لو تجاوز الحد."""
    now = time.time()
    attempts = [
        t for t in _IDENTIFIER_ATTEMPTS.get(client_key, [])
        if now - t < _IDENTIFIER_WINDOW_SECONDS
    ]
    if len(attempts) >= _MAX_IDENTIFIER_ATTEMPTS:
        return False
    attempts.append(now)
    _IDENTIFIER_ATTEMPTS[client_key] = attempts
    return True


# Username validation
_USERNAME_REGEX = re.compile(r"^[a-zA-Z0-9_]{3,30}$")


def _validate_username(username: str) -> str:
    """يتحقق من صيغة الـ username ويرجعه lowercase."""
    if not username:
        return ""
    u = username.strip().lower()
    if not _USERNAME_REGEX.match(u):
        raise HTTPException(
            status_code=400,
            detail="اسم المستخدم يجب أن يكون 3-30 حرف (a-z, 0-9, _)",
        )
    return u


def _is_username_taken(username: str, exclude_doc_id: str = "") -> bool:
    """يتحقق إن الـ username مش مستخدم في حساب تاني."""
    if not username:
        return False
    try:
        results = (
            db.collection("users")
            .where("username", "==", username)
            .limit(2)
            .stream()
        )
        for doc in results:
            if doc.id != exclude_doc_id:
                return True
    except Exception as e:
        print(f"⚠️ _is_username_taken error: {e}")
    return False

USER_ROLES = {
    "1": "موظف",
    "200": "مشرف",
    "201": "مدير",
    "99": "صاحب البرنامج"
}

class UserRegister(BaseModel):
    name: str
    email: EmailStr
    uid: str
    company_code: str
    # ⚠️ job_code: تم حذفه — الباك بيحدده من .env أو يعطيه "1" افتراضي
    employee_code: Optional[str] = None

class PermissionsUpdateModel(BaseModel):
    email: str
    permissions: dict
    allowed_branches: Optional[List[str]] = None
    hr_viewable_employees: Optional[List[str]] = None
    clear_hr_viewable_employees: bool = False

# ============================================================
# ⭐ Models جديدة — Admin Add User / Phone Check / Complete Reg
# ============================================================

class AdminAddUserModel(BaseModel):
    """الأدمن يضيف مستخدم جديد — الاسم اختياري، رقم/إيميل واحد على الأقل"""
    name: Optional[str] = None
    phone_number: Optional[str] = None
    branch_code: str
    role: str  # "admin" | "employee"
    company_code: Optional[str] = None
    email: Optional[str] = None
    username: Optional[str] = None


class PhoneCheckModel(BaseModel):
    # ⭐ الاسم قديم لكن المحتوى: identifier (إيميل/موبايل)
    phone_number: str


class CompleteRegistrationModel(BaseModel):
    # ⭐ phone_number اختياري (للسوبر أدمن)
    phone_number: Optional[str] = None
    email: EmailStr
    uid: str
    username: Optional[str] = None
    name: Optional[str] = None
    employee_code: Optional[str] = None  # ⭐ اختياري — لربط HR

class RegistrationRequestModel(BaseModel):
    """طلب انضمام لشركة (بدون دعوة)"""
    name: str
    phone_number: Optional[str] = None
    email: Optional[str] = None
    company_code: Optional[str] = None  # ⭐ اختياري — الأدمن يحدده
    branch_code: Optional[str] = None
    note: Optional[str] = None


class ApproveRequestModel(BaseModel):
    """الموافقة على طلب — تحدد الدور والفرع والشركة (لو مش محددة)"""
    role: str = "employee"
    branch_code: Optional[str] = ""
    company_code: Optional[str] = None  # ⭐ مطلوب لو الطلب مش محدد شركة

# ============================================================
# ⭐ إشعار السوبر أدمن بطلب انضمام جديد
# ============================================================
async def notify_super_admins_of_registration_request(
    request_doc_id: str,
    request_data: dict,
):
    """
    يبعت إشعار (Neon + Push) لكل سوبر أدمن لما يجي طلب انضمام جديد.
    """
    if not SUPER_ADMIN_EMAILS:
        print("⚠️ No SUPER_ADMIN_EMAILS configured — skip notification")
        return

    name = (request_data.get("name") or "").strip()
    phone = (request_data.get("phone_number") or "").strip()
    email = (request_data.get("email") or "").strip().lower()
    note = (request_data.get("note") or "").strip()

    title = "طلب انضمام جديد"

    body_parts = []
    if name:
        body_parts.append(f"الاسم: {name}")
    if phone:
        body_parts.append(f"الموبايل: {phone}")
    if email:
        body_parts.append(f"الإيميل: {email}")
    if note:
        body_parts.append(f"ملاحظات: {note}")
    body_text = " • ".join(body_parts)

    actor_display = name or phone or email or "مستخدم"

    event_id = str(uuid.uuid4())
    now = datetime.utcnow()

    push_targets: list[dict] = []

    async with AsyncSessionLocal() as session:
        try:
            for admin_email in SUPER_ADMIN_EMAILS:
                admin_email_clean = admin_email.strip().lower()
                if not admin_email_clean:
                    continue
                try:
                    admin_doc = db.collection("users").document(admin_email_clean).get()
                    if not admin_doc.exists:
                        continue
                    admin_data = admin_doc.to_dict() or {}
                    admin_uid = str(admin_data.get("uid", "") or "")
                    admin_company = str(admin_data.get("company_code", "01") or "01")
                    if not admin_uid:
                        continue

                    # ✅ Notification في Neon
                    session.add(Notification(
                        event_id=event_id,
                        recipient_uid=admin_uid,
                        recipient_email=admin_email_clean,
                        company_code=admin_company,
                        branch_code="",
                        section="registration_requests",
                        action="add",
                        actor_uid="",
                        actor_name=actor_display,
                        title=title,
                        body=body_text,
                        entity_id=request_doc_id,
                        created_at=now,
                        is_read=False,
                        read_at=None,
                    ))

                    # ✅ Push
                    push_targets.append({
                        "user_uid": admin_uid,
                        "company_code": admin_company,
                        "title": title,
                        "body": body_text,
                        "data": {
                            "type": "registration_request",
                            "section": "registration_requests",
                            "action": "add",
                            "event_id": event_id,
                        },
                    })
                except Exception as _e:
                    print(f"⚠️ notify_super_admin({admin_email_clean}): {_e}")

            await session.commit()
            print(
                f"✅ Notified {len(push_targets)} super admin(s) — "
                f"request={request_doc_id}"
            )
        except Exception as exc:
            await session.rollback()
            print(f"⚠️ notify_super_admins failed: {exc}")
            push_targets = []

    # Push بعد الـ commit
    for target in push_targets:
        try:
            send_push_to_user_bg(**target)
        except Exception as e:
            print(f"⚠️ push schedule failed: {e}")



# ==========================================
# ⭐ 2.11. طلب انضمام (Self-Registration Request)
# ==========================================
@router.post("/request-registration")
async def request_registration(data: RegistrationRequestModel):
    """
    المستخدم يطلب الانضمام لشركة (لو مش متسجل من الأدمن).
    
    - يتحقق من وجود الشركة
    - يتحقق من عدم تكرار الرقم/الإيميل
    - يحفظ الطلب في registration_requests
    """
    try:
        name = (data.name or "").strip()
        phone = (data.phone_number or "").strip()
        email = (data.email or "").strip().lower()
        company_code = (data.company_code or "").strip()
        company_name = ""

        if not name:
            raise HTTPException(status_code=400, detail="الاسم مطلوب")
        if not phone and not email:
            raise HTTPException(status_code=400, detail="رقم الموبايل أو الإيميل مطلوب")

        # ⭐ لو الشركة محددة → تحقق منها
        if company_code:
            async with AsyncSessionLocal() as session:
                stmt = select(Company).where(Company.code == company_code)
                result = await session.execute(stmt)
                company = result.scalar_one_or_none()
                if not company or not company.is_active:
                    raise HTTPException(status_code=404, detail="الشركة غير موجودة أو موقوفة")
                company_name = company.name

        # الرقم/الإيميل مش متسجل في users؟
        if phone:
            existing = find_user_by_phone(phone)
            if existing is not None:
                raise HTTPException(status_code=400, detail="هذا الرقم مسجل بالفعل")
        if email:
            if db.collection("users").document(email).get().exists:
                raise HTTPException(status_code=400, detail="هذا البريد مسجل بالفعل")

        # طلب مكرر معلق؟
        existing_requests = (
            db.collection("registration_requests")
            .where("company_code", "==", company_code)
            .where("status", "==", "pending")
            .stream()
        )
        for req in existing_requests:
            rd = req.to_dict() or {}
            if phone and rd.get("phone_number") == phone:
                raise HTTPException(status_code=400, detail="يوجد طلب معلق بنفس الرقم")
            if email and (rd.get("email") or "").lower() == email:
                raise HTTPException(status_code=400, detail="يوجد طلب معلق بنفس البريد")

        # أنشئ الطلب
        req_ref = db.collection("registration_requests").document()
        req_ref.set({
            "name": name,
            "phone_number": phone,
            "email": email,
            "company_code": company_code,      # ممكن يكون ""
            "company_name": company_name,      # ممكن يكون ""
            "branch_code": (data.branch_code or "").strip(),
            "note": (data.note or "").strip(),
            "status": "pending",
            "created_at": firestore.SERVER_TIMESTAMP,
            "reviewed_at": None,
            "reviewed_by": None,
        })

        # ⭐ إشعار السوبر أدمن (Neon + Push)
        try:
            await notify_super_admins_of_registration_request(
                request_doc_id=req_ref.id,
                request_data={
                    "name": name,
                    "phone_number": phone,
                    "email": email,
                    "note": data.note or "",
                    "company_code": company_code,
                },
            )
        except Exception as _e:
            print(f"⚠️ notify failed (continuing): {_e}")

        return {
            "status": "success",
            "message": "تم إرسال طلب الانضمام. سيتم مراجعته من الإدارة.",
            "request_id": req_ref.id,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ request_registration error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# ⭐ 2.12. قائمة طلبات الانضمام (للأدمن)
# ==========================================
@router.get("/admin/registration-requests")
async def list_registration_requests(
    request: Request,
    status: str = Query("pending"),  # pending | approved | rejected | all
):
    """قائمة طلبات الانضمام للشركة."""
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        target_company = None if actor_role == "super_admin" else actor_company
        if actor_role != "super_admin" and not target_company:
            raise HTTPException(status_code=403, detail="الحساب غير مرتبط بشركة")

        query = db.collection("registration_requests")
        if target_company:
            query = query.where("company_code", "==", target_company)
        if status != "all":
            query = query.where("status", "==", status)

        results = []
        for doc in query.stream():
            rd = doc.to_dict() or {}
            created_raw = rd.get("created_at")
            created_str = None
            try:
                if created_raw is not None and hasattr(created_raw, "isoformat"):
                    created_str = created_raw.isoformat()
            except Exception:
                pass

            results.append({
                "id": doc.id,
                "name": rd.get("name", ""),
                "phone_number": rd.get("phone_number", ""),
                "email": rd.get("email", ""),
                "company_code": rd.get("company_code", ""),
                "company_name": rd.get("company_name", ""),
                "branch_code": rd.get("branch_code", ""),
                "note": rd.get("note", ""),
                "status": rd.get("status", "pending"),
                "created_at": created_str,
            })

        results.sort(key=lambda x: x.get("created_at") or "", reverse=True)
        return results

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ list_registration_requests error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# ⭐ 2.13. الموافقة على طلب انضمام
# ==========================================
@router.post("/admin/registration-requests/{request_id}/approve")
async def approve_registration_request(
    request_id: str,
    data: ApproveRequestModel,
    request: Request,
    session: AsyncSession = Depends(get_db),
):
    """
    الموافقة على طلب:
    - ينشئ سجل في users (status: pending)
    - يحدّث الطلب لـ approved
    """
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        req_ref = db.collection("registration_requests").document(request_id)
        req_doc = req_ref.get()
        if not req_doc.exists:
            raise HTTPException(status_code=404, detail="الطلب غير موجود")

        rd = req_doc.to_dict() or {}
        if rd.get("status") != "pending":
            raise HTTPException(status_code=400, detail="الطلب تمت مراجعته بالفعل")

        # ⭐ تحديد الشركة: من الطلب أولاً، أو من الـ payload
        company_code = str(rd.get("company_code", "") or "").strip()
        payload_company = (data.company_code or "").strip()
        if not company_code:
            company_code = payload_company

        if not company_code:
            raise HTTPException(
                status_code=400,
                detail="يجب تحديد الشركة (الطلب غير مرتبط بشركة)",
            )

        # Admin مسموح له فقط بشركته
        if actor_role != "super_admin":
            if company_code != actor_company:
                raise HTTPException(status_code=403, detail="غير مسموح")
            # لو الطلب مش مربوط بشركة، الـ admin العادي ميقدرش يوافق
            if not str(rd.get("company_code", "") or "").strip():
                raise HTTPException(
                    status_code=403,
                    detail="الطلب غير مرتبط بشركة — يجب أن يوافق عليه السوبر أدمن",
                )

        # تحقق من الدور
        if actor_role == "admin" and data.role != "employee":
            raise HTTPException(status_code=403, detail="غير مسموح بتعيين هذا الدور")
        if data.role not in ("admin", "employee"):
            raise HTTPException(status_code=400, detail="دور غير صالح")

        # جيب الشركة
        stmt = select(Company).where(Company.code == company_code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()
        if not company:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")

        phone = (rd.get("phone_number") or "").strip()
        email = (rd.get("email") or "").strip().lower()
        name = (rd.get("name") or "").strip()

        if not phone and not email:
            raise HTTPException(status_code=400, detail="الطلب بدون رقم أو إيميل")

        # branch
        bc = (data.branch_code or "").strip()
        if bc in ("all", "", "الكل", "كل الفروع"):
            final_branch = ""
            final_allowed = ["all"]
        else:
            final_branch = bc
            final_allowed = [bc]

        # doc id
        if phone:
            doc_id = f"phone_{phone}"
        else:
            doc_id = email

        # تحقق مفيش مستخدم بنفس doc_id
        if db.collection("users").document(doc_id).get().exists:
            raise HTTPException(status_code=400, detail="يوجد مستخدم بنفس الرقم/البريد")

        job_code = ROLE_TO_JOB_CODE[data.role]
        user_data = {
            "phone_number": phone,
            "name": name,
            "company_code": company_code,
            "company_name": company.name,
            "branch_code": final_branch,
            "role": data.role,
            "job_code": job_code,
            "job_title": ROLE_TITLES[data.role],
            "email": email,
            "uid": "",
            "allowed_branches": final_allowed,
            "is_active": True,
            "permissions": _default_employee_permissions() if data.role == "employee" else {},
            "status": "pending",
            "email_verified": False,
            "requires_email_verification": True,
            "created_by_admin": str(actor.get("email", "")),
            "created_at": firestore.SERVER_TIMESTAMP,
            "from_registration_request": request_id,
        }
        db.collection("users").document(doc_id).set(user_data)

        # حدّث الطلب
        req_ref.update({
            "status": "approved",
            "company_code": company_code,      # ⭐ سجّل الشركة اللي اتاختارت
            "company_name": company.name,
            "reviewed_at": firestore.SERVER_TIMESTAMP,
            "reviewed_by": str(actor.get("email", "")),
            "user_doc_id": doc_id,
        })

        return {
            "status": "success",
            "message": f"تمت الموافقة على {name}. يمكنه إكمال التسجيل برقمه/بريده.",
            "user_doc_id": doc_id,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ approve_registration_request error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# ⭐ 2.14. رفض طلب انضمام
# ==========================================
@router.post("/admin/registration-requests/{request_id}/reject")
async def reject_registration_request(
    request_id: str,
    request: Request,
):
    """رفض طلب انضمام."""
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        req_ref = db.collection("registration_requests").document(request_id)
        req_doc = req_ref.get()
        if not req_doc.exists:
            raise HTTPException(status_code=404, detail="الطلب غير موجود")

        rd = req_doc.to_dict() or {}
        if actor_role != "super_admin" and str(rd.get("company_code", "")) != actor_company:
            raise HTTPException(status_code=403, detail="غير مسموح")

        req_ref.update({
            "status": "rejected",
            "reviewed_at": firestore.SERVER_TIMESTAMP,
            "reviewed_by": str(actor.get("email", "")),
        })

        return {"status": "success", "message": "تم رفض الطلب"}

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ reject_registration_request error: {e}")
        raise HTTPException(status_code=500, detail=str(e))
# ==========================================
# 1. تسجيل مستخدم جديد
# ==========================================
@router.post("/register")
async def register(
    user: UserRegister,
    session: AsyncSession = Depends(get_db)
):
    try:
        email_clean = user.email.strip().lower()
        comp_code = user.company_code.strip()

        # ⭐ role + job_code يتم تحديدهم من الباك فقط
        if email_clean in SUPER_ADMIN_EMAILS:
            role = "super_admin"
            job_code = "99"
        else:
            role = "employee"
            job_code = "1"

        # ✅ التحقق من الشركة من Neon (PostgreSQL)
        stmt = select(Company).where(Company.code == comp_code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()

        if not company:
            raise HTTPException(status_code=403, detail="كود الشركة غير صحيح أو غير مسجل في النظام")

        if not company.is_active:
            raise HTTPException(status_code=403, detail="هذه الشركة موقوفة حالياً، يرجى مراجعة إدارة البرنامج")

        company_name = company.name

        job_title = USER_ROLES.get(job_code)

        # ✅ التحقق من وجود المستخدم في Firestore
        user_ref = db.collection("users").document(email_clean)
        if user_ref.get().exists:
            raise HTTPException(status_code=400, detail="هذا البريد مسجل بالفعل في قاعدة البيانات")

        # ✅ حفظ المستخدم في Firestore
        user_data_to_save = {
            "uid": user.uid,
            "name": user.name.strip(),
            "email": email_clean,
            "company_code": comp_code,
            "company_name": company_name,
            "role": role,          # ⭐ جديد
            "job_code": job_code,
            "job_title": job_title,
            "allowed_branches": ["all"],
            "is_active": True,     # ⭐ جديد
            "permissions": _default_employee_permissions() if role == "employee" else {},
            "status": "active",
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        user_ref.set(user_data_to_save)

        # ============================================================
        # ⭐ ربط / إنشاء الموظف تلقائياً
        # ============================================================
        linked_employee = None

        if user.employee_code and user.employee_code.strip():
            # ─── ربط يدوي ───
            emp_code_clean = user.employee_code.strip()

            emp_stmt = select(Employee).where(
                Employee.company_code == comp_code,
                Employee.code == emp_code_clean,
                Employee.is_deleted.is_(False),
            )
            emp_result = await session.execute(emp_stmt)
            emp = emp_result.scalar_one_or_none()

            if not emp:
                raise HTTPException(
                    status_code=404,
                    detail=f"كود الموظف [{emp_code_clean}] غير موجود في هذه الشركة",
                )

            if emp.user_email and emp.user_email.strip().lower() != email_clean:
                raise HTTPException(
                    status_code=400,
                    detail="هذا الموظف مربوط بحساب آخر بالفعل",
                )

            emp.user_email = email_clean
            emp.user_uid = user.uid
            emp.updated_at = datetime.utcnow()
            await session.commit()

            linked_employee = {
                "code": emp.code,
                "name": emp.name,
                "linked": True,
            }

        # ⭐ لو مفيش ربط يدوي → إنشاء تلقائي
        if linked_employee is None and email_clean not in SUPER_ADMIN_EMAILS:
            try:
                linked_employee = await _auto_create_employee_if_needed(
                    db=session,
                    user_email=email_clean,
                    user_uid=user.uid,
                    user_name=user.name,
                    user_phone="",   # register مش بياخد phone_number
                    company_code=comp_code,
                    branch_code="",  # register مش بياخد branch_code
                )
            except Exception as e:
                print(f"⚠️ auto-create employee failed in register: {e}")

        return {
            "status": "success",
            "message": f"تم تسجيل {job_title} في {company_name}",
            "linked_employee": linked_employee,   # ⭐
        }

    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 2. التحقق من المستخدم (تسجيل الدخول)
# ==========================================
@router.post("/verify-user")
async def verify_user(
    authorization: str = Header(None),
    session: AsyncSession = Depends(get_db)  # ✅ جلسة PostgreSQL
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="لم يتم إرسال توكن صالح")

    try:
        token = authorization.split("Bearer ")[1]
        decoded_token = admin_auth.verify_id_token(token,
    clock_skew_seconds=60,)
        email = decoded_token.get("email")

        # ✅ قراءة بيانات المستخدم من Firestore
        user_doc = db.collection("users").document(email).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="بيانات المستخدم غير موجودة")

        data = user_doc.to_dict()
        comp_code = data.get("company_code")

        # ✅ التحقق من الشركة من Neon (PostgreSQL)
        stmt = select(Company).where(Company.code == comp_code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()

        if not company:
            raise HTTPException(status_code=404, detail="الشركة التابع لها هذا الحساب غير موجودة")

        if not company.is_active:
            raise HTTPException(status_code=403, detail="تم إيقاف صلاحية الوصول لهذه الشركة (يرجى سداد الاشتراك)")

        # ⭐ الدور الفعلي (من role أو job_code أو .env)
        data["email"] = email
        effective_role = _effective_role(data)

        return {
            "status": "success",
            "name": data.get("name"),
            "email": data.get("email"),
            "company_code": data.get("company_code"),
            "company_name": company.name,
            "role": effective_role,
            "job_code": data.get("job_code"),
            "job_title": data.get("job_title"),
            "user_status": data.get("status", "active"),
            "email_verified": bool(decoded_token.get("email_verified", False)),
            "requires_email_verification": bool(
                data.get("requires_email_verification", False)
            ),
            "branch_code": data.get("branch_code", ""),
            "allowed_branches": data.get("allowed_branches", ["all"]),   # ⭐ جديد
        }
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        print(f"⚠️ خطأ في التحقق من التوكن: {e}")
        raise HTTPException(status_code=401, detail="انتهت صلاحية الجلسة، سجل دخولك مرة أخرى")

# ==========================================
# ⭐ 2.4. حل الـ identifier (إيميل / موبايل / يوزرنيم)
# ==========================================
@router.post("/resolve-identifier")
async def resolve_identifier(
    data: IdentifierResolveModel,
    request: Request,
):
    """
    يترجم (إيميل / موبايل / يوزرنيم) إلى إيميل.
    التطبيق بعدها يستخدم signInWithEmailAndPassword عادي.

    ⚠️ ردود موحدة لتجنب User Enumeration:
       - لو موجود: { "found": true, "email": "..." }
       - لو مش موجود: { "found": false, "email": null }
    """
    # Rate limit (بسيط)
    client_ip = (request.client.host if request.client else "unknown") or "unknown"
    if not _check_identifier_rate_limit(client_ip):
        raise HTTPException(
            status_code=429,
            detail="محاولات كثيرة، حاول بعد دقيقة",
        )

    identifier = (data.identifier or "").strip()
    if not identifier:
        raise HTTPException(status_code=400, detail="الرجاء إدخال بيانات الدخول")

    identifier_lower = identifier.lower()

    try:
        # 1) إيميل
        if "@" in identifier_lower:
            doc = db.collection("users").document(identifier_lower).get()
            if doc.exists:
                return {"found": True, "email": identifier_lower}
            return {"found": False, "email": None}

        # 2) موبايل (أرقام فقط — 8 إلى 15 رقم)
        if identifier.isdigit() and 8 <= len(identifier) <= 15:
            doc = find_user_by_phone(identifier)
            if doc is not None:
                user_data = doc.to_dict() or {}
                # الإيميل ممكن يكون فاضي (مستخدم لسه مكملش)
                email = str(user_data.get("email", "") or "").strip().lower()
                if email:
                    return {"found": True, "email": email}
            return {"found": False, "email": None}

        # 3) يوزرنيم
        username = identifier_lower
        results = (
            db.collection("users")
            .where("username", "==", username)
            .limit(1)
            .stream()
        )
        for doc in results:
            user_data = doc.to_dict() or {}
            email = str(user_data.get("email", "") or "").strip().lower()
            if email:
                return {"found": True, "email": email}
        return {"found": False, "email": None}

    except Exception as e:
        print(f"⚠️ resolve_identifier error: {e}")
        # رفض صريح بدون كشف معلومات
        return {"found": False, "email": None}



# ==========================================
# ⭐ 2.5. التحقق من رقم الموبايل (قبل التسجيل)
# ==========================================
@router.post("/check-phone")
async def check_phone(data: PhoneCheckModel):
    """
    المستخدم يدخل (إيميل / موبايل) → نتحقق.
    
    Returns:
      - { "found": true, "name", "company_code", "company_name",
          "branch_code", "status", "has_account", "needs_setup", "is_super_admin" }
      - { "found": false }
    """
    try:
        identifier = (data.phone_number or "").strip()
        if not identifier:
            return {"found": False}

        # ⭐ بحث موحد يشمل email-only users
        doc = find_pending_user(
            phone=identifier if not ("@" in identifier) else "",
            email=identifier if "@" in identifier else "",
        )
        kind = None
        if doc is None:
            # fallback للبحث القديم (username مثلاً)
            doc, kind = find_user_by_identifier(identifier)

        # ⭐ حالة خاصة: السوبر أدمن مش متسجل بعد
        if doc is None:
            if "@" in identifier and identifier.lower() in SUPER_ADMIN_EMAILS:
                return {
                    "found": True,
                    "is_super_admin": True,
                    "needs_setup": True,
                    "has_account": False,
                    "name": "Super Admin",
                    "company_code": "01",
                    "company_name": "الشركة الافتراضية",
                    "branch_code": "",
                    "status": "pending",
                }
            return {"found": False}

        user_data = doc.to_dict() or {}
        status = user_data.get("status", "pending")
        uid = str(user_data.get("uid", "") or "")
        email = str(user_data.get("email", "") or "")

        # هل السوبر أدمن؟
        is_super_admin = email.lower() in SUPER_ADMIN_EMAILS
        needs_setup = False
        if is_super_admin and not uid:
            needs_setup = True

        return {
            "found": True,
            "is_super_admin": is_super_admin,
            "needs_setup": needs_setup,
            "name": user_data.get("name", ""),
            "company_code": user_data.get("company_code", ""),
            "company_name": user_data.get("company_name", ""),
            "branch_code": user_data.get("branch_code", ""),
            "status": status,
            "has_account": bool(uid) and bool(email),
        }
    except Exception as e:
        print(f"⚠️ check_phone error: {e}")
        raise HTTPException(status_code=500, detail="تعذر التحقق")

async def _setup_super_admin(
    data: CompleteRegistrationModel,
    uid: str,
    email_clean: str,
):
    """إنشاء حساب السوبر أدمن (مرة واحدة)."""
    existing = db.collection("users").document(email_clean).get()
    if existing.exists:
        existing_data = existing.to_dict() or {}
        if existing_data.get("uid"):
            raise HTTPException(status_code=400, detail="حساب السوبر أدمن موجود بالفعل")

    # اسم الشركة الافتراضية "01"
    async with AsyncSessionLocal() as session:
        stmt = select(Company).where(Company.code == "01")
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()
        company_name = company.name if company else "الشركة الافتراضية"

    user_data = {
        "uid": uid,
        "email": email_clean,
        "name": (data.name or "Super Admin").strip(),
        "company_code": "01",
        "company_name": company_name,
        "role": "super_admin",
        "job_code": "99",
        "job_title": "صاحب البرنامج",
        "status": "active",
        "is_active": True,
        "permissions": {},
        "allowed_branches": ["all"],
        "email_verified": False,
        "requires_email_verification": True,
        "registered_at": firestore.SERVER_TIMESTAMP,
    }
    if data.username:
        u = _validate_username(data.username)
        if _is_username_taken(u, exclude_doc_id=email_clean):
            raise HTTPException(status_code=400, detail="اسم المستخدم مستخدم بالفعل")
        user_data["username"] = u

    db.collection("users").document(email_clean).set(user_data)

    return {
        "status": "success",
        "role": "super_admin",
        "message": "تم إعداد حساب السوبر أدمن",
        "email": email_clean,
    }

class CheckEmailModel(BaseModel):
    email: str


@router.post("/check-email")
async def check_email(data: CheckEmailModel):
    """
    فحص وجود الإيميل (بدون عرض بيانات المستخدم).
    يُستخدم في "نسيت كلمة المرور" قبل إرسال إيميل Firebase.
    
    Returns:
      - {"exists": true, "needs_completion": false}  → الإيميل موجود ومكتمل
      - {"exists": true, "needs_completion": true}   → موجود لكن لم يكمل التسجيل
      - {"exists": false}                             → غير مسجل
    """
    email = (data.email or "").strip().lower()
    if not email:
        return {"exists": False, "needs_completion": False}
    
    # 1) ابحث في users/{email}
    doc = db.collection("users").document(email).get()
    
    # 2) لو مش موجود، ابحث في users/email_XXX
    if not doc.exists:
        doc = db.collection("users").document(_email_doc_id(email)).get()
    
    if not doc.exists:
        return {"exists": False, "needs_completion": False}
    
    user_data = doc.to_dict() or {}
    uid = (user_data.get("uid") or "").strip()
    return {
        "exists": True,
        "needs_completion": uid == "",
    }
# ==========================================
# ⭐ 2.6. إكمال التسجيل (بعد التحقق من الرقم)
# ==========================================
@router.post("/complete-registration")
async def complete_registration(
    data: CompleteRegistrationModel,
    authorization: Optional[str] = Header(None),
):
    """
    إكمال التسجيل:
      - السوبر أدمن: ينشئ سجله الجديد (مش محتاج phone)
      - مستخدم عادي: يكمل السجل الموجود (عبر phone)
    """
    try:
        # ⭐ 0. التحقق من Firebase ID token
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="التوثيق مطلوب")

        try:
            token = authorization.split(" ", 1)[1].strip()
            decoded = admin_auth.verify_id_token(token, clock_skew_seconds=60)
            token_uid = str(decoded.get("uid", ""))
            token_email = str(decoded.get("email", "")).strip().lower()
        except Exception as exc:
            print(f"⚠️ complete_registration token invalid: {exc}")
            raise HTTPException(status_code=401, detail="توكن غير صالح")

        email_clean = data.email.strip().lower()
        uid = data.uid.strip()

        if not email_clean or not uid:
            raise HTTPException(status_code=400, detail="بيانات ناقصة")

        # التوكن لازم يطابق البيانات
        if token_uid != uid:
            raise HTTPException(status_code=403, detail="بيانات الحساب لا تطابق التوكن")
        if token_email != email_clean:
            raise HTTPException(status_code=403, detail="البريد لا يطابق التوكن")

        # ⭐ 1. حالة السوبر أدمن
        if email_clean in SUPER_ADMIN_EMAILS:
            return await _setup_super_admin(data, uid, email_clean)

        # ⭐ 2. مستخدم عادي — phone أو email
        phone = (data.phone_number or "").strip()

        # ⭐ البحث الموحد (يشمل email-only users)
        doc = find_pending_user(phone=phone, email=email_clean)

        if doc is None:
            raise HTTPException(
                status_code=404,
                detail="البيانات غير مسجلة — تواصل مع الإدارة",
            )

        user_data = doc.to_dict() or {}

        # تأكد إنه مش مكمل التسجيل قبل كده
        if user_data.get("uid") and user_data.get("email"):
            raise HTTPException(
                status_code=400,
                detail="هذا الحساب مسجل بالفعل",
            )

        # ⭐ تأكد إن الإيميل لا يتعارض مع مستخدم آخر
        if user_data.get("email") and user_data["email"] != email_clean:
            raise HTTPException(
                status_code=400,
                detail="البيانات مرتبطة بحساب آخر",
            )

        # 3. تأكد إن الإيميل مش مستخدم بحساب تاني (ما عدا السجل الحالي)
        existing_email_doc = db.collection("users").document(email_clean).get()
        if existing_email_doc.exists and existing_email_doc.id != doc.id:
            raise HTTPException(
                status_code=400,
                detail="البريد الإلكتروني مسجل بالفعل",
            )

        # 4. لو فيه username → تحقق منه
        username_final = ""
        if data.username and data.username.strip():
            username_final = _validate_username(data.username)
            if _is_username_taken(username_final, exclude_doc_id=doc.id):
                raise HTTPException(
                    status_code=400,
                    detail="اسم المستخدم مستخدم بالفعل",
                )

        # 5. حدّث السجل الحالي (اللي الأدمن أنشأه)
        user_data.update({
            "uid": uid,
            "email": email_clean,
            "status": "active",
            "email_verified": False,
            "requires_email_verification": True,
            "registered_at": firestore.SERVER_TIMESTAMP,
            # ⭐ نضمن وجود الحقول دي
            "is_active": user_data.get("is_active", True),
            "permissions": user_data.get("permissions", {}),
        })
        if username_final:
            user_data["username"] = username_final

        # ============================================================
        # ⭐ ربط / إنشاء الموظف تلقائياً
        # ============================================================
        linked_employee = None

        if data.employee_code and data.employee_code.strip():
            # ─── ربط يدوي (المستخدم أدخل كود موظف موجود) ───
            emp_code = data.employee_code.strip()
            try:
                async with AsyncSessionLocal() as session:
                    from sqlalchemy import select as _sel
                    emp_stmt = _sel(Employee).where(
                        Employee.company_code == str(user_data.get("company_code", "")),
                        Employee.code == emp_code,
                        Employee.is_deleted.is_(False),
                    )
                    emp_result = await session.execute(emp_stmt)
                    emp = emp_result.scalar_one_or_none()
                    if emp:
                        emp.user_email = email_clean
                        emp.user_uid = uid
                        emp.updated_at = datetime.utcnow()
                        await session.commit()
                        user_data["employee_code"] = emp_code
                        linked_employee = {
                            "code": emp.code,
                            "name": emp.name,
                            "linked": True,
                        }
                        print(f"🔗 [Manual] ربط المستخدم بموظف #{emp.code}")
                    else:
                        print(f"⚠️ employee_code '{emp_code}' not found — creating new")
            except Exception as e:
                print(f"⚠️ employee link failed: {e}")

        # ⭐ لو مفيش ربط يدوي (أو فشل) → إنشاء تلقائي
        if linked_employee is None:
            # ⚠️ لا ننشئ موظف للسوبر أدمن
            if email_clean not in SUPER_ADMIN_EMAILS:
                try:
                    async with AsyncSessionLocal() as session:
                        linked_employee = await _auto_create_employee_if_needed(
                            db=session,
                            user_email=email_clean,
                            user_uid=uid,
                            user_name=user_data.get("name", ""),
                            user_phone=user_data.get("phone_number", ""),
                            company_code=user_data.get("company_code", ""),
                            branch_code=user_data.get("branch_code", ""),
                        )
                        if linked_employee:
                            user_data["employee_code"] = linked_employee["code"]
                except Exception as e:
                    print(f"⚠️ auto-create employee failed: {e}")

        # 5. نحفظ المستند بالـ ID الخاص بالموبايل (بيبقى موجود)، 
        #    لكن كمان نعمل نسخة بمفتاح الإيميل للتوافق مع باقي النظام
        #    (الـ auth_middleware بيستخدم email كـ document ID)
        
        # نحذف السجل القديم (المؤقت) وننشئ واحد جديد بالإيميل
        old_doc_id = doc.id  # بيبقى عادة phone أو temp_xxx
        if old_doc_id != email_clean:
            db.collection("users").document(email_clean).set(user_data)
            db.collection("users").document(old_doc_id).delete()
        else:
            db.collection("users").document(email_clean).set(user_data)

        return {
            "status": "success",
            "message": "تم إكمال التسجيل — يرجى التحقق من بريدك الإلكتروني",
            "email": email_clean,
            "linked_employee": linked_employee,   # ⭐ جديد
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ complete_registration error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# ⭐ 2.6.5. جلب مستخدمي الشركة
# ==========================================
@router.get("/company-users")
async def list_company_users(
    request: Request,
    company_code: Optional[str] = Query(None),
):
    """
    قائمة مستخدمي الشركة:
      - الأدمن (99): يقدر يحدد أي شركة، أو بدون شركة = كل الشركات
      - أدمن الشركة (201): يشوف شركته فقط
    """
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_job_code = str(actor.get("job_code", "1"))
        actor_company = str(actor.get("company_code", ""))

        # تحديد الشركة المستهدفة
        if actor_job_code == "99":
            target_company = (company_code or "").strip() or None
        else:
            if actor_job_code not in ("201", "200"):
                raise HTTPException(status_code=403, detail="غير مصرح")
            target_company = actor_company
            if not target_company:
                raise HTTPException(status_code=403, detail="الحساب غير مرتبط بشركة")

        # Query Firestore
        query = db.collection("users")
        if target_company:
            query = query.where("company_code", "==", target_company)

        results = []
        for doc in query.stream():
            data = doc.to_dict() or {}
            created_at_raw = data.get("created_at")
            created_at_str = None
            try:
                if created_at_raw is not None and hasattr(created_at_raw, "isoformat"):
                    created_at_str = created_at_raw.isoformat()
            except Exception:
                pass

            results.append({
                "email": doc.id,
                "name": data.get("name", ""),
                "phone_number": data.get("phone_number", ""),
                "company_code": data.get("company_code", ""),
                "company_name": data.get("company_name", ""),
                "branch_code": data.get("branch_code", ""),
                "job_code": data.get("job_code", "1"),
                "job_title": data.get("job_title", ""),
                "status": data.get("status", "active"),
                "email_verified": bool(data.get("email_verified", False)),
                "requires_email_verification": bool(
                    data.get("requires_email_verification", False)
                ),
                "has_account": bool(data.get("uid")),
                "username": data.get("username", ""),
                "created_at": created_at_str,
            })

        # ترتيب: pending أولاً ثم active ثم suspended، وبعدين بالاسم
        def sort_key(u):
            order = {"pending": 0, "active": 1, "suspended": 2}
            return (order.get(u["status"], 3), u.get("name", ""))

        results.sort(key=sort_key)
        return results

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ list_company_users error: {e}")
        raise HTTPException(status_code=500, detail=str(e))



# ==========================================
# ⭐ 2.7. الأدمن يضيف موظف جديد (Invitation Model)
# ==========================================
@router.post("/admin/add-user")
async def admin_add_user(
    data: AdminAddUserModel,
    request: Request,
    session: AsyncSession = Depends(get_db),
):
    """
    إضافة مستخدم:
      - الاسم اختياري
      - رقم الموبايل أو الإيميل مطلوب (واحد على الأقل)
      - Super Admin: يضيف admin/employee لأي شركة
      - Admin: يضيف employee لشركته فقط
    """
    try:
        # 1. صلاحية المنشئ
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role == "super_admin":
            allowed_roles = {"admin", "employee"}
            target_company = (data.company_code or "").strip()
            if not target_company:
                raise HTTPException(status_code=400, detail="يجب تحديد الشركة")
        elif actor_role == "admin":
            allowed_roles = {"employee"}
            target_company = actor_company
            if not target_company:
                raise HTTPException(status_code=400, detail="حسابك غير مرتبط بشركة")
        else:
            raise HTTPException(status_code=403, detail="غير مصرح لك بإضافة مستخدمين")

        # 2. تحقق من الدور
        if data.role not in allowed_roles:
            raise HTTPException(
                status_code=403,
                detail=f"غير مسموح بتعيين الدور '{data.role}'",
            )

        # 3. البيانات الأساسية — phone OR email
        name = (data.name or "").strip()
        phone = (data.phone_number or "").strip()
        email = (data.email or "").strip().lower()

        if not phone and not email:
            raise HTTPException(
                status_code=400,
                detail="رقم الموبايل أو الإيميل مطلوب (واحد على الأقل)",
            )

        # تحقق من phone
        if phone:
            if not re.match(r"^[0-9]{8,15}$", phone):
                raise HTTPException(status_code=400, detail="رقم الموبايل غير صحيح")
            existing = find_user_by_phone(phone)
            if existing is not None:
                raise HTTPException(status_code=400, detail="رقم الموبايل مسجل بالفعل")

        # تحقق من email
        if email:
            if not re.match(r"^[\w\.-]+@[\w\.-]+\.[a-zA-Z]{2,}$", email):
                raise HTTPException(status_code=400, detail="صيغة البريد الإلكتروني غير صحيحة")
            if db.collection("users").document(email).get().exists:
                raise HTTPException(status_code=400, detail="البريد الإلكتروني مسجل بالفعل")
            # تحقق doc email_XXX
            if db.collection("users").document(_email_doc_id(email)).get().exists:
                raise HTTPException(status_code=400, detail="البريد الإلكتروني مسجل بالفعل")

        # 4. جيب الشركة
        stmt = select(Company).where(Company.code == target_company)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()
        if not company:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")
        if not company.is_active:
            raise HTTPException(status_code=403, detail="الشركة موقوفة")

        # 5. username
        username_final = ""
        if data.username and data.username.strip():
            username_final = _validate_username(data.username)
            if _is_username_taken(username_final):
                raise HTTPException(status_code=400, detail="اسم المستخدم مستخدم بالفعل")

        # 6. أنشئ سجل مؤقت في Firestore
        #    doc_id: phone_XXX أو email_XXX
        if phone:
            temp_doc_id = f"phone_{phone}"
        else:
            temp_doc_id = _email_doc_id(email)

        job_code = ROLE_TO_JOB_CODE[data.role]

        # معالجة الفرع (all = موظف عام)
        branch_input = (data.branch_code or "").strip()
        if branch_input in ("all", "", "الكل", "كل الفروع"):
            final_branch = ""
            final_allowed = ["all"]
        else:
            final_branch = branch_input
            final_allowed = [branch_input]

        user_data = {
            "phone_number": phone or "",
            "name": name,  # ممكن يكون ""
            "company_code": target_company,
            "company_name": company.name,
            "branch_code": final_branch,
            "role": data.role,
            "job_code": job_code,
            "job_title": ROLE_TITLES[data.role],
            "email": email or "",
            "uid": "",
            "allowed_branches": final_allowed,
            "is_active": True,
            "permissions": _default_employee_permissions() if data.role == "employee" else {},
            "status": "pending",
            "email_verified": False,
            "requires_email_verification": True,
            "created_by_admin": str(actor.get("email", "")),
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        if username_final:
            user_data["username"] = username_final
        db.collection("users").document(temp_doc_id).set(user_data)

        display_name = name or email or phone
        return {
            "status": "success",
            "message": f"تم إضافة {display_name} كـ {ROLE_TITLES[data.role]} في {company.name}",
            "temp_doc_id": temp_doc_id,
            "role": data.role,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ admin_add_user error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# ⭐ 2.8. تعديل مستخدم (Admin)
# ==========================================
class AdminEditUserModel(BaseModel):
    email: str
    name: Optional[str] = None
    phone_number: Optional[str] = None
    branch_code: Optional[str] = None
    role: Optional[str] = None
    username: Optional[str] = None
    status: Optional[str] = None


@router.put("/admin/edit-user")
async def admin_edit_user(
    data: AdminEditUserModel,
    request: Request,
):
    """
    تعديل بيانات مستخدم:
      - Super Admin: أي مستخدم في أي شركة
      - Admin: مستخدمين شركته فقط (بدون تغيير role لـ admin)
    """
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        target_email = data.email.strip().lower()
        if not target_email:
            raise HTTPException(status_code=400, detail="البريد مطلوب")

        doc = db.collection("users").document(target_email).get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")

        target_data = doc.to_dict() or {}
        target_company = str(target_data.get("company_code", ""))
        target_role = _effective_role({**target_data, "email": target_email})

        # ⭐ فحص الصلاحية
        if actor_role == "admin":
            if target_company != actor_company:
                raise HTTPException(status_code=403, detail="غير مسموح بتعديل مستخدم من شركة أخرى")
            if target_role in ("super_admin", "admin"):
                raise HTTPException(status_code=403, detail="غير مسموح بتعديل مدير")

        updates = {}

        if data.name is not None:
            updates["name"] = data.name.strip()

        if data.phone_number is not None:
            new_phone = data.phone_number.strip()
            if new_phone and new_phone != target_data.get("phone_number"):
                # فحص إنه مش مستخدم
                existing = find_user_by_phone(new_phone)
                if existing is not None and existing.id != doc.id:
                    raise HTTPException(status_code=400, detail="رقم الموبايل مسجل بمستخدم آخر")
                updates["phone_number"] = new_phone

        if data.branch_code is not None:
            bc = data.branch_code.strip()
            if bc in ("all", "", "الكل", "كل الفروع"):
                updates["branch_code"] = ""
                updates["allowed_branches"] = ["all"]
            else:
                updates["branch_code"] = bc
                updates["allowed_branches"] = [bc]

        if data.username is not None:
            new_username = data.username.strip().lower()
            if new_username:
                _validate_username(new_username)
                if _is_username_taken(new_username, exclude_doc_id=doc.id):
                    raise HTTPException(status_code=400, detail="اسم المستخدم مستخدم بالفعل")
                updates["username"] = new_username
            else:
                updates["username"] = ""

        actor_email = str(actor.get("email", "")).strip().lower()
        target_email_clean = data.email.strip().lower()
        is_self = actor_email == target_email_clean

        if data.role is not None:
            if data.role not in ("admin", "employee", "super_admin"):
                raise HTTPException(status_code=400, detail="دور غير صالح")

            if actor_role == "admin" and data.role != "employee":
                raise HTTPException(status_code=403, detail="غير مسموح بتعيين هذا الدور")

            # ⭐ Super Admin له قواعد خاصة
            if target_role == "super_admin":
                if actor_role != "super_admin":
                    raise HTTPException(status_code=403, detail="غير مسموح بتعديل السوبر أدمن")
                if is_self and data.role != "super_admin":
                    raise HTTPException(status_code=403, detail="لا يمكن تغيير دور السوبر أدمن")

            # تعيين دور super_admin جديد
            if data.role == "super_admin" and actor_role != "super_admin":
                raise HTTPException(status_code=403, detail="غير مسموح بتعيين سوبر أدمن")

            updates["role"] = data.role
            updates["job_code"] = ROLE_TO_JOB_CODE[data.role]
            updates["job_title"] = ROLE_TITLES[data.role]
            if data.role == "admin":
                updates["permissions"] = {}

        if data.status is not None:
            if data.status not in ("active", "pending", "suspended"):
                raise HTTPException(status_code=400, detail="حالة غير صالحة")
            if target_role == "super_admin":
                if actor_role != "super_admin":
                    raise HTTPException(status_code=403, detail="غير مسموح")
                if is_self and data.status != "active":
                    raise HTTPException(status_code=403, detail="لا يمكن إيقاف السوبر أدمن")
            updates["status"] = data.status

        if not updates:
            return {"status": "success", "message": "لا توجد تغييرات"}

        updates["updated_at"] = firestore.SERVER_TIMESTAMP
        doc.reference.update(updates)

        return {
            "status": "success",
            "message": "تم التحديث بنجاح",
            "updates": {k: v for k, v in updates.items() if k != "updated_at"},
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ admin_edit_user error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# ⭐ 2.9. حذف مستخدم (Admin)
# ==========================================
@router.delete("/admin/delete-user")
async def admin_delete_user(
    request: Request,
    email: str = Query(..., min_length=1),
):
    """
    حذف مستخدم:
      - Super Admin: يحذف أي مستخدم (ما عدا نفسه)
      - Admin: يحذف موظفين شركته فقط
    """
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_email = str(actor.get("email", "")).strip().lower()
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        target_email = email.strip().lower()
        if target_email == actor_email:
            raise HTTPException(status_code=400, detail="لا يمكن حذف حسابك")

        doc = db.collection("users").document(target_email).get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")

        target_data = doc.to_dict() or {}
        target_company = str(target_data.get("company_code", ""))
        target_role = _effective_role({**target_data, "email": target_email})

        if actor_role == "admin":
            if target_company != actor_company:
                raise HTTPException(status_code=403, detail="غير مسموح بحذف مستخدم من شركة أخرى")
            if target_role != "employee":
                raise HTTPException(status_code=403, detail="غير مسموح بحذف مدير")

        if target_role == "super_admin":
            raise HTTPException(status_code=403, detail="لا يمكن حذف السوبر أدمن")

        # حذف من Firebase Auth (لو عنده uid)
        uid = str(target_data.get("uid", "") or "")
        if uid:
            try:
                admin_auth.delete_user(uid)
            except Exception as e:
                print(f"⚠️ Firebase Auth delete failed (continuing): {e}")

        # حذف من Firestore
        doc.reference.delete()

        return {"status": "success", "message": "تم حذف المستخدم"}

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ admin_delete_user error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# ⭐ 2.10. إعادة تعيين مستخدم معلق (Reset Pending)
# ==========================================
@router.post("/admin/reset-pending-user")
async def admin_reset_pending_user(
    request: Request,
    email: str = Query(..., min_length=1),
):
    """
    إعادة تعيين مستخدم عالق (pending):
      - يمسح uid, email, username, email_verified
      - يرجعه لـ status=pending
      - المستخدم يقدر يدخل رقمه من جديد
    """
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_company = str(actor.get("company_code", ""))

        if actor_role not in ("super_admin", "admin"):
            raise HTTPException(status_code=403, detail="غير مصرح")

        target_email = email.strip().lower()
        doc = db.collection("users").document(target_email).get()
        if not doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")

        target_data = doc.to_dict() or {}
        target_company = str(target_data.get("company_code", ""))
        target_role = _effective_role({**target_data, "email": target_email})

        if actor_role == "admin" and target_company != actor_company:
            raise HTTPException(status_code=403, detail="غير مسموح")
        if target_role == "super_admin":
            raise HTTPException(status_code=403, detail="غير مسموح بالسوبر أدمن")

        # امسح uid من Firebase Auth
        uid = str(target_data.get("uid", "") or "")
        if uid:
            try:
                admin_auth.delete_user(uid)
            except Exception as e:
                print(f"⚠️ Firebase Auth delete failed (continuing): {e}")

        # احتفظ بـ phone و name و company و branch و role
        # امسح uid, email, email_verified, username, registered_at
        reset_data = {
            "uid": "",
            "email": target_data.get("original_email") or "",
            "email_verified": False,
            "requires_email_verification": True,
            "status": "pending",
            "registered_at": None,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if "username" in target_data:
            reset_data["username"] = ""

        doc.reference.update(reset_data)

        return {
            "status": "success",
            "message": "تم إعادة تعيين المستخدم — يمكنه إكمال التسجيل من جديد",
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ admin_reset_pending_user error: {e}")
        raise HTTPException(status_code=500, detail=str(e))
# ==========================================
# ⭐ 2.15. إلغاء التسجيل (من شاشة تحقق الإيميل)
# ==========================================
@router.post("/cancel-registration")
async def cancel_registration(
    authorization: Optional[str] = Header(None),
):
    """
    إلغاء التسجيل (للمستخدم اللي مش قادر يكمل بسبب بيانات غلط):
      - يحذف Firebase Auth user
      - يعيد Firestore record لـ pending (مع الحفاظ على البيانات الأخرى)
    """
    try:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="التوثيق مطلوب")

        try:
            token = authorization.split(" ", 1)[1].strip()
            decoded = admin_auth.verify_id_token(token, clock_skew_seconds=60)
            uid = str(decoded.get("uid", ""))
            email = str(decoded.get("email", "")).strip().lower()
        except Exception as exc:
            print(f"⚠️ cancel_registration token invalid: {exc}")
            raise HTTPException(status_code=401, detail="توكن غير صالح")

        if not uid or not email:
            raise HTTPException(status_code=400, detail="بيانات ناقصة")

        # ابحث عن السجل الحالي (بالإيميل أو بالموبايل)
        user_doc = db.collection("users").document(email).get()

        # لو مش موجود بالإيميل → ابحث بالموبايل المرتبط بالـ uid
        if not user_doc.exists:
            for d in db.collection("users").stream():
                dd = d.to_dict() or {}
                if str(dd.get("uid", "")) == uid:
                    user_doc = d
                    break

        if user_doc.exists:
            data = user_doc.to_dict() or {}
            phone = str(data.get("phone_number", "") or "")

            # احتفظ بالبيانات (name, phone, company, branch, role, permissions)
            # امسح بس: uid, email, verified, status, registered_at
            reset_data = {
                **data,
                "uid": "",
                "email": "",
                "email_verified": False,
                "requires_email_verification": True,
                "status": "pending",
                "registered_at": None,
                "updated_at": firestore.SERVER_TIMESTAMP,
            }

            # لو فيه موبايل → ارجع لـ phone_xxx doc
            if phone:
                new_doc_id = f"phone_{phone}"
                db.collection("users").document(new_doc_id).set(reset_data)
                if new_doc_id != user_doc.id:
                    user_doc.reference.delete()
            else:
                user_doc.reference.set(reset_data)

        # احذف من Firebase Auth
        try:
            admin_auth.delete_user(uid)
        except Exception as e:
            print(f"⚠️ delete firebase user failed: {e}")

        return {
            "status": "success",
            "message": "تم إلغاء التسجيل — يمكنك البدء من جديد",
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ cancel_registration error: {e}")
        raise HTTPException(status_code=500, detail=str(e))




# ==========================================
# 4. إدارة الشركات (جميعها في Neon)
# ==========================================

@router.post("/companies/add")
async def add_new_company(
    company: CompanyModel,
    request: Request,
    admin_job_code: str = Query(...),
    session: AsyncSession = Depends(get_db)
):
    _require_program_admin(request)
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="عذراً، هذه الصلاحية خاصة بصاحب البرنامج فقط!")

    comp_code = company.code.strip()
    comp_name = company.name.strip()

    # التحقق من عدم وجود الشركة في Neon
    stmt = select(Company).where(Company.code == comp_code)
    result = await session.execute(stmt)
    if result.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="كود هذه الشركة مسجل بالفعل في النظام")

    new_company = Company(
        code=comp_code,
        name=comp_name,
        is_active=True
    )
    session.add(new_company)
    await session.commit()

    return {"status": "success", "message": f"تم تكويد شركة [{comp_name}] بنجاح"}


@router.get("/companies/all")
async def get_all_companies(
    request: Request,
    admin_job_code: str = Query(...),
    session: AsyncSession = Depends(get_db)
):
    _require_program_admin(request)
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")

    stmt = select(Company).order_by(Company.code)
    result = await session.execute(stmt)
    companies = result.scalars().all()

    companies_list = [
        {
            "code": c.code,
            "name": c.name,
            "is_active": c.is_active,
            "created_at": c.created_at.isoformat() if c.created_at else None,
        }
        for c in companies
    ]
    return companies_list


@router.post("/companies/toggle")
async def toggle_company_status(
    request: Request,
    code: str = Body(..., embed=True),
    is_active: bool = Body(..., embed=True),
    admin_job_code: str = Body(..., embed=True),
    session: AsyncSession = Depends(get_db)
):
    _require_program_admin(request)
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")

    stmt = select(Company).where(Company.code == code.strip())
    result = await session.execute(stmt)
    company = result.scalar_one_or_none()
    if not company:
        raise HTTPException(status_code=404, detail="الشركة غير موجودة")

    company.is_active = is_active
    await session.commit()

    status_txt = "تفعيلها" if is_active else "إيقافها لعدم السداد"
    return {"status": "success", "message": f"تم تحديث حالة الشركة بنجاح و{status_txt}"}


@router.put("/companies/update")
async def update_company(
    request: Request,
    old_code: str = Body(...),
    new_code: str = Body(...),
    new_name: str = Body(...),
    admin_job_code: str = Body(...),
    session: AsyncSession = Depends(get_db)
):
    try:
        _require_program_admin(request)
        if admin_job_code != "99":
            raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")

        old_code = old_code.strip()
        new_code = new_code.strip()
        new_name = new_name.strip()

        # البحث عن الشركة القديمة
        stmt = select(Company).where(Company.code == old_code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()
        if not company:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")

        if old_code != new_code:
            # التحقق من عدم وجود شركة أخرى بنفس الكود الجديد
            stmt2 = select(Company).where(Company.code == new_code)
            result2 = await session.execute(stmt2)
            if result2.scalar_one_or_none():
                raise HTTPException(status_code=400, detail="الكود الجديد مستخدم بالفعل")

            # حذف القديم وإضافة الجديد
            await session.delete(company)
            new_company = Company(
                code=new_code,
                name=new_name,
                is_active=company.is_active,
                created_at=company.created_at
            )
            session.add(new_company)

            # تحديث company_code في Firestore للمستخدمين
            users_ref = db.collection("users").where("company_code", "==", old_code).get()
            for user_doc in users_ref:
                user_doc.reference.update({
                    "company_code": new_code,
                    "company_name": new_name
                })
        else:
            # تحديث الاسم فقط
            company.name = new_name
            # تحديث company_name في Firestore
            users_ref = db.collection("users").where("company_code", "==", old_code).get()
            for user_doc in users_ref:
                user_doc.reference.update({"company_name": new_name})

        await session.commit()
        return {"status": "success", "message": "تم تعديل بيانات الشركة"}

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ خطأ في تحديث الشركة: {e}")
        raise HTTPException(status_code=500, detail=f"خطأ داخلي: {str(e)}")


@router.delete("/companies/delete/{code}")
async def delete_company(
    code: str,
    request: Request,
    admin_job_code: str = Query(...),
    session: AsyncSession = Depends(get_db)
):
    try:
        _require_program_admin(request)
        if admin_job_code != "99":
            raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")

        code = code.strip()
        if code == "01":
            raise HTTPException(status_code=403, detail="لا يمكن حذف الشركة الافتراضية")

        stmt = select(Company).where(Company.code == code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()
        if not company:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")

        await session.delete(company)
        await session.commit()

        # حذف المستخدمين المرتبطين بالشركة من Firestore
        users_ref = db.collection("users").where("company_code", "==", code).get()
        for user_doc in users_ref:
            user_doc.reference.delete()

        return {"status": "success", "message": "تم حذف الشركة"}

    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ خطأ في حذف الشركة: {e}")
        raise HTTPException(status_code=500, detail=f"خطأ داخلي: {str(e)}")


# ==========================================
# 5. تحديث الصلاحيات (يبقى في Firestore)
# ==========================================
@router.post("/update-permissions")
async def update_user_permissions(data: PermissionsUpdateModel, request: Request):
    try:
        actor = getattr(request.state, "auth_user", {})
        actor_role = _effective_role(actor)
        actor_email = str(actor.get("email", "")).strip().lower()
        actor_permissions = actor.get("permissions", {})
        general_permissions = actor_permissions.get("صلاحيات عامة", {}) if isinstance(actor_permissions, dict) else {}
        can_manage_permissions = isinstance(general_permissions, dict) and general_permissions.get("صفحة الصلاحيات(الاعدادات)") is True

        if actor_role not in ("super_admin", "admin") and not can_manage_permissions:
            raise HTTPException(status_code=403, detail="غير مصرح لك بتعديل الصلاحيات")

        email = data.email.strip().lower()
        user_ref = db.collection("users").document(email)
        user_doc = user_ref.get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")

        target_data = user_doc.to_dict() or {}
        target_role = _effective_role({**target_data, "email": email})

        # ⭐ حماية السوبر أدمن — مفيش حد يعدل صلاحياته ما عدا نفسه
        if target_role == "super_admin":
            if actor_role != "super_admin":
                raise HTTPException(
                    status_code=403,
                    detail="غير مسموح بتعديل صلاحيات السوبر أدمن",
                )
            # super_admin يقدر يعدل نفسه أو سوبر أدمن تاني
        elif actor_role == "admin":
            # admin مش يقدر يعدل admin تاني
            if str(target_data.get("company_code", "")) != str(actor.get("company_code", "")):
                raise HTTPException(status_code=403, detail="غير مسموح بتعديل صلاحيات مستخدم من شركة أخرى")
            if target_role == "admin":
                raise HTTPException(status_code=403, detail="لا يمكن تعديل صلاحيات مدير")
        update_data = {
            "permissions": data.permissions,
            "updated_at": firestore.SERVER_TIMESTAMP
        }

        if data.allowed_branches is not None:
            update_data["allowed_branches"] = data.allowed_branches

        # ⭐ جديد: فلترة الموظفين في HR
        if data.clear_hr_viewable_employees:
            update_data["hr_viewable_employees"] = None
        elif data.hr_viewable_employees is not None:
            update_data["hr_viewable_employees"] = data.hr_viewable_employees
        user_ref.update(update_data)
        return {"status": "success", "message": "تم تحديث الصلاحيات بنجاح"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/admin/presence/{email}")
async def delete_presence_record(email: str, request: Request):
    actor = getattr(request.state, "auth_user", {})
    role = _effective_role(actor)
    perms = actor.get("permissions", {})
    general = perms.get("صلاحيات عامة", {}) if isinstance(perms, dict) else {}
    if role not in ("admin", "super_admin") and not (
        isinstance(general, dict) and general.get("صفحة الصلاحيات(الاعدادات)") is True
    ):
        raise HTTPException(status_code=403, detail="غير مصرح لك بحذف سجل الحضور")
    target_email = email.strip().lower()
    if not target_email or db is None:
        raise HTTPException(status_code=503, detail="خدمة Firebase غير متاحة")
    user_doc = db.collection("users").document(target_email).get()
    if not user_doc.exists:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")
    target = user_doc.to_dict() or {}
    target_role = _effective_role({**target, "email": target_email})
    if target_role == "super_admin" and role != "super_admin":
        raise HTTPException(status_code=403, detail="غير مسموح بحذف سجل صاحب البرنامج")
    if role == "admin" and (str(target.get("company_code", "")) != str(actor.get("company_code", "")) or target_role == "admin"):
        raise HTTPException(status_code=403, detail="غير مسموح بهذا المستخدم")
    uid = str(target.get("uid", "")).strip()
    if not uid:
        raise HTTPException(status_code=404, detail="لا يوجد سجل حضور لهذا المستخدم")
    try:
        get_realtime_database().child("presence").child(uid).delete()
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:
        print(f"⚠️ delete_presence_record({target_email}): {exc}")
        raise HTTPException(status_code=502, detail="تعذر حذف سجل الحضور") from exc
    return {"status": "success", "message": "تم حذف سجل الحضور"}

