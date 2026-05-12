from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import auth, transactions, coding # ضفنا كودينج هنا

app = FastAPI(title="IslamApp V1.0 API")

# إعدادات الـ CORS لربط الفلاتر بالباك إند
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ربط المسارات (Routes)
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])
app.include_router(transactions.router, prefix="/transactions", tags=["Transactions"])
app.include_router(coding.router, prefix="/coding", tags=["Coding"]) # السطر ده مهم جداً

@app.get("/")
async def root():
    return {"message": "Welcome to IslamApp V1.0 API - Server is Running"}