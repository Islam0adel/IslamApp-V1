"""Stock transfer routes, split from the commercial sales module.

These endpoints reuse the shared generic engine in commercial.py and are
mounted under the same /commercial prefix, so URLs are unchanged:
/commercial/transfers/save | list | changes | delete.
"""
from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.routes.commercial import changes_kind, delete_kind, list_kind, save_kind

router = APIRouter()


@router.post("/transfers/save")
async def save_transfer(request: Request, db: AsyncSession = Depends(get_db)):
    return await save_kind("transfers", request, db)


@router.get("/transfers/list/{company_code}")
async def list_transfers(
    company_code: str, request: Request,
    branch_code: str | None = Query(default=None),
    from_date: str | None = Query(default=None), to_date: str | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    return await list_kind("transfers", company_code, request, branch_code, from_date, to_date, db)


@router.get("/transfers/changes/{company_code}")
async def changed_transfers(company_code: str, request: Request, since: str, db: AsyncSession = Depends(get_db)):
    return await changes_kind("transfers", company_code, request, since, db)


@router.post("/transfers/delete/{company_code}/{record_id}")
async def delete_transfer(company_code: str, record_id: str, request: Request, db: AsyncSession = Depends(get_db)):
    return await delete_kind("transfers", company_code, record_id, request, db)
