# backend/app/routes/inventory.py

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.permissions import require_any_section_permission
from app.core.auth_middleware import allowed_branches_for_profile
from app.core.models import InventoryRecord
from app.core.schemas import InventoryModel
from app.core.sync import manager

from typing import Optional
import datetime
import logging


router = APIRouter()


_CATEGORY = "حركة الجرد"


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
    """نفس حقوق التكلفة الثلاثة المستخدمة عند الحفظ."""
    from app.core.permissions import has_section_permission as _hsp
    return (
        _hsp(request.state.auth_user, "التكويد", "سعر الشراء")
        or _hsp(request.state.auth_user, "المبيعات", "عرض سعر الجملة")
        or _hsp(request.state.auth_user, "رصيد المخزون", "عرض سعر الجملة")
    )


_COST_ITEM_FIELDS = ("wholesalePrice", "wholesaleValue")


def serialize_inventory(
    doc: InventoryRecord,
    action: str | None = None,
    include_costs: bool = True,
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
        "employee": doc.employee or "غير محدد",
        "updated_at": (
            doc.updated_at.isoformat()
            if doc.updated_at
            else None
        ),
        "is_deleted": bool(doc.is_deleted),
    }

    if not include_costs:
        # من ليس له حق التكلفة لا تصله أسعار/قيم الجملة في أي مسلسل
        data.pop("total_wholesale", None)
        if isinstance(data.get("items"), list):
            data["items"] = [
                {
                    k: v for k, v in item.items()
                    if k not in _COST_ITEM_FIELDS
                }
                if isinstance(item, dict) else item
                for item in data["items"]
            ]

    if action is not None:
        data["action"] = action

    return data


# ============================================================
# 1. حفظ الجرد
#    إضافة أو تحديث
# ============================================================

