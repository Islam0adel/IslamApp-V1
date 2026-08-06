# backend/app/main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import auth, transactions, coding, inventory, supplier
from app.routes import sync  # ✅ استيراد راوتر المزامنة الجديد
from app.core.database import create_tables
import asyncio

app = FastAPI(title="IslamApp V1.0 API")

# ========== إعدادات CORS ==========
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ========== إنشاء الجداول عند بدء التشغيل ==========
@app.on_event("startup")
async def startup():
    await create_tables()
    print("✅ تم التحقق من الجداول في قاعدة البيانات (PostgreSQL)")

# ========== ربط المسارات (Routes) ==========
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])
app.include_router(transactions.router, prefix="/transactions", tags=["Transactions"])
app.include_router(coding.router, prefix="/coding", tags=["Coding"])
app.include_router(inventory.router, prefix="/inventory", tags=["Inventory"])
app.include_router(supplier.router, prefix="/supplier", tags=["Supplier"])
app.include_router(sync.router, prefix="/sync", tags=["Sync"])  # ✅ إضافة راوتر المزامنة (WebSocket)

@app.get("/")
async def root():
    return {
        "message": "Welcome to IslamApp V1.0 API - Server is Running",
        "status": "online",
        "database": "PostgreSQL (Neon)",
        "sync": "WebSocket enabled"
    }