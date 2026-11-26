# backend/app/routes/supplier.py

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import true, select, desc

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.permissions import require_any_section_permission
from app.core.auth_middleware import allowed_branches_for_profile
from app.core.models import SupplierRecord
from app.core.schemas import SupplierTransactionModel
from app.core.sync import manager

from typing import Optional
import datetime
import logging


router = APIRouter()


_CATEGORY = "حسابات الموردين"


def _require_any(request: Request, keys):
    return require_any_section_permission(
        request, [(_CATEGORY, key) for key in keys]
    )


def _check_branch(profile: dict, branch_code) -> None:
    allowed = allowed_branches_for_profile(profile)
    if allowed and branch_code and str(branch_code) not in allowed:
        raise HTTPException(
            status_code=403,
            detail="ليس لديك صلاحية على هذا الفرع",
        )
logger = logging.getLogger(__name__)


# ============================================================
# Helper
# ============================================================

def _viewer_may_costs(request) -> bool:
    """نفس حقوق التكلفة الثلاثة: التكويد/سعر الشراء أو عرض سعر
    الجملة في المبيعات أو رصيد المخزون."""
    from app.core.permissions import has_section_permission as _hsp
    return (
        _hsp(request.state.auth_user, "التكويد", "سعر الشراء")
        or _hsp(request.state.auth_user, "المبيعات", "عرض سعر الجملة")
        or _hsp(request.state.auth_user, "رصيد المخزون", "عرض سعر الجملة")
    )


# سعر بند المشتريات وإجمالي السطر وإجمالي الفاتورة مشتقة من
# سعر الجملة: حقوق محمية بصلاحية عرض التكلفة. لا يصل إجمالي
# الفاتورة لجهاز من لا يملك الحق، ويُخفى في الواجهة بدل أي صفر
# مضلل. القيمة الصحيحة محفوظة على الخادم وتُحسب منها التسويات
# لأصحاب الحق فقط.
_SUPPLIER_COST_ITEM_FIELDS = ("price", "total", "discountAmount",
                              "discountRate")
_SUPPLIER_COST_DOC_FIELDS = ("total_amount",)


