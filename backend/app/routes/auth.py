from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore

router = APIRouter()

# موديل التسجيل
class UserRegister(BaseModel):
    name: str
    email: EmailStr
    password: str
    company_code: str

# موديل تسجيل الدخول (إضافة لضمان استقرار السيرفر)
class UserLogin(BaseModel):
    email: EmailStr
    password: str

# القائمة الثابتة للأكواد (مؤقتاً)
COMPANY_MAP = {
    "01": "شركة إسلام",
    "02": "شركة بيت اللوز",
    "03": "شركة الأمل"
}

@router.post("/register")
async def register(user: UserRegister):
    try:
        email_clean = user.email.strip().lower()
        code = user.company_code.strip()
        
        # تحديد اسم الشركة بناءً على الكود، لو الكود مش موجود يكتب "شركة غير معروفة"
        company_name = COMPANY_MAP.get(code, "شركة غير معروفة")

        user_ref = db.collection("users").document(email_clean)
        user_data = {
            "name": user.name.strip(),
            "email": email_clean,
            "password": user.password,
            "company_code": code,
            "company_name": company_name, # حفظ الاسم بناءً على الكود
            "created_at": firestore.SERVER_TIMESTAMP,
        }
        user_ref.set(user_data)
        return {"status": "success", "message": f"تم التسجيل في {company_name}"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/login")
async def login(user_data_in: dict):
    try:
        email = user_data_in.get("email").strip().lower()
        password = user_data_in.get("password")
        
        user_doc = db.collection("users").document(email).get()
        if not user_doc.exists:
            raise HTTPException(status_code=404, detail="المستخدم غير موجود")
            
        data = user_doc.to_dict()
        
        if data["password"] == password:
            # نأخذ اسم الشركة المسجل في فايربيز أو نحدده من الكود لو مكانش متسجل
            company_code = data.get("company_code", "00")
            company_name = data.get("company_name") or COMPANY_MAP.get(company_code, "شركة عامة")

            return {
                "name": data.get("name"),
                "email": data.get("email"),
                "company_code": company_code,
                "company_name": company_name
            }
        else:
            raise HTTPException(status_code=401, detail="كلمة المرور خطأ")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))