# backend/app/routes/transactions.py

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.core.database import get_db
from app.core.models import Transaction
from app.core.schemas import TransactionModel
from app.core.sync import manager

import datetime


router = APIRouter()


# ============================================================
# Helper
# ============================================================

def serialize_transaction(
    tx: Transaction,
    action: str | None = None,
):
    data = {
        "id": tx.id,
        "company_code": tx.company_code,
        "branch_code": tx.branch_code,
        "serial": tx.serial,
        "treasury": tx.treasury,
        "amount": tx.amount,
        "statement": tx.statement,
        "category": tx.category,
        "date": tx.date,
        "type": tx.type,
        "employee": tx.employee,
        "updated_at": (
            tx.updated_at.isoformat()
            if tx.updated_at
            else None
        ),
        "is_deleted": bool(tx.is_deleted),
    }

    if action is not None:
        data["action"] = action

    return data


# ==========================================================
# 1. حفظ أو تحديث إذن
# ==========================================================

@router.post("/save")
async def save_transaction(
    data: TransactionModel,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # تحديد الـ Serial
        # ------------------------------------------------------

        if data.serial == 0:
            stmt = (
                select(Transaction)
                .where(
                    Transaction.company_code
                    == data.company_code,
                    Transaction.branch_code
                    == data.branch_code,
                    # المهم:
                    # لا نحتاج استبعاد المحذوف هنا
                    # لأن الـ serial لا يجب أن يعاد استخدامه.
                )
                .order_by(desc(Transaction.serial))
                .limit(1)
            )

            result = await db.execute(stmt)
            last = result.scalar_one_or_none()

            new_serial = (
                last.serial + 1
                if last
                else 1
            )

        else:
            new_serial = data.serial

        # ------------------------------------------------------
        # تعديل سجل موجود
        # ------------------------------------------------------

        if data.serial > 0:
            stmt = (
                select(Transaction)
                .where(
                    Transaction.company_code
                    == data.company_code,
                    Transaction.branch_code
                    == data.branch_code,
                    Transaction.serial
                    == data.serial,
                )
            )

            result = await db.execute(stmt)
            tx = result.scalar_one_or_none()

            if not tx:
                raise HTTPException(
                    status_code=404,
                    detail="Transaction not found",
                )

            # لا تسمح بتعديل سجل محذوف
            if tx.is_deleted:
                raise HTTPException(
                    status_code=404,
                    detail="Transaction has been deleted",
                )

            # --------------------------------------------------
            # تحديث البيانات
            # --------------------------------------------------

            tx.treasury = data.treasury
            tx.amount = data.amount
            tx.statement = data.statement
            tx.category = data.category
            tx.date = data.date
            tx.type = data.type
            tx.employee = data.employee

            tx.updated_at = datetime.datetime.utcnow()

            tx.is_deleted = False

            action = "update"

        else:
            # --------------------------------------------------
            # إضافة جديدة
            # --------------------------------------------------

            tx = Transaction(
                company_code=data.company_code,
                branch_code=data.branch_code,
                serial=new_serial,
                treasury=data.treasury,
                amount=data.amount,
                statement=data.statement,
                category=data.category,
                date=data.date,
                type=data.type,
                employee=data.employee,
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
        # WebSocket Broadcast
        # ------------------------------------------------------

        await manager.broadcast(
            data.company_code,
            {
                "type": "transaction",
                "action": action,
                "data": serialize_transaction(
                    tx,
                    action=action,
                ),
            },
        )

        # ------------------------------------------------------
        # Response
        # ------------------------------------------------------

        return {
            "status": "success",
            "serial": tx.serial,
            "action": action,
            "message": (
                "تم تعديل الإذن وتحديث قاعدة البيانات بنجاح"
                if action == "update"
                else "تم حفظ الإذن الجديد بنجاح"
            ),
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ==========================================================
# 2. جلب قائمة الأذون
#
# المحذوف لا يظهر هنا
# ==========================================================

@router.get("/list/{company_code}")
async def get_transactions(
    company_code: str,
    start_date: str = Query(...),
    end_date: str = Query(...),
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(Transaction)
            .where(
                Transaction.company_code
                == company_code,

                Transaction.date >= start_date,

                Transaction.date <= end_date,

                # إخفاء المحذوف
                Transaction.is_deleted.is_(False),
            )
        )

        if (
            branch_code
            and branch_code
            not in [
                "الكل",
                "كل الفروع",
                "all",
                "",
            ]
        ):
            stmt = stmt.where(
                Transaction.branch_code
                == branch_code
            )

        stmt = stmt.order_by(
            desc(Transaction.date),
            desc(Transaction.serial),
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = [
            serialize_transaction(doc)
            for doc in docs
        ]

        return results

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ==========================================================
# 3. جلب التحديثات التزايدية
#
# هنا أهم جزء في نظام الحذف.
#
# لو السجل:
# is_deleted = false
#    => action update
#
# لو:
# is_deleted = true
#    => action delete
#
# وبكده الجهاز Offline لما يرجع يعرف إن السجل اتحذف.
# ==========================================================

@router.get("/changes/{company_code}")
async def get_transactions_changes(
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
        # تحويل since
        # ------------------------------------------------------

        since_dt = datetime.datetime.fromisoformat(
            since.replace("Z", "+00:00")
        )

        # ------------------------------------------------------
        # تحويله إلى UTC
        # ثم إزالة timezone
        #
        # لأن updated_at عندك:
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
        # جلب كل التغييرات
        #
        # مهم:
        # لا نضع is_deleted = false هنا.
        #
        # لأننا نحتاج أيضًا للسجلات المحذوفة.
        # ------------------------------------------------------

        stmt = (
            select(Transaction)
            .where(
                Transaction.company_code
                == company_code,

                Transaction.updated_at >= since_dt,
            )
            .order_by(
                Transaction.updated_at
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        for doc in docs:

            # --------------------------------------------------
            # لو محذوف
            # --------------------------------------------------

            if doc.is_deleted:
                action = "delete"

            # --------------------------------------------------
            # لو موجود
            # --------------------------------------------------

            else:
                action = "update"

            results.append(
                serialize_transaction(
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


# ==========================================================
# 4. جلب التحديثات بدءاً من Serial معين
#
# للتوافق مع الكود القديم.
# المحذوف لا يظهر.
# ==========================================================

@router.get("/updates/{company_code}/{from_serial}")
async def get_transactions_from_serial(
    company_code: str,
    from_serial: int,
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(Transaction)
            .where(
                Transaction.company_code
                == company_code,

                Transaction.serial >= from_serial,

                Transaction.is_deleted.is_(False),
            )
            .order_by(
                Transaction.serial
            )
        )

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = [
            serialize_transaction(doc)
            for doc in docs
        ]

        return results

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ==========================================================
# 5. حذف إذن - Soft Delete
#
# لا نحذف السجل من Neon.
#
# فقط:
#
# is_deleted = true
# updated_at = now
#
# عشان الأجهزة Offline تعرف بالحذف.
# ==========================================================

@router.delete(
    "/delete/{company_code}/{branch_code}/{serial}"
)
async def delete_transaction(
    company_code: str,
    branch_code: str,
    serial: int,
    db: AsyncSession = Depends(get_db),
):
    try:
        # ------------------------------------------------------
        # البحث عن الإذن
        # ------------------------------------------------------

        stmt = (
            select(Transaction)
            .where(
                Transaction.company_code
                == company_code,

                Transaction.branch_code
                == branch_code,

                Transaction.serial
                == serial,
            )
        )

        result = await db.execute(stmt)

        tx = result.scalar_one_or_none()

        if not tx:
            raise HTTPException(
                status_code=404,
                detail="Transaction not found",
            )

        # ------------------------------------------------------
        # لو محذوف أصلًا
        # ------------------------------------------------------

        if tx.is_deleted:
            return {
                "status": "success",
                "message": "الإذن محذوف بالفعل",
                "deleted_id": (
                    f"branch_{branch_code}_{serial}"
                ),
            }

        # ------------------------------------------------------
        # Soft Delete
        # ------------------------------------------------------

        tx.is_deleted = True

        tx.updated_at = (
            datetime.datetime.utcnow()
        )

        await db.commit()

        await db.refresh(tx)

        # ------------------------------------------------------
        # إرسال إشعار فوري للأجهزة المتصلة
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "transaction",
                "action": "delete",
                "data": {
                    "id": tx.id,
                    "company_code":
                        tx.company_code,
                    "branch_code":
                        tx.branch_code,
                    "serial":
                        tx.serial,
                    "updated_at": (
                        tx.updated_at.isoformat()
                        if tx.updated_at
                        else None
                    ),
                    "is_deleted": True,
                },
            },
        )

        return {
            "status": "success",
            "message": (
                "تم حذف الإذن وإخفاؤه من النظام"
            ),
            "deleted_id":
                f"branch_{branch_code}_{serial}",
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ==========================================================
# 6. جلب آخر Serial
#
# هنا نُبقي المحذوف في الحساب حتى لا يتم إعادة
# استخدام رقم Serial قديم.
# ==========================================================

@router.get("/last_serial/{company_code}")
async def get_last_serial(
    company_code: str,
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db),
):
    try:
        stmt = (
            select(Transaction)
            .where(
                Transaction.company_code
                == company_code
            )
        )

        if (
            branch_code
            and branch_code
            not in [
                "الكل",
                "كل الفروع",
                "all",
                "",
            ]
        ):
            stmt = stmt.where(
                Transaction.branch_code
                == branch_code
            )

        stmt = (
            stmt
            .order_by(
                desc(Transaction.serial)
            )
            .limit(1)
        )

        result = await db.execute(stmt)

        last = result.scalar_one_or_none()

        return {
            "last_serial":
                last.serial if last else 0
        }

    except Exception:
        return {
            "last_serial": 0
        }


# ==========================================================
# 7. ملخص الأرصدة
#
# للتوافق مع الكود القديم.
# ==========================================================

@router.get("/summary/{company_code}")
async def get_summary(
    company_code: str,
):
    return {
        "status": "success",
        "active_treasuries": [],
    }