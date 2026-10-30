import os
from dotenv import load_dotenv
from pathlib import Path
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy.pool import NullPool

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
    echo=True,
    future=True,
    pool_pre_ping=True,
    pool_recycle=300,
    poolclass=NullPool,
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
        print("✅ تم إنشاء الجداول في قاعدة البيانات بنجاح (أو تأكيد وجودها)")