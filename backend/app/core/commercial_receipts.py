"""Owner-bound retry acknowledgement for committed commercial creates.

The caller holds the existing record save lock. This stores hashes and identity,
not an extra invoice copy. It never grants edit or view access to another row.
"""
import hashlib
import json
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.models import CommercialCreationReceipt


def _canonical_numbers(value):
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, list):
        return [_canonical_numbers(item) for item in value]
    if isinstance(value, dict):
        return {key: _canonical_numbers(item) for key, item in value.items()}
    return value


def request_fingerprint(data):
    values = data.model_dump(mode='json')
    values.pop('base_updated_at', None)
    values.pop('serial', None)
    return hashlib.sha256(json.dumps(_canonical_numbers(values), ensure_ascii=False, sort_keys=True,
        separators=(',', ':'), allow_nan=False).encode('utf-8')).hexdigest()


def record_fingerprint(record, schema):
    values = {key: getattr(record, key) for key in schema.model_fields
              if key != 'base_updated_at' and hasattr(record, key)}
    return request_fingerprint(schema.model_validate(values))


async def unchanged_creation(db, *, kind, data, schema, existing, owner_uid, fingerprint):
    if not isinstance(db, AsyncSession) or not owner_uid:
        return None
    receipt = await db.get(CommercialCreationReceipt, (kind, data.id))
    if (receipt is None or receipt.owner_uid != owner_uid
            or receipt.company_code != data.company_code
            or receipt.request_hash != fingerprint
            or data.serial not in (0, receipt.original_serial)
            or existing.serial != receipt.original_serial
            or existing.updated_at != receipt.record_updated_at):
        return None
    try:
        if record_fingerprint(existing, schema) != receipt.record_hash:
            return None
    except (TypeError, ValueError):
        return None
    return {'status':'success', 'id':data.id, 'serial':receipt.original_serial,
            'updated_at':existing.updated_at.isoformat(), 'action':'unchanged'}


def remember_creation(db, *, kind, data, schema, record, owner_uid, fingerprint):
    if not isinstance(db, AsyncSession) or not owner_uid:
        return
    db.add(CommercialCreationReceipt(kind=kind, record_id=data.id, company_code=data.company_code,
        owner_uid=owner_uid, request_hash=fingerprint, record_hash=record_fingerprint(record, schema),
        original_serial=record.serial, record_updated_at=record.updated_at))
