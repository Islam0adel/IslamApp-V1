"""Independent treasury transfer records. Never writes legacy journal rows."""
import datetime
import logging
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.models import TreasuryTransferRecord, TreasurySyncEntry
from app.core.treasury_sync import lock_state, store_entry, scope_token
from app.core.auth_middleware import _effective_role, allowed_branches_for_profile
from app.core.permissions import require_section_permission, require_any_section_permission
from app.core.treasury_permissions import can_view_treasury_effects
from app.core.sync import manager

router = APIRouter()
CATEGORY = "تحويلات الخزائن"
log = logging.getLogger(__name__)


class TreasuryTransferModel(BaseModel):
    id: str = Field(min_length=1, max_length=36)
    company_code: str = Field(min_length=1, max_length=50)
    branch_code: str = Field(min_length=1, max_length=50)
    serial: int = 0
    from_treasury: str = Field(min_length=1, max_length=255)
    to_treasury: str = Field(min_length=1, max_length=255)
    amount: float = Field(gt=0, allow_inf_nan=False)
    statement: str = ""
    employee: str = Field(default="غير معروف", max_length=255)
    date: str
    base_updated_at: datetime.datetime | None = None

    @field_validator("date")
    @classmethod
    def valid_date(cls, value):
        if datetime.date.fromisoformat(value).isoformat() != value:
            raise ValueError("Use yyyy-mm-dd")
        return value


def _scope(request, company, branch=None):
    profile = request.state.auth_user
    if _effective_role(profile) != "super_admin" and str(profile.get("company_code")) != company:
        raise HTTPException(403, "غير مسموح بالوصول إلى بيانات شركة أخرى")
    if branch:
        allowed = allowed_branches_for_profile(profile)
        if allowed and branch not in allowed:
            raise HTTPException(403, "ليس لديك صلاحية على هذا الفرع")
    return profile


def serialize(row):
    fields = ("id", "company_code", "branch_code", "serial", "from_treasury",
              "to_treasury", "amount", "statement", "employee", "date", "is_deleted")
    result = {key: getattr(row, key) for key in fields}
    result["updated_at"] = row.updated_at.isoformat() if row.updated_at else None
    return result


def _response(row, action):
    return {"status": "success", "action": action, "record": serialize(row)}


def _version(value):
    if value.tzinfo:
        value = value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return value


async def _notify(row, action, revision=None, payload=None):
    payload = payload if payload is not None else serialize(row)
    messages = [
        {"type": "treasury_transfer", "action": action, "data": {**payload, **({'revision': revision} if revision is not None else {})}},
        {"type": "treasury_balance_changed", "action": "update", "suppress_notification": True,
         "data": {"company_code": row.company_code, "branch_code": row.branch_code}},
    ]
    for message in messages:
        try:
            await manager.broadcast(row.company_code, message)
        except Exception:
            log.exception("Treasury transfer notification failed after commit")


@router.post("/save")
async def save_transfer(request: Request, data: TreasuryTransferModel,
                        db: AsyncSession = Depends(get_db)):
    profile = _scope(request, data.company_code, data.branch_code)
    require_any_section_permission(request, [(CATEGORY, "إضافة"), (CATEGORY, "تعديل")])
    if data.branch_code in {"all", "الكل", "كل الفروع"}:
        raise HTTPException(400, "اختر فرعاً محدداً للتحويل")
    if data.from_treasury == data.to_treasury:
        raise HTTPException(400, "لا يمكن التحويل لنفس الخزينة")
    values = data.model_dump(exclude={"base_updated_at", "serial"})
    for attempt in range(4):
        try:
            state = await lock_state(db, data.company_code)
            row = await db.scalar(select(TreasuryTransferRecord).where(
                TreasuryTransferRecord.id == data.id).with_for_update())
            if row is not None:
                if row.company_code != data.company_code or row.is_deleted:
                    raise HTTPException(404, "التحويل غير موجود")
                _scope(request, row.company_code, row.branch_code)
                same = all(getattr(row, key) == value for key, value in values.items())
                # A lost reply retries the same ID and exact submitted values.
                own_create_retry = (data.serial <= 0 and same
                    and row.created_by_uid == str(profile.get("uid", "")))
                require_section_permission(request, CATEGORY, "إضافة" if own_create_retry else "تعديل")
                if same:
                    await db.commit()
                    return _response(row, "unchanged")
                if not data.base_updated_at or _version(row.updated_at) != _version(data.base_updated_at):
                    raise HTTPException(409, "تغير التحويل على جهاز آخر، حدّث البيانات قبل التعديل")
                if data.branch_code != row.branch_code:
                    raise HTTPException(409, "الفرع ثابت لهذا التحويل")
                for key, value in values.items():
                    setattr(row, key, value)
                row.updated_at = datetime.datetime.utcnow()
                action = "update"
            else:
                require_section_permission(request, CATEGORY, "إضافة")
                last = await db.scalar(select(func.max(TreasuryTransferRecord.serial)).where(
                    TreasuryTransferRecord.company_code == data.company_code,
                    TreasuryTransferRecord.branch_code == data.branch_code))
                row = TreasuryTransferRecord(**values, serial=int(last or 0) + 1,
                    created_by_uid=str(profile.get("uid", "")), is_deleted=False,
                    updated_at=datetime.datetime.utcnow())
                db.add(row)
                action = "insert"
            await db.flush()
            entry = await store_entry(db, state, row)
            revision = entry.revision
            committed = dict(entry.payload)
            await db.commit()
            await _notify(row, action, revision, committed)
            return _response(row, action)
        except IntegrityError:
            await db.rollback()
            if attempt == 3:
                raise HTTPException(409, "تعارض مؤقت، أعد محاولة نفس التحويل")
        except HTTPException:
            await db.rollback()
            raise
        except Exception:
            await db.rollback()
            log.exception("Treasury transfer save failed")
            raise HTTPException(500, "فشل حفظ التحويل")


