import os
from dotenv import load_dotenv
from pathlib import Path
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy.pool import AsyncAdaptedQueuePool
from sqlalchemy import text

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
    pool_pre_ping=True,
    pool_recycle=300,
    poolclass=AsyncAdaptedQueuePool,
    pool_size=5,
    max_overflow=10,
    connect_args={
        "ssl": True,
        "server_settings": {"application_name": "myapp"}
    }
)

AsyncSessionLocal = async_sessionmaker(
    engine,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)

Base = declarative_base()

async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()

async def create_tables():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Additive compatibility for installations where the commercial tables
        # were created by an earlier local build.
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS credit_amount FLOAT NOT NULL DEFAULT 0.0"))
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS refund_amount FLOAT NOT NULL DEFAULT 0.0"))
        await conn.execute(text("ALTER TABLE sale_returns ADD COLUMN IF NOT EXISTS settlement_mode VARCHAR(30) NOT NULL DEFAULT 'credit_first'"))
        await conn.execute(text("ALTER TABLE coding_records ADD COLUMN IF NOT EXISTS branch_code VARCHAR(50) NULL"))
        await conn.execute(text("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS link_id VARCHAR(100) NULL"))
        await conn.execute(text("ALTER TABLE transactions ADD COLUMN IF NOT EXISTS supplier_name VARCHAR(255) NULL"))
        await conn.execute(text("ALTER TABLE supplier_settlements ADD COLUMN IF NOT EXISTS link_id VARCHAR(100) NULL"))
        print("✅ تم إنشاء الجداول في قاعدة البيانات بنجاح (أو تأكيد وجودها)")
