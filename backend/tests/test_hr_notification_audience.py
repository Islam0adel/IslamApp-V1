"""HR notifications and live data use the same employee target as resource reads.

Actual routes/manager, temporary SQLite, fake identity/Firestore/push transport.
"""
import asyncio
import copy

import pytest
from fastapi import HTTPException
from sqlalchemy import select, func

from app.core import database as core_db, models, notification_events as events
from app.core.hr_audience import HRTarget, stored_target_code
from app.routes import employees, notifications
from test_notification_revocation import (
    OLD, EMAIL, Socket, setup_source, notification_db, request,
)


def profile(kind):
    value = {**copy.deepcopy(OLD), 'allowed_branches': ['B1'],
             'permissions': {'الموارد البشرية': {}}}
    if kind == 'own':
        value['permissions']['الموارد البشرية']['canViewOwnHRData'] = True
    else:
        value['permissions']['الموارد البشرية']['canViewEmployees'] = True
    if kind == 'limited':
        value['hr_viewable_employees'] = ['E1']
    return value


async def seed(factory):
    async with factory() as db:
        db.add_all([
            models.Employee(company_code='C1',code='E1',name='Synthetic self',branch_code='B1',
                            user_uid=OLD['uid'],user_email=EMAIL),
            models.Employee(company_code='C1',code='E2',name='Synthetic other',branch_code='B1',
                            user_uid='other-user',user_email='other@example.invalid'),
        ])
        await db.commit()


def event(code, *, event_type='employee'):
    data = {'company_code':'C1','branch_code':'B1', 'name':'Synthetic '+code}
    if event_type == 'employee':
        data.update({'code':code,'phone':'SYNTHETIC_PRIVATE_PHONE',
                     'user_uid':OLD['uid'] if code=='E1' else 'other-user',
                     'user_email':EMAIL if code=='E1' else 'other@example.invalid'})
    else:
        data.update({'employee_code':code,'id':'fixture-'+code})
    return {'type':event_type,'action':'update','data':data}


@pytest.mark.parametrize('kind', ['own','limited'])
def test_forbidden_E2_is_blocked_at_resource_live_persistence_read_and_push(kind,tmp_path,monkeypatch):
    state, database, manager = setup_source(monkeypatch)
    state.update(profile(kind))
    pushes=[]
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))

    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory)
            await seed(factory)
            socket=Socket()
            await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            async with factory() as db:
                with pytest.raises(HTTPException) as error:
                    await employees.get_employee('C1','E2',request(state),db)
                assert error.value.status_code==403
            await manager.broadcast('C1',event('E2'))
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification))==0
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert result['items']==[]
            assert socket.sent==[] and pushes==[]
    asyncio.run(run())


@pytest.mark.parametrize('kind,code', [('own','E1'),('limited','E1'),('broad','E2')])
def test_allowed_delivery_still_reaches_one_socket_one_notification_one_push(kind,code,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile(kind));pushes=[]
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))

    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            await manager.broadcast('C1',event(code))
            assert len(socket.sent)==1 and len(pushes)==1
            assert socket.sent[0]['notification_scope']['employee_code']==code
            async with factory() as db:
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert len(result['items'])==1
                assert result['items'][0]['notification_scope']['employee_code']==code
                if kind=='own': assert result['items'][0]['notification_scope']['is_self'] is True
    asyncio.run(run())


@pytest.mark.parametrize('event_type', ['hr_attendance','hr_vacation','hr_adjustment','hr_employee_settings'])
def test_visible_employee_list_filters_each_HR_live_event_type(event_type,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile('limited'))
    state['permissions']['الموارد البشرية'].update({
        'canOpenAttendancePage':True,'canOpenVacationsPage':True,'canViewAdjustments':True,
    })
    pushes=[];monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))

    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            await manager.broadcast('C1',event('E2',event_type=event_type))
            assert socket.sent==[] and pushes==[]
    asyncio.run(run())


@pytest.mark.parametrize('right', [False,True])
def test_own_copy_requires_the_own_data_right(right,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch)
    state.update(profile('own'));state['permissions']['الموارد البشرية']['canViewOwnHRData']=right

    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            message=event('E1',event_type='hr_attendance');message['suppress_notification']=True
            await manager.broadcast('C1',message)
            assert len(socket.sent)==int(right)
    asyncio.run(run())


@pytest.mark.parametrize('kind,target_case,expected', [
    ('own','self',1),('own','other',0),('own','unknown',0),('own','conflicting-audit',0),
    ('limited','self',1),('limited','other',0),('limited','unknown',0),
    ('broad','unknown',1),
])
def test_historical_rows_use_audit_target_not_body_or_generic_entity_id(kind,target_case,expected,tmp_path,monkeypatch):
    state,database,manager=setup_source(monkeypatch);state.update(profile(kind))

    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory)
            async with factory() as db:
                db.add(models.Notification(event_id='historical',recipient_uid=OLD['uid'],recipient_email=EMAIL,
                    company_code='C1',branch_code='B1',section='hr_employees',action='edit',
                    title='Synthetic historical',body='Not a trustworthy employee identifier E1',entity_id='E1'))
                if target_case!='unknown':
                    codes=['E1','E2'] if target_case=='conflicting-audit' else ['E1' if target_case=='self' else 'E2']
                    for code in codes:
                        db.add(models.AuditLog(event_id='historical',company_code='C1',section='hr_employees',
                            action='edit',details={'code':code}))
                await db.commit()
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert len(result['items'])==expected
    asyncio.run(run())