def serialize_supplier(
    doc: SupplierRecord,
    action: str | None = None,
    include_costs: bool = True,
):
    data = {
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
        "is_add_to_coding": bool(doc.is_add_to_coding),
        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if not include_costs:
        for field in _SUPPLIER_COST_DOC_FIELDS:
            data.pop(field, None)
        if isinstance(data.get("items"), list):
            data["items"] = [
                {
                    k: v for k, v in item.items()
                    if k not in _SUPPLIER_COST_ITEM_FIELDS
                }
                if isinstance(item, dict) else item
                for item in data["items"]
            ]

    if action is not None:
        data["action"] = action

    return data


# ============================================================
# 1. حفظ حركة المورد
#    إضافة أو تحديث
# ============================================================

@router.post("/save")
async def save_supplier_transaction(
    request: Request,
    data: SupplierTransactionModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["اضافة", "تعديل"])
    _check_branch(_profile, data.branch_code)

    try:
        # ------------------------------------------------------
        # التحقق من doc_id
        # ------------------------------------------------------

        doc_id_int = None

        if data.doc_id:
            try:
                doc_id_int = int(data.doc_id)
            except (ValueError, TypeError):
                raise HTTPException(
                    status_code=400,
                    detail=(
                        f"doc_id غير صالح: {data.doc_id}"
                    ),
                )

        # ------------------------------------------------------
        # تحويل الأصناف إلى JSON
        # ------------------------------------------------------

        try:
            items_json = [
                item.model_dump()
                if hasattr(item, "model_dump")
                else item.dict()
                for item in data.items
            ]
        except Exception as e:
            logger.error(
                f"خطأ في تحويل items إلى JSON: {e}"
            )

            raise HTTPException(
                status_code=400,
                detail="بيانات الأصناف غير صالحة",
            )

        # سياسة الأسعار المتبعة في هذا المسار (مطبقة بطلب المالك عبر قناة المحادثة الموثقة بتاريخ ٢٠٢٦-١١-٢١؛ التعليق توثيق للسلوك وليس مستند تفويض بذاته):
        # - من لا يملك أي حق تكلفة: سعر البند من كتالوج التكويد،
        #   وقيم السطور والإجمالي تُحسب منه، وصنف غير معروف يُرفض
        #   برسالة واضحة قبل أي كتابة (ذرّي).
        # - حامل حق التكلفة: يبقى مساره الحالي بأسعاره المدخلة —
        #   لا إعادة تسعير لفواتير تاريخية عند التعديل.
        # - صنف غير معروف لحامل التكلفة: يُقبل فقط مع حق إضافة
        #   التكويد الفعلي (مسار إنشاء الأصناف القائم).
        from app.core.permissions import has_section_permission as _hsp
        _may_costs = _viewer_may_costs(request)
        _may_add_coding = _hsp(
            request.state.auth_user, "التكويد", "اضافة صنف"
        )
        # عند تعديل فاتورة موجودة: أسعار سطورها المخزنة موثوقة
        # وتُحفظ (لا إعادة تسعير للتاريخ)
        # سطور مخزنة لكل كود (قائمة بترتيبها: الكود المكرر في
        # نفس الفاتورة يُطابق سطراً بسطر). تُحفظ الخصومات مع
        # السعر: إسقاطها كان يعيد حساب إجمالي تاريخي بخصم صفر.
        _stored_lines_by_code: dict = {}
        if doc_id_int:
            _cur = await db.execute(
                select(SupplierRecord.items).where(
                    SupplierRecord.id == doc_id_int,
                    SupplierRecord.company_code == data.company_code,
                )
            )
            _stored = _cur.scalar_one_or_none()
            if isinstance(_stored, list):
                for _si in _stored:
                    if isinstance(_si, dict) and _si.get("code"):
                        _stored_lines_by_code.setdefault(
                            str(_si["code"]), []
                        ).append({
                            "price": float(_si.get("price") or 0.0),
                            "discountAmount": float(
                                _si.get("discountAmount") or 0.0
                            ),
                            "discountRate": float(
                                _si.get("discountRate") or 0.0
                            ),
                        })
        _codes = [
            str(item.get("code", ""))
            for item in items_json
            if item.get("code")
        ]
        if _codes and _may_costs and not _may_add_coding:
            # حامل تكلفة بلا حق تكويد: الأصناف لازم تكون موجودة
            from app.core.models import CodingRecord as _CR2
            _known = await db.execute(
                select(_CR2.code).where(
                    _CR2.company_code == data.company_code,
                    _CR2.category == "items",
                    _CR2.code.in_(_codes),
                    _CR2.is_deleted.is_(False),
                )
            )
            _known_codes = {str(c) for (c,) in _known.all()}
            for _c in _codes:
                if _c not in _known_codes:
                    raise HTTPException(
                        status_code=400,
                        detail=(
                            f"الصنف غير موجود في التكويد: {_c}. "
                            "سجّله أولاً من شاشة التكويد بواسطة "
                            "مستخدم مخوّل، ثم أعد حفظ الفاتورة."
                        ),
                    )
        if _codes and not _may_costs:
            from app.core.models import CodingRecord as _CR
            _cost_result = await db.execute(
                select(
                    _CR.code,
                    _CR.wholesale_price,
                    _CR.cost_pending,
                ).where(
                    _CR.company_code == data.company_code,
                    _CR.category == "items",
                    _CR.code.in_(_codes),
                    _CR.is_deleted.is_(False),
                )
            )
            _cost_by_code = {}
            _unset_cost_codes = set()
            for code, price, pending in _cost_result.all():
                _cost_by_code[str(code)] = float(price or 0.0)
                if pending:
                    _unset_cost_codes.add(str(code))
            for item in items_json:
                _code = str(item.get("code", ""))
                if _stored_lines_by_code.get(_code):
                    continue  # سطر مخزن: محفوظ كما هو
                # صنف جديد كلياً ومن لا يملك حق التكلفة لا يمكنه
                # تزويد سعره (حقل السعر مخفي عنه أصلاً): يُسجَّل
                # أولاً من شاشة التكويد، مهما كانت باقي حقوقه —
                # لا سعر صفري مُختلَق يصبح سعر كتالوج.
                if _code not in _cost_by_code:
                    raise HTTPException(
                        status_code=400,
                        detail=(
                            f"الصنف غير موجود في التكويد: {_code}. "
                            "سجّله أولاً من شاشة التكويد، "
                            "ثم أعد حفظ الفاتورة."
                        ),
                    )
            _total = 0.0
            for item in items_json:
                _code = str(item.get("code", ""))
                _queue = _stored_lines_by_code.get(_code)
                if _queue:
                    # سطر مخزن: السعر والخصم المخزنان محفوظان
                    # (تطابق بالترتيب للكود المكرر)
                    _s = _queue.pop(0)
                    item["price"] = _s["price"]
                    item["discountAmount"] = _s["discountAmount"]
                    item["discountRate"] = _s["discountRate"]
                else:
                    # صنف سعره "غير محدد" (أنشأه من لا يملك الحق):
                    # فاتورة عليه بلا سعر سجل مالي خاطئ، والمحرر
                    # هنا لا يرى السعر أصلاً — رفض ذري قبل أي
                    # كتابة (لا حفظ جزئي). الصفر المصرَّح به
                    # (cost_pending=False) قيمة مشروعة تمر.
                    # السطور المخزنة مستثناة (حفظ تاريخي).
                    if _code in _unset_cost_codes:
                        raise HTTPException(
                            status_code=400,
                            detail=(
                                f"الصنف بلا سعر شراء محدد في "
                                f"التكويد: {_code}. حدّد سعر الشراء "
                                "من شاشة التكويد بواسطة مستخدم "
                                "مخوّل، ثم أعد حفظ الفاتورة."
                            ),
                        )
                    item["price"] = _cost_by_code[_code]
                _qty = float(item.get("quantity") or 0.0)
                _price = float(item.get("price") or 0.0)
                _disc = float(item.get("discountAmount") or 0.0)
                item["total"] = _qty * _price - _disc
                _total += item["total"]
            data.total_amount = _total

        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        if doc_id_int:

            stmt = (
                select(SupplierRecord)
                .where(
                    SupplierRecord.id
                    == doc_id_int,

                    SupplierRecord.company_code
                    == data.company_code,
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

        # Resolve the action from the server lookup, not a client action flag.
        _require_any(request, ["تعديل" if existing is not None else "اضافة"])

        if existing:

            # الفرع المخزَّن أيضاً: منع تعديل/نقل سجل فرع غير مسموح
            _check_branch(_profile, existing.branch_code)
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
            existing.is_add_to_coding = data.is_add_to_coding
            existing.updated_at = (
                datetime.datetime.utcnow()
            )

            # لو السجل كان محذوفًا وتم حفظه مرة أخرى
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
                updated_at=datetime.datetime.utcnow(),
                is_add_to_coding=data.is_add_to_coding,
                is_deleted=False,
            )

            db.add(new_record)

            action = "insert"

            record = new_record

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        try:
            await db.commit()
            await db.refresh(record)

        except Exception as e:
            await db.rollback()

            logger.error(
                f"خطأ في حفظ قاعدة البيانات: {e}",
                exc_info=True,
            )

            raise HTTPException(
                status_code=500,
                detail=f"فشل حفظ البيانات: {str(e)}",
            )

        # ------------------------------------------------------
        # WebSocket
        # ------------------------------------------------------

        try:
            await manager.broadcast(
                data.company_code,
                {
                    "type": "supplier",
                    "action": action,
                    "data": serialize_supplier(
                        record,
                        action=action,
                    ),
                },
            )

        except Exception as e:
            logger.warning(
                f"فشل بث WebSocket: {e}"
            )

        # ------------------------------------------------------
        # Response
        # ------------------------------------------------------

        return {
            "status": "success",
            "doc_id": str(record.id),
            "action": action,
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            "خطأ غير متوقع في "
            "save_supplier_transaction: "
            f"{e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=f"خطأ داخلي: {str(e)}",
        )


# ============================================================
# 2. جلب قائمة حركات الموردين
#
# المحذوف لا يظهر
# ============================================================

@router.get("/list/{company_code}")
async def list_supplier_transactions(
    request: Request,
    company_code: str,
    branch_code: Optional[str] = Query(None),
    supplier_name: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None),
    end_date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["معاينة", "اضافة"])

    try:
        stmt = (
            select(SupplierRecord)
            .where(
                SupplierRecord.company_code
                == company_code,

                SupplierRecord.is_deleted.is_(False),
            )
        )

        if branch_code and branch_code.lower() not in {"all", "الكل", "كل الفروع"}:
            stmt = stmt.where(
                SupplierRecord.branch_code
                == branch_code
            )

        if supplier_name:
            stmt = stmt.where(
                SupplierRecord.supplier_name
                == supplier_name
            )

        if start_date:
            stmt = stmt.where(
                SupplierRecord.date
                >= start_date
            )

        if end_date:
            stmt = stmt.where(
                SupplierRecord.date
                <= end_date
            )

        stmt = stmt.order_by(
            desc(SupplierRecord.date),
            desc(SupplierRecord.serial),
        )

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(SupplierRecord.branch_code.in_(allowed_branches))

        result = await db.execute(stmt)

        docs = result.scalars().all()

        _may = _viewer_may_costs(request)
        results = [
            serialize_supplier(doc, include_costs=_may)
            for doc in docs
        ]

        return results

    except Exception as e:
        logger.error(
            f"خطأ في list_supplier_transactions: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# 3. جلب التحديثات التزايدية للموردين
#
# مهم:
# المحذوفات لا يتم استبعادها.
# ============================================================

@router.get("/changes-v2/{company_code}")
async def get_supplier_changes_v2(
    request: Request,
    company_code: str,
    cursor: str = Query("0:0"),
    limit: int = Query(200, ge=1, le=500),
    scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    """EXPERIMENT. Same permission, branch filter and cost projection as /changes; needs migration 004."""
    from app.core import feed_v2
    from app.core.changes_v2 import feed_epoch, bootstrap_cursor, parse_cursor
    import hashlib, json
    _profile = _require_any(request, ["معاينة", "اضافة"])
    allowed = allowed_branches_for_profile(request.state.auth_user)
    costs = bool(_viewer_may_costs(request))
    epoch = await feed_epoch(db, "supplier")
    fp = hashlib.sha256(json.dumps({"co": company_code, "epoch": epoch, "costs": costs,
                                    "branches": sorted(allowed or [])}, sort_keys=True).encode()).hexdigest()[:16]
    if cursor == "latest":
        return {"invalid": False, "items": [], "has_more": False, "scope": fp, "epoch": epoch,
                "next_cursor": await bootstrap_cursor(db)}
    if scope and scope != fp:
        return {"invalid": True, "reason": "scope", "items": [], "has_more": False,
                "next_cursor": cursor, "scope": fp, "epoch": epoch}
    try:
        parse_cursor(cursor)
    except Exception:
        raise HTTPException(status_code=400, detail="bad cursor")
    visibility = SupplierRecord.branch_code.in_(allowed) if allowed else true()
    out = await feed_v2.fetch(
        db, SupplierRecord, "supplier_records", company_code, cursor, limit, visibility, allowed,
        lambda d: serialize_supplier(d, include_costs=costs, action=("delete" if d.is_deleted else "update")),
        lambda d: {"doc_id": str(d.id), "company_code": d.company_code, "serial": d.serial, "action": "delete",
                   "tombstone": True, "updated_at": d.updated_at.isoformat() if d.updated_at else None})
    out["scope"] = fp
    out["epoch"] = epoch
    return out


@router.get("/changes/{company_code}")
async def get_supplier_changes(
    request: Request,
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
    _profile = _require_any(request, ["معاينة", "اضافة"])

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
        # UTC
        #
        # updated_at = TIMESTAMP WITHOUT TIME ZONE
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
        # بما فيها المحذوف.
        # ------------------------------------------------------

        stmt = (
            select(SupplierRecord)
            .where(
                SupplierRecord.company_code
                == company_code,

                SupplierRecord.updated_at
                >= since_dt,
            )
            .order_by(
                SupplierRecord.updated_at
            )
        )

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(SupplierRecord.branch_code.in_(allowed_branches))

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        for doc in docs:

            if doc.is_deleted:
                action = "delete"
            else:
                action = "update"

            results.append(
                serialize_supplier(
                    doc,
                    include_costs=_viewer_may_costs(request),
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
# 4. حذف حركة مورد
#
# Soft Delete
# ============================================================

@router.delete(
    "/delete/{company_code}/{doc_id}"
)
async def delete_supplier_transaction(
    request: Request,
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["حذف"])

    try:
        # ------------------------------------------------------
        # تحويل doc_id
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
            select(SupplierRecord)
            .where(
                SupplierRecord.id
                == doc_id_int,

                SupplierRecord.company_code
                == company_code,
            )
        )

        result = await db.execute(stmt)

        existing = result.scalar_one_or_none()

        if not existing:
            raise HTTPException(
                status_code=404,
                detail="Supplier record not found",
            )
        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches and existing.branch_code not in allowed_branches:
            raise HTTPException(status_code=403, detail="غير مسموح بالوصول إلى هذا الفرع")

        # ------------------------------------------------------
        # لو محذوف بالفعل
        # ------------------------------------------------------

        if existing.is_deleted:
            return {
                "status": "success",
                "message": (
                    "حركة المورد محذوفة بالفعل"
                ),
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
        # بث الحذف للأجهزة المتصلة
        # ------------------------------------------------------

        await manager.broadcast(
            company_code,
            {
                "type": "supplier",
                "action": "delete",
                "data": {
                    "doc_id": str(existing.id),
                    "company_code":
                        existing.company_code,
                    "branch_code":
                        existing.branch_code,
                    "store_code":
                        existing.store_code,
                    "serial":
                        existing.serial,
                    "date":
                        existing.date,
                    "supplier_name":
                        existing.supplier_name,
                    "payment_method":
                        existing.payment_method,
                    "treasury":
                        existing.treasury,
                    "is_add_to_store":
                        existing.is_add_to_store,
                    "employee":
                        existing.employee,
                    "items":
                        existing.items,
                    "total_amount":
                        existing.total_amount,
                    "paid_amount":
                        existing.paid_amount,
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
            "message": (
                "تم حذف حركة المورد بنجاح"
            ),
            "doc_id": str(existing.id),
        }

    except HTTPException:
        raise

    except Exception as e:
        await db.rollback()

        logger.error(
            f"خطأ في delete_supplier_transaction: {e}",
            exc_info=True,
        )

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )