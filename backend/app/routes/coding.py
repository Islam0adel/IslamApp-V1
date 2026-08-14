# backend/app/routes/coding.py

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.core.models import CodingRecord
from app.core.schemas import CodingModel
from app.core.sync import manager

import datetime


router = APIRouter()


# ============================================================
# التكويدات الافتراضية
# ============================================================

DEFAULT_TYPES = [
    {"name": "ايراد", "type": "وارد"},
    {"name": "فيزا", "type": "وارد"},
    {"name": "استهلاكات بضاعة", "type": "صادر"},
    {"name": "انترنت", "type": "صادر"},
    {"name": "ايجار", "type": "صادر"},
    {"name": "بوفية", "type": "صادر"},
    {"name": "عمولة", "type": "صادر"},
    {"name": "صيانة", "type": "صادر"},
    {"name": "ضرائب", "type": "صادر"},
    {"name": "مرتبات", "type": "صادر"},
    {"name": "نظافة", "type": "صادر"},
    {"name": "تأمينات", "type": "صادر"},
    {"name": "نقل بضاعة", "type": "صادر"},
    {"name": "ارباح", "type": "صادر"},
    {"name": "بضاعة", "type": "صادر"},
]


DEFAULT_CATEGORIES_DATA = {
    "safes": [
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"},
    ],

    "customers": [
        {"name": "عميل نقدي"},
    ],

    "stores": [
        {"name": "المخزن الرئيسي"},
    ],

    "branches": [
        {"name": "الفرع الرئيسي"},
    ],

    "payment_methods": [
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"},
    ],
}


# ============================================================
# Helper
# ============================================================

def serialize_coding(
    doc: CodingRecord,
    action: str | None = None,
):
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "category": doc.category,
        "code": doc.code,
        "name": doc.name,
        "type": doc.type,
        "barcode": doc.barcode,
        "wholesale_price": doc.wholesale_price,
        "selling_price": doc.selling_price,
        "profit_margin": doc.profit_margin,
        "profit_percent": doc.profit_percent,
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
# 1. حفظ تكويد
#    إضافة أو تحديث
# ============================================================

