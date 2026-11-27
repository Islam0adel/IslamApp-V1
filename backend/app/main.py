# backend/app/main.py
import asyncio

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from app.routes import auth, transactions, coding, inventory, supplier, supplier_settlement
from app.routes import sync, notifications, product_lookup
from app.routes import employees
from app.routes import commercial
from app.routes import treasury_transfers
from app.routes import transfers  # ⭐ التحويلات المخزنية (وحدة مستقلة)
from app.routes import hr  # ← NEW (ملف واحد لكل HR)
from app.core.auth_middleware import authenticate_http_request
from app.core.changes_v2 import FeedNotApplied
from app.core import feed_migrator
from app.core.database import create_tables, AsyncSessionLocal
from app.core.models import Company
from sqlalchemy import select

# تطبيق FastAPI الرئيسي وإعداد الـCORS
app = FastAPI(title="IslamApp V1.0 API")
app.middleware("http")(authenticate_http_request)

# ========== إعدادات CORS ==========
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ========== دالة إنشاء الشركة الافتراضية ==========
# ينشئ الشركة الافتراضية لو مش موجودة
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
# حدث بدء التشغيل: ينشئ الجداول والشركة الافتراضية ويطبّق الفيدات لو ناقصة
@app.on_event("startup")
async def startup():
    await create_tables()
    await create_default_company()
    print("✅ تم التحقق من الجداول والشركة الافتراضية في قاعدة البيانات (PostgreSQL)")
    applied = await feed_migrator.applied_feed_count()
    if applied >= feed_migrator.EXPECTED_FEEDS:
        print(f"✅ v2 feed migrations already applied ({applied}/{feed_migrator.EXPECTED_FEEDS})")
    else:
        print(f"ℹ️ v2 feed migrations pending ({max(applied, 0)}/{feed_migrator.EXPECTED_FEEDS}); "
              "applying in background, old sync keeps working")
        asyncio.create_task(feed_migrator.run_background())


# معالج خطأ الفيد غير المطبّق: يرد بدل 500 ويخلّي التطبيق يرجع للتزامن القديم
@app.exception_handler(FeedNotApplied)
async def feed_not_applied_handler(request, exc):
    # The v2 feed migration is missing or failed on this database: never a 500.
    # cursor=latest gets a non-200 so the app captures nothing and stays on the old sync;
    # paged requests get a clean "disabled" so the client clears its cursor and falls back
    # to a full sync in place.
    if request.query_params.get("cursor") == "latest":
        return JSONResponse({"detail": "v2 feed disabled"}, status_code=503)
    return JSONResponse({
        "invalid": True,
        "reason": "disabled",
        "items": [],
        "has_more": False,
        "next_cursor": request.query_params.get("cursor", ""),
        "scope": "",
    })


# ========== ربط المسارات (Routes) ==========
# ربط كل مجموعات المسارات (routes) بالتطبيق
app.include_router(auth.router, prefix="/auth", tags=["Authentication"])
app.include_router(transactions.router, prefix="/transactions", tags=["Transactions"])
app.include_router(coding.router, prefix="/coding", tags=["Coding"])
app.include_router(employees.router, prefix="/employees", tags=["Employees"])
app.include_router(inventory.router, prefix="/inventory", tags=["Inventory"])
app.include_router(supplier.router, prefix="/supplier", tags=["Supplier"])
app.include_router(sync.router, prefix="/sync", tags=["Sync"])
app.include_router(notifications.router, prefix="/notifications", tags=["Notifications"])
app.include_router(product_lookup.router, prefix="/products", tags=["Product Lookup"])
app.include_router(
    supplier_settlement.router,
    prefix="/supplier-settlement",
    tags=["Supplier Settlement"],
)

# ✅ HR Routes
# ✅ HR Routes (موحدة)
app.include_router(hr.router, prefix="/hr", tags=["HR"])
# ⭐ ترتيب مهم: راوتر التحويلات قبل التجاري حتى تصل /commercial/transfers/* للوحدة الجديدة
app.include_router(transfers.router, prefix="/commercial", tags=["Stock Transfers"])
app.include_router(commercial.router, prefix="/commercial", tags=["Sales, Returns and Customer Payments"])


# مسار الصفحة الرئيسية لفحص إن السيرفر شغال
@app.get("/")
async def root():
    return {
        "message": "Welcome to IslamApp V1.0 API - Server is Running",
        "status": "online",
        "database": "PostgreSQL (Neon)",
        "sync": "WebSocket enabled"
    }


# ربط مسارات تحويلات الخزائن
app.include_router(treasury_transfers.router, prefix="/treasury-transfers", tags=["Treasury Transfers"])
