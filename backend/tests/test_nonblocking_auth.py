"""Synthetic blocking SDK, real HTTP middleware, no external accounts."""
import asyncio
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI
import httpx
from app.core import auth_middleware as mw


def test_fresh_profiles_overlap_without_blocking_event_loop(monkeypatch):
    calls=[]
    def read(*a, **kw):
        assert kw['force_refresh'] is True
        calls.append(threading.get_ident())
        time.sleep(.08)
        return {'uid':'fixture','role':'super_admin','company_code':'C1','is_active':True}
    monkeypatch.setattr(mw, '_profile_for', read)
    monkeypatch.setattr(mw.admin_auth,'verify_id_token',lambda *a,**k:{'uid':'fixture','email':'fixture@example.invalid'})
    app=FastAPI();app.middleware('http')(mw.authenticate_http_request)
    @app.get('/probe')
    async def probe(): return {'ok':True}
    async def work():
        ticks=0
        async def heartbeat():
            nonlocal ticks
            for _ in range(12):
                await asyncio.sleep(.005);ticks+=1
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture',headers={'Authorization':'Bearer fixture'}) as client:
            start=time.perf_counter()
            values=await asyncio.gather(heartbeat(),*[client.get('/probe') for _ in range(5)])
            elapsed=time.perf_counter()-start
            assert all(v.status_code==200 for v in values[1:])
            assert ticks==12
            assert elapsed < .35 # serial source reads alone take .40s.
            assert len(calls)==5 and all(x!=threading.get_ident() for x in calls)
    asyncio.run(work())


def test_revocation_during_threaded_read_retries_and_denies(monkeypatch):
    entered=threading.Event();release=threading.Event();calls=[];active=True
    def read(*a,**kw):
        snapshot=active;calls.append(snapshot)
        if len(calls)==1:
            entered.set();assert release.wait(2)
        return {'uid':'fixture','role':'super_admin','company_code':'C1','is_active':snapshot}
    monkeypatch.setattr(mw,'_profile_for',read)
    monkeypatch.setattr(mw.admin_auth,'verify_id_token',lambda *a,**k:{'uid':'fixture','email':'fixture@example.invalid'})
    app=FastAPI();app.middleware('http')(mw.authenticate_http_request)
    @app.get('/probe')
    async def probe(): return {'ok':True}
    async def work():
        nonlocal active
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture',headers={'Authorization':'Bearer fixture'}) as client:
            pending=asyncio.create_task(client.get('/probe'))
            while not entered.is_set(): await asyncio.sleep(.001)
            active=False;mw.invalidate_profile_cache('fixture@example.invalid');release.set()
            assert (await pending).status_code==403
            assert calls==[True,False]
    asyncio.run(work())
