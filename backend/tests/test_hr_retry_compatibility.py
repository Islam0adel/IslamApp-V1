"""HR exact retries never become add-only edits or a new read grant."""
import asyncio
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import event,select
from sqlalchemy.ext.asyncio import create_async_engine,async_sessionmaker
from app.core.database import Base
from app.core import models,schemas
from app.routes import hr

SCENARIOS=['own-create','other-actor','changed-payload','deleted','revoked','branch-revoked','other-company','legacy-readable','legacy-unreadable','legacy-hidden-employee','missing-uid']

@pytest.mark.parametrize('kind',['attendance','vacation'])
@pytest.mark.parametrize('scenario',SCENARIOS)
def test_exact_retry_is_no_write_and_requires_creator_or_existing_read_scope(kind,scenario,tmp_path,monkeypatch):
    broadcasts=[]
    async def broadcast(*args,**kwargs):broadcasts.append(args)
    monkeypatch.setattr(hr.manager,'broadcast',broadcast)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'retry.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        writes=[]
        @event.listens_for(engine.sync_engine,'before_cursor_execute')
        def record_write(conn,cursor,statement,parameters,context,executemany):
            if statement.lstrip().upper().startswith(('UPDATE','INSERT','DELETE')):writes.append(statement)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                if kind=='attendance':
                    save=hr.save_attendance;model=models.HRAttendance
                    data=schemas.HRAttendanceModel(company_code='C1',branch_code='B1',employee_code='E1',date='2026-11-22',notes='initial')
                    add='canAddAttendance';read='canOpenAttendancePage';field='notes';serialize=hr.serialize_attendance
                else:
                    save=hr.save_vacation;model=models.HRVacation
                    data=schemas.HRVacationModel(company_code='C1',branch_code='B1',date='2026-11-22',name='initial')
                    add='canAddVacation';read='canOpenVacationsPage';field='name';serialize=hr.serialize_vacation
                profile={'uid':'' if scenario=='missing-uid' else 'u1','role':'employee','company_code':'C1','allowed_branches':['B1'],'permissions':{'الموارد البشرية':{add:True}}}
                request=SimpleNamespace(state=SimpleNamespace(auth_user=profile))
                first=await save(request,data,db)
                assert first['status']=='success'
                row=await db.scalar(select(model))
                assert serialize(row)['created_by'] is None
                assert len(broadcasts)==1
                if scenario.startswith('legacy-'):
                    row.created_by=None;await db.commit();await db.refresh(row)
                timestamp=row.updated_at
                changed=data.model_copy(deep=True)
                if scenario=='other-actor':profile['uid']='u2'
                if scenario=='changed-payload':setattr(changed,field,'changed')
                if scenario=='deleted':row.is_deleted=True;await db.commit();await db.refresh(row);timestamp=row.updated_at
                if scenario=='revoked':profile['permissions']={}
                if scenario=='branch-revoked':profile['allowed_branches']=['B2']
                if scenario=='other-company':profile['company_code']='C2'
                if scenario in {'legacy-readable','legacy-hidden-employee'}:
                    profile['permissions']['الموارد البشرية'][read]=True
                    if scenario=='legacy-hidden-employee':profile['hr_viewable_employees']=['E2']
                writes.clear()
                if scenario in {'own-create','legacy-readable'}:
                    replay=await save(request,changed,db)
                    assert replay=={'status':'success','id':first['id'],'action':'unchanged'}
                else:
                    with pytest.raises(HTTPException) as exc:await save(request,changed,db)
                    assert exc.value.status_code==403
                    await db.rollback()
                assert writes==[]
                assert len(broadcasts)==1
                await db.refresh(row)
                assert row.updated_at==timestamp
                assert getattr(row,field)=='initial'
                assert bool(row.is_deleted)==(scenario=='deleted')
        finally:await engine.dispose()
    asyncio.run(main())


def test_legacy_creator_email_is_preserved_but_internal_marker_is_not_exposed():
    assert hr._public_creator('old@example.test')=='old@example.test'
    assert hr._public_creator('urn:islamapp:creator:u1') is None


@pytest.mark.parametrize('target',['global','employee'])
def test_vacation_retry_uses_normalized_target_without_new_read_right(target,tmp_path,monkeypatch):
    async def quiet(*args,**kwargs):pass
    monkeypatch.setattr(hr.manager,'broadcast',quiet)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'target.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn:await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                profile={'uid':'u1','role':'employee','company_code':'C1','allowed_branches':['B1'],'permissions':{'الموارد البشرية':{'canAddVacation':True}}}
                request=SimpleNamespace(state=SimpleNamespace(auth_user=profile))
                data=schemas.HRVacationModel(company_code='C1',branch_code='B1' if target=='employee' else None,employee_code='E1' if target=='employee' else None,date='2026-11-22',name='Holiday')
                initial=await hr.save_vacation(request,data,db)
                assert (await hr.save_vacation(request,data,db))=={'status':'success','id':initial['id'],'action':'unchanged'}
                row=await db.scalar(select(models.HRVacation))
                assert row.branch_code is None
        finally:await engine.dispose()
    asyncio.run(main())
