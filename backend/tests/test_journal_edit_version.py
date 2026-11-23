"""Journal edit compare-and-set, before any linked/business write."""
import asyncio
import pytest
from fastapi import HTTPException
from sqlalchemy import select,func
from sqlalchemy.ext.asyncio import create_async_engine,async_sessionmaker
from app.core import models
from app.routes import transactions
from test_journal_receipts import data,request

@pytest.mark.parametrize('case',['exact','stale','missing','invalid','legacy','linked','replay'])
def test_edit_version_and_receipt_order(case,tmp_path,monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(transactions.manager,'broadcast',quiet)
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'version.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                first=data()
                if case=='linked':first=first.model_copy(update={'category':'بضاعة','add_to_settlement':True,'supplier_name':'S','link_id':'link-v'})
                saved=await transactions.save_transaction(request(),first,db)
                base=saved['record']['updated_at']
                edit=first.model_copy(update={'serial':saved['serial'],'amount':20,'operation_id':'journal-version-edit-0001','base_updated_at':base})
                if case=='stale':edit.base_updated_at='2000-01-01T00:00:00'
                if case=='missing':edit.base_updated_at=None
                if case=='invalid':edit.base_updated_at='invalid'
                if case=='legacy':edit.operation_id=None;edit.base_updated_at=None
                if case=='linked':edit.base_updated_at='2000-01-01T00:00:00'
                expected=400 if case=='invalid' else 409 if case in {'stale','missing','linked'} else None
                if expected:
                    with pytest.raises(HTTPException) as error:await transactions.save_transaction(request(rights={'التعديل':True}),edit,db)
                    assert error.value.status_code==expected
                    await db.rollback()
                    row=await db.scalar(select(models.Transaction));assert row.amount==10
                    assert await db.scalar(select(func.count()).select_from(models.JournalSaveReceipt))==1
                    if case=='linked':assert (await db.scalar(select(models.SupplierSettlementRecord))).amount==10
                else:
                    result=await transactions.save_transaction(request(rights={'التعديل':True}),edit,db)
                    assert result['record']['amount']==20
                    if case=='replay':
                        newer=edit.model_copy(update={'amount':30,'operation_id':'journal-version-edit-0002','base_updated_at':result['record']['updated_at']})
                        await transactions.save_transaction(request(rights={'التعديل':True}),newer,db)
                        replay=await transactions.save_transaction(request(rights={'التعديل':True}),edit,db)
                        assert replay['action']=='unchanged' and replay['record']['amount']==30
        finally:await engine.dispose()
    asyncio.run(work())
