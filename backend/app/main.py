from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware # استيراد المكتبة
from app.routes import auth

app = FastAPI(title="IslamApp API")

# إعدادات الـ CORS - دي اللي هتحل مشكلة الاتصال
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # بيسمح لأي موقع يكلم السيرفر (مناسب جداً للتطوير)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/auth", tags=["Authentication"])

@app.get("/")
async def root():
    return {"status": "Server is running!"}