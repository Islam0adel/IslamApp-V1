from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from app.core.firebase_setup import db
from google.cloud import firestore

router = APIRouter()

# شكل البيانات اللي السيرفر مستنيها من فلاتر
class UserAuth(BaseModel):
    email: str
    password: str

@router.post("/register")
async def register(user: UserAuth):
    try:
        # التأكد إن المستخدم مش موجود قبل كدة
        # بدل السطر القديم، استخدم ده عشان ينظف الإيميل من المسافات
        user_ref = db.collection("users").document(user.email.strip().lower())
        if user_ref.get().exists:
            raise HTTPException(status_code=400, detail="المستخدم موجود بالفعل")
        
        # حفظ المستخدم الجديد
        user_ref.set({
            "email": user.email,
            "password": user.password, # في النسخ الجاية هنشفره للأمان
            "created_at": firestore.SERVER_TIMESTAMP
        })
        return {"message": "تم إنشاء الحساب بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/login")
async def login(user: UserAuth):
    try:
        user_ref = db.collection("users").document(user.email)
        doc = user_ref.get()
        
        if doc.exists:
            user_data = doc.to_dict()
            if user_data["password"] == user.password:
                return {"message": "تم تسجيل الدخول بنجاح", "user": user.email}
        
        raise HTTPException(status_code=401, detail="بيانات الدخول غير صحيحة")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))