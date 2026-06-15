from fastapi import APIRouter, HTTPException, Header, Body, Query
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth as admin_auth

router = APIRouter()

# ========== إنشاء شركة افتراضية إذا لم تكن موجودة ==========
def create_default_company():
    """تأكد من وجود شركة 01 - اسلام في قاعدة البيانات"""
    try:
        default_company_ref = db.collection("companies").document("01")
        if not default_company_ref.get().exists:
            default_company_ref.set({
                "code": "01",
                "name": "اسلام",
                "is_active": True,
                "created_at": firestore.SERVER_TIMESTAMP
            })
            print("✅ تم إنشاء الشركة الافتراضية: 01 - اسلام")
    except Exception as e:
        print(f"⚠️ خطأ في إنشاء الشركة الافتراضية: {e}")

# استدعاء الدالة عند بدء التشغيل (ضعها بعد تعريف `db` مباشرة)
create_default_company()
# ======================================================

USER_ROLES = {
    "1": "موظف",
    "200": "مشرف",
    "201": "مدير",
    "99": "صاحب البرنامج"
}

class UserRegister(BaseModel):
    name: str
    email: EmailStr
    uid: str  # سنستقبل الـ UID الناتج من Firebase Auth
    company_code: str
    job_code: str

# نموذج جديد مخصص لإضافة شركة
class CompanyModel(BaseModel):
    code: str
    name: str

@router.post("/register")
async def register(user: UserRegister):
    try:
        email_clean = user.email.strip().lower()
        comp_code = user.company_code.strip()
        job_code = user.job_code.strip()

        # 1. التحقق من الشركة من الفايربيز مباشرة
        company_doc = db.collection("companies").document(comp_code).get()
        if not company_doc.exists:
            raise HTTPException(status_code=403, detail="كود الشركة غير صحيح أو غير مسجل في النظام")
            
        company_data = company_doc.to_dict()
        # التأكد أن الشركة غير موقوفة
        if not company_data.get("is_active", True):
            raise HTTPException(status_code=403, detail="هذه الشركة موقوفة حالياً، يرجى مراجعة إدارة البرنامج")
            
        company_name = company_data.get("name")

        # 2. التحقق من كود الوظيفة
        if job_code not in USER_ROLES:
            raise HTTPException(status_code=403, detail="كود الوظيفة غير صحيح")

        job_title = USER_ROLES.get(job_code)

        user_ref = db.collection("users").document(email_clean)
        
        if user_ref.get().exists:
            raise HTTPException(status_code=400, detail="هذا البريد مسجل بالفعل في قاعدة البيانات")

        # تخزين البيانات الشخصية والصلاحيات
        user_data_to_save = {
            "uid": user.uid,
            "name": user.name.strip(),
            "email": email_clean,
            "company_code": comp_code,
            "company_name": company_name,
            "job_code": job_code,
            "job_title": job_title,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        
        user_ref.set(user_data_to_save)
        return {"status": "success", "message": f"تم تسجيل {job_title} في {company_name}"}

    except Exception as e:
        if isinstance(e, HTTPException): raise e
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/verify-user")
async def verify_user(authorization: str = Header(None)):
    """تأكيد الهوية عبر التوكن وجلب الصلاحيات مع التحقق من حالة الشركة"""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="لم يتم إرسال توكن صالح")
    
    try:
        token = authorization.split("Bearer ")[1]
        # التحقق من التوكن عبر جوجل
        decoded_token = admin_auth.verify_id_token(token)
        email = decoded_token.get("email")

        # جلب بيانات المستخدم من Firestore
        user_doc = db.collection("users").document(email).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="بيانات المستخدم غير موجودة")
            
        data = user_doc.to_dict()
        comp_code = data.get("company_code")

        # التحقق من حالة الشركة لمنع الدخول إذا كان الاشتراك موقوفاً
        company_doc = db.collection("companies").document(comp_code).get()
        if not company_doc.exists:
            raise HTTPException(status_code=404, detail="الشركة التابع لها هذا الحساب غير موجودة")

        company_data = company_doc.to_dict()
        if not company_data.get("is_active", True):
            raise HTTPException(status_code=403, detail="تم إيقاف صلاحية الوصول لهذه الشركة (يرجى سداد الاشتراك)")

        return {
            "status": "success",
            "name": data.get("name"),
            "email": data.get("email"),
            "company_code": data.get("company_code"),
            "company_name": data.get("company_name"),
            "job_code": data.get("job_code"),
            "job_title": data.get("job_title"),
        }
    except Exception as e:
        if isinstance(e, HTTPException): raise e # إرسال رسالة الإيقاف إن وجدت
        print(f"⚠️ خطأ في التحقق من التوكن: {e}") 
        raise HTTPException(status_code=401, detail="انتهت صلاحية الجلسة، سجل دخولك مرة أخرى")

@router.post("/verify-reset")
async def verify_reset(email: str = Body(..., embed=True), company_code: str = Body(..., embed=True), job_code: str = Body(..., embed=True)):
    """التحقق من الأكواد قبل السماح بإرسال رابط الاستعادة"""
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

