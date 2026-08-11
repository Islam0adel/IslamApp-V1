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
import logging

router = APIRouter()
logger = logging.getLogger(__name__)

# ==========================================
# 1. حفظ حركة المورد (إضافة أو تحديث)
# ==========================================
@router.post("/save")
async def save_supplier_transaction(
    data: SupplierTransactionModel,
    db: AsyncSession = Depends(get_db)
):
    try:
        # ✅ التحقق من doc_id وتحويله إلى int
        doc_id_int = None
        if data.doc_id:
            try:
                doc_id_int = int(data.doc_id)
            except (ValueError, TypeError) as e:
                raise HTTPException(status_code=400, detail=f"doc_id غير صالح: {data.doc_id}")

        # ✅ تحويل الأصناف إلى JSON
        try:
            items_json = [item.dict() for item in data.items]
        except Exception as e:
            logger.error(f"خطأ في تحويل items إلى JSON: {e}")
            raise HTTPException(status_code=400, detail="بيانات الأصناف غير صالحة")

        # ✅ البحث عن السجل إذا كان doc_id موجوداً
        if doc_id_int:
            stmt = select(SupplierRecord).where(SupplierRecord.id == doc_id_int)
            result = await db.execute(stmt)
            existing = result.scalar_one_or_none()
            if not existing:
                raise HTTPException(status_code=404, detail=f"السجل غير موجود (id={doc_id_int})")
        else:
            existing = None

        # ✅ إنشاء السجل أو تحديثه
        if existing:
            # تحديث
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
            record = existing
        else:
            # إضافة جديدة
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
            record = new_record

        # ✅ حفظ التغييرات في قاعدة البيانات
        try:
            await db.commit()
            await db.refresh(record)
        except Exception as e:
            await db.rollback()
            logger.error(f"خطأ في حفظ قاعدة البيانات: {e}")
            raise HTTPException(status_code=500, detail=f"فشل حفظ البيانات: {str(e)}")

        record_id = str(record.id)

        # 🔄 بث التغيير عبر WebSocket
        try:
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
        except Exception as e:
            logger.warning(f"فشل بث WebSocket: {e}")

        return {"status": "success", "doc_id": record_id}

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        logger.error(f"خطأ غير متوقع في save_supplier_transaction: {e}", exc_info=True)
        # ✅ إرجاع تفاصيل الخطأ للمطور (مع إخفاء التفاصيل الحساسة في الإنتاج)
        raise HTTPException(status_code=500, detail=f"خطأ داخلي: {str(e)}")


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
        logger.error(f"خطأ في list_supplier_transactions: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 4. جلب التحديثات التزايدية للموردين
# ==========================================
@router.get("/changes/{company_code}")
async def get_supplier_changes(
    company_code: str,
    since: str = Query(..., description="وقت آخر مزامنة بصيغة ISO 8601"),
    db: AsyncSession = Depends(get_db)
):
    try:
        since_dt = datetime.datetime.fromisoformat(since)
        
        stmt = select(SupplierRecord).where(
            SupplierRecord.company_code == company_code,
            SupplierRecord.updated_at >= since_dt
        ).order_by(SupplierRecord.updated_at)
        
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
        
    except ValueError:
        raise HTTPException(status_code=400, detail="صيغة `since` غير صحيحة، استخدم ISO 8601")
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
        # تحويل doc_id إلى int
        try:
            doc_id_int = int(doc_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="doc_id غير صالح (يجب أن يكون رقماً)")

        stmt = select(SupplierRecord).where(SupplierRecord.id == doc_id_int)
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if not existing:
            raise HTTPException(status_code=404, detail="Supplier record not found")

        # حفظ البيانات قبل الحذف
        deleted_data = {
            "doc_id": str(existing.id),
            "company_code": existing.company_code,
            "branch_code": existing.branch_code,
            "store_code": existing.store_code,
            "serial": existing.serial,
            "date": existing.date,
            "supplier_name": existing.supplier_name,
            "payment_method": existing.payment_method,
            "treasury": existing.treasury,
            "is_add_to_store": existing.is_add_to_store,
            "employee": existing.employee,
            "items": existing.items,
            "total_amount": existing.total_amount,
            "paid_amount": existing.paid_amount,
            "updated_at": existing.updated_at.isoformat() if existing.updated_at else None,
        }

        await db.delete(existing)
        await db.commit()

        # بث الحذف
        await manager.broadcast(company_code, {
            "type": "supplier",
            "action": "delete",
            "data": deleted_data
        })

        return {"status": "success"}

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        logger.error(f"خطأ في delete_supplier_transaction: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))