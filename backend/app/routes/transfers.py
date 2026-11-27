# backend/app/routes/transfers.py
"""Stock transfer routes, split from the commercial sales module.

These endpoints reuse the shared generic engine in commercial.py and are
mounted under the same /commercial prefix, so URLs are unchanged:
/commercial/transfers/save | list | changes | delete.
"""
from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.routes.commercial import changed_records_v2, changes_kind, delete_kind, list_kind, save_kind

# راوتر تحويلات المخازن
router = APIRouter()


# حفظ تحويل مخزني
@router.post("/transfers/save")
async def save_transfer(request: Request, db: AsyncSession = Depends(get_db)):
    return await save_kind("transfers", request, db)


# قائمة التحويلات المخزنية للشركة بفلاتر الفرع والتاريخ
@router.get("/transfers/list/{company_code}")
async def list_transfers(
    company_code: str, request: Request,
    branch_code: str | None = Query(default=None),
    from_date: str | None = Query(default=None), to_date: str | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    return await list_kind("transfers", company_code, request, branch_code, from_date, to_date, db)


# التغييرات منذ آخر مزامنة للتحويلات
@router.get("/transfers/changes/{company_code}")
async def changed_transfers(company_code: str, request: Request, since: str, db: AsyncSession = Depends(get_db)):
    return await changes_kind("transfers", company_code, request, since, db)


# حذف تحويل مخزني
@router.post("/transfers/delete/{company_code}/{record_id}")
async def delete_transfer(company_code: str, record_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    return await delete_kind("transfers", company_code, record_id, request, db)


# فيد التغييرات v2 للتحويلات (تجريبي، يحتاج الهجرة 008)
@router.get("/transfers/changes-v2/{company_code}")
async def changed_transfers_v2(
    company_code: str, request: Request,
    cursor: str = Query("0:"), limit: int = Query(200, ge=1, le=500), scope: str = Query(""),
    db: AsyncSession = Depends(get_db),
):
    """EXPERIMENT. Needs migration 008."""
    return await changed_records_v2("transfers", company_code, request, cursor, limit, scope, db)
