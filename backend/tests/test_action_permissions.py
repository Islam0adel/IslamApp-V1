"""Action-specific permissions using real routes and temporary SQLite."""
import asyncio
from types import SimpleNamespace
import pytest
from sqlalchemy import select,func
from sqlalchemy.ext.asyncio import create_async_engine,async_sessionmaker
from app.core.database import Base
from app.core import models,schemas
from app.routes import inventory,supplier,supplier_settlement,transactions


def request(category,key):
    return SimpleNamespace(state=SimpleNamespace(auth_user={'role':'employee','uid':'u1','company_code':'C1',
        'allowed_branches':['B1'],'permissions':{category:{key:True},'التكويد':{'سعر الشراء':True}}}))


def case(kind):
    common={'company_code':'C1','branch_code':'B1','date':'2026-11-22','serial':1,'employee':'test'}
    if kind=='journal':
        return transactions.save_transaction,schemas.TransactionModel(**{**common,'serial':0},treasury='A',amount=10,statement='initial',category='Income',type='وارد'),models.Transaction,'حركة الخزينة','ادخال اذون','التعديل'
    if kind=='inventory':
        item=schemas.InventoryItemModel(code='P1',name='Product',quantity=1,wholesalePrice=10,retailPrice=20,wholesaleValue=10,retailValue=20)
        return inventory.save_inventory,schemas.InventoryModel(**common,store_code='S1',inventory_type='عام',items=[item],total_wholesale=10,total_retail=20),models.InventoryRecord,'حركة الجرد','اضافة','تعديل'
    if kind=='supplier':
        item=schemas.SupplierItemModel(code='P1',name='Product',quantity=1,price=10,type='وارد',discountRate=0,discountAmount=0,total=10)
        return supplier.save_supplier_transaction,schemas.SupplierTransactionModel(**common,store_code='S1',supplier_name='Supplier',payment_method='نقدي',treasury='A',is_add_to_store=False,items=[item],total_amount=10,paid_amount=0),models.SupplierRecord,'حسابات الموردين','اضافة','تعديل'
    return supplier_settlement.save_settlement,schemas.SupplierSettlementModel(**common,supplier_name='Supplier',payment_method='نقدي',treasury='A',amount=10,statement='initial'),models.SupplierSettlementRecord,'تسويات الموردين','إضافة','تعديل'


@pytest.mark.parametrize('kind',['journal','inventory','supplier','settlement'])
@pytest.mark.parametrize('create_with_edit',[False,True])
def test_create_and_edit_rights_use_resolved_server_action(kind,create_with_edit,tmp_path,monkeypatch):
    async def no_broadcast(*a,**kw):pass
    monkeypatch.setattr(transactions.manager,'broadcast',no_broadcast)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'permissions.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                db.add(models.CodingRecord(company_code='C1',category='items',code='P1',name='Product',wholesale_price=10,cost_pending=False))
                await db.commit()
                save,data,model,category,add,edit=case(kind)
                from fastapi import HTTPException
                # Edit includes create under the owner's clarified hierarchy.
                result=await save(request(category,edit if create_with_edit else add),data,db)
                assert result['status']=='success'
                assert await db.scalar(select(func.count()).select_from(model))==1
                row=await db.scalar(select(model))
                updated=data.model_copy(deep=True)
                if kind=='journal':updated.serial=row.serial;updated.statement='changed by add-only'
                elif kind=='inventory':updated.doc_id=str(row.id);updated.employee='changed by add-only'
                elif kind=='supplier':updated.doc_id=str(row.id);updated.employee='changed by add-only'
                else:updated.doc_id=str(row.id);updated.statement='changed by add-only'
                with pytest.raises(HTTPException) as exc:
                    await save(request(category,add),updated,db)
                assert exc.value.status_code==403
                await db.rollback()
                changed=await save(request(category,edit),updated,db)
                assert changed['status']=='success'
                await db.refresh(row)
                assert getattr(row,'statement' if kind in {'journal','settlement'} else 'employee')=='changed by add-only'
        finally:await engine.dispose()
    asyncio.run(main())


@pytest.mark.parametrize('kind',['journal','settlement'])
def test_link_id_cannot_disguise_existing_record_as_add(kind,tmp_path,monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(transactions.manager,'broadcast',quiet)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'linked.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                save,data,model,category,add,edit=case(kind)
                data.link_id='linked-action-test'
                if kind=='settlement': data.add_to_daily=True
                assert (await save(request(category,add),data,db))['status']=='success'
                changed=data.model_copy(deep=True)
                changed.statement='linked update'
                if kind=='settlement':changed.doc_id=None
                else:changed.serial=0
                from fastapi import HTTPException
                with pytest.raises(HTTPException) as exc:await save(request(category,add),changed,db)
                assert exc.value.status_code==403
                await db.rollback()
                assert (await save(request(category,edit),changed,db))['status']=='success'
                assert await db.scalar(select(func.count()).select_from(model))==1
        finally:await engine.dispose()
    asyncio.run(main())


@pytest.mark.parametrize('category',['المبيعات','المرتجعات','التحويلات المخزنية'])
def test_operational_stock_access_respects_edit_includes_add(category,tmp_path):
    from app.routes import commercial
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'stock-rights.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                assert await commercial.stock_events('C1',request(category,'تعديل'),db)==[]
        finally:await engine.dispose()
    asyncio.run(main())
