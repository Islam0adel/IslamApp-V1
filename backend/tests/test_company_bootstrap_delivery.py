"""Bootstrap holds actual handshake/live/queued-push paths, not just projection."""
import asyncio
import pytest
from sqlalchemy import select, func
from app.core import models, notification_events as events, fcm_service as fcm
from app.routes import sync as routes
from test_company_policy_socket import fixture as socket_fixture, HandshakeSocket
from test_company_policy_live_delivery import fixture as live_fixture, business, business_messages
from test_company_policy_push import fixture as push_fixture, event

@pytest.mark.parametrize('role,allowed',[('admin',False),('employee',False),('super_admin',True)])
def test_new_company_gate_is_enforced_by_actual_socket_handshake(role,allowed,tmp_path,monkeypatch):
    async def run():
        async with socket_fixture(tmp_path,monkeypatch,active=False,role=role) as (_,_,manager,factory,_):
            async with factory() as session:
                company=await session.get(models.Company,'C1');company.requires_permission_review=True;await session.commit()
            socket=HandshakeSocket();await routes.websocket_endpoint(socket,'C1')
            assert bool(manager.registered) is allowed
            assert socket.closed==([] if allowed else [1008])
    asyncio.run(run())


def test_live_delivery_reads_new_company_gate_without_a_local_epoch_change(tmp_path,monkeypatch):
    async def run():
        async with live_fixture(tmp_path,monkeypatch) as (_,_,factory,_,manager,socket):
            async with factory() as session:
                company=await session.get(models.Company,'C1');company.requires_permission_review=True;await session.commit()
            await manager.broadcast('C1',business())
            assert not business_messages(socket)
            assert manager.connection_profiles[socket]['_permissions_invalidated'] is True
    asyncio.run(run())


def test_new_company_gate_prevents_notification_persistence_and_queue_creation(tmp_path,monkeypatch):
    async def run():
        async with push_fixture(tmp_path,monkeypatch) as (_,_,factory,_,queued,sent):
            async with factory() as session:
                company=await session.get(models.Company,'C1');company.requires_permission_review=True;await session.commit()
            await events.prepare_and_persist_event('C1',event())
            assert not queued and not sent
            async with factory() as session:
                assert await session.scalar(select(func.count()).select_from(models.Notification))==0
    asyncio.run(run())


def test_already_queued_push_is_rechecked_against_bootstrap_gate_at_execution(tmp_path,monkeypatch):
    async def run():
        async with push_fixture(tmp_path,monkeypatch) as (_,_,factory,_,queued,sent):
            await events.prepare_and_persist_event('C1',event())
            assert len(queued)==1
            async with factory() as session:
                company=await session.get(models.Company,'C1');company.requires_permission_review=True;await session.commit()
            work=fcm.send_push_to_user_bg(**queued[0]);assert work is not None;await work
            assert not sent
    asyncio.run(run())
