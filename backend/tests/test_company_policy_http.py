"""Actual authenticated middleware + SQL policy + route integration.

All identities, tokens and databases are synthetic. No activation API is used.
"""
import asyncio
from copy import deepcopy

import httpx
from fastapi import FastAPI, Request
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.core import models
from app.core import auth_middleware as mw
from app.core.permissions import has_section_permission, has_hr_permission
from app.routes import auth


def test_live_policy_read_projects_real_http_scope_without_cache_delay(tmp_path, monkeypatch):
    async def work():
        engine = create_async_engine('sqlite+aiosqlite:///' + str(tmp_path / 'auth-policy.db'))
        factory = async_sessionmaker(engine, expire_on_commit=False)
        async with engine.begin() as conn: await conn.run_sync(models.Base.metadata.create_all)
        async with factory() as db:
            db.add(models.Company(code='C1', name='Fixture', is_active=True))
            await db.commit()
        raw = {'uid':'uid-admin', 'email':'fixture@example.invalid', 'role':'admin', 'job_code':'201',
               'company_code':'C1', 'is_active':True, 'status':'active', 'allowed_branches':['B1'],
               'permissions': {'المبيعات': {'حذف':True}}, 'unrelated_private_field':'not-for-session'}
        reads = []
        class Document:
            exists = True
            def get(self): reads.append(1); return self
            def to_dict(self): return deepcopy(raw)
        class Firestore:
            def collection(self, name): assert name == 'users'; return self
            def document(self, email): assert email == raw['email']; return Document()
        monkeypatch.setattr(mw, 'AsyncSessionLocal', factory)
        monkeypatch.setattr(mw, 'firebase_db', Firestore())
        monkeypatch.setattr(mw.admin_auth, 'verify_id_token', lambda *a, **kw: {'uid':'uid-admin','email':raw['email']})
        mw._PROFILE_CACHE.clear(); mw._COMPANY_CACHE.clear()
        app = FastAPI()
        app.middleware('http')(mw.authenticate_http_request)
        app.include_router(auth.router, prefix='/auth')
        @app.get('/probe')
        async def probe(request: Request):
            p=request.state.auth_user
            return {'add':has_section_permission(p,'المبيعات','إضافة'),
                    'edit':has_section_permission(p,'المبيعات','تعديل'),
                    'view':has_section_permission(p,'المبيعات','معاينة'),
                    'delete':has_section_permission(p,'المبيعات','حذف'),
                    'salary':has_hr_permission(p,'canViewSalaryAmounts'),
                    'role':p['role'], 'branches':mw.allowed_branches_for_profile(p)}
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://fixture',
                                        headers={'authorization':'Bearer fixture'}) as client:
                before=await client.get('/probe')
                assert before.status_code==200 and all(before.json()[k] for k in ('add','edit','view','delete','salary'))
                assert before.json()['branches'] is None
                # Legacy positive caches cannot keep a revoked identity alive.
                source_reads = len(reads)
                raw['is_active'] = False
                assert (await client.get('/probe')).status_code == 403
                assert len(reads) == source_reads + 1
                raw['is_active'] = True
                source_reads = len(reads)
                assert (await client.get('/probe')).status_code == 200
                assert len(reads) == source_reads + 1
                # Own-profile refresh is fresh even before a company's opt-in.
                raw['role']='employee'
                raw['permissions']={}
                fresh=await client.get('/auth/session-profile')
                assert fresh.status_code==200 and fresh.json()['role']=='employee'
                assert fresh.json()['company_policy_active'] is False
                raw['role']='admin'
                raw['permissions']={'المبيعات': {'حذف':True}}
                config={'company_permissions':{'المبيعات':{'تعديل':True}}, 'admin_profiles':{
                    'uid-admin':{'operating_permissions':{'المبيعات':{'تعديل':True}}, 'delegable_permissions':{'المبيعات':{'إضافة':True}}, 'delegable_branches':['B2']},
                    'another-private-admin-uid':{'operating_permissions':{},'delegable_permissions':{}},
                }}
                async with factory() as db:
                    db.add(models.CompanyPermissionPolicy(company_code='C1',revision=1,active_revision=1,active=config))
                    await db.commit()
                source_reads = len(reads)
                active=await client.get('/probe')
                assert len(reads) == source_reads + 1, 'active policy must not duplicate the source read'
                assert active.status_code==200
                assert active.json()=={'add':True,'edit':True,'view':False,'delete':False,'salary':False,'role':'admin','branches':['B1']}
                own=await client.get('/auth/session-profile')
                assert own.status_code==200
                data=own.json()
                assert data['company_policy_active'] is True and data['company_policy_revision']==1
                assert data['permissions']=={'المبيعات':{'إضافة':True,'تعديل':True}}
                assert data['delegable_permissions']=={'المبيعات':{'إضافة':True}}
                assert data['delegable_branches']==['B2'] and data['allowed_branches']==['B1']
                assert 'another-private-admin-uid' not in own.text and 'unrelated_private_field' not in data
                assert 'not-for-session' not in own.text
                # Raw cached profile retains its source. Projection never poisons it.
                assert mw._PROFILE_CACHE[raw['email']][1]['permissions']=={'المبيعات':{'حذف':True}}
                async with factory() as db:
                    row=await db.get(models.CompanyPermissionPolicy,'C1')
                    row.active={'company_permissions':{},'admin_profiles':{}}
                    row.active_revision=2
                    await db.commit()
                revoked=await client.get('/probe')
                assert revoked.status_code==200
                assert not any(revoked.json()[k] for k in ('add','edit','view','delete','salary'))
                assert revoked.json()['role']=='admin'
                for invalid_scope in (None, [], ['all','B1'], ['B1','B1']):
                    raw['allowed_branches']=invalid_scope
                    assert (await client.get('/probe')).status_code==503
                raw['allowed_branches']=['B1']
                raw['is_active']=False
                blocked=await client.get('/probe')
                assert blocked.status_code==403
                assert len(reads)>=5
                # Permission-store failures must not restore a legacy bypass.
                raw['is_active']=True
                mw._PROFILE_CACHE.clear()
                async def unavailable(*args, **kwargs): raise RuntimeError('fixture unavailable')
                monkeypatch.setattr(mw,'active_policy_configuration',unavailable)
                assert (await client.get('/probe')).status_code==503
        finally:
            mw._PROFILE_CACHE.clear(); mw._COMPANY_CACHE.clear()
            await engine.dispose()
    asyncio.run(work())
