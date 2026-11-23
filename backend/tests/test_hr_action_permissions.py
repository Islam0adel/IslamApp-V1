import asyncio
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import create_async_engine,async_sessionmaker
from app.core.database import Base
from app.core import models,schemas
from app.routes import hr


def request(right):
    return SimpleNamespace(state=SimpleNamespace(auth_user={'role':'employee','uid':'u1','company_code':'C1','allowed_branches':['B1'],'permissions':{'الموارد البشرية':{right:True}}}))


@pytest.mark.parametrize('kind',['attendance','vacation'])
@pytest.mark.parametrize('create_with_edit',[False,True])
def test_hr_save_uses_actual_action(kind,create_with_edit,tmp_path,monkeypatch):
    async def quiet(*args,**kwargs): pass
    monkeypatch.setattr(hr.manager,'broadcast',quiet)
    async def main():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'hr-action.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as conn: await conn.run_sync(Base.metadata.create_all)
        try:
            async with factory() as db:
                if kind=='attendance':
                    save=hr.save_attendance
                    data=schemas.HRAttendanceModel(company_code='C1',branch_code='B1',employee_code='E1',date='2026-11-22',notes='initial')
                    model=models.HRAttendance; add='canAddAttendance';edit='canEditAttendance';field='notes'
                else:
                    save=hr.save_vacation
                    data=schemas.HRVacationModel(company_code='C1',branch_code='B1',date='2026-11-22',name='initial')
                    model=models.HRVacation;add='canAddVacation';edit='canEditVacation';field='name'
                result=await save(request(edit if create_with_edit else add),data,db)
                assert result['status']=='success'
                changed=data.model_copy(deep=True,update={field:'changed'})
                with pytest.raises(HTTPException) as exc:
                    await save(request(add),changed,db)
                assert exc.value.status_code==403
                await db.rollback()
                row=await db.scalar(select(model))
                assert getattr(row,field)=='initial'
                result=await save(request(edit),changed,db)
                assert result['status']=='success'
                await db.refresh(row)
                assert getattr(row,field)=='changed'
        finally: await engine.dispose()
    asyncio.run(main())
