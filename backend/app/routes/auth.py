from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, EmailStr
from app.core.firebase_setup import db
from google.cloud import firestore
from firebase_admin import auth

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


# ==========================
# تسجيل مستخدم جديد
# ==========================
@router.post("/register")
async def register(user: UserRegister):
    try:
        email_clean = user.email.strip().lower()
        code = user.company_code.strip()
        company_name = COMPANY_MAP.get(code, "شركة غير معروفة")

        # --------------------------------
        # 1) إنشاء المستخدم في Firebase Auth
        # --------------------------------
        try:
            auth.get_user_by_email(email_clean)
            raise HTTPException(
                status_code=400,
                detail="البريد الإلكتروني مستخدم بالفعل"
            )
        except auth.UserNotFoundError:
            # لو مش موجود، أنشئه
            auth.create_user(
                email=email_clean,
                password=user.password
            )

        # --------------------------------
        # 2) تخزين البيانات في Firestore
        # --------------------------------
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

        return {
            "status": "success",
            "message": f"تم التسجيل في {company_name}"
        }

    except HTTPException:
        raise

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e)
        )


# ==========================
# تسجيل الدخول
# ==========================
@router.post("/login")
async def login(user_data_in: dict):
    try:
        email = user_data_in.get("email").strip().lower()
        password = user_data_in.get("password")

        user_doc = db.collection("users").document(email).get()

        if not user_doc.exists:
            raise HTTPException(
                status_code=404,
                detail="المستخدم غير موجود"
            )

        data = user_doc.to_dict()

        if data["password"] == password:
            company_code = data.get("company_code", "00")
            company_name = data.get("company_name") or COMPANY_MAP.get(
                company_code,
                "شركة عامة"
            )

            return {
                "name": data.get("name"),
                "email": data.get("email"),
                "company_code": company_code,
                "company_name": company_name
            }

        else:
            raise HTTPException(
                status_code=401,
                detail="كلمة المرور خطأ"
            )

    except HTTPException:
        raise

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e)
        )


# ==========================
# إعادة تعيين كلمة المرور
# ==========================
@router.post("/reset-password")
async def reset_password(request: ResetPasswordRequest):
    try:
        email_clean = request.email.strip().lower()

        # التأكد إن المستخدم موجود في Firebase Auth
        auth.get_user_by_email(email_clean)

        # إنشاء وإرسال رابط إعادة تعيين كلمة المرور
        auth.generate_password_reset_link(email_clean)

        return {
            "status": "success",
            "message": "تم إرسال رابط إعادة تعيين كلمة المرور إلى بريدك الإلكتروني"
        }

    except auth.UserNotFoundError:
        raise HTTPException(
            status_code=404,
            detail="البريد الإلكتروني غير مسجل"
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e)
        )