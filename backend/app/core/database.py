
import os
from dotenv import load_dotenv
from pathlib import Path
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy.pool import NullPool
import re

BASE_DIR = Path(__file__).resolve().parent.parent.parent
ENV_PATH = BASE_DIR / "D:\IslamApp-V1\.env"
load_dotenv(dotenv_path=ENV_PATH)

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("❌ DATABASE_URL environment variable is not set!")

# ✅ تنظيف الرابط: إزالة أي معاملات بعد علامة الاستفهام (?) أو (&)
# نقسم الرابط على '?' ونأخذ الجزء الأول فقط (قبل المعاملات)
clean_url = DATABASE_URL.split('?')[0]

# إذا كان هناك معاملات أخرى بعد علامة & (نادرة لكن للاحتياط)
# نضمن أن clean_url لا يحتوي على '?'
print(f"🔗 Original URL: {DATABASE_URL[:50]}...")
print(f"🔗 Clean URL: {clean_url[:50]}...")

engine = create_async_engine(
    clean_url,   # ✅ استخدم الرابط النظيف
    echo=True,
    future=True,
    pool_pre_ping=True,
    pool_recycle=300,
    poolclass=NullPool,
    connect_args={"ssl": True}  # ✅ تفعيل SSL بشكل آمن
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