@router.post("/save")
async def save_inventory(
    request: Request,
    data: InventoryModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["اضافة", "تعديل"])
    _check_branch(_profile, data.branch_code)

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

        # سياسة الأسعار المتبعة في هذا المسار (مطبقة بطلب المالك عبر قناة المحادثة الموثقة بتاريخ ٢٠٢٦-١١-٢١؛ التعليق توثيق للسلوك وليس مستند تفويض بذاته):
        # - من لا يملك أي حق تكلفة: أسعار الجملة من كتالوج التكويد
        #   دائماً، لا يصله سعر جملة، وصنف غير معروف يُرفض برسالة
        #   واضحة قبل أي كتابة (ذرّي).
        # - حامل حق التكلفة: يبقى سلوكه الحالي (سعره المدخل محفوظ)
        #   فلا يُعاد تسعير سجلات تاريخية ولا يتغير مساره.
        # - صنف غير معروف لحامل التكلفة: يُقبل فقط لو معه حق إضافة
        #   التكويد الفعلي (مسار إنشاء الأصناف القائم)، وإلا يُرفض.
        from app.core.permissions import has_section_permission as _hsp
        _may_costs = (
            _hsp(request.state.auth_user, "التكويد", "سعر الشراء")
            or _hsp(request.state.auth_user, "المبيعات", "عرض سعر الجملة")
            or _hsp(request.state.auth_user, "رصيد المخزون", "عرض سعر الجملة")
        )
        _may_add_coding = _hsp(
            request.state.auth_user, "التكويد", "اضافة صنف"
        )
        # عند تعديل سجل موجود: أسعار سطوره المخزنة موثوقة وتُحفظ
        # (لا إعادة تسعير للتاريخ). سعر الكتالوج يُفرض فقط على
        # السطور الجديدة لمن لا يملك حق التكلفة.
        _stored_price_by_code = {}
        if doc_id_int:
            _cur = await db.execute(
                select(InventoryRecord.items).where(
                    InventoryRecord.id == doc_id_int,
                    InventoryRecord.company_code == data.company_code,
                )
            )
            _stored = _cur.scalar_one_or_none()
            if isinstance(_stored, list):
                for _si in _stored:
                    if isinstance(_si, dict) and _si.get("code"):
                        _stored_price_by_code[str(_si["code"])] = float(
                            _si.get("wholesalePrice") or 0.0
                        )
        _codes = [
            str(item.get("code", ""))
            for item in items_json
            if item.get("code")
        ]
        _cost_by_code = {}
        if _codes:
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
        _total_wholesale = 0.0
        _total_retail = 0.0
        for item in items_json:
            _code = str(item.get("code", ""))
            _qty = float(item.get("quantity") or 0.0)
            _retail = float(item.get("retailPrice") or 0.0)
            if _code in _stored_price_by_code and not _may_costs:
                # سطر موجود مسبقاً ولا حق تكلفة للمحرر: السعر
                # المخزن محفوظ (لا إعادة تسعير ولا تحكم بالتكلفة).
                # حامل حق التكلفة يُحترم سعره المدخل حتى عند التعديل
                # (السلوك الأصلي)، فيقدر يصحح سعر سطر قائم.
                _wholesale = _stored_price_by_code[_code]
            elif _code in _cost_by_code:
                if _may_costs:
                    _wholesale = float(item.get("wholesalePrice") or 0.0)
                else:
                    # سعر "غير محدد" (cost_pending) ومحرر لا يرى
                    # الأسعار: إذن بقيمة غير محددة سجل مالي خاطئ
                    # — رفض ذري قبل أي كتابة. الصفر المصرَّح به
                    # يمر كقيمة مشروعة. السطور المخزنة مستثناة.
                    if _code in _unset_cost_codes:
                        raise HTTPException(
                            status_code=400,
                            detail=(
                                f"الصنف بلا سعر شراء محدد في "
                                f"التكويد: {_code}. حدّد سعر الشراء "
                                "من شاشة التكويد بواسطة مستخدم "
                                "مخوّل، ثم أعد إدخال الإذن."
                            ),
                        )
                    _wholesale = _cost_by_code[_code]
            else:
                # صنف جديد كلياً: يُقبل بسعره المدخل فقط ممن
                # يملك حق التكلفة مع حق إضافة التكويد معاً. من
                # لا يرى سعر الجملة لا يمكنه تزويد سعر شرعي
                # (حقله مخفي)، فيُسجِّل الصنف أولاً من شاشة
                # التكويد — لا سعر صفري مُختلَق يصبح كتالوجاً.
                if not (_may_add_coding and _may_costs):
                    raise HTTPException(
                        status_code=400,
                        detail=(
                            f"الصنف غير موجود في التكويد: {_code}. "
                            "سجّله أولاً من شاشة التكويد، "
                            "ثم أعد إدخال الإذن."
                        ),
                    )
                _wholesale = float(item.get("wholesalePrice") or 0.0)
            item["wholesalePrice"] = _wholesale
            item["wholesaleValue"] = _wholesale * _qty
            item["retailValue"] = _retail * _qty
            _total_wholesale += item["wholesaleValue"]
            _total_retail += item["retailValue"]
        data.total_wholesale = _total_wholesale
        data.total_retail = _total_retail

        # ------------------------------------------------------
        # البحث عن السجل
        # ------------------------------------------------------

        if doc_id_int:
            stmt = (
                select(InventoryRecord)
                .where(
                    InventoryRecord.id
                    == doc_id_int,
                    InventoryRecord.company_code == data.company_code,
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
            # ✅ لا يوجد doc_id → جرد جديد
            # لكن قبل الإنشاء، تحقق إن كان هناك جرد نشط بنفس المفتاح
            stmt = (
                select(InventoryRecord)
                .where(
                    InventoryRecord.company_code == data.company_code,
                    InventoryRecord.branch_code == data.branch_code,
                    InventoryRecord.store_code == data.store_code,
                    InventoryRecord.date == data.date,
                    InventoryRecord.is_deleted.is_(False),
                )
            )

            result = await db.execute(stmt)
            conflicting = result.scalar_one_or_none()

            if conflicting:
                raise HTTPException(
                    status_code=409,
                    detail={
                        "code": "INVENTORY_EXISTS",
                        "message": "يوجد جرد بالفعل لهذا التاريخ بنفس الفرع والمخزن",
                        "existing_doc_id": str(conflicting.id),
                        "existing_serial": conflicting.serial,
                        "existing_date": conflicting.date,
                    },
                )

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
            existing.date = data.date
            existing.inventory_type = data.inventory_type
            existing.items = items_json
            existing.total_wholesale = data.total_wholesale
            existing.total_retail = data.total_retail
            existing.serial = data.serial
            existing.employee = data.employee

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
                employee=data.employee,
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
    request: Request,
    company_code: str,
    branch_code: Optional[str] = Query(None),
    store_code: Optional[str] = Query(None),
    date: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["معاينة", "اضافة"])

    try:
        stmt = (
            select(InventoryRecord)
            .where(
                InventoryRecord.company_code
                == company_code,

                InventoryRecord.is_deleted.is_(False),
            )
        )

        if branch_code and branch_code.lower() not in {"all", "الكل", "كل الفروع"}:
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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(InventoryRecord.branch_code.in_(allowed_branches))

        result = await db.execute(stmt)

        docs = result.scalars().all()

        _may = _viewer_may_costs(request)
        results = [
            serialize_inventory(doc, include_costs=_may)
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

@router.get("/changes-v2/{company_code}")
async def get_inventory_changes_v2(
    request: Request,
    company_code: str,
    cursor: str = Query("0:0"),
    limit: int = Query(200, ge=1, le=500),
    scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    """EXPERIMENT. Same permission, branch filter and cost projection as /changes; needs migration 006."""
    from app.core import feed_v2
    from app.core.changes_v2 import feed_epoch, bootstrap_cursor, parse_cursor
    from sqlalchemy import true
    import hashlib, json
    _profile = _require_any(request, ["معاينة", "اضافة"])
    allowed = allowed_branches_for_profile(request.state.auth_user)
    costs = bool(_viewer_may_costs(request))
    epoch = await feed_epoch(db, "inventory")
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
    M = InventoryRecord
    visibility = M.branch_code.in_(allowed) if allowed else true()
    out = await feed_v2.fetch(
        db, M, "inventory_records", company_code, cursor, limit, visibility, allowed,
        lambda d: serialize_inventory(d, include_costs=costs, action=("delete" if d.is_deleted else "update")),
        lambda d: {"doc_id": str(d.id), "company_code": d.company_code, "serial": d.serial, "action": "delete",
                   "tombstone": True, "updated_at": d.updated_at.isoformat() if d.updated_at else None})
    out["scope"] = fp
    out["epoch"] = epoch
    return out


@router.get("/changes/{company_code}")
async def get_inventory_changes(
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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(InventoryRecord.branch_code.in_(allowed_branches))

        result = await db.execute(stmt)

        docs = result.scalars().all()

        results = []

        _may = _viewer_may_costs(request)
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
                    include_costs=_may,
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
    request: Request,
    company_code: str,
    doc_id: str,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["حذف"])

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
        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches and existing.branch_code not in allowed_branches:
            raise HTTPException(status_code=403, detail="غير مسموح بالوصول إلى هذا الفرع")

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