def test_target_identity_does_not_fall_back_to_email_when_uid_points_to_someone_else():
    target=HRTarget(code='E2',uid='other-user',email=EMAIL)
    assert not target.is_self(OLD)
    assert HRTarget(code='E1',email=EMAIL.upper()).is_self(OLD)
    assert not HRTarget(code='E1',uid=OLD['uid'],deleted=True).is_self(OLD)


def test_ambiguous_historical_code_is_not_inferred():
    assert stored_target_code({'employee_code':'E1','code':'E2'})==''
    assert stored_target_code({'entity_id':'E1','name':'E1'})==''
    assert stored_target_code({'hr_employee_code':'','code':'E1'})==''

@pytest.mark.parametrize('change', ['delete', 'uid', 'email', 'unlink'])
def test_actual_link_change_invalidates_old_account_and_hides_its_history(change, tmp_path, monkeypatch):
    from test_notification_revocation import ACTOR
    state, database, manager = setup_source(monkeypatch)
    state.update(profile('own'))
    monkeypatch.setattr(employees, 'manager', manager)
    monkeypatch.setattr(events, 'send_push_to_user_bg', lambda **values: None)

    async def run():
        async with notification_db(tmp_path, monkeypatch) as factory:
            monkeypatch.setattr(core_db, 'AsyncSessionLocal', factory)
            await seed(factory)
            old, new, impostor = Socket(), Socket(), Socket()
            await manager.connect('C1', old, accept_connection=False, profile=copy.deepcopy(state))
            new_profile = {**copy.deepcopy(state), 'uid': 'new-linked-uid', 'email': 'new-linked@example.invalid'}
            class Sources:
                def collection(self, name): return self
                def document(self, email):
                    from test_notification_revocation import Document
                    return Document(new_profile if email == new_profile['email'] else state)
            from app.core import sync as live_sync
            monkeypatch.setattr(live_sync, 'firebase_db', Sources())
            await manager.connect('C1', new, accept_connection=False, profile=new_profile)
            await manager.connect('C1', impostor, accept_connection=False,
                                  profile={**copy.deepcopy(state), 'uid': 'conflicting-uid'})
            await manager.broadcast('C1', event('E1'))
            async with factory() as db:
                result = await notifications.list_notifications(request(state), limit=100, after_id=None, unread_only=False, db=db)
                assert len(result['items']) == 1
            old.sent.clear(); new.sent.clear(); impostor.sent.clear()
            async with factory() as db:
                if change == 'delete':
                    result = await employees.delete_employee('C1', 'E1', request(ACTOR), db)
                else:
                    result = await employees.save_employee(employees.EmployeeModel(
                        company_code='C1', code='E1', name='Synthetic self', branch_code='B1',
                        user_uid='new-linked-uid' if change == 'uid' else None,
                        user_email='new-linked@example.invalid' if change == 'email' else None,
                    ), request(ACTOR), db)
                assert result['status'] == 'success'
            assert old.sent and all(msg['type'] == 'permissions_changed' for msg in old.sent)
            assert old.sent[0]['data'] == {'resync': True}
            assert all(msg['type'] == 'permissions_changed' for msg in impostor.sent)
            if change in ('uid', 'email'):
                assert [msg['type'] for msg in new.sent] == ['permissions_changed', 'employee']
            else:
                assert new.sent == []
            async with factory() as db:
                result = await notifications.list_notifications(request(state), limit=100, after_id=None, unread_only=False, db=db)
                assert result['items'] == []
    asyncio.run(run())

@pytest.mark.parametrize('change', ['unlink', 'delete'])
def test_link_change_during_notification_commit_drops_old_live_payload_and_push(change,tmp_path,monkeypatch):
    from sqlalchemy import update
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
    state,database,manager=setup_source(monkeypatch);state.update(profile('own'))
    pushes=[];armed=False;fired=False
    monkeypatch.setattr(events,'send_push_to_user_bg',lambda **values:pushes.append(values))
    class ChangeDuringCommit(AsyncSession):
        async def commit(self):
            nonlocal fired
            if armed and not fired:
                fired=True
                plain=async_sessionmaker(self.bind,expire_on_commit=False)
                async with plain() as other:
                    values={'is_deleted':True} if change=='delete' else {'user_uid':None,'user_email':None}
                    await other.execute(update(models.Employee).where(models.Employee.company_code=='C1',models.Employee.code=='E1').values(**values))
                    await other.commit()
                await manager.notify_hr_link_changed('C1',[HRTarget(code='E1',uid=OLD['uid'],email=EMAIL)])
            await super().commit()
    async def run():
        nonlocal armed
        async with notification_db(tmp_path,monkeypatch,ChangeDuringCommit) as factory:
            monkeypatch.setattr(core_db,'AsyncSessionLocal',factory);await seed(factory)
            socket=Socket();await manager.connect('C1',socket,accept_connection=False,profile=copy.deepcopy(state))
            armed=True
            await manager.broadcast('C1',event('E1'))
            assert fired and not pushes
            assert [msg['type'] for msg in socket.sent]==['permissions_changed']
            async with factory() as db:
                assert await db.scalar(select(func.count()).select_from(models.Notification))==1
                result=await notifications.list_notifications(request(state),limit=100,after_id=None,unread_only=False,db=db)
                assert result['items']==[]
    asyncio.run(run())
