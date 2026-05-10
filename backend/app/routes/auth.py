from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth

router = APIRouter()

# القواميس الأساسية للنظام [طبقاً لملف الوورد]
COMPANY_MAP = {
    "01": "إسلام",
    "02": "بيت اللوز",
    "03": "الأمل"
}

USER_ROLES = {
    "1": "موظف",
    "200": "مشرف",
    "201": "مدير",
    "99": "صاحب البرنامج"
}

class UserRegister(BaseModel):
    name: str
    email: EmailStr
    password: str
    company_code: str
    job_code: str  # الحقل الجديد لكود الوظيفة

class ResetPasswordRequest(BaseModel):
    email: EmailStr

@router.post("/register")
async def register(user: UserRegister):
    try:
        email_clean = user.email.strip().lower()
        comp_code = user.company_code.strip()
        job_code = user.job_code.strip()
        
        # التأكد من صحة الأكواد
        company_name = COMPANY_MAP.get(comp_code, "شركة غير معروفة")
        job_title = USER_ROLES.get(job_code, "غير محدد")

        user_ref = db.collection("users").document(email_clean)
        
        # منع التسجيل المتكرر بنفس الإيميل
        if user_ref.get().exists:
            raise HTTPException(status_code=400, detail="هذا البريد مسجل بالفعل")

        user_data = {
            "name": user.name.strip(),
            "email": email_clean,
            "password": user.password, # يفضل لاحقاً تشفيره بـ bcrypt
            "company_code": comp_code,
            "company_name": company_name,
            "job_code": job_code,
            "job_title": job_title,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        
        user_ref.set(user_data)
        return {"status": "success", "message": f"تم تسجيل {job_title} في {company_name}"}
    except Exception as e:
        if isinstance(e, HTTPException): raise e
        raise HTTPException(status_code=500, detail=str(e))

# ... دالة الـ login والـ reset-password هتفضل زي ما هي مع استلام الـ job_code

@router.post("/login")
async def login(user_data_in: dict):
    try:
        email = user_data_in.get("email", "").strip().lower()
        password = user_data_in.get("password", "")
        
        if not email or not password:
            raise HTTPException(status_code=400, detail="البريد والباسورد مطلوبين")

        user_doc = db.collection("users").document(email).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")
            
        data = user_doc.to_dict()
        
        if data["password"] == password:
            company_code = data.get("company_code", "00")
            company_name = data.get("company_name") or COMPANY_MAP.get(company_code, "شركة عامة")
            
            # إرجاع البيانات الجديدة (الصلاحيات)
            return {
                "name": data.get("name"),
                "email": data.get("email"),
                "company_code": company_code,
                "company_name": company_name,
                "job_code": data.get("job_code", "1"), # الافتراضي موظف
                "job_title": data.get("job_title", "موظف"),
                "status": "success"
            }
        else:
            raise HTTPException(status_code=401, detail="كلمة المرور غير صحيحة")
    except Exception as e:
        if isinstance(e, HTTPException): raise e
        raise HTTPException(status_code=500, detail=str(e))

# دالة إعادة تعيين كلمة المرور الجديدة


@router.post("/reset-password")
async def reset_password(request: ResetPasswordRequest): # تأكد إنها ResetPasswordRequest
    try:
        # فايربيز بيحتاج الإيميل عشان يبعت الرابط
        auth.generate_password_reset_link(request.email)
        return {"status": "success", "message": "تم إرسال الرابط"}
    except Exception as e:
        # لو الإيميل مش موجود في Firebase Auth هيطلع 404
        raise HTTPException(status_code=404, detail="البريد الإلكتروني غير مسجل")

class ResetVerify(BaseModel):
    email: EmailStr
    company_code: str
    job_code: str

@router.post("/verify-reset")
async def verify_reset(data: ResetVerify):
    try:
        email_clean = data.email.strip().lower()
        user_doc = db.collection("users").document(email_clean).get()
        
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="البريد الإلكتروني غير مسجل")
            
        user_data = user_doc.to_dict()
        
        # التأكد من مطابقة الأكواد المخزنة عند التسجيل
        if (user_data.get("company_code") == data.company_code.strip() and 
            user_data.get("job_code") == data.job_code.strip()):
            
            # لو البيانات صح، بنولد رابط استعادة كلمة المرور من فايربيز
            link = auth.generate_password_reset_link(email_clean)
            return {
                "status": "success", 
                "message": "تم التحقق من البيانات بنجاح",
                "reset_link": link
            }
        else:
            raise HTTPException(status_code=401, detail="أكواد التحقق غير صحيحة")
            
    except Exception as e:
        if isinstance(e, HTTPException): raise e
        raise HTTPException(status_code=500, detail=str(e))    