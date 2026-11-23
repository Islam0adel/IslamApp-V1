"""Actual queued sends must not delete usable devices after transient failure."""
import asyncio
import pytest
from types import SimpleNamespace

from sqlalchemy import select
from firebase_admin import messaging, exceptions
from app.core import fcm_service as fcm, models, notification_events as events
from test_company_policy_push import fixture, event, TOKEN

REAL_SEND = fcm._send_sync

def sdk(send):
    return SimpleNamespace(MulticastMessage=lambda **values: values,
        send_each_for_multicast=send, UnregisteredError=messaging.UnregisteredError)

def test_transport_failure_keeps_usable_token_and_does_not_claim_success(tmp_path, monkeypatch, capsys):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, factory, _, queued, _):
            def unavailable(message): raise TimeoutError('Synthetic temporary outage')
            monkeypatch.setattr(fcm, '_send_sync', REAL_SEND)
            monkeypatch.setattr(fcm, '_fb_messaging', sdk(unavailable))
            await events.prepare_and_persist_event('C1', event())
            task = fcm.send_push_to_user_bg(**queued[0]); assert task is not None; await task
            async with factory() as db:
                assert list((await db.scalars(select(models.UserFcmToken.fcm_token))).all()) == [TOKEN]
    asyncio.run(run())
    assert 'FCM sent' not in capsys.readouterr().out


def test_only_confirmed_unregistered_device_is_deleted(tmp_path, monkeypatch, capsys):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (_, _, factory, _, queued, _):
            async with factory() as db:
                db.add(models.UserFcmToken(user_uid='fixture-target', company_code='C1', fcm_token='synthetic-unregistered'))
                await db.commit()
            def result(message):
                responses = [SimpleNamespace(success=False, exception=(messaging.UnregisteredError('Synthetic expired device')
                    if token == 'synthetic-unregistered' else messaging.QuotaExceededError('Synthetic rate limit')))
                    for token in message['tokens']]
                return SimpleNamespace(responses=responses)
            monkeypatch.setattr(fcm, '_send_sync', REAL_SEND)
            monkeypatch.setattr(fcm, '_fb_messaging', sdk(result))
            await events.prepare_and_persist_event('C1', event())
            task = fcm.send_push_to_user_bg(**queued[0]); assert task is not None; await task
            async with factory() as db:
                assert list((await db.scalars(select(models.UserFcmToken.fcm_token))).all()) == [TOKEN]
    asyncio.run(run())
    output = capsys.readouterr().out
    assert TOKEN[:20] not in output and 'FCM sent' not in output


@pytest.mark.parametrize('error', [messaging.QuotaExceededError, messaging.ThirdPartyAuthError,
    messaging.SenderIdMismatchError, exceptions.InvalidArgumentError, exceptions.UnavailableError,
    exceptions.InternalError, RuntimeError])
def test_per_device_error_does_not_imply_expired_registration(error, monkeypatch, capsys):
    monkeypatch.setattr(fcm, 'is_fcm_enabled', lambda: True)
    monkeypatch.setattr(fcm, '_fb_messaging', sdk(lambda message: SimpleNamespace(responses=[
        SimpleNamespace(success=False, exception=error('Synthetic private error detail'))])))
    result = REAL_SEND([TOKEN], 'Synthetic', 'Synthetic')
    assert result.invalid_tokens == () and result.success_count == 0
    output = capsys.readouterr().out
    assert TOKEN[:20] not in output and 'Synthetic private error detail' not in output


def test_partial_response_counts_real_success_not_every_retained_device(monkeypatch):
    monkeypatch.setattr(fcm, 'is_fcm_enabled', lambda: True)
    monkeypatch.setattr(fcm, '_fb_messaging', sdk(lambda message: SimpleNamespace(responses=[
        SimpleNamespace(success=True),
        SimpleNamespace(success=False, exception=messaging.UnregisteredError('Synthetic expired')),
        SimpleNamespace(success=False, exception=messaging.QuotaExceededError('Synthetic rate limit'))])))
    result = REAL_SEND(['synthetic-good', 'synthetic-expired', 'synthetic-throttled'], 'Synthetic', 'Synthetic')
    assert result.invalid_tokens == ('synthetic-expired',) and result.success_count == 1


def test_response_count_mismatch_never_guesses_a_device_to_delete(monkeypatch):
    monkeypatch.setattr(fcm, 'is_fcm_enabled', lambda: True)
    monkeypatch.setattr(fcm, '_fb_messaging', sdk(lambda message: SimpleNamespace(responses=[
        SimpleNamespace(success=False, exception=messaging.UnregisteredError('Synthetic expired'))])))
    result = REAL_SEND(['synthetic-A', 'synthetic-B'], 'Synthetic', 'Synthetic')
    assert result.invalid_tokens == () and result.success_count == 0


def test_older_sdk_adapter_still_uses_the_same_safe_result(monkeypatch):
    monkeypatch.setattr(fcm, 'is_fcm_enabled', lambda: True)
    monkeypatch.setattr(fcm, '_fb_messaging', SimpleNamespace(MulticastMessage=lambda **values: values,
        send_multicast=lambda message: SimpleNamespace(responses=[SimpleNamespace(success=True)]),
        UnregisteredError=messaging.UnregisteredError))
    result = REAL_SEND([TOKEN], 'Synthetic', 'Synthetic')
    assert result.invalid_tokens == () and result.success_count == 1
