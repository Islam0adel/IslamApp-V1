from policy_fixtures import legacy_delivery_policy, payload_only_manager
"""Independent-record route tests. Temporary SQLite, no live systems."""
import asyncio
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import event, select, func
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from sqlalchemy.exc import IntegrityError
from app.core.database import Base
from app.core.models import TreasuryTransferRecord, Transaction
from app.routes import treasury_transfers as route
from app.core.notification_events import _can_view_section


def req(role='admin',company='C1',uid='u1',branches=None,perms=None):
    return SimpleNamespace(state=SimpleNamespace(auth_user=dict(role=role,company_code=company,
        uid=uid,allowed_branches=branches or ['all'],permissions=perms or {})))


def data(**extra):
    return route.TreasuryTransferModel(**dict(id='transfer-one',company_code='C1',branch_code='B1',
        from_treasury='A',to_treasury='B',amount=100.25,date='2026-11-22',
        employee='test',statement='memo',**extra))


def changed(base,**extra):
    return route.TreasuryTransferModel(**{**base.model_dump(),**extra})


def run(tmp_path,monkeypatch,scenario):
    async def no_notice(*a,**kw):pass
    monkeypatch.setattr(route.manager,'broadcast',no_notice)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'treasury.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:await scenario(factory,engine)
        finally:await engine.dispose()
    asyncio.run(main())


