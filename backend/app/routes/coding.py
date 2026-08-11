from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, and_
from app.core.database import get_db
from app.core.models import CodingRecord
from app.core.schemas import CodingModel
from app.core.sync import manager
from typing import Optional
import datetime

router = APIRouter()

# ===== التكويدات الافتراضية (نفس القيم السابقة) =====
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
    {"name": "بضاعة", "type": "صادر"}
]

DEFAULT_CATEGORIES_DATA = {
    "safes": [{"name": "نقدي"}, {"name": "فيزا"}, {"name": "محفظة الكترونية"}],
    "customers": [{"name": "عميل نقدي"}],
    "stores": [{"name": "المخزن الرئيسي"}],
    "branches": [{"name": "الفرع الرئيسي"}],
    "payment_methods": [{"name": "نقدي"}, {"name": "فيزا"}, {"name": "محفظة الكترونية"}]
}

router = APIRouter()

# ==========================================
# 1. حفظ تكويد (إضافة أو تحديث)
# ==========================================
@router.post("/save")
async def save_code(
    data: CodingModel,
    db: AsyncSession = Depends(get_db)
):
    try:
        company_code = data.company_code
        category = data.category
        code = data.code

        if not code:
            raise HTTPException(status_code=400, detail="الكود مطلوب ولا يمكن أن يكون فارغاً")

        # البحث عن السجل
        stmt = select(CodingRecord).where(
            CodingRecord.company_code == company_code,
            CodingRecord.category == category,
            CodingRecord.code == code
        )
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()

        if existing:
            # تحديث
            existing.name = data.name
            existing.type = data.type
            existing.barcode = data.barcode
            existing.wholesale_price = data.wholesale_price
            existing.selling_price = data.selling_price
            existing.profit_margin = data.profit_margin
            existing.profit_percent = data.profit_percent
            existing.updated_at = datetime.datetime.utcnow()
            action = "update"
        else:
            # إضافة جديدة
            new_record = CodingRecord(
                company_code=company_code,
                category=category,
                code=code,
                name=data.name,
                type=data.type or "وارد",
                barcode=data.barcode or "",
                wholesale_price=data.wholesale_price or 0.0,
                selling_price=data.selling_price or 0.0,
                profit_margin=data.profit_margin or 0.0,
                profit_percent=data.profit_percent or 0.0,
            )
            db.add(new_record)
            action = "insert"

        await db.commit()

        # بث التغيير
        await manager.broadcast(company_code, {
            "type": "coding",
            "action": action,
            "data": {
                "company_code": company_code,
                "category": category,
                "code": code,
                "name": data.name,
                "type": data.type,
                "barcode": data.barcode,
                "wholesale_price": data.wholesale_price,
                "selling_price": data.selling_price,
                "profit_margin": data.profit_margin,
                "profit_percent": data.profit_percent,
                "updated_at": datetime.datetime.utcnow().isoformat()
            }
        })

        return {
            "status": "success",
            "message": "تم حفظ التكويد بنجاح",
            "code": code,
            "action": action
        }

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=f"خطأ في السيرفر: {str(e)}")

# ==========================================
# 2. جلب قائمة التكويدات
# ==========================================
@router.get("/list/{company_code}/{category}")
async def list_codes(
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

        # إذا لم توجد بيانات، ننشئ البيانات الافتراضية
        if not docs:
            if category == "types":
                for index, item in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    new_record = CodingRecord(
                        company_code=company_code,
                        category=category,
                        code=code,
                        name=item["name"],
                        type=item["type"],
                    )
                    db.add(new_record)
                await db.commit()
                # إعادة الجلب
                stmt = select(CodingRecord).where(
                    CodingRecord.company_code == company_code,
                    CodingRecord.category == category
                ).order_by(CodingRecord.code)
                result = await db.execute(stmt)
                docs = result.scalars().all()

            elif category in DEFAULT_CATEGORIES_DATA:
                for index, item in enumerate(DEFAULT_CATEGORIES_DATA[category], start=1):
                    code = str(index)
                    new_record = CodingRecord(
                        company_code=company_code,
                        category=category,
                        code=code,
                        name=item["name"],
                    )
                    db.add(new_record)
                await db.commit()
                stmt = select(CodingRecord).where(
                    CodingRecord.company_code == company_code,
                    CodingRecord.category == category
                ).order_by(CodingRecord.code)
                result = await db.execute(stmt)
                docs = result.scalars().all()

        # تحويل النتائج إلى قواميس (نفس تنسيق Firestore)
        results = []
        for doc in docs:
            results.append({
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
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })

        # ترتيب حسب الكود (نفس المنطق القديم)
        results.sort(key=lambda x: int(x.get("code", 0)) if str(x.get("code", "")).isdigit() else str(x.get("code", "")))
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 3. حذف تكويد
# ==========================================
@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(
    company_code: str,
    category: str,
    code: str,
    db: AsyncSession = Depends(get_db)
):
    try:
        stmt = select(CodingRecord).where(
            CodingRecord.company_code == company_code,
            CodingRecord.category == category,
            CodingRecord.code == code
        )
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        if not existing:
            raise HTTPException(status_code=404, detail="التكويد غير موجود")

        await db.delete(existing)
        await db.commit()

        # بث حدث الحذف
        await manager.broadcast(company_code, {
            "type": "coding",
            "action": "delete",
            "data": {
                "company_code": company_code,
                "category": category,
                "code": code,
            }
        })

        return {"status": "success", "message": "تم حذف التكويد بنجاح"}

    except HTTPException:
        raise
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(e))

# ==========================================
# 4. جلب التحديثات التزايدية للتكويد (حسب القسم)
# ==========================================
@router.get("/changes/{company_code}")
async def get_coding_changes(
    company_code: str,
    category: str = Query(..., description="القسم المطلوب (مثل items, safes, types)"),
    since: str = Query(..., description="وقت آخر مزامنة بصيغة ISO 8601"),
    db: AsyncSession = Depends(get_db)
):
    try:
        since_dt = datetime.datetime.fromisoformat(since)
        
        stmt = select(CodingRecord).where(
            CodingRecord.company_code == company_code,
            CodingRecord.category == category,
            CodingRecord.updated_at >= since_dt
        ).order_by(CodingRecord.updated_at)
        
        result = await db.execute(stmt)
        docs = result.scalars().all()
        
        # تحويل النتائج إلى قواميس (نفس تنسيق /list)
        results = []
        for doc in docs:
            results.append({
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
                "updated_at": doc.updated_at.isoformat() if doc.updated_at else None,
            })
        return results
        
    except ValueError:
        raise HTTPException(status_code=400, detail="صيغة `since` غير صحيحة، استخدم ISO 8601")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))