from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth  # ضروري لإدارة كلمات المرور
import os
import requests

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

router = APIRouter()

# قراءة المفتاح من "الخزنة" (Environment Variables)
# تأكد إنك سميت السر في Hugging Face بنفس الاسم ده: FIREBASE_KEYS
FIREBASE_KEYS = os.getenv("FIREBASE_KEYS")

class ResetPasswordRequest(BaseModel):
    email: EmailStr

@router.post("/reset-password")
async def reset_password(request: ResetPasswordRequest):
    try:
        # 1. تنظيف الإيميل والتأكد من وجوده في قاعدة بياناتنا (Firestore)
        email = request.email.strip().lower()
        user_doc = db.collection("users").document(email).get()
        
        if not user_doc.exists:
            # للأمان ممكن نطلع نفس الرسالة، بس هنا هنعرفك لو الإيميل مش موجود
            raise HTTPException(status_code=404, detail="البريد الإلكتروني غير مسجل في النظام")

        # 2. التأكد إن الـ API Key موجود في إعدادات السيرفر
        if not FIREBASE_KEYS:
            print("❌ خطأ: FIREBASE_KEYS مش موجود في إعدادات السيرفر!")
            raise HTTPException(
                status_code=500, 
                detail="خطأ في إعدادات السيرفر، برجاء مراجعة مدير النظام"
            )

        # 3. إرسال الطلب لـ Firebase Auth REST API لإرسال الإيميل
        # دي الدالة اللي بتخلي فايربيز يبعت الإيميل بالـ Template بتاعك أوتوماتيك
        url = f"https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key={FIREBASE_KEYS}"
        payload = {
            "requestType": "PASSWORD_RESET",
            "email": email
        }
        
        response = requests.post(url, json=payload)
        result = response.json()

        # 4. التحقق من رد فايربيز
        if response.status_code == 200:
            return {
                "status": "success", 
                "message": "تم إرسال رابط إعادة تعيين كلمة المرور إلى بريدك الإلكتروني بنجاح"
            }
        else:
            # لو فايربيز رفض الطلب (مثلاً الإيميل ممسوح من الـ Authentication)
            error_message = result.get("error", {}).get("message", "حدث خطأ أثناء إرسال الإيميل")
            print(f"Firebase Error: {error_message}")
            raise HTTPException(status_code=400, detail=f"فشل الطلب: {error_message}")

    except Exception as e:
        # لو الخطأ إحنا اللي رامينه (HTTPException) نطلعه زي ما هو
        if isinstance(e, HTTPException):
            raise e
        # أي خطأ تقني تاني غير متوقع
        print(f"Technical Error: {str(e)}")
        raise HTTPException(status_code=500, detail="حدث خطأ تقني في السيرفر")