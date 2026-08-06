from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc
from app.core.database import get_db
from app.core.models import InventoryRecord
from app.core.schemas import InventoryModel
from app.core.sync import manager
from typing import Optional
import datetime
import json

router = APIRouter()

# ==========================================
# 1. حفظ الجرد
# ==========================================
@router.post("/save")
async def save_inventory(
    data: InventoryModel,
    db: AsyncSession = Depends(get_db)
):
    try:
        doc_id = data.doc_id or f"{data.company_code}_{data.branch_code}_{data.store_code}_{data.date}_{datetime.datetime.now().timestamp()}"

        # تحويل الأصناف إلى JSON
        items_json = [item.dict() for item in data.items]

        # البحث عن سجل موجود
        if data.doc_id:
            stmt = select(InventoryRecord).where(InventoryRecord.id == data.doc_id)
            result = await db.execute(stmt)
            existing = result.scalar_one_or_none()
        else:
            existing = None

        if existing:
            # تحديث
            existing.branch_code = data.branch_code
            existing.store_code = data.store_code
            existing.date = data.date
            existing.inventory_type = data.inventory_type
            existing.items = items_json
            existing.total_wholesale = data.total_wholesale
            existing.total_retail = data.total_retail
            existing.serial = data.serial
            existing.updated_at = datetime.datetime.utcnow()
            action = "update"
        else:
            # إضافة جديدة
            new_record = InventoryRecord(
                company_code=data.company_code,
                branch_code=data.branch_code,
                store_code=data.store_code,
                date=data.date,
                inventory_type=data.inventory_type,
                items=items_json,
                total_wholesale=data.total_wholesale,
                total_retail=data.total_retail,
                serial=data.serial,
            )
            db.add(new_record)
            action = "insert"

        await db.commit()
        await db.refresh(new_record if not existing else existing)

        record = existing or new_record
        record_id = str(record.id)

        # بث التغيير
        await manager.broadcast(data.company_code, {
            "type": "inventory",
            "action": action,
            "data": {
                "doc_id": record_id,
                "company_code": record.company_code,
                "branch_code": record.branch_code,
                "store_code": record.store_code,
                "date": record.date,
                "inventory_type": record.inventory_type,
                "items": record.items,
                "total_wholesale": record.total_wholesale,
                "total_retail": record.total_retail,
                "serial": record.serial,
                "updated_at": record.updated_at.isoformat() if record.updated_at else None,
            }
        })

        return {"status": "success", "doc_id": record_id}

    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 2. جلب قائمة الجردات
# ==========================================
@router.get("/list/{company_code}")
async def list_inventory(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    store_code: Optional[str] = Query(None),
    date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(InventoryRecord).where(InventoryRecord.company_code == company_code)
        if branch_code:
            stmt = stmt.where(InventoryRecord.branch_code == branch_code)
        if store_code:
            stmt = stmt.where(InventoryRecord.store_code == store_code)
        if date:
            stmt = stmt.where(InventoryRecord.date == date)

        stmt = stmt.order_by(desc(InventoryRecord.date), desc(InventoryRecord.serial))
        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = []
        for doc in docs:
            results.append({
                "doc_id": str(doc.id),
                "company_code": doc.company_code,
                "branch_code": doc.branch_code,
                "store_code": doc.store_code,
                "date": doc.date,
                "inventory_type": doc.inventory_type,
                "items": doc.items,
                "total_wholesale": doc.total_wholesale,
                "total_retail": doc.total_retail,
                "serial": doc.serial,
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 3. حذف جرد
# ==========================================
@router.delete("/delete/{company_code}/{doc_id}")
async def delete_inventory(
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(InventoryRecord).where(InventoryRecord.id == int(doc_id))
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if not existing:
            raise HTTPException(status_code=404, detail="Inventory record not found")

        await db.delete(existing)
        await db.commit()

        await manager.broadcast(company_code, {
            "type": "inventory",
            "action": "delete",
            "data": {"doc_id": doc_id}
        })

        return {"status": "success"}

    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))