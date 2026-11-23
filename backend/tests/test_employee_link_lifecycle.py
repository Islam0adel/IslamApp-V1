"""Employee creation and account-link notifications share one initialized lifecycle."""
import asyncio
from types import SimpleNamespace
import pytest
from sqlalchemy import select,func
from sqlalchemy.ext.asyncio import create_async_engine,async_sessionmaker
from app.core import models,schemas
from app.routes import employees

@pytest.mark.parametrize('scenario',['new-unlinked','new-linked','changed','removed','unchanged'])
def test_employee_link_lifecycle(scenario,tmp_path,monkeypatch):
    broadcasts=[];notifications=[]
    async def broadcast(*args,**kwargs):broadcasts.append(args)
    async def notify(company,targets):
        notifications.extend(target.email for target in targets if target.email)
    monkeypatch.setattr(employees.manager,'broadcast',broadcast)
    monkeypatch.setattr(employees.manager,'notify_hr_link_changed',notify)
    async def work():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'employees.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        try:
            async with engine.begin() as connection:await connection.run_sync(models.Base.metadata.create_all)
            async with factory() as db:
                if not scenario.startswith('new'):
                    db.add(models.Employee(company_code='C1',code='E1',name='Fixture',branch_code='B1',salary=23.5,user_uid='old-uid',user_email='old@example.invalid'))
                    await db.commit()
                uid,email='',''
                if scenario in ('new-linked','changed'):uid,email='new-uid','new@example.invalid'
                if scenario=='unchanged':uid,email='old-uid','old@example.invalid'
                data=schemas.EmployeeModel(company_code='C1',code='E1',name='Fixture',branch_code='B1',salary=23.5,user_uid=uid,user_email=email)
                actor=SimpleNamespace(state=SimpleNamespace(auth_user={'role':'admin','company_code':'C1','uid':'fixture'}))
                result=await employees.save_employee(data,actor,db)
                assert result['status']=='success'
                assert result['action']==('insert' if scenario.startswith('new') else 'update')
                assert await db.scalar(select(func.count()).select_from(models.Employee))==1
                row=await db.scalar(select(models.Employee))
                assert row.branch_code=='B1' and row.salary==23.5
                assert (row.user_uid,row.user_email)==(uid,email)
                assert len(broadcasts)==1
                expected={'new-unlinked':set(),'new-linked':{'new@example.invalid'},'changed':{'old@example.invalid','new@example.invalid'},'removed':{'old@example.invalid'},'unchanged':set()}[scenario]
                assert set(notifications)==expected
        finally:await engine.dispose()
    asyncio.run(work())
