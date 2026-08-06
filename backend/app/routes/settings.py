from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.core.database import get_db
from app.core.models import CodingRecord
from pydantic import BaseModel
from typing import List
import datetime

router = APIRouter()

class CodingItem(BaseModel):
    category: str
    code: str
    name: str
    company_code: str

# ==========================================
# 1. إضافة تكويد (مستخدم في الإعدادات)
# ==========================================
@router.post("/add-code")
async def add_coding_item(
    item: CodingItem,
    db: AsyncSession = Depends(get_db)
):
    try:
        # التحقق من عدم وجود تكويد مكرر
        stmt = select(CodingRecord).where(
            CodingRecord.company_code == item.company_code,
            CodingRecord.category == item.category,
            CodingRecord.code == item.code
        )
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if existing:
            raise HTTPException(status_code=400, detail="هذا الكود موجود بالفعل في هذا القسم")

        # إضافة سجل جديد
        new_record = CodingRecord(
            company_code=item.company_code,
            category=item.category,
            code=item.code,
            name=item.name,
            type="",  # قد يكون فارغاً أو يمكن تعيين قيمة افتراضية
            barcode="",
            wholesale_price=0.0,
            selling_price=0.0,
            profit_margin=0.0,
            profit_percent=0.0,
        )
        db.add(new_record)
        await db.commit()

        return {"status": "success", "message": f"تم إضافة {item.name} بنجاح"}

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 2. جلب قائمة التكويدات (مستخدم في الإعدادات)
# ==========================================
@router.get("/get-codes/{company_code}/{category}")
async def get_coding_items(
    company_code: str,
    category: str,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(CodingRecord).where(
            CodingRecord.company_code == company_code,
            CodingRecord.category == category
        ).order_by(CodingRecord.code)
        result = await db.execute(stmt)
        docs = result.scalars().all()

        items = [{"code": doc.code, "name": doc.name} for doc in docs]
        return items

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))