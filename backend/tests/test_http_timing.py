"""Diagnostic removal preserves authorization decisions."""
import asyncio
import httpx
from fastapi import FastAPI
from app.core import auth_middleware as mw


def test_no_diagnostic_headers_success_and_denial(monkeypatch):
    monkeypatch.setattr(mw.admin_auth, 'verify_id_token', lambda *a, **k: {'uid':'fixture', 'email':'fixture@example.invalid'})
    monkeypatch.setattr(mw, '_profile_for', lambda *a, **k: {'uid':'fixture', 'role':'super_admin', 'company_code':'C1', 'is_active':True})
    app = FastAPI()
    app.middleware('http')(mw.authenticate_http_request)
    @app.get('/probe')
    async def probe(): return {'ok':True}
    async def work():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://fixture') as client:
            denied = await client.get('/probe')
            assert denied.status_code == 401
            response = await client.get('/probe',headers={'Authorization':'Bearer fixture'})
            assert response.status_code == 200
            assert response.json() == {'ok':True}
            for result in (denied, response):
                assert 'server-timing' not in result.headers
                assert 'x-app-perf-version' not in result.headers
    asyncio.run(work())