def test_create_one_record_no_journal_and_effects_once(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            result=await route.save_transfer(req(),data(),db)
            assert result['record']['serial']==1
            assert await db.scalar(select(func.count()).select_from(TreasuryTransferRecord))==1
            assert await db.scalar(select(func.count()).select_from(Transaction))==0
            effects=await route.transfer_effects(req(),'C1',db)
            assert [(r['treasury'],r['signed_amount']) for r in effects]==[('A',-100.25),('B',100.25)]
            assert set(effects[0])=={'company_code','branch_code','date','treasury','signed_amount'}
            assert sum(r['signed_amount'] for r in effects)==0
    run(tmp_path,monkeypatch,scenario)


def test_add_only_lost_reply_retry_is_idempotent(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        user=req(role='employee',perms={'تحويلات الخزائن':{'إضافة':True}})
        async with factory() as db:
            first=await route.save_transfer(user,data(),db)
            retry=await route.save_transfer(user,data(),db)
            assert first['record']==retry['record']
            assert await db.scalar(select(func.count()).select_from(TreasuryTransferRecord))==1
            with pytest.raises(HTTPException) as exc:
                await route.save_transfer(user,changed(data(),amount=150),db)
            assert exc.value.status_code==403
    run(tmp_path,monkeypatch,scenario)


def test_versioned_edit_and_stale_edit_rejection(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            first=await route.save_transfer(req(),data(),db)
            edit=changed(data(),amount=30,serial=1,base_updated_at=first['record']['updated_at'])
            newer=await route.save_transfer(req(),edit,db)
            assert newer['record']['amount']==30
            assert (await route.save_transfer(req(),edit,db))['record']==newer['record']
            with pytest.raises(HTTPException) as exc:
                await route.save_transfer(req(),changed(edit,amount=40),db)
            assert exc.value.status_code==409
    run(tmp_path,monkeypatch,scenario)


def test_failed_commit_has_no_transfer_or_journal(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        def fail(conn,cursor,statement,parameters,context,executemany):
            if statement.startswith('INSERT INTO treasury_transfers '):raise RuntimeError('injected database failure')
        event.listen(engine.sync_engine,'before_cursor_execute',fail)
        async with factory() as db:
            with pytest.raises(HTTPException) as exc:await route.save_transfer(req(),data(),db)
            assert exc.value.status_code==500
            assert await db.scalar(select(func.count()).select_from(TreasuryTransferRecord))==0
            assert await db.scalar(select(func.count()).select_from(Transaction))==0
    run(tmp_path,monkeypatch,scenario)


def test_serial_collision_retries_without_duplicate_record(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        hits=[]
        def fail_once(conn,cursor,statement,parameters,context,executemany):
            if statement.startswith('INSERT INTO treasury_transfers '):
                hits.append(1)
                if len(hits)==1:raise IntegrityError('injected',{},Exception('serial conflict'))
        event.listen(engine.sync_engine,'before_cursor_execute',fail_once)
        async with factory() as db:
            await route.save_transfer(req(),data(),db)
            assert len(hits)==2
            assert await db.scalar(select(func.count()).select_from(TreasuryTransferRecord))==1
    run(tmp_path,monkeypatch,scenario)


def test_soft_delete_retry_and_no_resurrection_or_serial_reuse(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            created=await route.save_transfer(req(),data(),db)
            deleted=await route.delete_transfer(req(),'C1','transfer-one',db,base_updated_at=created['record']['updated_at'])
            assert deleted['record']['is_deleted']
            assert await route.delete_transfer(req(),'C1','transfer-one',db)==deleted
            assert await route.transfer_effects(req(),'C1',db)==[]
            with pytest.raises(HTTPException) as exc:await route.save_transfer(req(),data(),db)
            assert exc.value.status_code==404
            second=await route.save_transfer(req(),changed(data(),id='transfer-two'),db)
            assert second['record']['serial']==2
    run(tmp_path,monkeypatch,scenario)


def test_permission_safe_effects_without_raw_details(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        user=req(role='employee',branches=['B1'],perms={'حركة الخزينة':{'شاشات الارصدة':True}})
        async with factory() as db:
            await route.save_transfer(req(),data(),db)
            await route.save_transfer(req(),changed(data(),id='B2-transfer',branch_code='B2'),db)
            effects=await route.transfer_effects(user,'C1',db)
            assert effects and all(r['branch_code']=='B1' for r in effects)
            assert all('employee' not in r and 'statement' not in r and 'id' not in r for r in effects)
            with pytest.raises(HTTPException) as exc:await route.list_transfers(user,'C1',db=db)
            assert exc.value.status_code==403
            assert _can_view_section(user.state.auth_user,'treasury_effects')
            assert not _can_view_section(user.state.auth_user,'treasury_transfers')
    run(tmp_path,monkeypatch,scenario)


@pytest.mark.parametrize('user',[
    req(role='employee'),
    req(company='C2'),
    req(role='employee',branches=['B2'],perms={'تحويلات الخزائن':{'إضافة':True}}),
])
def test_create_denies_missing_right_company_or_branch(user):
    with pytest.raises(HTTPException) as exc:asyncio.run(route.save_transfer(user,data(),None))
    assert exc.value.status_code==403


def test_calculator_right_does_not_imply_write_permission():
    user=req(role='employee',perms={'التقارير':{'تقرير فترة':True}})
    with pytest.raises(HTTPException) as exc:
        # The DB must never be needed to decide a new record's write rights.
        asyncio.run(route.save_transfer(user,data(),None))
    assert exc.value.status_code==403


def test_stale_delete_does_not_remove_newer_transfer(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            first=await route.save_transfer(req(),data(),db)
            await route.save_transfer(req(),changed(data(),amount=25,serial=1,base_updated_at=first['record']['updated_at']),db)
            with pytest.raises(HTTPException) as exc:
                await route.delete_transfer(req(),'C1','transfer-one',db,base_updated_at=first['record']['updated_at'])
            assert exc.value.status_code==409
            rows=await route.list_transfers(req(),'C1',db=db)
            assert len(rows)==1 and rows[0]['amount']==25
    run(tmp_path,monkeypatch,scenario)


def test_invalidation_still_runs_when_raw_notification_fails(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        calls=[]
        async def fail_raw(company,message):
            calls.append(message['type'])
            if message['type']=='treasury_transfer':raise RuntimeError('injected delivery failure')
        monkeypatch.setattr(route.manager,'broadcast',fail_raw)
        async with factory() as db:
            result=await route.save_transfer(req(),data(),db)
            assert result['status']=='success'
            assert calls==['treasury_transfer','treasury_balance_changed']
    run(tmp_path,monkeypatch,scenario)


def test_legacy_journal_transfer_creation_is_no_longer_an_alternate_entry():
    from app.routes import transactions
    legacy = SimpleNamespace(branch_code='B1',category='تحويل خزائن')
    with pytest.raises(HTTPException) as exc:
        asyncio.run(transactions.save_transaction(req(),legacy,None))
    assert exc.value.status_code==409


def test_legacy_journal_delete_cannot_guess_or_mutate_counterpart():
    from app.routes import transactions
    legacy = SimpleNamespace(category='تحويل خزائن',is_deleted=False)
    class DB:
        async def execute(self,*a,**kw):
            return SimpleNamespace(scalar_one_or_none=lambda:legacy)
        async def rollback(self):pass
    with pytest.raises(HTTPException) as exc:
        asyncio.run(transactions.delete_transaction(req(),'C1','B1',1,DB()))
    assert exc.value.status_code==409
    assert not legacy.is_deleted


def test_treasury_data_updates_do_not_override_notification_opt_out():
    from app.core.sync import ConnectionManager
    class WS:
        def __init__(self):self.sent=[]
        async def send_json(self,message):self.sent.append(message)
    async def main():
        manager=payload_only_manager()
        viewer,calculator,denied,other=WS(),WS(),WS(),WS()
        manager.active_connections['C1']={viewer,calculator,denied,other}
        def profile(perms,branch='B1'):
            return {'role':'employee','allowed_branches':[branch], 'permissions':{
                'صلاحيات عامة':{'إظهار الإشعارات':False},**perms}}
        manager.connection_profiles[viewer]=profile({'تحويلات الخزائن':{'معاينة':True}})
        manager.connection_profiles[calculator]=profile({'حركة الخزينة':{'شاشات الارصدة':True}})
        manager.connection_profiles[denied]=profile({})
        manager.connection_profiles[other]=profile({'حركة الخزينة':{'شاشات الارصدة':True}},'B2')
        assert not _can_view_section(manager.connection_profiles[viewer],'treasury_transfers')
        assert not _can_view_section(manager.connection_profiles[calculator],'treasury_effects')
        await manager.broadcast('C1',{'type':'treasury_transfer','data':{'branch_code':'B1'},'suppress_notification':True})
        await manager.broadcast('C1',{'type':'treasury_balance_changed','data':{'branch_code':'B1'},'suppress_notification':True})
        assert [m['type'] for m in viewer.sent]==['treasury_transfer']
        assert [m['type'] for m in calculator.sent]==['treasury_balance_changed']
        assert denied.sent==[] and other.sent==[]
    asyncio.run(main())


def test_revision_bootstrap_delta_delete_and_effect_permission_boundary(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            first=await route.save_transfer(req(),data(),db)
            initial=await route.treasury_changes(req(),'records','C1',0,'',db)
            assert initial['reset'] is True and len(initial['items'])==1
            checkpoint=initial['cursor']; scope=initial['scope']
            empty=await route.treasury_changes(req(),'records','C1',checkpoint,scope,db)
            assert empty['reset'] is False and empty['items']==[] and empty['cursor']==checkpoint
            edit=changed(data(),amount=40,to_treasury='C',date='2026-11-23',serial=1,base_updated_at=first['record']['updated_at'])
            saved=await route.save_transfer(req(),edit,db)
            delta=await route.treasury_changes(req(),'records','C1',checkpoint,scope,db)
            assert len(delta['items'])==1 and delta['items'][0]['to_treasury']=='C'
            balance=req(role='employee',perms={'التقارير':{'تحليل الخزائن النقدية':True}})
            effects=await route.transfer_effects(balance,'C1',db)
            assert [(e['treasury'],e['signed_amount']) for e in effects]==[('A',-40),('C',40)]
            assert all(set(e)=={'company_code','branch_code','date','treasury','signed_amount'} for e in effects)
            await route.delete_transfer(req(),'C1','transfer-one',db,saved['record']['updated_at'])
            deleted=await route.treasury_changes(req(),'records','C1',delta['cursor'],scope,db)
            assert deleted['items'][0]['is_deleted'] is True
            assert await route.transfer_effects(balance,'C1',db)==[]
            with pytest.raises(HTTPException): await route.treasury_changes(balance,'effects','C1',0,'',db)
            with pytest.raises(HTTPException): await route.treasury_changes(balance,'records','C1',0,'',db)
    run(tmp_path,monkeypatch,scenario)


def test_revision_scope_reset_and_rollback_do_not_skip_commits(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        async with factory() as db:
            await route.save_transfer(req(),data(),db)
            snapshot=await route.treasury_changes(req(),'records','C1',0,'',db)
            denied=req(role='employee',branches=['B2'],perms={route.CATEGORY:{'معاينة':True}})
            restricted=await route.treasury_changes(denied,'records','C1',snapshot['cursor'],snapshot['scope'],db)
            assert restricted['reset'] is True and restricted['items']==[]
            future=await route.treasury_changes(req(),'records','C1',999999,snapshot['scope'],db)
            assert future['reset'] is True and len(future['items'])==1
            from app.core.treasury_sync import lock_state
            state=await lock_state(db,'C1'); state.revision+=1
            await db.flush(); await db.rollback()
            same=await route.treasury_changes(req(),'records','C1',snapshot['cursor'],snapshot['scope'],db)
            assert same['cursor']==snapshot['cursor'] and same['items']==[]
    run(tmp_path,monkeypatch,scenario)


def test_historical_old_rows_bootstrap_and_legacy_endpoint_contract_is_unchanged(tmp_path,monkeypatch):
    async def scenario(factory,engine):
        import datetime
        async with factory() as db:
            db.add(TreasuryTransferRecord(id='historical',company_code='C1',branch_code='B1',serial=4,
                from_treasury='A',to_treasury='B',amount=12,date='2026-01-01',statement='private memo',
                employee='private employee',created_by_uid='old',is_deleted=False,updated_at=datetime.datetime(2026,1,1)))
            db.add(TreasuryTransferRecord(id='deleted-old',company_code='C1',branch_code='B1',serial=5,
                from_treasury='A',to_treasury='B',amount=100,date='2026-01-01',is_deleted=True,
                updated_at=datetime.datetime(2026,1,1)))
            await db.commit()
            legacy=await route.list_transfers(req(),'C1',db=db)
            assert len(legacy)==1 and 'revision' not in legacy[0]
            snap=await route.treasury_changes(req(),'records','C1',0,'',db)
            assert len(snap['items'])==2
            effects=await route.transfer_effects(req(),'C1',db)
            assert 'private memo' not in str(effects) and 'private employee' not in str(effects)
            again=await route.treasury_changes(req(),'records','C1',snap['cursor'],snap['scope'],db)
            assert again['items']==[]
    run(tmp_path,monkeypatch,scenario)
