from fastapi import APIRouter, HTTPException, Header, Body
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth as admin_auth

router = APIRouter()

# القواميس الأساسية للنظام
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
    uid: str  # سنستقبل الـ UID الناتج من Firebase Auth
    company_code: str
    job_code: str

@router.post("/register")
async def register(user: UserRegister):
    try:
        email_clean = user.email.strip().lower()
        comp_code = user.company_code.strip()
        job_code = user.job_code.strip()

        # 1. التحقق من أن كود الشركة وكود الوظيفة "صحيحين" ومعرفين في الـ MAPS عندك
        # لو الكود مش موجود في الـ Map، هنرفض التسجيل فوراً
        if comp_code not in COMPANY_MAP:
            raise HTTPException(status_code=403, detail="كود الشركة غير صحيح أو غير مسجل في النظام")
        
        if job_code not in USER_ROLES:
            raise HTTPException(status_code=403, detail="كود الوظيفة غير صحيح")

        # 2. (اختياري) لو عاوز تربط أكواد موظفين معينة بكل شركة في قاعدة البيانات
        # ممكن تعمل Collection في Firestore اسمه "valid_codes" وتتأكد منه هنا
        # حالياً الاعتماد على COMPANY_MAP و USER_ROLES هو حل ممتاز وسريع.

        company_name = COMPANY_MAP.get(comp_code)
        job_title = USER_ROLES.get(job_code)

        user_ref = db.collection("users").document(email_clean)
        
        if user_ref.get().exists:
            raise HTTPException(status_code=400, detail="هذا البريد مسجل بالفعل في قاعدة البيانات")

        # تخزين البيانات الشخصية والصلاحيات
        user_data = {
            "uid": user.uid,
            "name": user.name.strip(),
            "email": email_clean,
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

@router.post("/verify-user")
async def verify_user(authorization: str = Header(None)):
    """تأكيد الهوية عبر التوكن وجلب الصلاحيات"""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="لم يتم إرسال توكن صالح")
    
    try:
        token = authorization.split("Bearer ")[1]
        # التحقق من التوكن عبر جوجل
        decoded_token = admin_auth.verify_id_token(token)
        email = decoded_token.get("email")

        # جلب الصلاحيات من Firestore
        user_doc = db.collection("users").document(email).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="بيانات المستخدم غير موجودة")
            
        data = user_doc.to_dict()
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