@router.get("/list/{company_code}")
async def list_transfers(request: Request, company_code: str,
                         branch_code: str | None = None,
                         since: str | None = None, db: AsyncSession = Depends(get_db)):
    profile = _scope(request, company_code)
    require_section_permission(request, CATEGORY, "معاينة")
    stmt = select(TreasuryTransferRecord).where(TreasuryTransferRecord.company_code == company_code)
    allowed = allowed_branches_for_profile(profile)
    if branch_code and branch_code not in {"all", "الكل", "كل الفروع"}:
        _scope(request, company_code, branch_code)
        stmt = stmt.where(TreasuryTransferRecord.branch_code == branch_code)
    elif allowed:
        stmt = stmt.where(TreasuryTransferRecord.branch_code.in_(allowed))
    if since:
        try:
            timestamp = _version(datetime.datetime.fromisoformat(since.replace("Z", "+00:00")))
        except ValueError:
            raise HTTPException(400, "تاريخ المزامنة غير صالح")
        stmt = stmt.where(TreasuryTransferRecord.updated_at >= timestamp)
    else:
        stmt = stmt.where(TreasuryTransferRecord.is_deleted.is_(False))
    rows = (await db.scalars(stmt.order_by(TreasuryTransferRecord.serial))).all()
    return [serialize(row) for row in rows]


@router.get("/effects/{company_code}")
async def transfer_effects(request: Request, company_code: str,
                           db: AsyncSession = Depends(get_db)):
    profile = _scope(request, company_code)
    if not can_view_treasury_effects(profile):
        raise HTTPException(403, "ليس لديك صلاحية أرصدة الخزائن أو تقاريرها")
    stmt = select(TreasuryTransferRecord).where(
        TreasuryTransferRecord.company_code == company_code,
        TreasuryTransferRecord.is_deleted.is_(False))
    allowed = allowed_branches_for_profile(profile)
    if allowed:
        stmt = stmt.where(TreasuryTransferRecord.branch_code.in_(allowed))
    grouped = {}
    for row in (await db.scalars(stmt)).all():
        for treasury, sign in ((row.from_treasury, -1), (row.to_treasury, 1)):
            key = (row.branch_code, row.date, treasury)
            grouped[key] = grouped.get(key, 0.0) + sign * row.amount
    return [{"company_code": company_code, "branch_code": key[0], "date": key[1],
             "treasury": key[2], "signed_amount": value}
            for key, value in sorted(grouped.items()) if value != 0]


@router.post("/delete/{company_code}/{record_id}")
async def delete_transfer(request: Request, company_code: str, record_id: str,
                          db: AsyncSession = Depends(get_db),
                          base_updated_at: str | None = None):
    _scope(request, company_code)
    require_section_permission(request, CATEGORY, "حذف")
    try:
        state = await lock_state(db, company_code)
        row = await db.scalar(select(TreasuryTransferRecord).where(
            TreasuryTransferRecord.id == record_id,
            TreasuryTransferRecord.company_code == company_code).with_for_update())
        if row is None:
            raise HTTPException(404, "التحويل غير موجود")
        _scope(request, company_code, row.branch_code)
        if not row.is_deleted:
            try:
                base = _version(datetime.datetime.fromisoformat(base_updated_at.replace("Z", "+00:00"))) if base_updated_at else None
            except ValueError:
                raise HTTPException(400, "إصدار التحويل غير صالح")
            if base is None or _version(row.updated_at) != base:
                raise HTTPException(409, "تغير التحويل على جهاز آخر، حدّث البيانات قبل الحذف")
            row.is_deleted = True
            row.updated_at = datetime.datetime.utcnow()
            await db.flush()
            entry = await store_entry(db, state, row)
            revision = entry.revision
            committed = dict(entry.payload)
            await db.commit()
            await _notify(row, "delete", revision, committed)
        return _response(row, "delete")
    except HTTPException:
        await db.rollback()
        raise
    except Exception:
        await db.rollback()
        log.exception("Treasury transfer deletion failed")
        raise HTTPException(500, "فشل حذف التحويل")


@router.get('/changes/{mode}/{company_code}')
async def treasury_changes(request: Request, mode: str, company_code: str,
                           cursor: int = 0, scope: str = '',
                           db: AsyncSession = Depends(get_db)):
    profile = _scope(request, company_code)
    if mode == 'records':
        require_section_permission(request, CATEGORY, 'معاينة')
    else:
        raise HTTPException(404, 'مسار مزامنة غير معروف')
    allowed = allowed_branches_for_profile(profile)
    token = scope_token(str(profile.get('uid', '')), company_code, mode, allowed)
    state = await lock_state(db, company_code)
    reset = scope != token or cursor < 0 or cursor > state.revision
    since = 0 if reset else cursor
    entries = (await db.scalars(select(TreasurySyncEntry).where(
        TreasurySyncEntry.company_code == company_code,
        TreasurySyncEntry.revision > since,
        TreasurySyncEntry.revision <= state.revision).order_by(TreasurySyncEntry.revision))).all()
    items = []
    for entry in entries:
        value = entry.payload
        if allowed and str(value.get('branch_code', '')) not in allowed:
            continue
        items.append({**value, 'revision': entry.revision})
    checkpoint = state.revision
    # Clock lock serializes the response snapshot with EVERY treasury writer.
    await db.commit()
    return {'protocol': 2, 'mode': mode, 'company_code': company_code,
            'scope': token, 'reset': reset, 'cursor': checkpoint, 'items': items}
