"""Real HR read/delivery paths with synthetic identities and temporary SQLite."""
import asyncio,copy
import pytest
from fastapi import HTTPException
from sqlalchemy import select,update
from app.core import models,database as core_db,notification_events as events
from app.core.hr_identity import resolve_own_employee_code
from app.routes import employees,hr,notifications
from test_notification_revocation import OLD,EMAIL,request,notification_db,setup_source,Socket


def profile(*,own=True,broad=False,restricted=False,salary=False):
    flags={'canViewOwnHRData':own,'canViewSalaryAmounts':salary}
    if broad:flags.update({'canViewEmployees':True,'canViewAdjustments':True})
    return {**copy.deepcopy(OLD),'permissions':{'الموارد البشرية':flags},
        'allowed_branches':['B2'] if restricted else ['B1'],
        'hr_viewable_employees':['E2'] if restricted else None}


async def seed(factory,conflict=False):
    async with factory() as db:
        db.add_all([
            models.Employee(company_code='C1',code='E1',name='Synthetic self',branch_code='B1',
                user_uid=OLD['uid'],user_email=EMAIL,salary=111,phone='OWN_SYNTHETIC_PHONE'),
            models.Employee(company_code='C1',code='E2',name='Synthetic other',branch_code='B1',
                user_uid='other-uid',user_email=EMAIL if conflict else 'other@example.invalid',salary=999),
            models.Employee(company_code='C2',code='E1',name='Synthetic other company',branch_code='B1',
                user_uid=OLD['uid'],user_email=EMAIL,salary=777),
        ])
        for code,amount in [('E1',11),('E2',99)]:
            db.add(models.HRAdjustment(company_code='C1',employee_code=code,branch_code='B1',month='2026-11',
                date='2026-11-01',type='bonus',amount=amount,reason='Synthetic bonus'))
        await db.commit()


def event(code,event_type='employee'):
    data={'company_code':'C1','branch_code':'B1','name':'Synthetic self' if code=='E1' else 'Synthetic other'}
    if event_type=='employee':data.update({'code':code,'user_uid':OLD['uid'] if code=='E1' else 'other-uid',
        'user_email':EMAIL if code=='E1' else 'other@example.invalid','salary':111 if code=='E1' else 999})
    else:data.update({'employee_code':code,'id':'fixture-'+code,'date':'2026-11-01','amount':11 if code=='E1' else 99})
    return {'type':event_type,'action':'update','data':data}


def test_conflicting_email_cannot_override_explicit_uid_in_any_employee_read(tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory,conflict=True);p=profile()
            async with factory() as db:
                for read in [lambda:employees.get_employee('C1','E2',request(p),db),
                    lambda:employees.get_employee_profile('C1','E2',request(p),month='2026-11',db=db),
                    lambda:hr._authorize_employee_target(request(p),db,'C1','E2')]:
                    with pytest.raises(HTTPException) as error:await read()
                    assert error.value.status_code==403
                rows=await employees.list_employees('C1',request(p),db)
                assert [row['code'] for row in rows]==['E1']
                changes=await employees.get_employee_changes('C1',request(p),since='2000-01-01T00:00:00',db=db)
                assert [row['code'] for row in changes]==['E1']
                assert await resolve_own_employee_code(db,'C1',p)=='E1'
    asyncio.run(run())


@pytest.mark.parametrize('reference_grant',[False,True])
def test_identity_without_explicit_own_right_does_not_open_profile(reference_grant,tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);p=profile(own=False)
            if reference_grant:p['permissions']['المبيعات']={'إضافة':True}
            async with factory() as db:
                with pytest.raises(HTTPException) as error:
                    await employees.get_employee_profile('C1','E1',request(p),month='2026-11',db=db)
                assert error.value.status_code==403
    asyncio.run(run())


@pytest.mark.parametrize('broad',[False,True])
def test_explicit_own_access_survives_branch_and_employee_list_exclusion(broad,tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);p=profile(broad=broad,restricted=True)
            async with factory() as db:
                row=await employees.get_employee('C1','E1',request(p),db)
                assert row['salary']==111 and row['phone']=='OWN_SYNTHETIC_PHONE'
                result=await employees.get_employee_profile('C1','E1',request(p),month='2026-11',db=db)
                assert result['employee']['salary']==111
                assert result['adjustments']['records'][0]['amount']==11
                assert result['adjustments']['summary']['bonuses_total']==11
                assert [item['code'] for item in await employees.list_employees('C1',request(p),db)]==['E1']
                assert [item['code'] for item in await employees.get_employee_changes('C1',request(p),since='2000-01-01',db=db)]==['E1']
                assert await hr._authorize_employee_target(request(p),db,'C1','E1') is p
                own_docs=[type('Doc',(),{'employee_code':'E1','branch_code':'B1'})(),
                    type('Doc',(),{'employee_code':'E2','branch_code':'B1'})()]
                assert await hr._filter_docs(db,own_docs,'C1',p)==own_docs[:1]
                with pytest.raises(HTTPException):await employees.get_employee('C1','E2',request(p),db)
                with pytest.raises(HTTPException):await employees.get_employee('C2','E1',request(p),db)
    asyncio.run(run())


@pytest.mark.parametrize('event_type',['employee','hr_attendance','hr_vacation','hr_adjustment','hr_employee_settings'])
@pytest.mark.parametrize('broad',[False,True])
def test_own_notifications_live_history_push_share_approved_precedence(event_type,broad,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile(broad=broad,restricted=True));pushes=[]
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            await manager.broadcast('C1',event('E1',event_type))
            assert len(socket.sent)==1 and len(pushes)==1
            assert socket.sent[0]['notification_scope']=={'employee_code':'E1','is_self':True}
            if event_type=='employee':assert socket.sent[0]['data']['salary']==111
            if event_type=='hr_adjustment':assert socket.sent[0]['data']['amount']==11
            async with factory() as db:
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert len(result['items'])==1
                assert result['items'][0]['notification_scope']['is_self'] is True
    asyncio.run(run())


