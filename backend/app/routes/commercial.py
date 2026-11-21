"""Sales, customer receipts, returns and stock transfers.

These records intentionally do not create entries in the legacy daily journal.
"""
from datetime import datetime
from datetime import timezone
from typing import Any
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.models import CodingRecord, SaleRecord, SaleReturnRecord, CustomerPaymentRecord, StockTransferRecord
from app.core.schemas import SaleModel, SaleReturnModel, CustomerPaymentModel, StockTransferModel
from app.core.sync import manager

router = APIRouter()

CONFIG = {
    "sales": (SaleRecord, SaleModel, "المبيعات", "sale", "branch_code"),
    "returns": (SaleReturnRecord, SaleReturnModel, "المرتجعات", "sale_return", "branch_code"),
    "customer-payments": (CustomerPaymentRecord, CustomerPaymentModel, "حسابات العملاء", "customer_payment", "branch_code"),
    "transfers": (StockTransferRecord, StockTransferModel, "التحويلات المخزنية", "stock_transfer", "from_branch_code"),
}

# الأنواع التي يخدمها هذا الراوتر بعد فصل التحويلات في routes/transfers.py.
# CONFIG يحتفظ بالتحويلات لأن الصلاحيات والتجميعات تشاركه.
_ROUTE_KINDS = ("sales", "returns", "customer-payments")


def _role(profile: dict[str, Any]) -> str:
    return str(profile.get("role") or "employee")


def _check_permission(request: Request, kind: str, action: str) -> dict:
    profile = request.state.auth_user
    if _role(profile) in {"admin", "super_admin"}:
        return profile
    category = CONFIG[kind][2]
    perms = profile.get("permissions") if isinstance(profile.get("permissions"), dict) else {}
    section = perms.get(category) if isinstance(perms.get(category), dict) else {}
    aliases = {"add": "إضافة", "edit": "تعديل", "delete": "حذف", "view": "معاينة"}
    if kind == "customer-payments":
        aliases["add"] = "إضافة تحصيل"
        aliases["edit"] = "تعديل تحصيل"
        aliases["delete"] = "حذف تحصيل"
    key = aliases.get(action, action)
    if section.get(key) is not True:
        raise HTTPException(status_code=403, detail=f"ليس لديك صلاحية {key} في {category}")
    return profile


def _check_branches(profile: dict, branches: list[str]) -> None:
    allowed = allowed_branches_for_profile(profile)
    if allowed and any(str(branch) not in allowed for branch in branches if branch):
        raise HTTPException(status_code=403, detail="غير مسموح بالوصول إلى هذا الفرع")


def _serialize(record: Any, action: str | None = None) -> dict:
    result = {column.name: getattr(record, column.name) for column in record.__table__.columns}
    if result.get("updated_at"):
        result["updated_at"] = result["updated_at"].isoformat()
    result["is_deleted"] = bool(result.get("is_deleted"))
    if action:
        result["action"] = action
    return result


def _query(kind: str, company_code: str):
    model = CONFIG[kind][0]
    return select(model).where(model.company_code == company_code, model.is_deleted.is_(False))


def _timestamp(value: datetime | str | None) -> datetime | None:
    if value is None:
        return None
    parsed = value if isinstance(value, datetime) else datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


@router.post("/{kind}/save")
async def save_record(kind: str, request: Request, db: AsyncSession = Depends(get_db)):
    if kind not in _ROUTE_KINDS:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    return await save_kind(kind, request, db)


async def save_kind(kind: str, request: Request, db: AsyncSession):
    if kind not in CONFIG:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    raw = await request.json()
    record_model, schema, _, event_type, branch_field = CONFIG[kind]
    data = schema.model_validate(raw)
    existing = await db.get(record_model, data.id)
    if existing and existing.company_code != data.company_code:
        raise HTTPException(status_code=404, detail="الحركة غير موجودة")
    if existing and existing.is_deleted:
        raise HTTPException(status_code=404, detail="الحركة محذوفة")
    is_edit = existing is not None and existing.company_code == data.company_code and not existing.is_deleted
    if is_edit and data.base_updated_at:
        try:
            if _timestamp(data.base_updated_at) != _timestamp(existing.updated_at):
                raise HTTPException(status_code=409, detail="تم تعديل هذا السجل من مستخدم آخر. حدّث البيانات ثم أعد التعديل.")
        except ValueError:
            raise HTTPException(status_code=400, detail="تاريخ النسخة المراد تعديلها غير صالح")
    profile = _check_permission(request, kind, "edit" if is_edit else "add")
    if is_edit:
        old_branches = [existing.from_branch_code, existing.to_branch_code] if kind == "transfers" else [getattr(existing, branch_field)]
        _check_branches(profile, old_branches)
    if kind == "transfers":
        _check_branches(profile, [data.from_branch_code, data.to_branch_code])
        if data.from_branch_code == data.to_branch_code and data.from_store_code == data.to_store_code:
            raise HTTPException(status_code=400, detail="اختر مخزنين مختلفين للتحويل")
    else:
        _check_branches(profile, [getattr(data, branch_field)])
    if kind == "sales":
        if data.total < 0 or data.paid < 0 or data.due < 0 or data.paid - data.total > 0.01:
            raise HTTPException(status_code=400, detail="مبالغ الفاتورة غير صحيحة")
        if data.discount < 0 or any(float(i.get("quantity", 0) or 0) <= 0 or float(i.get("price", 0) or 0) < 0 for i in data.items):
            raise HTTPException(status_code=400, detail="كميات أو أسعار الأصناف غير صحيحة")
        calculated_subtotal = sum(float(i.get("quantity", 0) or 0) * float(i.get("price", 0) or 0) for i in data.items)
        if abs(data.subtotal - calculated_subtotal) > 0.02 or abs(data.total - max(data.subtotal - data.discount, 0.0)) > 0.02:
            raise HTTPException(status_code=400, detail="إجمالي الفاتورة لا يطابق تفاصيل الأصناف والخصم")
        if abs(data.total - data.paid - data.due) > 0.02:
            raise HTTPException(status_code=400, detail="الباقي لا يساوي الإجمالي بعد خصم المدفوع")
        if abs(sum(float(p.get("amount", 0) or 0) for p in data.payments) - data.paid) > 0.02:
            raise HTTPException(status_code=400, detail="إجمالي طرق الدفع لا يساوي المدفوع")
        old_sale = existing if isinstance(existing, SaleRecord) else None
        if old_sale and old_sale.company_code == data.company_code:
            linked_returns = (await db.execute(select(SaleReturnRecord).where(SaleReturnRecord.company_code == data.company_code, SaleReturnRecord.sale_id == data.id, SaleReturnRecord.is_deleted.is_(False)))).scalars().all()
            if linked_returns and (old_sale.customer_code != data.customer_code or old_sale.branch_code != data.branch_code or old_sale.store_code != data.store_code):
                raise HTTPException(status_code=400, detail="لا يمكن تغيير العميل أو الفرع أو المخزن بعد تسجيل مرتجع مرتبط بالفاتورة")
            quantities: dict[str, float] = {}
            for item in data.items:
                code = str(item.get("code", ""))
                quantities[code] = quantities.get(code, 0.0) + float(item.get("quantity", 0) or 0)
            returned_quantities: dict[str, float] = {}
            for returned in linked_returns:
                for item in returned.items or []:
                    code = str(item.get("code", ""))
                    returned_quantities[code] = returned_quantities.get(code, 0.0) + float(item.get("quantity", 0) or 0)
            if any(qty > quantities.get(code, 0.0) + 0.0001 for code, qty in returned_quantities.items()):
                raise HTTPException(status_code=400, detail="لا يمكن تقليل كمية صنف عن الكمية التي تم إرجاعها")
        sales_permissions = profile.get("permissions") if isinstance(profile.get("permissions"), dict) else {}
        sales_section = sales_permissions.get("المبيعات") if isinstance(sales_permissions.get("المبيعات"), dict) else {}
        can_change_price = _role(profile) in {"admin", "super_admin"} or sales_section.get("تغيير سعر البيع") is True
        if not can_change_price:
            previous_prices = {}
            if old_sale:
                previous_prices = {str(item.get("code", "")): float(item.get("price", 0) or 0) for item in old_sale.items or []}
            item_codes = {str(item.get("code", "")) for item in data.items}
            catalog_rows = (await db.execute(select(CodingRecord).where(CodingRecord.company_code == data.company_code, CodingRecord.category == "items", CodingRecord.code.in_(item_codes), CodingRecord.is_deleted.is_(False)))).scalars().all() if item_codes else []
            catalog_prices = {row.code: float(row.selling_price or 0) for row in catalog_rows}
            for item in data.items:
                code = str(item.get("code", ""))
                expected_price = previous_prices.get(code, catalog_prices.get(code))
                if expected_price is None or abs(float(item.get("price", 0) or 0) - expected_price) > 0.001:
                    raise HTTPException(status_code=403, detail="ليس لديك صلاحية تغيير سعر البيع")
    elif kind == "returns":
        calculated_total = sum(float(i.get("quantity", 0) or 0) * float(i.get("price", 0) or 0) for i in data.items)
        if data.total < 0 or any(float(i.get("quantity", 0) or 0) <= 0 or float(i.get("price", 0) or 0) < 0 for i in data.items) or abs(data.total - calculated_total) > 0.02:
            raise HTTPException(status_code=400, detail="بيانات المرتجع غير صحيحة")
        if data.sale_id:
            outstanding_q = select(SaleRecord).where(SaleRecord.company_code == data.company_code, SaleRecord.customer_code == data.customer_code, SaleRecord.date <= data.date, SaleRecord.is_deleted.is_(False))
            if data.branch_code:
                outstanding_q = outstanding_q.where(SaleRecord.branch_code == data.branch_code)
            outstanding_sales = (await db.execute(outstanding_q)).scalars().all()
            outstanding = sum(sale.due for sale in outstanding_sales)
            receipts_q = select(CustomerPaymentRecord).where(CustomerPaymentRecord.company_code == data.company_code, CustomerPaymentRecord.customer_code == data.customer_code, CustomerPaymentRecord.date <= data.date, CustomerPaymentRecord.is_deleted.is_(False))
            if data.branch_code:
                receipts_q = receipts_q.where(CustomerPaymentRecord.branch_code == data.branch_code)
            receipts = (await db.execute(receipts_q)).scalars().all()
            outstanding -= sum(row.amount for row in receipts)
            existing_returns_q = select(SaleReturnRecord).where(SaleReturnRecord.company_code == data.company_code, SaleReturnRecord.customer_code == data.customer_code, SaleReturnRecord.date <= data.date, SaleReturnRecord.is_deleted.is_(False))
            if data.branch_code:
                existing_returns_q = existing_returns_q.where(SaleReturnRecord.branch_code == data.branch_code)
            if data.serial:
                existing_returns_q = existing_returns_q.where(SaleReturnRecord.serial != data.serial)
            existing_returns = (await db.execute(existing_returns_q)).scalars().all()
            outstanding -= sum(row.credit_amount for row in existing_returns)
            if data.settlement_mode == "credit_first":
                data.credit_amount = min(data.total, max(outstanding, 0.0))
            elif data.settlement_mode == "cash_refund":
                data.credit_amount = 0.0
            else:
                raise HTTPException(status_code=400, detail="قاعدة تسوية المرتجع غير معروفة")
            data.refund_amount = max(data.total - data.credit_amount, 0.0)
        else:
            data.credit_amount = 0.0
            data.refund_amount = data.total
        if abs(sum(float(p.get("amount", 0) or 0) for p in data.payments) - data.refund_amount) > 0.02:
            raise HTTPException(status_code=400, detail="توزيع المبلغ المصروف من الخزينة غير صحيح")
        if data.sale_id:
            sale = await db.get(SaleRecord, data.sale_id)
            if not sale or sale.company_code != data.company_code or sale.is_deleted:
                raise HTTPException(status_code=400, detail="فاتورة البيع الأصلية غير موجودة")
            if sale.branch_code != data.branch_code or sale.customer_code != data.customer_code:
                raise HTTPException(status_code=400, detail="يجب أن يتبع المرتجع فرع وعميل فاتورة البيع الأصلية")
            previous_q = select(SaleReturnRecord).where(
                SaleReturnRecord.company_code == data.company_code,
                SaleReturnRecord.sale_id == data.sale_id,
                SaleReturnRecord.is_deleted.is_(False),
            )
            if data.serial:
                previous_q = previous_q.where(SaleReturnRecord.serial != data.serial)
            previous = (await db.execute(previous_q)).scalars().all()
            returned_qty: dict[str, float] = {}
            for old in previous:
                for item in old.items or []:
                    code = str(item.get("code", ""))
                    returned_qty[code] = returned_qty.get(code, 0.0) + float(item.get("quantity", 0) or 0)
            sale_qty: dict[str, float] = {}
            for item in sale.items or []:
                code = str(item.get("code", ""))
                sale_qty[code] = sale_qty.get(code, 0.0) + float(item.get("quantity", 0) or 0)
            for item in data.items:
                code = str(item.get("code", ""))
                requested = float(item.get("quantity", 0) or 0)
                if requested > sale_qty.get(code, 0.0) - returned_qty.get(code, 0.0) + 0.0001:
                    raise HTTPException(status_code=400, detail=f"الكمية المرتجعة أكبر من الكمية المتبقية للصنف {code}")
    elif kind == "customer-payments":
        if data.amount <= 0 or abs(sum(float(p.get("amount", 0) or 0) for p in data.payments) - data.amount) > 0.02:
            raise HTTPException(status_code=400, detail="مبلغ التحصيل أو توزيع طرق الدفع غير صحيح")
    elif kind == "transfers" and any(float(i.get("quantity", 0) or 0) <= 0 for i in data.items):
        raise HTTPException(status_code=400, detail="كميات التحويل يجب أن تكون أكبر من صفر")
    try:
        values = data.model_dump()
        values.pop("base_updated_at", None)
        if values.get("serial", 0) <= 0:
            if existing:
                values["serial"] = existing.serial
            else:
                branch_value = getattr(data, branch_field)
                serial_field = record_model.serial
                stmt = select(func.max(serial_field)).where(record_model.company_code == data.company_code)
                if kind != "transfers":
                    stmt = stmt.where(getattr(record_model, branch_field) == branch_value)
                last = await db.scalar(stmt)
                values["serial"] = int(last or 0) + 1
        if existing:
            for key, value in values.items():
                setattr(existing, key, value)
            existing.is_deleted = False
            existing.updated_at = datetime.utcnow()
            record = existing
            action = "update"
        else:
            record = record_model(**values, is_deleted=False, updated_at=datetime.utcnow())
            db.add(record)
            action = "insert"
        await db.commit()
        await db.refresh(record)
        serialized = _serialize(record, action)
        await manager.broadcast(data.company_code, {"type": event_type, "action": action, "data": serialized})
        return {"status": "success", "id": record.id, "serial": record.serial,
                "updated_at": serialized.get("updated_at"), "action": action}
    except HTTPException:
        await db.rollback()
        raise
    except Exception as exc:
        await db.rollback()
        raise HTTPException(status_code=500, detail=str(exc))


@router.get("/{kind}/list/{company_code}")
async def list_records(
    kind: str, company_code: str, request: Request,
    branch_code: str | None = Query(default=None),
    from_date: str | None = Query(default=None), to_date: str | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    if kind not in _ROUTE_KINDS:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    return await list_kind(kind, company_code, request, branch_code, from_date, to_date, db)


async def list_kind(
    kind: str, company_code: str, request: Request,
    branch_code: str | None, from_date: str | None, to_date: str | None,
    db: AsyncSession,
):
    if kind not in CONFIG:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    profile = _check_permission(request, kind, "view")
    model = CONFIG[kind][0]
    stmt = _query(kind, company_code)
    allowed = allowed_branches_for_profile(profile)
    if kind == "transfers":
        if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
            _check_branches(profile, [branch_code])
            stmt = stmt.where((model.from_branch_code == branch_code) | (model.to_branch_code == branch_code))
        elif allowed:
            stmt = stmt.where((model.from_branch_code.in_(allowed)) | (model.to_branch_code.in_(allowed)))
        date_col = model.date
    else:
        if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
            _check_branches(profile, [branch_code])
            stmt = stmt.where(model.branch_code == branch_code)
        elif allowed:
            stmt = stmt.where(model.branch_code.in_(allowed))
        date_col = model.date
    if from_date:
        stmt = stmt.where(date_col >= from_date)
    if to_date:
        stmt = stmt.where(date_col <= to_date)
    result = await db.execute(stmt.order_by(model.date.desc(), model.serial.desc()))
    return [_serialize(record) for record in result.scalars().all()]


@router.get("/{kind}/changes/{company_code}")
async def changed_records(kind: str, company_code: str, request: Request, since: str, db: AsyncSession = Depends(get_db)):
    if kind not in _ROUTE_KINDS:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    return await changes_kind(kind, company_code, request, since, db)


async def changes_kind(kind: str, company_code: str, request: Request, since: str, db: AsyncSession):
    if kind not in CONFIG:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    profile = _check_permission(request, kind, "view")
    model = CONFIG[kind][0]
    try:
        timestamp = datetime.fromisoformat(since.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        raise HTTPException(status_code=400, detail="تاريخ المزامنة غير صالح")
    stmt = select(model).where(model.company_code == company_code, model.updated_at >= timestamp)
    allowed = allowed_branches_for_profile(profile)
    if allowed:
        if kind == "transfers":
            stmt = stmt.where((model.from_branch_code.in_(allowed)) | (model.to_branch_code.in_(allowed)))
        else:
            stmt = stmt.where(model.branch_code.in_(allowed))
    result = await db.execute(stmt.order_by(model.updated_at.asc()))
    return [_serialize(record, "delete" if record.is_deleted else "update") for record in result.scalars().all()]


@router.post("/{kind}/delete/{company_code}/{record_id}")
async def delete_record(kind: str, company_code: str, record_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    if kind not in _ROUTE_KINDS:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    return await delete_kind(kind, company_code, record_id, request, db)


async def delete_kind(kind: str, company_code: str, record_id: str, request: Request, db: AsyncSession):
    if kind not in CONFIG:
        raise HTTPException(status_code=404, detail="نوع حركة غير معروف")
    model, _, _, event_type, branch_field = CONFIG[kind]
    profile = _check_permission(request, kind, "delete")
    record = await db.get(model, record_id)
    if not record or record.is_deleted or record.company_code != company_code:
        raise HTTPException(status_code=404, detail="الحركة غير موجودة")
    if kind == "sales":
        linked = await db.scalar(select(func.count()).select_from(SaleReturnRecord).where(SaleReturnRecord.company_code == company_code, SaleReturnRecord.sale_id == record_id, SaleReturnRecord.is_deleted.is_(False)))
        if linked:
            raise HTTPException(status_code=400, detail="احذف المرتجعات المرتبطة بالفاتورة أولًا قبل حذفها")
    branches = [record.from_branch_code, record.to_branch_code] if kind == "transfers" else [getattr(record, branch_field)]
    _check_branches(profile, branches)
    record.is_deleted = True
    record.updated_at = datetime.utcnow()
    await db.commit()
    await db.refresh(record)
    serialized = _serialize(record, "delete")
    await manager.broadcast(record.company_code, {"type": event_type, "action": "delete", "data": serialized})
    return {"status": "success", "id": record_id}


def _check_extra_permission(request: Request, category: str, key: str) -> dict:
    profile = request.state.auth_user
    if _role(profile) in {"admin", "super_admin"}:
        return profile
    permissions = profile.get("permissions") if isinstance(profile.get("permissions"), dict) else {}
    section = permissions.get(category) if isinstance(permissions.get(category), dict) else {}
    if section.get(key) is not True:
        raise HTTPException(status_code=403, detail=f"ليس لديك صلاحية {key} في {category}")
    return profile


@router.get("/returnable/{company_code}/{sale_id}")
async def returnable_sale(company_code: str, sale_id: str, request: Request, to_date: str | None = Query(default=None), exclude_return_id: str | None = Query(default=None), db: AsyncSession = Depends(get_db)):
    profile = request.state.auth_user
    if _role(profile) not in {"admin", "super_admin"}:
        permissions = profile.get("permissions") if isinstance(profile.get("permissions"), dict) else {}
        sales_permissions = permissions.get("المبيعات", {}) if isinstance(permissions.get("المبيعات"), dict) else {}
        returns_permissions = permissions.get("المرتجعات", {}) if isinstance(permissions.get("المرتجعات"), dict) else {}
        can_add_return = returns_permissions.get("إضافة") is True
        can_edit_return = bool(exclude_return_id) and returns_permissions.get("تعديل") is True
        if sales_permissions.get("معاينة") is not True or not (can_add_return or can_edit_return):
            raise HTTPException(status_code=403, detail="ليس لديك صلاحية تسجيل مرتجع لهذه الفاتورة")
    sale = await db.get(SaleRecord, sale_id)
    if not sale or sale.company_code != company_code or sale.is_deleted:
        raise HTTPException(status_code=404, detail="فاتورة البيع غير موجودة")
    _check_branches(profile, [sale.branch_code])
    returns_q = select(SaleReturnRecord).where(SaleReturnRecord.company_code == company_code, SaleReturnRecord.sale_id == sale_id, SaleReturnRecord.is_deleted.is_(False))
    if exclude_return_id:
        returns_q = returns_q.where(SaleReturnRecord.id != exclude_return_id)
    returns = (await db.execute(returns_q)).scalars().all()
    remaining: dict[str, float] = {}
    for item in sale.items or []:
        code = str(item.get("code", ""))
        remaining[code] = remaining.get(code, 0.0) + float(item.get("quantity", 0) or 0)
    for returned in returns:
        for item in returned.items or []:
            code = str(item.get("code", ""))
            remaining[code] = remaining.get(code, 0.0) - float(item.get("quantity", 0) or 0)
    effective_date = to_date or sale.date
    sales = (await db.execute(select(SaleRecord).where(SaleRecord.company_code == company_code, SaleRecord.branch_code == sale.branch_code, SaleRecord.customer_code == sale.customer_code, SaleRecord.date <= effective_date, SaleRecord.is_deleted.is_(False)))).scalars().all()
    receipts = (await db.execute(select(CustomerPaymentRecord).where(CustomerPaymentRecord.company_code == company_code, CustomerPaymentRecord.branch_code == sale.branch_code, CustomerPaymentRecord.customer_code == sale.customer_code, CustomerPaymentRecord.date <= effective_date, CustomerPaymentRecord.is_deleted.is_(False)))).scalars().all()
    prior_returns_q = select(SaleReturnRecord).where(SaleReturnRecord.company_code == company_code, SaleReturnRecord.branch_code == sale.branch_code, SaleReturnRecord.customer_code == sale.customer_code, SaleReturnRecord.date <= effective_date, SaleReturnRecord.is_deleted.is_(False))
    if exclude_return_id:
        prior_returns_q = prior_returns_q.where(SaleReturnRecord.id != exclude_return_id)
    prior_returns = (await db.execute(prior_returns_q)).scalars().all()
    customer_balance = max(0.0, sum(row.due for row in sales) - sum(row.amount for row in receipts) - sum(row.credit_amount for row in prior_returns))
    return {"remaining_quantities": remaining, "customer_balance": customer_balance}


@router.get("/customer-balances/{company_code}")
async def customer_balances(company_code: str, request: Request, branch_code: str | None = Query(default=None), to_date: str | None = Query(default=None), db: AsyncSession = Depends(get_db)):
    profile = _check_extra_permission(request, "حسابات العملاء", "عرض الأرصدة")
    if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
        _check_branches(profile, [branch_code])
    allowed = allowed_branches_for_profile(profile)
    sales_q = select(SaleRecord).where(SaleRecord.company_code == company_code, SaleRecord.is_deleted.is_(False))
    returns_q = select(SaleReturnRecord).where(SaleReturnRecord.company_code == company_code, SaleReturnRecord.is_deleted.is_(False))
    receipts_q = select(CustomerPaymentRecord).where(CustomerPaymentRecord.company_code == company_code, CustomerPaymentRecord.is_deleted.is_(False))
    if to_date:
        sales_q = sales_q.where(SaleRecord.date <= to_date)
        returns_q = returns_q.where(SaleReturnRecord.date <= to_date)
        receipts_q = receipts_q.where(CustomerPaymentRecord.date <= to_date)
    if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
        sales_q = sales_q.where(SaleRecord.branch_code == branch_code)
        returns_q = returns_q.where(SaleReturnRecord.branch_code == branch_code)
        receipts_q = receipts_q.where(CustomerPaymentRecord.branch_code == branch_code)
    elif allowed:
        sales_q = sales_q.where(SaleRecord.branch_code.in_(allowed))
        returns_q = returns_q.where(SaleReturnRecord.branch_code.in_(allowed))
        receipts_q = receipts_q.where(CustomerPaymentRecord.branch_code.in_(allowed))
    sales = (await db.execute(sales_q)).scalars().all()
    returns = (await db.execute(returns_q)).scalars().all()
    receipts = (await db.execute(receipts_q)).scalars().all()
    result: dict[str, dict[str, Any]] = {}
    for row in sales:
        item = result.setdefault(row.customer_code, {"customer_code": row.customer_code, "customer_name": row.customer_name, "balance": 0.0})
        item["balance"] += row.due
    for row in receipts:
        item = result.setdefault(row.customer_code, {"customer_code": row.customer_code, "customer_name": row.customer_name, "balance": 0.0})
        item["balance"] -= row.amount
    for row in returns:
        item = result.setdefault(row.customer_code, {"customer_code": row.customer_code, "customer_name": row.customer_name, "balance": 0.0})
        item["balance"] -= row.credit_amount
    return [dict(item, balance=max(0.0, round(item["balance"], 2))) for item in result.values() if item["balance"] > 0.005]


@router.get("/cash-balances/{company_code}")
async def cash_balances(company_code: str, request: Request, branch_code: str | None = Query(default=None), to_date: str | None = Query(default=None), db: AsyncSession = Depends(get_db)):
    profile = _check_extra_permission(request, "أرصدة خزائن المبيعات", "معاينة")
    if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
        _check_branches(profile, [branch_code])
    allowed = allowed_branches_for_profile(profile)
    result: dict[str, float] = {}
    sources = [
        (SaleRecord, "payments"), (SaleReturnRecord, "payments"), (CustomerPaymentRecord, "payments"),
    ]
    for model, field in sources:
        stmt = select(model).where(model.company_code == company_code, model.is_deleted.is_(False))
        if to_date:
            stmt = stmt.where(model.date <= to_date)
        if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
            stmt = stmt.where(model.branch_code == branch_code)
        elif allowed:
            stmt = stmt.where(model.branch_code.in_(allowed))
        rows = (await db.execute(stmt)).scalars().all()
        sign = -1 if model is SaleReturnRecord else 1
        for row in rows:
            for payment in getattr(row, field) or []:
                name = str(payment.get("treasury", ""))
                if name:
                    result[name] = result.get(name, 0.0) + sign * float(payment.get("amount", 0) or 0)
    return [{"treasury": key, "balance": round(value, 2)} for key, value in result.items()]


@router.get("/stock-events/{company_code}")
async def stock_events(company_code: str, request: Request, db: AsyncSession = Depends(get_db)):
    profile = request.state.auth_user
    if _role(profile) not in {"admin", "super_admin"}:
        permissions = profile.get("permissions") if isinstance(profile.get("permissions"), dict) else {}
        stock_permissions = permissions.get("رصيد المخزون", {}) if isinstance(permissions.get("رصيد المخزون"), dict) else {}
        operational = any(
            isinstance(permissions.get(category), dict) and permissions[category].get(key) is True
            for category, key in (("المبيعات", "إضافة"), ("المرتجعات", "إضافة"), ("التحويلات المخزنية", "إضافة"))
        )
        if stock_permissions.get("معاينة") is not True and not operational:
            raise HTTPException(status_code=403, detail="ليس لديك صلاحية عرض رصيد المخزون")
    allowed = allowed_branches_for_profile(profile)
    output: list[dict[str, Any]] = []
    for model, kind, branch_attr, store_attr, sign in (
        (SaleRecord, "sale", "branch_code", "store_code", -1),
        (SaleReturnRecord, "return", "branch_code", "store_code", 1),
    ):
        stmt = select(model).where(model.company_code == company_code, model.is_deleted.is_(False))
        if allowed:
            stmt = stmt.where(getattr(model, branch_attr).in_(allowed))
        for row in (await db.execute(stmt)).scalars().all():
            output.append({"id": row.id, "company_code": company_code, "branch_code": getattr(row, branch_attr), "store_code": getattr(row, store_attr), "date": row.date, "event_type": kind, "positive": sign > 0, "items": [{"code": item.get("code"), "quantity": item.get("quantity", 0)} for item in row.items or []]})
    transfer_stmt = select(StockTransferRecord).where(StockTransferRecord.company_code == company_code, StockTransferRecord.is_deleted.is_(False))
    if allowed:
        transfer_stmt = transfer_stmt.where((StockTransferRecord.from_branch_code.in_(allowed)) | (StockTransferRecord.to_branch_code.in_(allowed)))
    for row in (await db.execute(transfer_stmt)).scalars().all():
        items = [{"code": item.get("code"), "quantity": item.get("quantity", 0)} for item in row.items or []]
        for branch, store, event_type, positive in (
            (row.from_branch_code, row.from_store_code, "transfer_out", False),
            (row.to_branch_code, row.to_store_code, "transfer_in", True),
        ):
            if allowed and branch not in allowed:
                continue
            output.append({"id": f"{row.id}:{event_type}", "company_code": company_code, "branch_code": branch, "store_code": store, "date": row.date, "event_type": event_type, "positive": positive, "items": items})
    return output
