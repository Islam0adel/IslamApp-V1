from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.core.models import CodingRecord
from app.core.sync import manager

from pydantic import BaseModel

import datetime


router = APIRouter()


# ============================================================
# Model
# ============================================================

class CodingItem(BaseModel):
    category: str
    code: str
    name: str
    company_code: str


# ============================================================
# 1. إضافة تكويد
#    مستخدم في الإعدادات
# ============================================================

@router.post("/add-code")
async def add_coding_item(
    item: CodingItem,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # البحث عن الكود حتى لو كان Soft Deleted
        # ------------------------------------------------------

        stmt = (
            select(CodingRecord)
            .where(
                CodingRecord.company_code
                == item.company_code,

                CodingRecord.category
                == item.category,

                CodingRecord.code
                == item.code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        # ------------------------------------------------------
        # لو موجود
        # ------------------------------------------------------

        if existing:

            # لو موجود لكنه محذوف
            # نعيد تفعيله بدل إنشاء سجل جديد
            if existing.is_deleted:
                existing.name = item.name

                existing.type = ""

                existing.barcode = ""

                existing.wholesale_price = 0.0
                existing.selling_price = 0.0
                existing.profit_margin = 0.0
                existing.profit_percent = 0.0

                existing.is_deleted = False

                existing.updated_at = (
                    datetime.datetime.utcnow()
                )

                await db.commit()
                await db.refresh(existing)

                # ------------------------------------------------
                # WebSocket
                # ------------------------------------------------

                await manager.broadcast(
                    item.company_code,
                    {
                        "type": "coding",
                        "action": "insert",
                        "data": {
                            "id": existing.id,
                            "company_code":
                                existing.company_code,
                            "category":
                                existing.category,
                            "code":
                                existing.code,
                            "name":
                                existing.name,
                            "type":
                                existing.type,
                            "barcode":
                                existing.barcode,
                            "wholesale_price":
                                existing.wholesale_price,
                            "selling_price":
                                existing.selling_price,
                            "profit_margin":
                                existing.profit_margin,
                            "profit_percent":
                                existing.profit_percent,
                            "updated_at": (
                                existing.updated_at.isoformat()
                                if existing.updated_at
                                else None
                            ),
                            "is_deleted": False,
                        },
                    },
                )

                return {
                    "status": "success",
                    "message": (
                        f"تم إعادة تفعيل "
                        f"{item.name} بنجاح"
                    ),
                    "action": "insert",
                }

            # موجود وغير محذوف
            raise HTTPException(
                status_code=400,
                detail=(
                    "هذا الكود موجود بالفعل "
                    "في هذا القسم"
                ),
            )

        # ------------------------------------------------------
        # إضافة سجل جديد
        # ------------------------------------------------------

        new_record = CodingRecord(
            company_code=item.company_code,
            category=item.category,
            code=item.code,
            name=item.name,

            type="",

            barcode="",

            wholesale_price=0.0,
            selling_price=0.0,

            profit_margin=0.0,
            profit_percent=0.0,

            updated_at=datetime.datetime.utcnow(),

            is_deleted=False,
        )

        db.add(new_record)

        await db.commit()

        await db.refresh(new_record)

        # ------------------------------------------------------
        # Broadcast
        # ------------------------------------------------------

        await manager.broadcast(
            item.company_code,
            {
                "type": "coding",
                "action": "insert",
                "data": {
                    "id": new_record.id,
                    "company_code":
                        new_record.company_code,
                    "category":
                        new_record.category,
                    "code":
                        new_record.code,
                    "name":
                        new_record.name,
                    "type":
                        new_record.type,
                    "barcode":
                        new_record.barcode,
                    "wholesale_price":
                        new_record.wholesale_price,
                    "selling_price":
                        new_record.selling_price,
                    "profit_margin":
                        new_record.profit_margin,
                    "profit_percent":
                        new_record.profit_percent,
                    "updated_at": (
                        new_record.updated_at.isoformat()
                        if new_record.updated_at
                        else None
                    ),
                    "is_deleted": False,
                },
            },
        )

        return {
            "status": "success",
            "message": (
                f"تم إضافة {item.name} بنجاح"
            ),
            "action": "insert",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 2. جلب قائمة التكويدات
#
# المحذوف لا يظهر
# ============================================================

@router.get("/get-codes/{company_code}/{category}")
async def get_coding_items(
    company_code: str,
    category: str,
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(CodingRecord)
            .where(
                CodingRecord.company_code
                == company_code,

                CodingRecord.category
                == category,

                CodingRecord.is_deleted.is_(False),
            )
            .order_by(
                CodingRecord.code
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        items = [
            {
                "code": doc.code,
                "name": doc.name,
            }
            for doc in docs
        ]

        return items

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )