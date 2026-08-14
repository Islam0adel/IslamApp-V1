# backend/app/routes/inventory.py

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.core.database import get_db
from app.core.models import InventoryRecord
from app.core.schemas import InventoryModel
from app.core.sync import manager

from typing import Optional
import datetime
import logging


router = APIRouter()

logger = logging.getLogger(__name__)


# ============================================================
# Helper
# ============================================================

def serialize_inventory(
    doc: InventoryRecord,
    action: str | None = None,
):
    data = {
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
# 1. حفظ الجرد
#    إضافة أو تحديث
# ============================================================

@router.post("/save")
async def save_inventory(
    data: InventoryModel,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # تحويل doc_id إلى int إذا وجد
        # ------------------------------------------------------

        doc_id_int = None

        if data.doc_id:
            try:
                doc_id_int = int(data.doc_id)
            except (ValueError, TypeError):
                raise HTTPException(
                    status_code=400,
                    detail="doc_id غير صالح (يجب أن يكون رقماً)",
                )

        # ------------------------------------------------------
        # تحويل الأصناف إلى JSON
        # ------------------------------------------------------

        items_json = [
            item.model_dump()
            if hasattr(item, "model_dump")
            else item.dict()
            for item in data.items
        ]

        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        if doc_id_int:
            stmt = (
                select(InventoryRecord)
                .where(
                    InventoryRecord.id
                    == doc_id_int
                )
            )

            result = await db.execute(stmt)

            existing = result.scalar_one_or_none()

            if not existing:
                raise HTTPException(
                    status_code=404,
                    detail=(
                        f"السجل غير موجود "
                        f"(id={doc_id_int})"
                    ),
                )
        else:
            existing = None

        # ------------------------------------------------------
        # تحديث سجل موجود
        # ------------------------------------------------------

        if existing:
            existing.branch_code = data.branch_code
            existing.store_code = data.store_code
            existing.date = data.date
            existing.inventory_type = data.inventory_type
            existing.items = items_json
            existing.total_wholesale = data.total_wholesale
            existing.total_retail = data.total_retail
            existing.serial = data.serial

            existing.updated_at = (
                datetime.datetime.utcnow()
            )

            # لو كان محذوفًا ثم تم حفظه مرة أخرى
            was_deleted = bool(
                existing.is_deleted
            )

            existing.is_deleted = False

            action = (
                "insert"
                if was_deleted
                else "update"
            )

            record = existing

        # ------------------------------------------------------
        # إضافة جديدة
        # ------------------------------------------------------

        else:
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
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )

            db.add(new_record)

            action = "insert"

            record = new_record

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        await db.commit()

        await db.refresh(record)

        record_id = str(record.id)

        # ------------------------------------------------------
        # WebSocket
        # ------------------------------------------------------

        await manager.broadcast(
            data.company_code,
            {
                "type": "inventory",
                "action": action,
                "data": serialize_inventory(
                    record,
                    action=action,
                ),
            },
        )

        # ------------------------------------------------------
        # Response
        # ------------------------------------------------------

        return {
            "status": "success",
            "doc_id": record_id,
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            f"خطأ في حفظ الجرد: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=f"خطأ داخلي: {str(e)}",
        )


# ============================================================
# 2. جلب قائمة الجردات
#
# المحذوف لا يظهر
# ============================================================

@router.get("/list/{company_code}")
async def list_inventory(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    store_code: Optional[str] = Query(None),
    date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(InventoryRecord)
            .where(
                InventoryRecord.company_code
                == company_code,

                InventoryRecord.is_deleted.is_(False),
            )
        )

        if branch_code:
            stmt = stmt.where(
                InventoryRecord.branch_code
                == branch_code
            )

        if store_code:
            stmt = stmt.where(
                InventoryRecord.store_code
                == store_code
            )

        if date:
            stmt = stmt.where(
                InventoryRecord.date
                == date
            )

        stmt = stmt.order_by(
            desc(InventoryRecord.date),
            desc(InventoryRecord.serial),
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = [
            serialize_inventory(doc)
            for doc in docs
        ]

        return results

    except Exception as e:
        logger.error(
            f"خطأ في list_inventory: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 3. جلب التحديثات التزايدية للجرد
#
# مهم:
# لا نستبعد المحذوف.
#
# الجهاز Offline لازم يعرف أن السجل اتحذف.
# ============================================================

@router.get("/changes/{company_code}")
async def get_inventory_changes(
    company_code: str,
    since: str = Query(
        ...,
        description=(
            "وقت آخر مزامنة بصيغة ISO 8601 "
            "مثال: 2026-08-11T14:30:00Z"
        ),
    ),
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # 1) تحويل since
        # ------------------------------------------------------

        since_dt = (
            datetime.datetime.fromisoformat(
                since.replace(
                    "Z",
                    "+00:00",
                )
            )
        )

        # ------------------------------------------------------
        # 2) توحيد التوقيت إلى UTC
        #
        # لأن updated_at:
        # TIMESTAMP WITHOUT TIME ZONE
        # ------------------------------------------------------

        if since_dt.tzinfo is not None:
            since_dt = since_dt.astimezone(
                datetime.timezone.utc
            )

            since_dt = since_dt.replace(
                tzinfo=None
            )

        # ------------------------------------------------------
        # 3) جلب كل التغييرات
        #
        # بما فيها المحذوف.
        # ------------------------------------------------------

        stmt = (
            select(InventoryRecord)
            .where(
                InventoryRecord.company_code
                == company_code,

                InventoryRecord.updated_at
                >= since_dt,
            )
            .order_by(
                InventoryRecord.updated_at
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        for doc in docs:
            # --------------------------------------------------
            # تحديد نوع التغيير
            # --------------------------------------------------

            if doc.is_deleted:
                action = "delete"
            else:
                action = "update"

            results.append(
                serialize_inventory(
                    doc,
                    action=action,
                )
            )

        return results

    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=(
                "صيغة `since` غير صحيحة، "
                "استخدم ISO 8601"
            ),
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 4. حذف جرد - Soft Delete
# ============================================================

@router.delete(
    "/delete/{company_code}/{doc_id}"
)
async def delete_inventory(
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # تحويل doc_id إلى int
        # ------------------------------------------------------

        try:
            doc_id_int = int(doc_id)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail=(
                    "doc_id غير صالح "
                    "(يجب أن يكون رقماً)"
                ),
            )

        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        stmt = (
            select(InventoryRecord)
            .where(
                InventoryRecord.id
                == doc_id_int,

                InventoryRecord.company_code
                == company_code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="Inventory record not found",
            )

        # ------------------------------------------------------
        # لو محذوف بالفعل
        # ------------------------------------------------------

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "الجرد محذوف بالفعل",
                "doc_id": str(existing.id),
            }

        # ------------------------------------------------------
        # Soft Delete
        # ------------------------------------------------------

        existing.is_deleted = True

        existing.updated_at = (
            datetime.datetime.utcnow()
        )

        await db.commit()

        await db.refresh(existing)

        # ------------------------------------------------------
        # إرسال الحذف للأجهزة المتصلة
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "inventory",
                "action": "delete",
                "data": {
                    "doc_id": str(existing.id),
                    "company_code":
                        existing.company_code,
                    "branch_code":
                        existing.branch_code,
                    "store_code":
                        existing.store_code,
                    "date":
                        existing.date,
                    "inventory_type":
                        existing.inventory_type,
                    "serial":
                        existing.serial,
                    "updated_at": (
                        existing.updated_at.isoformat()
                        if existing.updated_at
                        else None
                    ),
                    "is_deleted": True,
                },
            },
        )

        return {
            "status": "success",
            "message": "تم حذف الجرد بنجاح",
            "doc_id": str(existing.id),
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            f"خطأ في delete_inventory: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )