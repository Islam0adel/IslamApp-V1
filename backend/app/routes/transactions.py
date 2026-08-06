# backend/app/routes/transactions.py
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, and_, desc
from app.core.database import get_db
from app.core.models import Transaction
from app.core.schemas import TransactionModel
from app.core.sync import manager
import datetime

router = APIRouter()

# ==========================================
# 1. حفظ أو تحديث إذن (PostgreSQL + WebSocket Broadcast)
# ==========================================
@router.post("/save")
async def save_transaction(
    data: TransactionModel,
    db: AsyncSession = Depends(get_db)
):
    try:
        # 🔹 حساب serial جديد إذا كان 0 (إضافة جديدة)
        if data.serial == 0:
            stmt = select(Transaction).where(
                Transaction.company_code == data.company_code,
                Transaction.branch_code == data.branch_code
            ).order_by(desc(Transaction.serial)).limit(1)
            result = await db.execute(stmt)
            last = result.scalar_one_or_none()
            new_serial = (last.serial + 1) if last else 1
        else:
            new_serial = data.serial

        # 🔹 البحث عن السجل إذا كان تعديل (serial > 0)
        if data.serial > 0:
            stmt = select(Transaction).where(
                Transaction.company_code == data.company_code,
                Transaction.branch_code == data.branch_code,
                Transaction.serial == data.serial
            )
            result = await db.execute(stmt)
            tx = result.scalar_one_or_none()
            if not tx:
                raise HTTPException(status_code=404, detail="Transaction not found")
            # تحديث الحقول
            tx.treasury = data.treasury
            tx.amount = data.amount
            tx.statement = data.statement
            tx.category = data.category
            tx.date = data.date
            tx.type = data.type
            tx.employee = data.employee
            tx.updated_at = datetime.datetime.utcnow()
            action = "update"
        else:
            # إضافة جديدة
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
            )
            db.add(tx)
            action = "insert"

        await db.commit()
        await db.refresh(tx)

        # 🔹 بث التغيير عبر WebSocket لكل الأجهزة المتصلة بنفس الشركة
        await manager.broadcast(data.company_code, {
            "type": "transaction",
            "action": action,
            "data": {
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
                "updated_at": tx.updated_at.isoformat() if tx.updated_at else None
            }
        })

        # 🔹 نفس الرد الذي كان يعود من Firebase (متطابق تماماً)
        return {
            "status": "success",
            "serial": tx.serial,
            "action": action,
            "message": "تم تعديل الإذن وتحديث قاعدة البيانات بنجاح" if action == "update" else "تم حفظ الإذن الجديد بنجاح"
        }

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 2. جلب قائمة الأذون (مع فلترة بالتاريخ والفرع)
# ==========================================
@router.get("/list/{company_code}")
async def get_transactions(
    company_code: str,
    start_date: str = Query(...),
    end_date: str = Query(...),
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(Transaction).where(
            Transaction.company_code == company_code,
            Transaction.date >= start_date,
            Transaction.date <= end_date
        )
        if branch_code and branch_code not in ["الكل", "كل الفروع", "all", ""]:
            stmt = stmt.where(Transaction.branch_code == branch_code)

        stmt = stmt.order_by(desc(Transaction.date), desc(Transaction.serial))
        result = await db.execute(stmt)
        docs = result.scalars().all()

        # تحويل النتائج إلى قواميس (نفس تنسيق Firestore القديم)
        results = []
        for doc in docs:
            results.append({
                "id": doc.id,
                "company_code": doc.company_code,
                "branch_code": doc.branch_code,
                "serial": doc.serial,
                "treasury": doc.treasury,
                "amount": doc.amount,
                "statement": doc.statement,
                "category": doc.category,
                "date": doc.date,
                "type": doc.type,
                "employee": doc.employee,
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 3. جلب التحديثات بدءاً من رقم إذن معين
# ==========================================
@router.get("/updates/{company_code}/{from_serial}")
async def get_transactions_from_serial(
    company_code: str,
    from_serial: int,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(Transaction).where(
            Transaction.company_code == company_code,
            Transaction.serial >= from_serial
        ).order_by(Transaction.serial)
        result = await db.execute(stmt)
        docs = result.scalars().all()

        results = []
        for doc in docs:
            results.append({
                "id": doc.id,
                "company_code": doc.company_code,
                "branch_code": doc.branch_code,
                "serial": doc.serial,
                "treasury": doc.treasury,
                "amount": doc.amount,
                "statement": doc.statement,
                "category": doc.category,
                "date": doc.date,
                "type": doc.type,
                "employee": doc.employee,
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 4. حذف إذن
# ==========================================
@router.delete("/delete/{company_code}/{branch_code}/{serial}")
async def delete_transaction(
    company_code: str,
    branch_code: str,
    serial: int,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(Transaction).where(
            Transaction.company_code == company_code,
            Transaction.branch_code == branch_code,
            Transaction.serial == serial
        )
        result = await db.execute(stmt)
        tx = result.scalar_one_or_none()
        if not tx:
            raise HTTPException(status_code=404, detail="Transaction not found")

        await db.delete(tx)
        await db.commit()

        # بث حدث الحذف
        await manager.broadcast(company_code, {
            "type": "transaction",
            "action": "delete",
            "data": {
                "id": tx.id,
                "company_code": tx.company_code,
                "branch_code": tx.branch_code,
                "serial": tx.serial,
            }
        })

        return {
            "status": "success",
            "message": "تم حذف الإذن بنجاح من الخادم الرئيسي",
            "deleted_id": f"branch_{branch_code}_{serial}"
        }

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 5. جلب آخر سيريال
# ==========================================
@router.get("/last_serial/{company_code}")
async def get_last_serial(
    company_code: str,
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(Transaction).where(Transaction.company_code == company_code)
        if branch_code and branch_code not in ["الكل", "كل الفروع", "all", ""]:
            stmt = stmt.where(Transaction.branch_code == branch_code)
        stmt = stmt.order_by(desc(Transaction.serial)).limit(1)
        result = await db.execute(stmt)
        last = result.scalar_one_or_none()
        return {"last_serial": last.serial if last else 0}

    except Exception as e:
        return {"last_serial": 0}


# ==========================================
# 6. ملخص الأرصدة (يتم حسابه محلياً في Flutter، لكن نتركه للتوافق)
# ==========================================
@router.get("/summary/{company_code}")
async def get_summary(company_code: str):
    # يتم حساب الأرصدة محلياً في Flutter عبر Hive، لذا نعيد قائمة فارغة
    # لكن نحتفظ بالدالة للتوافق مع الكود القديم
    return {"status": "success", "active_treasuries": []}