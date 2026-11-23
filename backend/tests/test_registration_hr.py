"""Registration HR ownership with actual SQL, no live identity services."""
import asyncio
import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models
from app.core.registration_hr import link_registration_employee
from app.routes import auth

@pytest.mark.parametrize('path,owner', [(path,owner) for path in ['manual','email','phone'] for owner in ['none','same','other-uid','other-email'] if path=='manual' or owner!='other-email'])
def test_registration_never_takes_an_owned_hr_identity(path,owner,tmp_path):
    async def run():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'hr.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        email='new@example.invalid';uid='new-uid'
        old_uid={'none':'','same':uid,'other-uid':'other-uid','other-email':''}[owner]
        old_email={'none':'','same':email,'other-uid':email,'other-email':'other@example.invalid'}[owner]
        try:
            async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
            async with factory() as db:
                db.add(models.Company(code='C1',name='One',is_active=True))
                db.add(models.Employee(company_code='C1',code='E1',name='Employee',phone='01012345678',user_uid=old_uid,
                    user_email='' if path=='phone' else (email if path=='email' else old_email),branch_code='B1',salary=123))
                await db.commit()
                async def operation():
                    if path=='manual':return await link_registration_employee(db,company_code='C1',employee_code='E1',uid=uid,email=email,invited_phone='01012345678')
                    return await auth._auto_create_employee_if_needed(db,email,uid,'Name','01012345678','C1','')
                conflict=owner.startswith('other')
                if conflict:
                    with pytest.raises(HTTPException) as error:await operation()
                    assert error.value.status_code==409
                else:
                    value=await operation();assert value['code']=='E1'
                row=await db.scalar(select(models.Employee).where(models.Employee.code=='E1'))
                assert row.salary==123 and row.branch_code=='B1'
                if conflict:assert row.user_uid==old_uid
                else:assert row.user_uid==uid and row.user_email==email
        finally:await engine.dispose()
    asyncio.run(run())


def test_unowned_employee_code_alone_is_not_identity_proof(tmp_path):
    async def run():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'unowned.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        try:
            async with engine.begin() as conn:await conn.run_sync(models.Base.metadata.create_all)
            async with factory() as db:
                db.add(models.Company(code='C1',name='One',is_active=True))
                db.add(models.Employee(company_code='C1',code='E1',name='Unowned'))
                await db.commit()
                with pytest.raises(HTTPException) as error:
                    await link_registration_employee(db,company_code='C1',employee_code='E1',uid='new',email='new@example.invalid')
                assert error.value.status_code==403
                row=await db.scalar(select(models.Employee));assert not row.user_uid
        finally:await engine.dispose()
    asyncio.run(run())
