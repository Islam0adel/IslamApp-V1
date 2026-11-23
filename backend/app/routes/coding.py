# backend/app/routes/coding.py

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.models import CodingRecord
from app.core.permissions import (
    has_section_permission,
    require_any_section_permission,
    require_section_permission,
)
from app.core.schemas import CodingModel
from app.core.sync import manager

_CATEGORY = "التكويد"

# نفس خريطة الواجهة (coding_page._canAddSelectedCategory): القسم → مفتاح الإضافة
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
    "banks",
}


def _add_permission_key(category: str) -> str:
    """نفس منطق الواجهة (_canAddSelectedCategory):
    - فئة غير صالحة أصلاً = رفض مغلق.
    - فئة صالحة بلا مفتاح خاص (items/types) = حق الإضافة العام "اضافة صنف".
    """
    if category not in _VALID_CATEGORIES:
        raise HTTPException(
            status_code=403,
            detail="فئة تكويد غير معروفة",
        )
    return _ADD_PERMISSION_BY_CATEGORY.get(category, "اضافة صنف")


# صلاحيات بديلة بتخوّل رؤية سعر الشراء (الجملة) والأرباح:
# "سعر الشراء" في التكويد، أو "عرض سعر الجملة" في المبيعات/رصيد المخزون.
_COST_PERMISSION_CHECKS = [
    ("التكويد", "سعر الشراء"),
    ("المبيعات", "عرض سعر الجملة"),
    ("رصيد المخزون", "عرض سعر الجملة"),
]

_CODING_COST_FIELDS = ("wholesale_price", "profit_margin", "profit_percent")

# الأقسام التي تستهلك كتالوج التكويد فعلاً في شاشات الإدخال والتقارير
# (مولَّدة من مخطط صلاحيات العميل في permissions_page). من ليس له أي
# صلاحية في أي قسم مستهلك لا يحتاج الكتالوج إطلاقاً.
_CODING_VIEW_CHECKS = [
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
    ("التقارير", "تقرير المبيعات"), ("التقارير", "التقرير الموسع (صافي الجرد)"),
    ("الموارد البشرية", "canOpenAttendancePage"),
    ("الموارد البشرية", "canViewEmployees"),
    ("الموارد البشرية", "canManageEmployees"),
    ("الموارد البشرية", "canViewBranchSalaryReport"),
]


def _may_view_costs(profile: dict) -> bool:
    return any(
        has_section_permission(profile, category, key)
        for category, key in _COST_PERMISSION_CHECKS
    )


