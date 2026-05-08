from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import auth # تأكد إن الـ import ده صح

app = FastAPI(title="IslamApp API")

# إعدادات الـ CORS عشان الفلاتر يعرف يكلم البايثون
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ربط ملف الـ Auth
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])

@app.get("/")
async def root():
    return {"message": "Welcome to IslamApp V1.0 API"}