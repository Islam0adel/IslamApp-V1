from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc
from app.core.database import get_db
from app.core.models import SupplierRecord
from app.core.schemas import SupplierTransactionModel
from app.core.sync import manager
from typing import Optional
import datetime
import json

router = APIRouter()

# ==========================================
# 1. حفظ حركة المورد
# ==========================================
@router.post("/save")
async def save_supplier_transaction(
    data: SupplierTransactionModel,
    db: AsyncSession = Depends(get_db)
):
    try:
        doc_id = data.doc_id or f"{data.company_code}_{data.branch_code}_{data.serial}_{datetime.datetime.now().timestamp()}"

        items_json = [item.dict() for item in data.items]

        # البحث عن سجل موجود
        if data.doc_id:
            stmt = select(SupplierRecord).where(SupplierRecord.id == data.doc_id)
            result = await db.execute(stmt)
            existing = result.scalar_one_or_none()
        else:
            existing = None

        if existing:
            existing.branch_code = data.branch_code
            existing.store_code = data.store_code
            existing.serial = data.serial
            existing.date = data.date
            existing.supplier_name = data.supplier_name
            existing.payment_method = data.payment_method
            existing.treasury = data.treasury
            existing.is_add_to_store = data.is_add_to_store
            existing.employee = data.employee
            existing.items = items_json
            existing.total_amount = data.total_amount
            existing.paid_amount = data.paid_amount
            existing.updated_at = datetime.datetime.utcnow()
            action = "update"
        else:
            new_record = SupplierRecord(
                company_code=data.company_code,
                branch_code=data.branch_code,
                store_code=data.store_code,
                serial=data.serial,
                date=data.date,
                supplier_name=data.supplier_name,
                payment_method=data.payment_method,
                treasury=data.treasury,
                is_add_to_store=data.is_add_to_store,
                employee=data.employee,
                items=items_json,
                total_amount=data.total_amount,
                paid_amount=data.paid_amount,
            )
            db.add(new_record)
            action = "insert"

        await db.commit()
        await db.refresh(new_record if not existing else existing)

        record = existing or new_record
        record_id = str(record.id)

        # بث التغيير
        await manager.broadcast(data.company_code, {
            "type": "supplier",
            "action": action,
            "data": {
                "doc_id": record_id,
                "company_code": record.company_code,
                "branch_code": record.branch_code,
                "store_code": record.store_code,
                "serial": record.serial,
                "date": record.date,
                "supplier_name": record.supplier_name,
                "payment_method": record.payment_method,
                "treasury": record.treasury,
                "is_add_to_store": record.is_add_to_store,
                "employee": record.employee,
                "items": record.items,
                "total_amount": record.total_amount,
                "paid_amount": record.paid_amount,
                "updated_at": record.updated_at.isoformat() if record.updated_at else None,
            }
        })

        return {"status": "success", "doc_id": record_id}

    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 2. جلب قائمة حركات الموردين
# ==========================================
@router.get("/list/{company_code}")
async def list_supplier_transactions(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    supplier_name: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None),
    end_date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(SupplierRecord).where(SupplierRecord.company_code == company_code)
        if branch_code:
            stmt = stmt.where(SupplierRecord.branch_code == branch_code)
        if supplier_name:
            stmt = stmt.where(SupplierRecord.supplier_name == supplier_name)
        if start_date:
            stmt = stmt.where(SupplierRecord.date >= start_date)
        if end_date:
            stmt = stmt.where(SupplierRecord.date <= end_date)

        stmt = stmt.order_by(desc(SupplierRecord.date), desc(SupplierRecord.serial))
        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = []
        for doc in docs:
            results.append({
                "doc_id": str(doc.id),
                "company_code": doc.company_code,
                "branch_code": doc.branch_code,
                "store_code": doc.store_code,
                "serial": doc.serial,
                "date": doc.date,
                "supplier_name": doc.supplier_name,
                "payment_method": doc.payment_method,
                "treasury": doc.treasury,
                "is_add_to_store": doc.is_add_to_store,
                "employee": doc.employee,
                "items": doc.items,
                "total_amount": doc.total_amount,
                "paid_amount": doc.paid_amount,
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 3. حذف حركة مورد
# ==========================================
@router.delete("/delete/{company_code}/{doc_id}")
async def delete_supplier_transaction(
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(SupplierRecord).where(SupplierRecord.id == int(doc_id))
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if not existing:
            raise HTTPException(status_code=404, detail="Supplier record not found")

        await db.delete(existing)
        await db.commit()

        await manager.broadcast(company_code, {
            "type": "supplier",
            "action": "delete",
            "data": {"doc_id": doc_id}
        })

        return {"status": "success"}

    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))