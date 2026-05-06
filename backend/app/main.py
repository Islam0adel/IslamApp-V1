from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import auth
from app.core.firebase_setup import db  # استيراد الـ db عشان نضمن إن الفايربيز اشتغل أول ما السيرفر يقوم

app = FastAPI(
    title="IslamApp API",
    description="Backend API for Islam's Financial Project v1.0",
    version="1.0.0"
)

# --- إعدادات الـ CORS ---
# دي الخطوة السحرية عشان تطبيق Vercel (Frontend) يقدر يكلم Hugging Face (Backend)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],      # بيسمح لأي Domain بالوصول (Vercel, Localhost, etc.)
    allow_credentials=True,
    allow_methods=["*"],      # بيسمح بجميع أنواع الطلبات (GET, POST, PUT, DELETE)
    allow_headers=["*"],      # بيسمح بكل الـ Headers (Authorization, Content-Type)
)

# تسجيل الـ Routers
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])

@app.get("/")
async def root():
    """
    نقطة النهاية الأساسية للتأكد من أن السيرفر يعمل
    """
    return {
        "status": "Server is running!",
        "project": "IslamApp V1.0",
        "environment": "Production (Hugging Face)"
    }

# ملاحظة: uvicorn بيتم تشغيله من خلال الـ Dockerfile اللي عملناه