# backend/app/main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routes import auth, transactions, coding, inventory, supplier, supplier_settlement
from app.routes import sync
from app.core.database import create_tables, AsyncSessionLocal
from app.core.models import Company
from sqlalchemy import select

app = FastAPI(title="IslamApp V1.0 API")

# ========== إعدادات CORS ==========
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ========== دالة إنشاء الشركة الافتراضية ==========
async def create_default_company():
    async with AsyncSessionLocal() as db:
        stmt = select(Company).where(Company.code == "01")
        result = await db.execute(stmt)
        company = result.scalar_one_or_none()
        if not company:
            new_company = Company(
                code="01",
                name="اسلام",
                is_active=True
            )
            db.add(new_company)
            await db.commit()
            print("✅ تم إنشاء الشركة الافتراضية في Neon: 01 - اسلام")

# ========== إنشاء الجداول والبيانات الافتراضية عند بدء التشغيل ==========
@app.on_event("startup")
async def startup():
    await create_tables()
    await create_default_company()
    print("✅ تم التحقق من الجداول والشركة الافتراضية في قاعدة البيانات (PostgreSQL)")

# ========== ربط المسارات (Routes) ==========
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])
app.include_router(transactions.router, prefix="/transactions", tags=["Transactions"])
app.include_router(coding.router, prefix="/coding", tags=["Coding"])
app.include_router(inventory.router, prefix="/inventory", tags=["Inventory"])
app.include_router(supplier.router, prefix="/supplier", tags=["Supplier"])
app.include_router(sync.router, prefix="/sync", tags=["Sync"])
app.include_router(
    supplier_settlement.router,
    prefix="/supplier-settlement",
    tags=["Supplier Settlement"],
)

@app.get("/")
async def root():
    return {
        "message": "Welcome to IslamApp V1.0 API - Server is Running",
        "status": "online",
        "database": "PostgreSQL (Neon)",
        "sync": "WebSocket enabled"
    }