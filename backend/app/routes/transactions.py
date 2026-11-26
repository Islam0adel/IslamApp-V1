# backend/app/routes/transactions.py

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, desc

from app.core.auth_middleware import allowed_branches_for_profile
from app.core.database import get_db
from app.core.permissions import require_any_section_permission
from app.core.auth_middleware import allowed_branches_for_profile
from app.core.models import Transaction, SupplierSettlementRecord, JournalSaveReceipt
from app.core.schemas import TransactionModel
from app.core.sync import manager
from app.core.save_locks import lock_save

import datetime
import hashlib
import json
import logging

log = logging.getLogger(__name__)


async def _safe_broadcast(company, message):
    try:
        await manager.broadcast(company, message)
    except Exception:
        log.exception("Journal notification failed after commit")


router = APIRouter()


_CATEGORY = "حركة الخزينة"


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
        "link_id": tx.link_id,
        "supplier_name": tx.supplier_name,
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

def _check_edit_version(data, tx):
    # Old non-intent clients retain their existing missing-version contract.
    # New intent-based edits must name the exact displayed server version.
    if not data.base_updated_at:
        if data.operation_id:
            raise HTTPException(409, "أعد تحميل الإذن قبل التعديل لتأكيد نسخته الحالية")
        return
    def stamp(value):
        parsed = value if isinstance(value, datetime.datetime) else datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=datetime.timezone.utc) if parsed.tzinfo is None else parsed.astimezone(datetime.timezone.utc)
    try:
        matches = stamp(data.base_updated_at) == stamp(tx.updated_at)
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(400, "تاريخ نسخة الإذن غير صالح")
    if not matches:
        raise HTTPException(409, "تم تعديل هذا الإذن من مستخدم آخر. أعد تحميله وراجع التعديل")


def _request_fingerprint(data):
    values = data.model_dump(mode="json", exclude={"operation_id"})
    if values.get("base_updated_at") is None:values.pop("base_updated_at", None)
    try:
        return hashlib.sha256(json.dumps(values, sort_keys=True, ensure_ascii=False,
                                         separators=(",", ":"), allow_nan=False).encode()).hexdigest()
    except ValueError:
        raise HTTPException(400, "بيانات الحفظ غير صالحة")


async def _receipt_snapshot(db, receipt, profile):
    result = {"status": "success", "committed": True, "available": False,
              "serial": receipt.original_serial, "action": "unchanged",
              "record": None, "linked_settlement": None, "link_id": None}
    row = await db.get(Transaction, receipt.transaction_id)
    if row is None or row.is_deleted or row.company_code != receipt.company_code:
        return result
    try:
        _check_branch(profile, row.branch_code)
    except HTTPException:
        return result
    linked = None
    if row.link_id:
        linked = await db.scalar(select(SupplierSettlementRecord).where(
            SupplierSettlementRecord.company_code == row.company_code,
            SupplierSettlementRecord.link_id == row.link_id))
        if linked is not None:
            try:
                _check_branch(profile, linked.branch_code)
            except HTTPException:
                linked = None
    from app.routes.supplier_settlement import serialize_settlement
    result.update(available=True, serial=row.serial, link_id=row.link_id,
                  record=serialize_transaction(row),
                  linked_settlement=serialize_settlement(linked) if linked is not None else None,
                  message="تم تأكيد الحفظ السابق بدون إنشاء إذن جديد")
    return result


async def _replay_receipt(db, receipt, data, profile, fingerprint):
    if (receipt.owner_uid != str(profile.get("uid") or "")
            or receipt.company_code != data.company_code
            or receipt.branch_code != data.branch_code):
        raise HTTPException(403, "عملية الحفظ لا تخص هذا الحساب والنطاق")
    if receipt.request_hash != fingerprint:
        raise HTTPException(409, "تغيّرت بيانات محاولة الحفظ غير المؤكدة")
    result = await _receipt_snapshot(db, receipt, profile)
    if not result["available"]:
        raise HTTPException(409, "الإذن المحفوظ سابقاً لم يعد متاحاً، راجع السجل")
    return result