def _check_branch(profile: dict, branch_code) -> None:
    allowed = allowed_branches_for_profile(profile)
    if allowed and branch_code and str(branch_code) not in allowed:
        raise HTTPException(
            status_code=403,
            detail="ليس لديك صلاحية على هذا الفرع",
        )

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
    include_costs: bool = True,
):
    data = {
        "id": doc.id,
        "company_code": doc.company_code,
        "category": doc.category,
        "branch_code": doc.branch_code,
        "code": doc.code,
        "name": doc.name,
        "type": doc.type,
        "barcode": doc.barcode,
        "wholesale_price": doc.wholesale_price if include_costs else None,
        "cost_pending": bool(getattr(doc, "cost_pending", False)),
        "selling_price": doc.selling_price,
        "profit_margin": doc.profit_margin if include_costs else None,
        "profit_percent": doc.profit_percent if include_costs else None,
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
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _permission_key = _add_permission_key(data.category)
    _profile = require_section_permission(request, _CATEGORY, _permission_key)
    _check_branch(_profile, data.branch_code)
    _may_costs = _may_view_costs(_profile)
    try:
    # ✅ حماية: الموظفين انتقلوا لـ /employees
        if data.category == "employees":
            raise HTTPException(
                status_code=400,
                detail="الموظفين أصبحوا في /employees وليس /coding",
            )
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

            # الفرع المخزَّن أيضاً: منع نقل/تعديل سجل فرع غير مسموح
            _check_branch(_profile, existing.branch_code)

            # تحديث البيانات
            existing.name = data.name
            existing.branch_code = data.branch_code
            existing.type = data.type
            existing.barcode = data.barcode

            # تأكيد الصفر الصريح بلا حق تكلفة = رفض، لا تجاهل صامت
            if not _may_costs and getattr(
                data, "confirm_zero_cost", False
            ):
                raise HTTPException(
                    status_code=403,
                    detail="تأكيد سعر الشراء الصفري يتطلب صلاحية سعر الشراء",
                )

            # حقول التكلفة: من لا يملك حق التكلفة لا يغيّر القيم المخزنة
            # (الواجهة تعيد إرسال القيمة المفرغة، فكتابتها كانت ستصفّرها)
            if _may_costs:
                if not existing.cost_pending:
                    # سلوك قائم محفوظ: صاحب الحق يرى السعر الحقيقي
                    # في النموذج وإعادة إرساله تحفظه كما هو
                    existing.wholesale_price = (
                        data.wholesale_price
                    )
                elif (
                    (data.wholesale_price or 0.0) != 0.0
                    or getattr(data, "confirm_zero_cost", False)
                ):
                    # صنف "غير محدد": إزالة العلامة تتطلب نية سعر
                    # صريحة — سعر غير صفري، أو تأكيد صفري مصرَّح.
                    # الحفظ العادي (إعادة إرسال الصفر شكلاً) لا يزيلها.
                    existing.wholesale_price = (
                        data.wholesale_price
                    )
                    existing.cost_pending = False

            existing.selling_price = (
                data.selling_price
            )

            if _may_costs:
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
                branch_code=data.branch_code,
                type=data.type or "وارد",
                barcode=data.barcode or "",
                wholesale_price=(
                    (data.wholesale_price or 0.0) if _may_costs else 0.0
                ),
                # من لا يملك حق التكلفة لا يزوّد سعراً: الصفر
                # المخزن "غير محدد" لا صفراً مصرَّحاً به
                cost_pending=not _may_costs,
                selling_price=(
                    data.selling_price or 0.0
                ),
                profit_margin=(
                    (data.profit_margin or 0.0) if _may_costs else 0.0
                ),
                profit_percent=(
                    (data.profit_percent or 0.0) if _may_costs else 0.0
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
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    # القراءة مقيدة بمن له صلاحية في قسم مستهلك للتكويد فعلاً
    # (معاينة أو إضافة)، مع تقليل حقول التكلفة لمن ليس عنده صلاحيتها.
    require_any_section_permission(request, _CODING_VIEW_CHECKS)
    _include_costs = _may_view_costs(request.state.auth_user)
    try:
                # ✅ حماية: الموظفين انتقلوا لـ /employees
        if category == "employees":
            raise HTTPException(
                status_code=400,
                detail="الموظفين أصبحوا في /employees وليس /coding",
            )
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

                # ✅ استعلام واحد لجلب كل السجلات الموجودة
                # (بدل استعلام لكل عنصر)
                all_codes = [
                    str(i)
                    for i in range(
                        1, len(DEFAULT_TYPES) + 1
                    )
                ]

                existing_stmt = (
                    select(CodingRecord)
                    .where(
                        CodingRecord.company_code
                        == company_code,

                        CodingRecord.category
                        == category,

                        CodingRecord.code.in_(
                            all_codes
                        ),
                    )
                )

                existing_result = (
                    await db.execute(
                        existing_stmt
                    )
                )

                existing_map = {
                    r.code: r
                    for r in existing_result
                    .scalars().all()
                }

                for index, item in enumerate(
                    DEFAULT_TYPES,
                    start=1,
                ):
                    code = str(index)

                    existing = existing_map.get(
                        code
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

                # ✅ استعلام واحد لجلب كل السجلات الموجودة
                # (بدل استعلام لكل عنصر)
                all_codes = [
                    str(i)
                    for i in range(
                        1,
                        len(
                            DEFAULT_CATEGORIES_DATA[
                                category
                            ]
                        ) + 1,
                    )
                ]

                existing_stmt = (
                    select(CodingRecord)
                    .where(
                        CodingRecord.company_code
                        == company_code,

                        CodingRecord.category
                        == category,

                        CodingRecord.code.in_(
                            all_codes
                        ),
                    )
                )

                existing_result = (
                    await db.execute(
                        existing_stmt
                    )
                )

                existing_map = {
                    r.code: r
                    for r in existing_result
                    .scalars().all()
                }

                for index, item in enumerate(
                    DEFAULT_CATEGORIES_DATA[category],
                    start=1,
                ):
                    code = str(index)

                    existing = existing_map.get(
                        code
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
            serialize_coding(doc, include_costs=_include_costs)
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
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    # الواجهة بتعرض الحذف مع نفس صلاحية الإضافة للقسم
    _permission_key = _add_permission_key(category)
    _profile = require_section_permission(request, _CATEGORY, _permission_key)
    try:
                # ✅ حماية: الموظفين انتقلوا لـ /employees
        if category == "employees":
            raise HTTPException(
                status_code=400,
                detail="الموظفين أصبحوا في /employees وليس /coding",
            )
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

        _check_branch(_profile, existing.branch_code)

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
    request: Request,

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
    require_any_section_permission(request, _CODING_VIEW_CHECKS)
    _include_costs = _may_view_costs(request.state.auth_user)
    try:
                # ✅ حماية: الموظفين انتقلوا لـ /employees
        if category == "employees":
            raise HTTPException(
                status_code=400,
                detail="الموظفين أصبحوا في /employees وليس /coding",
            )
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
                    include_costs=_include_costs,
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
