"""Malformed active branch scope is isolated at the actual notification path."""
import asyncio
import copy
from types import SimpleNamespace
from sqlalchemy import select
from app.core import models, notification_events as events
from test_company_policy_push import fixture, event


def test_one_invalid_scope_does_not_block_correctly_scoped_recipients(tmp_path, monkeypatch):
    async def run():
        async with fixture(tmp_path, monkeypatch) as (state, source, factory, _, queued, _):
            malformed=copy.deepcopy(state)
            malformed.update(uid='malformed-account',allowed_branches=[])
            bad=SimpleNamespace(id='malformed@example.invalid',to_dict=lambda: copy.deepcopy(malformed))
            monkeypatch.setattr(source,'stream',lambda: [bad,source.doc])
            await events.prepare_and_persist_event('C1',event())
            assert len(queued)==1 and queued[0]['user_uid']==state['uid']
            async with factory() as db:
                rows=(await db.scalars(select(models.Notification))).all()
                assert len(rows)==1 and rows[0].recipient_uid==state['uid']
    asyncio.run(run())
