# backend/app/core/database.py
import os
from dotenv import load_dotenv
from pathlib import Path
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy.pool import AsyncAdaptedQueuePool
from sqlalchemy import text
from app.core.pool_health import install_asyncpg_pool_health_check

# إعداد الاتصال بقاعدة البيانات: مسار .env ورابط الاتصال وإنشاء الـengine
BASE_DIR = Path(__file__).resolve().parent.parent.parent
ENV_PATH = Path(r"D:\IslamApp-V1\.env")
load_dotenv(dotenv_path=ENV_PATH)

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("❌ DATABASE_URL environment variable is not set!")

# ✅ تنظيف الرابط من المعاملات الإضافية
clean_url = DATABASE_URL.split('?')[0]

# ✅ تحويل البروتوكول إلى asyncpg إذا لزم الأمر
if clean_url.startswith("postgresql://"):
    clean_url = clean_url.replace("postgresql://", "postgresql+asyncpg://", 1)

# print(f"🔗 Original URL: {DATABASE_URL[:80]}...")
# print(f"🔗 Clean URL: {clean_url[:80]}...")

engine = create_async_engine(
    clean_url,
    echo=False,
    future=True,
    # Equivalent checkout liveness, one simple-query round trip instead of
    # asyncpg dialect pre-ping's transaction + query + rollback round trips.
    pool_pre_ping=False,
    pool_recycle=300,
    poolclass=AsyncAdaptedQueuePool,
    pool_size=5,
    max_overflow=10,
    connect_args={
        "ssl": True,
        "server_settings": {"application_name": "myapp"}
    }
)

install_asyncpg_pool_health_check(engine)

AsyncSessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)

Base = declarative_base()


# يفتح جلسة قاعدة بيانات لكل طلب ويقفلها بعده
async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()


# ينشئ الجداول ويضيف الأعمدة الناقصة عند بدء التشغيل
async def create_tables():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Preserve existing companies as legacy. The create-company route
        # explicitly marks new rows for review; migration grants nothing.
        await conn.execute(text("ALTER TABLE companies ADD COLUMN IF NOT EXISTS requires_permission_review BOOLEAN NOT NULL DEFAULT FALSE"))
        await conn.execute(text("ALTER TABLE company_permission_policies ADD COLUMN IF NOT EXISTS draft_base_active_revision INTEGER NULL"))
        # Additive compatibility for installations where the commercial tables
        # were created by an earlier local build.
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS credit_amount FLOAT NOT NULL DEFAULT 0.0"))
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS refund_amount FLOAT NOT NULL DEFAULT 0.0"))
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS settlement_mode VARCHAR(30) NOT NULL DEFAULT 'credit_first'"))
        await conn.execute(text("ALTER TABLE coding_records ADD COLUMN IF NOT EXISTS branch_code VARCHAR(50) NULL"))
        # عمود قبل الكود: يُضاف عند إقلاع النسخة الجديدة قبل خدمة
        # أي طلب، والصفوف التاريخية تُقرأ "صريحة" (FALSE) بما فيها
        # الأصفار القديمة — لا تعبئة رجعية ولا تخمين.
        await conn.execute(text("ALTER TABLE coding_records ADD COLUMN IF NOT EXISTS cost_pending BOOLEAN NOT NULL DEFAULT FALSE"))
        await conn.execute(text("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS link_id VARCHAR(100) NULL"))
        await conn.execute(text("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS supplier_name VARCHAR(255) NULL"))
        await conn.execute(text("ALTER TABLE supplier_settlements ADD COLUMN IF NOT EXISTS link_id VARCHAR(100) NULL"))
        print("✅ تم إنشاء الجداول في قاعدة البيانات بنجاح (أو تأكيد وجودها)")
