# backend/app/routes/settings.py
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.core.models import CodingRecord
from app.core.permissions import (
    require_any_section_permission,
    require_section_permission,
)

# قراءة التكويد من الإعدادات: نفس مستهلكي الكتالوج في coding.py
# صلاحيات قراءة الأكواد من الإعدادات
_GET_CODES_VIEW_CHECKS = [
    ("التكويد", "معاينة"),
    ("حركة الخزينة", "المعاينة"), ("حركة الخزينة", "ادخال اذون"),
    ("حسابات الموردين", "معاينة"), ("حسابات الموردين", "اضافة"),
    ("تسويات الموردين", "معاينة"), ("تسويات الموردين", "إضافة"),
    ("حركة الجرد", "معاينة"), ("حركة الجرد", "اضافة"),
    ("المبيعات", "معاينة"), ("المبيعات", "إضافة"),
    ("المرتجعات", "معاينة"), ("المرتجعات", "إضافة"),
    ("حسابات العملاء", "معاينة"), ("حسابات العملاء", "إضافة تحصيل"),
    ("التحويلات المخزنية", "معاينة"), ("التحويلات المخزنية", "إضافة"),
    ("رصيد المخزون", "معاينة"),
    ("أرصدة خزائن المبيعات", "معاينة"),
    ("التقارير", "تقرير المبيعات"),
    ("الموارد البشرية", "canOpenAttendancePage"),
    ("الموارد البشرية", "canViewEmployees"),
    ("الموارد البشرية", "canManageEmployees"),
]
from app.core.sync import manager

# اسم تصنيف صلاحيات التكويد
_CATEGORY = "التكويد"

# نفس خريطة coding.py: القسم → مفتاح صلاحية الإضافة
_ADD_PERMISSION_BY_CATEGORY = {
    "stores": "اضافة مخزن",
    "branches": "اضافة فرع",
    "safes": "اضافة خزينة",
    "suppliers": "اضافة مورد",
    "customers": "اضافة عملاء",
    "payment_methods": "اضافة طرق دفع",
    "banks": "اضافة بنك",
}

# الفئات الصالحة فعلاً عند العميل (coding_service.categories)
_VALID_CATEGORIES = {
    "safes", "types", "branches", "stores",
    "suppliers", "customers", "payment_methods", "items",
}

from pydantic import BaseModel

import datetime

# راوتر الإعدادات
router = APIRouter()


# ============================================================
# Model
# ============================================================


# نموذج بيانات إضافة كود جديد
class CodingItem(BaseModel):
    category: str
    code: str
    name: str
    company_code: str


# ============================================================
# 1. إضافة تكويد
#    مستخدم في الإعدادات
# ============================================================


# مسار إضافة كود جديد للإعدادات
@router.post("/add-code")
async def add_coding_item(
    item: CodingItem,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    # نفس منطق الواجهة: فئة غير صالحة = رفض، وصالحة بلا مفتاح خاص
    # (items/types) تستخدم حق الإضافة العام "اضافة صنف"
    if item.category not in _VALID_CATEGORIES:
        raise HTTPException(status_code=403, detail="فئة تكويد غير معروفة")
    _permission_key = _ADD_PERMISSION_BY_CATEGORY.get(
        item.category, "اضافة صنف"
    )
    require_section_permission(request, _CATEGORY, _permission_key)
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
                # خط الأساس كان يصفّر السعر عند إعادة التفعيل،
                # فالصنف العائد بلا سعر معروف: يُوسَم "غير محدد"
                # حتى يحدده صاحب الحق (لا إبطال لسعر قائم)
                existing.cost_pending = item.category == "items"

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

            # لا مدخل سعر في هذه النقطة إطلاقاً: صنف جديد
            # يُوسَم "غير محدد" أياً كان المنشئ
            cost_pending=item.category == "items",

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


# مسار قراءة أكواد تصنيف معين
@router.get("/get-codes/{company_code}/{category}")
async def get_coding_items(
    company_code: str,
    category: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _profile = request.state.auth_user
    from app.core.auth_middleware import _effective_role
    if _effective_role(_profile) != "super_admin" and str(
        _profile.get("company_code", "")
    ) != str(company_code):
        raise HTTPException(status_code=403, detail="غير مصرح لهذه الشركة")
    require_any_section_permission(request, _GET_CODES_VIEW_CHECKS)
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
