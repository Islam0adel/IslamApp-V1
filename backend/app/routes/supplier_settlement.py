from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.core.database import get_db
from app.core.models import SupplierSettlementRecord
from app.core.schemas import SupplierSettlementModel
from app.core.sync import manager

from typing import Optional
import datetime
import logging


router = APIRouter()
logger = logging.getLogger(__name__)


# ============================================================
# Helper
# ============================================================

def serialize_settlement(
    doc: SupplierSettlementRecord,
    action: str | None = None,
):
    data = {
        "doc_id": str(doc.id),
        "company_code": doc.company_code,
        "branch_code": doc.branch_code,
        "serial": doc.serial,
        "date": doc.date,
        "supplier_name": doc.supplier_name,
        "payment_method": doc.payment_method,
        "treasury": doc.treasury,
        "amount": doc.amount,
        "statement": doc.statement,
        "employee": doc.employee,
        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if action is not None:
        data["action"] = action

    return data


# ============================================================
# 1. حفظ / تعديل تسوية
# ============================================================

@router.post("/save")
async def save_settlement(
    data: SupplierSettlementModel,
    db: AsyncSession = Depends(get_db),
):
    try:
        doc_id_int = None

        # ------------------------------------------------------
        # doc_id
        # ------------------------------------------------------

        if data.doc_id:
            try:
                doc_id_int = int(data.doc_id)
            except (ValueError, TypeError):
                raise HTTPException(
                    status_code=400,
                    detail="doc_id غير صالح",
                )

        # ------------------------------------------------------
        # التحقق من المبلغ
        # ------------------------------------------------------

        if data.amount <= 0:
            raise HTTPException(
                status_code=400,
                detail="مبلغ التسوية يجب أن يكون أكبر من صفر",
            )

        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        existing = None

        if doc_id_int:
            stmt = (
                select(SupplierSettlementRecord)
                .where(
                    SupplierSettlementRecord.id == doc_id_int,
                    SupplierSettlementRecord.company_code
                    == data.company_code,
                )
            )

            result = await db.execute(stmt)
            existing = result.scalar_one_or_none()

            if not existing:
                raise HTTPException(
                    status_code=404,
                    detail="التسوية غير موجودة",
                )

        # ------------------------------------------------------
        # UPDATE
        # ------------------------------------------------------

        if existing:
            existing.branch_code = data.branch_code
            existing.serial = data.serial
            existing.date = data.date
            existing.supplier_name = data.supplier_name
            existing.payment_method = data.payment_method
            existing.treasury = data.treasury
            existing.amount = data.amount
            existing.statement = data.statement
            existing.employee = data.employee

            existing.updated_at = datetime.datetime.utcnow()

            was_deleted = bool(existing.is_deleted)

            existing.is_deleted = False

            action = (
                "insert"
                if was_deleted
                else "update"
            )

            record = existing

        # ------------------------------------------------------
        # INSERT
        # ------------------------------------------------------

        else:
            record = SupplierSettlementRecord(
                company_code=data.company_code,
                branch_code=data.branch_code,
                serial=data.serial,
                date=data.date,
                supplier_name=data.supplier_name,
                payment_method=data.payment_method,
                treasury=data.treasury,
                amount=data.amount,
                statement=data.statement,
                employee=data.employee,
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )

            db.add(record)
            action = "insert"

        # ------------------------------------------------------
        # Commit
        # ------------------------------------------------------

        try:
            await db.commit()
            await db.refresh(record)

        except Exception as e:
            await db.rollback()

            logger.error(
                f"خطأ في حفظ التسوية: {e}",
                exc_info=True,
            )

            raise HTTPException(
                status_code=500,
                detail=f"فشل حفظ التسوية: {str(e)}",
            )

        # ------------------------------------------------------
        # WebSocket Broadcast
        # ------------------------------------------------------

        try:
            await manager.broadcast(
                data.company_code,
                {
                    "type": "settlement",
                    "action": action,
                    "data": serialize_settlement(
                        record,
                        action=action,
                    ),
                },
            )

        except Exception as e:
            logger.warning(
                f"فشل بث تسوية المورد: {e}"
            )

        # ------------------------------------------------------
        # Response
        # ------------------------------------------------------

        return {
            "status": "success",
            "doc_id": str(record.id),
            "serial": record.serial,
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            f"خطأ غير متوقع في save_settlement: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 2. جلب التسويات
# ============================================================

@router.get("/list/{company_code}")
async def list_settlements(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    supplier_name: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None),
    end_date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(SupplierSettlementRecord)
            .where(
                SupplierSettlementRecord.company_code
                == company_code,
                SupplierSettlementRecord.is_deleted.is_(False),
            )
        )

        if branch_code:
            stmt = stmt.where(
                SupplierSettlementRecord.branch_code
                == branch_code
            )

        if supplier_name:
            stmt = stmt.where(
                SupplierSettlementRecord.supplier_name
                == supplier_name
            )

        if start_date:
            stmt = stmt.where(
                SupplierSettlementRecord.date
                >= start_date
            )

        if end_date:
            stmt = stmt.where(
                SupplierSettlementRecord.date
                <= end_date
            )

        stmt = stmt.order_by(
            desc(SupplierSettlementRecord.date),
            desc(SupplierSettlementRecord.serial),
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        return [
            serialize_settlement(doc)
            for doc in docs
        ]

    except Exception as e:
        logger.error(
            f"خطأ في list_settlements: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 3. المزامنة التزايدية
# ============================================================

@router.get("/changes/{company_code}")
async def get_settlement_changes(
    company_code: str,
    since: str = Query(...),
    db: AsyncSession = Depends(get_db),
):
    try:
        since_dt = datetime.datetime.fromisoformat(
            since.replace("Z", "+00:00")
        )

        if since_dt.tzinfo is not None:
            since_dt = since_dt.astimezone(
                datetime.timezone.utc
            )

            since_dt = since_dt.replace(
                tzinfo=None
            )

        stmt = (
            select(SupplierSettlementRecord)
            .where(
                SupplierSettlementRecord.company_code
                == company_code,
                SupplierSettlementRecord.updated_at
                >= since_dt,
            )
            .order_by(
                SupplierSettlementRecord.updated_at
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        for doc in docs:
            action = (
                "delete"
                if doc.is_deleted
                else "update"
            )

            results.append(
                serialize_settlement(
                    doc,
                    action=action,
                )
            )

        return results

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="صيغة since غير صحيحة، استخدم ISO 8601",
        )

    except Exception as e:
        logger.error(
            f"خطأ في settlement changes: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 4. حذف تسوية
# ============================================================

@router.delete("/delete/{company_code}/{doc_id}")
async def delete_settlement(
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db),
):
    try:
        try:
            doc_id_int = int(doc_id)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail="doc_id غير صالح",
            )

        stmt = (
            select(SupplierSettlementRecord)
            .where(
                SupplierSettlementRecord.id == doc_id_int,
                SupplierSettlementRecord.company_code
                == company_code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="التسوية غير موجودة",
            )

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "التسوية محذوفة بالفعل",
                "doc_id": str(existing.id),
            }

        existing.is_deleted = True
        existing.updated_at = datetime.datetime.utcnow()

        await db.commit()
        await db.refresh(existing)

        # ------------------------------------------------------
        # WebSocket
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "settlement",
                "action": "delete",
                "data": serialize_settlement(
                    existing,
                    action="delete",
                ),
            },
        )

        return {
            "status": "success",
            "doc_id": str(existing.id),
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            f"خطأ في delete_settlement: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )