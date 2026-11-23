import pytest
from test_treasury_transfers import run,req,data,changed
from app.routes import treasury_transfers as route

@pytest.mark.parametrize('amounts',[[.01,.02,.03],[99999999999999.98,.01,.01],[1e16,1,1],[100.25,71.49,6.2]])
def test_authoritative_aggregate_scopes_dates_edits_and_deletes(tmp_path,monkeypatch,amounts):
    async def scenario(factory,engine):
        async with factory() as db:
            saved=[]
            for i,amount in enumerate(amounts):
                saved.append(await route.save_transfer(req(),changed(data(),id='T'+str(i),amount=amount,
                    branch_code='B1' if i<2 else 'B2',date='2026-01-01' if i<2 else '2026-01-02'),db))
            for branches in (['all'],['B1'],['B2']):
                profile=req(role='employee',branches=branches,perms={'التقارير':{'تحليل الخزائن النقدية':True}})
                before=await route.transfer_effects(profile,'C1',db)
                # Persisted unchanged aggregate path is repeatable with same state.
                assert await route.transfer_effects(profile,'C1',db)==before
                assert all(set(e)=={'company_code','branch_code','date','treasury','signed_amount'} for e in before)
                assert all(e['branch_code'] in branches for e in before) if 'all' not in branches else True
            await route.save_transfer(req(),changed(data(),id='T0',amount=.75,to_treasury='C',date='2026-02-01',serial=1,
                base_updated_at=saved[0]['record']['updated_at']),db)
            await route.delete_transfer(req(),'C1','T1',db,saved[1]['record']['updated_at'])
            rows=await route.transfer_effects(req(),'C1',db)
            assert not any(e['date']=='2026-01-01' for e in rows)
            edited=[e for e in rows if e['date']=='2026-02-01']
            assert [(e['treasury'],e['signed_amount']) for e in edited]==[('A',-.75),('C',.75)]
    run(tmp_path,monkeypatch,scenario)