@router.post("/save")
async def save_code(
    data: CodingModel,
    db: AsyncSession = Depends(get_db),
):
    try:
        company_code = data.company_code
        category = data.category
        code = data.code

        # ------------------------------------------------------
        # التحقق من الكود
        # ------------------------------------------------------

        if not code:
            raise HTTPException(
                status_code=400,
                detail="الكود مطلوب ولا يمكن أن يكون فارغاً",
            )

        # ------------------------------------------------------
        # البحث عن السجل حتى لو كان Soft Deleted
        # ------------------------------------------------------

        stmt = (
            select(CodingRecord)
            .where(
                CodingRecord.company_code
                == company_code,

                CodingRecord.category
                == category,

                CodingRecord.code
                == code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        # ------------------------------------------------------
        # تعديل موجود
        # ------------------------------------------------------

        if existing:

            # تحديث البيانات
            existing.name = data.name
            existing.type = data.type
            existing.barcode = data.barcode

            existing.wholesale_price = (
                data.wholesale_price
            )

            existing.selling_price = (
                data.selling_price
            )

            existing.profit_margin = (
                data.profit_margin
            )

            existing.profit_percent = (
                data.profit_percent
            )

            existing.updated_at = (
                datetime.datetime.utcnow()
            )

            # لو كان محذوفًا وتم حفظه مرة أخرى
            # يرجع Active
            was_deleted = bool(
                existing.is_deleted
            )

            existing.is_deleted = False

            action = (
                "insert"
                if was_deleted
                else "update"
            )

            tx = existing

        # ------------------------------------------------------
        # إضافة جديدة
        # ------------------------------------------------------

        else:
            tx = CodingRecord(
                company_code=company_code,
                category=category,
                code=code,
                name=data.name,
                type=data.type or "وارد",
                barcode=data.barcode or "",
                wholesale_price=(
                    data.wholesale_price or 0.0
                ),
                selling_price=(
                    data.selling_price or 0.0
                ),
                profit_margin=(
                    data.profit_margin or 0.0
                ),
                profit_percent=(
                    data.profit_percent or 0.0
                ),
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )

            db.add(tx)

            action = "insert"

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        await db.commit()

        await db.refresh(tx)

        # ------------------------------------------------------
        # WebSocket
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "coding",
                "action": action,
                "data": serialize_coding(
                    tx,
                    action=action,
                ),
            },
        )

        return {
            "status": "success",
            "message": "تم حفظ التكويد بنجاح",
            "code": code,
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        raise HTTPException(
            status_code=500,
            detail=f"خطأ في السيرفر: {str(e)}",
        )


# ============================================================
# 2. جلب قائمة التكويدات
#
# المحذوف لا يظهر
# ============================================================

@router.get("/list/{company_code}/{category}")
async def list_codes(
    company_code: str,
    category: str,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # جلب البيانات غير المحذوفة فقط
        # ------------------------------------------------------

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

        # ------------------------------------------------------
        # لو مفيش بيانات، ننشئ الافتراضيات
        # ------------------------------------------------------

        if not docs:

            # ==================================================
            # types
            # ==================================================

            if category == "types":

                for index, item in enumerate(
                    DEFAULT_TYPES,
                    start=1,
                ):
                    code = str(index)

                    # نشوف إذا سجل Soft Deleted موجود
                    existing_stmt = (
                        select(CodingRecord)
                        .where(
                            CodingRecord.company_code
                            == company_code,

                            CodingRecord.category
                            == category,

                            CodingRecord.code
                            == code,
                        )
                    )

                    existing_result = (
                        await db.execute(
                            existing_stmt
                        )
                    )

                    existing = (
                        existing_result
                        .scalar_one_or_none()
                    )

                    if existing:
                        existing.name = item["name"]
                        existing.type = item["type"]
                        existing.is_deleted = False
                        existing.updated_at = (
                            datetime.datetime.utcnow()
                        )
                    else:
                        new_record = CodingRecord(
                            company_code=company_code,
                            category=category,
                            code=code,
                            name=item["name"],
                            type=item["type"],
                            updated_at=datetime.datetime.utcnow(),
                            is_deleted=False,
                        )

                        db.add(new_record)

                await db.commit()

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

            # ==================================================
            # باقي البيانات الافتراضية
            # ==================================================

            elif category in DEFAULT_CATEGORIES_DATA:

                for index, item in enumerate(
                    DEFAULT_CATEGORIES_DATA[category],
                    start=1,
                ):
                    code = str(index)

                    existing_stmt = (
                        select(CodingRecord)
                        .where(
                            CodingRecord.company_code
                            == company_code,

                            CodingRecord.category
                            == category,

                            CodingRecord.code
                            == code,
                        )
                    )

                    existing_result = (
                        await db.execute(
                            existing_stmt
                        )
                    )

                    existing = (
                        existing_result
                        .scalar_one_or_none()
                    )

                    if existing:
                        existing.name = item["name"]
                        existing.is_deleted = False
                        existing.updated_at = (
                            datetime.datetime.utcnow()
                        )
                    else:
                        new_record = CodingRecord(
                            company_code=company_code,
                            category=category,
                            code=code,
                            name=item["name"],
                            updated_at=datetime.datetime.utcnow(),
                            is_deleted=False,
                        )

                        db.add(new_record)

                await db.commit()

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

        # ------------------------------------------------------
        # تحويل النتائج
        # ------------------------------------------------------

        results = [
            serialize_coding(doc)
            for doc in docs
        ]

        # ------------------------------------------------------
        # ترتيب حسب الكود
        # ------------------------------------------------------

        results.sort(
            key=lambda x:
                (
                    int(x.get("code", 0))
                    if str(
                        x.get("code", "")
                    ).isdigit()
                    else str(
                        x.get("code", "")
                    )
                )
        )

        return results

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 3. حذف تكويد - Soft Delete
# ============================================================

@router.delete(
    "/delete/{company_code}/{category}/{code}"
)
async def delete_code(
    company_code: str,
    category: str,
    code: str,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        stmt = (
            select(CodingRecord)
            .where(
                CodingRecord.company_code
                == company_code,

                CodingRecord.category
                == category,

                CodingRecord.code
                == code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="التكويد غير موجود",
            )

        # ------------------------------------------------------
        # لو محذوف بالفعل
        # ------------------------------------------------------

        if existing.is_deleted:
            return {
                "status": "success",
                "message": "التكويد محذوف بالفعل",
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
        # WebSocket
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "coding",
                "action": "delete",
                "data": {
                    "id": existing.id,
                    "company_code": company_code,
                    "category": category,
                    "code": code,
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
            "message": "تم حذف التكويد بنجاح",
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
# 4. جلب التحديثات التزايدية للتكويد
#
# مهم:
# لا نستبعد is_deleted هنا.
#
# لأن الجهاز Offline يحتاج يعرف أن السجل تم حذفه.
# ============================================================

@router.get("/changes/{company_code}")
async def get_coding_changes(
    company_code: str,

    category: str = Query(
        ...,
        description=(
            "القسم المطلوب "
            "(مثل items, safes, types)"
        ),
    ),

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
        # تحويل since
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
        # توحيد UTC
        # ------------------------------------------------------

        if since_dt.tzinfo is not None:
            since_dt = since_dt.astimezone(
                datetime.timezone.utc
            )

            since_dt = since_dt.replace(
                tzinfo=None
            )

        # ------------------------------------------------------
        # جلب كل التغييرات
        #
        # بما فيها المحذوف.
        # ------------------------------------------------------

        stmt = (
            select(CodingRecord)
            .where(
                CodingRecord.company_code
                == company_code,

                CodingRecord.category
                == category,

                CodingRecord.updated_at
                >= since_dt,
            )
            .order_by(
                CodingRecord.updated_at
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        for doc in docs:

            # --------------------------------------------------
            # تحديد نوع العملية
            # --------------------------------------------------

            if doc.is_deleted:
                action = "delete"
            else:
                action = "update"

            results.append(
                serialize_coding(
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