# =====================================================================
# مسارات إدارة الشركات (خاصة بصاحب البرنامج فقط - كود 99)
# =====================================================================

@router.post("/companies/add")
async def add_new_company(company: CompanyModel, admin_job_code: str = Query(...)):
    """تكويد شركة جديدة"""
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="عذراً، هذه الصلاحية خاصة بصاحب البرنامج فقط!")
        
    comp_code = company.code.strip()
    comp_name = company.name.strip()
    
    comp_ref = db.collection("companies").document(comp_code)
    if comp_ref.get().exists:
        raise HTTPException(status_code=400, detail="كود هذه الشركة مسجل بالفعل في النظام")
        
    comp_ref.set({
        "code": comp_code,
        "name": comp_name,
        "is_active": True, # الشركة نشطة بشكل افتراضي عند الإضافة
        "created_at": firestore.SERVER_TIMESTAMP
    })
    return {"status": "success", "message": f"تم تكويد شركة [{comp_name}] بنجاح"}

@router.get("/companies/all")
async def get_all_companies(admin_job_code: str = Query(...)):
    """جلب جميع الشركات مع حالتها"""
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")
        
    docs = db.collection("companies").order_by("code").stream()
    companies_list = []
    for doc in docs:
        companies_list.append(doc.to_dict())
    return companies_list

@router.post("/companies/toggle")
async def toggle_company_status(code: str = Body(..., embed=True), is_active: bool = Body(..., embed=True), admin_job_code: str = Body(..., embed=True)):
    """تفعيل أو إيقاف اشتراك شركة"""
    if admin_job_code != "99":
        raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")
        
    comp_ref = db.collection("companies").document(code.strip())
    if not comp_ref.get().exists:
        raise HTTPException(status_code=404, detail="الشركة غير موجودة")
        
    comp_ref.update({"is_active": is_active})
    status_txt = "تفعيلها" if is_active else "إيقافها لعدم السداد"
    return {"status": "success", "message": f"تم تحديث حالة الشركة بنجاح و{status_txt}"}

@router.put("/companies/update")
async def update_company(
    old_code: str = Body(...),
    new_code: str = Body(...),
    new_name: str = Body(...),
    admin_job_code: str = Body(...)
):
    """تعديل كود واسم الشركة"""
    try:
        if admin_job_code != "99":
            raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")
        
        old_code = old_code.strip()
        new_code = new_code.strip()
        new_name = new_name.strip()
        
        comp_ref = db.collection("companies").document(old_code)
        comp_doc = comp_ref.get()
        if not comp_doc.exists:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")
        
        # إذا تم تغيير الكود
        if old_code != new_code:
            new_ref = db.collection("companies").document(new_code)
            if new_ref.get().exists:
                raise HTTPException(status_code=400, detail="الكود الجديد مستخدم بالفعل")
            
            old_data = comp_doc.to_dict()
            old_data["code"] = new_code
            old_data["name"] = new_name
            new_ref.set(old_data)
            comp_ref.delete()
            
            # تحديث المستخدمين المرتبطين (بدون async for لتجنب المشاكل)
            users_ref = db.collection("users").where("company_code", "==", old_code).get()
            for user_doc in users_ref:
                user_doc.reference.update({
                    "company_code": new_code,
                    "company_name": new_name
                })
        else:
            comp_ref.update({"name": new_name})
            users_ref = db.collection("users").where("company_code", "==", old_code).get()
            for user_doc in users_ref:
                user_doc.reference.update({"company_name": new_name})
        
        # إرسال رد واضح
        return {"status": "success", "message": "تم تعديل بيانات الشركة"}
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ خطأ في تحديث الشركة: {e}")
        raise HTTPException(status_code=500, detail=f"خطأ داخلي: {str(e)}")

@router.delete("/companies/delete/{code}")
async def delete_company(
    code: str,
    admin_job_code: str = Query(...)
):
    """حذف شركة بالكامل (بشرط ألا يكون لها مستخدمين)"""
    try:
        if admin_job_code != "99":
            raise HTTPException(status_code=403, detail="غير مصرح لك بالوصول")
        
        code = code.strip()
        comp_ref = db.collection("companies").document(code)
        if not comp_ref.get().exists:
            raise HTTPException(status_code=404, detail="الشركة غير موجودة")
        
        if code == "01":
            raise HTTPException(status_code=403, detail="لا يمكن حذف الشركة الافتراضية")
        
        # التحقق من وجود مستخدمين (بدون async for)
        users_query = db.collection("users").where("company_code", "==", code).limit(1).get()
        if len(users_query) > 0:
            raise HTTPException(status_code=400, detail="لا يمكن حذف الشركة لأن بها مستخدمين مسجلين")
        
        comp_ref.delete()
        return {"status": "success", "message": "تم حذف الشركة"}
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"⚠️ خطأ في حذف الشركة: {e}")
        raise HTTPException(status_code=500, detail=f"خطأ داخلي: {str(e)}")