@router.get("/save-status/{company_code}/{operation_id}")
async def journal_save_status(request: Request, company_code: str, operation_id: str,
                              branch_code: str = Query(...), db: AsyncSession = Depends(get_db)):
    profile = _require_any(request, ["ادخال اذون", "التعديل"])
    _check_branch(profile, branch_code)
    uid = str(profile.get("uid") or "")
    if not uid or (str(profile.get("role")) != "super_admin"
                   and str(profile.get("company_code")) != company_code):
        raise HTTPException(403, "تعذر إثبات صاحب عملية الحفظ ونطاقها")
    # Wait for an in-flight save to commit or roll back before reporting absence.
    await lock_save(db, ("operation", "journal", operation_id))
    receipt = await db.get(JournalSaveReceipt, operation_id)
    if receipt is None:
        raise HTTPException(404, "لا توجد نتيجة حفظ مؤكدة لهذه العملية")
    if receipt.owner_uid != uid or receipt.company_code != company_code or receipt.branch_code != branch_code:
        raise HTTPException(403, "عملية الحفظ لا تخص هذا الحساب والنطاق")
    return await _receipt_snapshot(db, receipt, profile)


@router.post("/save")
async def save_transaction(
    request: Request,
    data: TransactionModel,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["ادخال اذون", "التعديل"])
    _check_branch(_profile, data.branch_code)

    if data.category.strip() == "تحويل خزائن":
        raise HTTPException(409, "استخدم قسم تحويلات الخزائن المستقل")

    try:
        resources = [("sequence", "journal", data.company_code, data.branch_code)]
        if data.add_to_settlement or data.unlink_settlement:
            resources.append(("sequence", "settlement", data.company_code, data.branch_code or "1"))
        receipt = None
        fingerprint = None
        if data.operation_id:
            uid = str(_profile.get("uid") or "")
            if not uid or len(uid) > 128:
                raise HTTPException(403, "تعذر إثبات صاحب عملية الحفظ")
            if str(_profile.get("role")) != "super_admin" and str(_profile.get("company_code")) != data.company_code:
                raise HTTPException(403, "غير مصرح لهذه الشركة")
            fingerprint = _request_fingerprint(data)
            resources.append(("operation", "journal", data.operation_id))
        await lock_save(db, *resources)
        if data.operation_id:
            receipt = await db.get(JournalSaveReceipt, data.operation_id)
            if receipt is not None:
                return await _replay_receipt(db, receipt, data, _profile, fingerprint)
        linked_settlement = None
        settlement_created = False
        link_id = data.link_id
        if data.add_to_settlement and data.category.strip() == "بضاعة":
            if not data.supplier_name or not data.supplier_name.strip():
                raise HTTPException(status_code=400, detail="اختر المورد لربط حركة البضاعة بالتسويات")
            if not link_id:
                import uuid
                link_id = uuid.uuid4().hex
        elif data.unlink_settlement:
            link_id = None

        if link_id:
            linked_result = await db.execute(select(Transaction).where(
                Transaction.company_code == data.company_code,
                Transaction.link_id == link_id,
            ).with_for_update())
            linked_transaction = linked_result.scalar_one_or_none()
        else:
            linked_transaction = None
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

        if linked_transaction is not None:
            _require_any(request, ["التعديل"])
            tx = linked_transaction
            if tx.is_deleted:raise HTTPException(404, "Transaction has been deleted")
            # الفرع المخزَّن أيضاً: منع تعديل/نقل إذن فرع غير مسموح
            _check_branch(_profile, tx.branch_code)
            _check_edit_version(data, tx)
            tx.branch_code = data.branch_code or tx.branch_code
            tx.serial = new_serial if data.serial <= 0 else data.serial
            tx.treasury = data.treasury
            tx.amount = data.amount
            tx.statement = data.statement
            tx.category = data.category
            tx.date = data.date
            tx.type = data.type
            tx.employee = data.employee
            tx.link_id = link_id
            tx.supplier_name = data.supplier_name if data.add_to_settlement else None
            tx.updated_at = datetime.datetime.utcnow()
            tx.is_deleted = False
            action = "update"
        elif data.serial > 0:
            stmt = (
                select(Transaction)
                .where(
                    Transaction.company_code
                    == data.company_code,
                    Transaction.branch_code
                    == data.branch_code,
                    Transaction.serial
                    == data.serial,
                ).with_for_update()
            )

            result = await db.execute(stmt)
            tx = result.scalar_one_or_none()

            if not tx:
                raise HTTPException(
                    status_code=404,
                    detail="Transaction not found",
                )

            _require_any(request, ["التعديل"])

            # لا تسمح بتعديل سجل محذوف
            if tx.is_deleted:
                raise HTTPException(
                    status_code=404,
                    detail="Transaction has been deleted",
                )

            _check_edit_version(data, tx)

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
            tx.link_id = link_id
            tx.supplier_name = data.supplier_name if data.add_to_settlement else None

            tx.updated_at = datetime.datetime.utcnow()

            tx.is_deleted = False

            action = "update"

        else:
            # --------------------------------------------------
            # إضافة جديدة
            # --------------------------------------------------

            _require_any(request, ["ادخال اذون"])

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
                link_id=link_id,
                supplier_name=data.supplier_name if data.add_to_settlement else None,
                updated_at=datetime.datetime.utcnow(),
                is_deleted=False,
            )

            db.add(tx)

            action = "insert"

        # ------------------------------------------------------
        # حفظ
        # ------------------------------------------------------

        if data.add_to_settlement and data.category.strip() == "بضاعة":
            q = await db.execute(select(SupplierSettlementRecord).where(
                SupplierSettlementRecord.company_code == data.company_code,
                SupplierSettlementRecord.link_id == link_id,
            ))
            linked_settlement = q.scalar_one_or_none()
            if linked_settlement is None:
                sr = await db.execute(select(SupplierSettlementRecord).where(
                    SupplierSettlementRecord.company_code == data.company_code,
                    SupplierSettlementRecord.branch_code == (data.branch_code or "1"),
                ).order_by(desc(SupplierSettlementRecord.serial)).limit(1))
                last_settlement = sr.scalar_one_or_none()
                linked_settlement = SupplierSettlementRecord(
                    company_code=data.company_code, branch_code=data.branch_code or "1",
                    serial=(last_settlement.serial + 1) if last_settlement else 1,
                    date=data.date, supplier_name=data.supplier_name.strip(),
                    payment_method=data.treasury, treasury=data.treasury, amount=data.amount,
                    statement=data.statement, employee=data.employee, link_id=link_id,
                    is_deleted=False,
                )
                db.add(linked_settlement)
                settlement_created = True
            else:
                _check_branch(_profile, linked_settlement.branch_code)
                if linked_settlement.serial <= 0:
                    sr = await db.execute(select(SupplierSettlementRecord).where(
                        SupplierSettlementRecord.company_code == data.company_code,
                        SupplierSettlementRecord.branch_code == (data.branch_code or "1"),
                    ).order_by(desc(SupplierSettlementRecord.serial)).limit(1))
                    last_settlement = sr.scalar_one_or_none()
                    linked_settlement.serial = (last_settlement.serial + 1) if last_settlement else 1
                linked_settlement.branch_code = data.branch_code or linked_settlement.branch_code
                linked_settlement.date = data.date
                linked_settlement.supplier_name = data.supplier_name.strip()
                linked_settlement.payment_method = data.treasury
                linked_settlement.treasury = data.treasury
                linked_settlement.amount = data.amount
                linked_settlement.statement = data.statement
                linked_settlement.employee = data.employee
                linked_settlement.updated_at = datetime.datetime.utcnow()
                linked_settlement.is_deleted = False
        elif data.unlink_settlement and data.link_id:
            q = await db.execute(select(SupplierSettlementRecord).where(
                SupplierSettlementRecord.company_code == data.company_code,
                SupplierSettlementRecord.link_id == data.link_id,
                SupplierSettlementRecord.is_deleted.is_(False),
            ))
            linked_settlement = q.scalar_one_or_none()
            if linked_settlement is not None:
                _check_branch(_profile, linked_settlement.branch_code)
                linked_settlement.is_deleted = True
                linked_settlement.updated_at = datetime.datetime.utcnow()
        if data.operation_id:
            await db.flush()
            db.add(JournalSaveReceipt(operation_id=data.operation_id,
                owner_uid=str(_profile["uid"]), company_code=data.company_code,
                branch_code=data.branch_code, request_hash=fingerprint,
                transaction_id=tx.id, original_serial=tx.serial))
        await db.commit()
        await db.refresh(tx)
        if linked_settlement is not None:
            await db.refresh(linked_settlement)

        # ------------------------------------------------------
        # WebSocket Broadcast
        # ------------------------------------------------------

        await _safe_broadcast(
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
        if linked_settlement is not None and not linked_settlement.is_deleted:
            from app.routes.supplier_settlement import serialize_settlement
            await _safe_broadcast(data.company_code, {
                "type": "settlement", "action": "insert" if settlement_created else "update",
                "data": serialize_settlement(linked_settlement), "suppress_notification": True,
            })
        elif linked_settlement is not None:
            from app.routes.supplier_settlement import serialize_settlement
            await _safe_broadcast(data.company_code, {
                "type": "settlement", "action": "delete", "data": serialize_settlement(linked_settlement), "suppress_notification": True,
            })

        # ------------------------------------------------------
        # Response
        # ------------------------------------------------------

        return {
            "status": "success",
            "serial": tx.serial,
            "record": serialize_transaction(tx, action=action),
            "link_id": tx.link_id,
            "linked_settlement": (
                __import__("app.routes.supplier_settlement", fromlist=["serialize_settlement"]).serialize_settlement(linked_settlement)
                if linked_settlement is not None else None
            ),
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
    request: Request,
    company_code: str,
    start_date: str = Query(...),
    end_date: str = Query(...),
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["المعاينة", "ادخال اذون"])

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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(Transaction.branch_code.in_(allowed_branches))

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

@router.get("/changes-v2/{company_code}")
async def get_transactions_changes_v2(
    request: Request,
    company_code: str,
    cursor: str = Query("0:0"),
    limit: int = Query(200, ge=1, le=500),
    scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    """EXPERIMENT. Same authority checks as /changes; branch scope read from the caller on every page."""
    from app.core import changes_v2
    _require_any(request, ["المعاينة", "ادخال اذون"])
    _allowed = allowed_branches_for_profile(request.state.auth_user)
    # Fingerprint of what this caller may read (company + branch list). A cursor made
    # under another fingerprint says nothing about rows in newly allowed branches.
    fp = await changes_v2.scope_fingerprint(db, "transactions", company_code, _allowed)
    if cursor == "latest":
        return {"invalid": False, "items": [], "has_more": False, "scope": fp,
                "next_cursor": await changes_v2.bootstrap_cursor(db)}
    if scope and scope != fp:
        return {"invalid": True, "reason": "scope", "items": [], "has_more": False,
                "next_cursor": cursor, "scope": fp}
    try:
        changes_v2.parse_cursor(cursor)
    except Exception:
        raise HTTPException(status_code=400, detail="bad cursor")
    allowed = allowed_branches_for_profile(request.state.auth_user)
    def ser(r):
        j = dict(r["row_json"])
        j.pop("touched", None); j.pop("tx", None)
        j["action"] = "delete" if j.get("is_deleted") else "update"
        return j
    out = await changes_v2.fetch(db, company_code, allowed, cursor, limit, ser)
    out['scope'] = fp
    return out


@router.get("/changes/{company_code}")
async def get_transactions_changes(
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
    _profile = _require_any(request, ["المعاينة", "ادخال اذون"])

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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(Transaction.branch_code.in_(allowed_branches))

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
    request: Request,
    company_code: str,
    from_serial: int,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["المعاينة", "ادخال اذون"])

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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(Transaction.branch_code.in_(allowed_branches))

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
    request: Request,
    company_code: str,
    branch_code: str,
    serial: int,
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["الحذف"])

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

        if (tx.category or "").strip() == "تحويل خزائن":
            raise HTTPException(409, "تحويلات الخزائن لا تُحذف كأذون يومية")

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

        linked_settlement = None
        if tx.link_id:
            linked_result = await db.execute(select(SupplierSettlementRecord).where(
                SupplierSettlementRecord.company_code == company_code,
                SupplierSettlementRecord.link_id == tx.link_id,
                SupplierSettlementRecord.is_deleted.is_(False),
            ))
            linked_settlement = linked_result.scalar_one_or_none()
            if linked_settlement is not None:
                linked_settlement.is_deleted = True
                linked_settlement.updated_at = datetime.datetime.utcnow()

        await db.commit()

        await db.refresh(tx)
        if linked_settlement is not None:
            await db.refresh(linked_settlement)

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
        if linked_settlement is not None:
            from app.routes.supplier_settlement import serialize_settlement
            await manager.broadcast(company_code, {
                "type": "settlement", "action": "delete",
                "data": serialize_settlement(linked_settlement, action="delete"),
                "suppress_notification": True,
            })

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
    request: Request,
    company_code: str,
    branch_code: str = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _profile = _require_any(request, ["ادخال اذون"])

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

        allowed_branches = allowed_branches_for_profile(request.state.auth_user)
        if allowed_branches:
            stmt = stmt.where(Transaction.branch_code.in_(allowed_branches))

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
    request: Request,
    company_code: str,
):
    _profile = _require_any(request, ["المعاينة", "شاشات الارصدة"])

    return {
        "status": "success",
        "active_treasuries": [],
    }
