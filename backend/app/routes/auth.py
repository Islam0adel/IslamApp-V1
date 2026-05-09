from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth  # ضروري لإدارة كلمات المرور

router = APIRouter()

class UserRegister(BaseModel):
    name: str
    email: EmailStr
    password: str
    company_code: str

class ResetPasswordRequest(BaseModel):
    email: EmailStr

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
        company_name = COMPANY_MAP.get(code, "شركة غير معروفة")

        user_ref = db.collection("users").document(email_clean)
        user_data = {
            "name": user.name.strip(),
            "email": email_clean,
            "password": user.password,
            "company_code": code,
            "company_name": company_name,
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

# دالة إعادة تعيين كلمة المرور الجديدة


@router.post("/reset-password")
async def reset_password(request: ResetPasswordRequest):
    try:
        # 1. بنجرب نولد الرابط عشان نتأكد إن المستخدم موجود أصلاً في Firebase Auth
        # الدالة دي هترمي Exception لو الإيميل مش مسجل في قائمة الـ Users بفايربيز
        link = auth.generate_password_reset_link(request.email)
        
        # 2. لو إنت عاوز فايربيز هو اللي يبعت الإيميل "تلقائياً" بالـ Template بتاعك
        # الأفضل في Python Admin SDK إنك تبعت الرابط ده للمستخدم عبر خدمة إيميل
        # لكن لو عاوز فايربيز يبعته مباشرة "زي الموبايل"، فده بيتم غالباً من جهة Flutter
        
        # كحل سريع وممتاز للباك إند:
        print(f"الرابط اتولد بنجاح: {link}") # عشان تشوفه في الـ Logs للتجربة
        
        return {
            "status": "success", 
            "message": "تم إنشاء رابط استعادة كلمة المرور بنجاح"
        }
    except auth.UserNotFoundError:
        raise HTTPException(status_code=404, detail="البريد الإلكتروني غير مسجل في النظام")
    except Exception as e:
        print(f"Error: {e}")
        raise HTTPException(status_code=500, detail="حدث خطأ أثناء محاولة إرسال الإيميل")