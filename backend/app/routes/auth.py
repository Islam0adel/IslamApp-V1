# backend/app/routes/auth.py
from fastapi import APIRouter, HTTPException, Header, Body, Query, Depends, Request
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db  # ✅ كائن Firestore (للمستخدمين والصلاحيات)
from google.cloud import firestore
from firebase_admin import auth as admin_auth
from typing import Optional, List
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.core.database import get_db
from app.core.models import Company
from app.core.schemas import CompanyModel

router = APIRouter()


def _require_program_admin(request: Request):
    if str(getattr(request.state, "auth_user", {}).get("job_code", "1")) != "99":
        raise HTTPException(status_code=403, detail="هذه الصلاحية خاصة بصاحب البرنامج فقط")

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
    job_code: str

class PermissionsUpdateModel(BaseModel):
    email: str
    permissions: dict
    allowed_branches: Optional[List[str]] = None


# ==========================================
# 1. تسجيل مستخدم جديد
# ==========================================
@router.post("/register")
async def register(
    user: UserRegister,
    session: AsyncSession = Depends(get_db)  # ✅ جلسة PostgreSQL
):
    try:
        email_clean = user.email.strip().lower()
        comp_code = user.company_code.strip()
        job_code = user.job_code.strip()

        # ✅ التحقق من الشركة من Neon (PostgreSQL)
        stmt = select(Company).where(Company.code == comp_code)
        result = await session.execute(stmt)
        company = result.scalar_one_or_none()

        if not company:
            raise HTTPException(status_code=403, detail="كود الشركة غير صحيح أو غير مسجل في النظام")

        if not company.is_active:
            raise HTTPException(status_code=403, detail="هذه الشركة موقوفة حالياً، يرجى مراجعة إدارة البرنامج")

        company_name = company.name

        if job_code not in USER_ROLES:
            raise HTTPException(status_code=403, detail="كود الوظيفة غير صحيح")

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
            "job_code": job_code,
            "job_title": job_title,
            "allowed_branches": ["all"],
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        user_ref.set(user_data_to_save)

        return {"status": "success", "message": f"تم تسجيل {job_title} في {company_name}"}

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

        return {
            "status": "success",
            "name": data.get("name"),
            "email": data.get("email"),
            "company_code": data.get("company_code"),
            "company_name": company.name,  # ✅ من Neon
            "job_code": data.get("job_code"),
            "job_title": data.get("job_title"),
        }
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        print(f"⚠️ خطأ في التحقق من التوكن: {e}")
        raise HTTPException(status_code=401, detail="انتهت صلاحية الجلسة، سجل دخولك مرة أخرى")


# ==========================================
# 3. التحقق من كود الاستعادة (نسيت كلمة المرور)
# ==========================================
@router.post("/verify-reset")
async def verify_reset(
    email: str = Body(..., embed=True),
    company_code: str = Body(..., embed=True),
    job_code: str = Body(..., embed=True)
):
    try:
        user_doc = db.collection("users").document(email.strip().lower()).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="البريد غير مسجل")

        user_data = user_doc.to_dict()
        if (user_data.get("company_code") == company_code.strip() and
            user_data.get("job_code") == job_code.strip()):
            link = admin_auth.generate_password_reset_link(email)
            return {"status": "success", "reset_link": link}
        else:
            raise HTTPException(status_code=401, detail="أكواد التحقق غير مطابقة")
    except Exception as e:
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
        actor_job_code = str(actor.get("job_code", "1"))
        actor_permissions = actor.get("permissions", {})
        general_permissions = actor_permissions.get("صلاحيات عامة", {}) if isinstance(actor_permissions, dict) else {}
        can_manage_permissions = isinstance(general_permissions, dict) and general_permissions.get("صفحة الصلاحيات(الاعدادات)") is True
        if actor_job_code != "99" and actor_job_code != "201" and not can_manage_permissions:
            raise HTTPException(status_code=403, detail="غير مصرح لك بتعديل الصلاحيات")
        email = data.email.strip().lower()
        user_ref = db.collection("users").document(email)
        user_doc = user_ref.get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")
        target_data = user_doc.to_dict() or {}
        if actor_job_code != "99" and str(target_data.get("company_code", "")) != str(actor.get("company_code", "")):
            raise HTTPException(status_code=403, detail="غير مسموح بتعديل صلاحيات مستخدم من شركة أخرى")
        update_data = {
            "permissions": data.permissions,
            "updated_at": firestore.SERVER_TIMESTAMP
        }
        if data.allowed_branches is not None:
            update_data["allowed_branches"] = data.allowed_branches
        user_ref.update(update_data)
        return {"status": "success", "message": "تم تحديث الصلاحيات بنجاح"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