@pytest.mark.parametrize('bad',[None,[], 'invalid', {'canViewEmployees':'true'}, {'canViewOwnHRData':1}])
def test_malformed_hr_map_or_values_fail_closed_for_live_storage_history_push(bad,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state['permissions']['الموارد البشرية']=bad;pushes=[]
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            await manager.broadcast('C1',event('E2'))
            assert socket.sent==[] and pushes==[]
            async with factory() as db:
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert result['items']==[]
    asyncio.run(run())


@pytest.mark.parametrize('own,salary',[(False,False),(True,False),(False,True)])
def test_financial_fields_are_masked_consistently_without_changing_stored_amounts(own,salary,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile(own=own,broad=True,salary=salary))
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:None)
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            async with factory() as db:
                for code,visible in [('E1',own or salary),('E2',salary)]:
                    result=await employees.get_employee_profile('C1',code,request(state),month='2026-11',db=db)
                    assert (result['employee']['salary'] is not None)==visible
                    assert (result['adjustments']['records'][0]['amount'] is not None)==visible
                    assert (result['adjustments']['summary']['bonuses_total'] is not None)==visible
                    records=await hr.list_employee_adjustments(request(state),'C1',code,month='2026-11',db=db)
                    assert (records[0]['amount'] is not None)==visible
                listed=await hr.list_adjustments(request(state),'C1',month='2026-11',branch_code=None,db=db)
                changed=await hr.get_adjustment_changes(request(state),'C1',since='2000-01-01',db=db)
                for records in [listed,changed]:
                    values={row['employee_code']:row['amount'] for row in records}
                    assert values=={'E1':11 if own or salary else None,'E2':99 if salary else None}
                assert await db.scalar(select(models.Employee.salary).where(models.Employee.company_code=='C1',models.Employee.code=='E2'))==999
                assert await db.scalar(select(models.HRAdjustment.amount).where(models.HRAdjustment.employee_code=='E2'))==99
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            for code,visible in [('E1',own or salary),('E2',salary)]:
                await manager.broadcast('C1',event(code,'employee'))
                assert ('salary' in socket.sent[-1]['data'])==visible
                await manager.broadcast('C1',event(code,'hr_adjustment'))
                assert ('amount' in socket.sent[-1]['data'])==visible
    asyncio.run(run())


@pytest.mark.parametrize('own',[False,True])
def test_salary_report_self_amounts_require_an_actual_own_or_salary_right(own,tmp_path,monkeypatch):
    async def fake_calculator(**kwargs):return {'employee_code':'E1','net_salary':111,'elapsed_days':1}
    monkeypatch.setattr(hr,'calculate_salary',fake_calculator)
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);p=profile(own=own)
            p['permissions']['الموارد البشرية']['canOpenReportPage']=True
            async with factory() as db:
                result=await hr.get_salary_report(request(p),'C1','E1',month='2026-11',db=db)
                assert ('net_salary' in result)==own
                assert result['elapsed_days']==1
    asyncio.run(run())


def test_ambiguous_default_self_link_is_not_guessed_and_email_only_fallback_is_kept(tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);p=profile()
            async with factory() as db:
                await db.execute(update(models.Employee).where(models.Employee.company_code=='C1',models.Employee.code=='E2')
                    .values(user_uid=OLD['uid']))
                await db.commit()
                assert await resolve_own_employee_code(db,'C1',p) is None
                await db.execute(update(models.Employee).where(models.Employee.company_code=='C1',models.Employee.code=='E2')
                    .values(user_uid='other-uid'))
                await db.execute(update(models.Employee).where(models.Employee.company_code=='C1',models.Employee.code=='E1')
                    .values(user_uid=None,user_email='  '+EMAIL.upper()+'  '))
                await db.commit()
                assert await resolve_own_employee_code(db,'C1',p)=='E1'
    asyncio.run(run())

def test_shared_identity_contract_matches_sql_filter_and_default_resolution(tmp_path,monkeypatch):
    import json
    from pathlib import Path
    from types import SimpleNamespace
    from app.core.hr_identity import HRTarget,employee_self_clause
    contract=json.loads((Path(__file__).resolve().parents[2]/'contracts/employee_identity.json').read_text())
    assert contract['schema_version']==1
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            for index,case in enumerate(contract['cases']):
                company='contract-'+str(index)
                row={'name':'Synthetic contract',**case['row']}
                assert HRTarget.from_employee(SimpleNamespace(**row)).is_self(case['actor'])==case['self']
                async with factory() as db:
                    db.add(models.Employee(company_code=company,**row));await db.commit()
                    selected=(await db.execute(select(models.Employee.code).where(models.Employee.company_code==company,
                        models.Employee.is_deleted.is_(False),employee_self_clause(case['actor'])))).scalars().all()
                    assert bool(selected)==case['self']
                    assert await resolve_own_employee_code(db,company,case['actor'])==('E1' if case['self'] else None)
    asyncio.run(run())


@pytest.mark.parametrize('key',['إظهار الإشعارات','إظهار الموارد البشرية'])
def test_own_right_does_not_turn_disabled_notifications_into_pushes(key,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile());state['permissions']['صلاحيات عامة']={key:False}
    pushes=[];monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            await manager.broadcast('C1',event('E1'))
            assert len(socket.sent)==1  # Authorized own-data sync is separate from an alert.
            assert not pushes
            async with factory() as db:
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert result['items']==[]
    asyncio.run(run())
