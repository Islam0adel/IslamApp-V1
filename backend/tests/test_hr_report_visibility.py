"""Real branch-report route and SQLite, synthetic calculator output only."""
import asyncio
import pytest
from test_hr_identity_profile_access import profile,seed
from test_notification_revocation import notification_db,request
from app.routes import hr

@pytest.mark.parametrize('salary',[False,True])
@pytest.mark.parametrize('own',[False,True])
def test_branch_report_financial_fields_require_salary_right(salary,own,tmp_path,monkeypatch):
    async def calculate(**kwargs):
        return {'net_salary':112.0,'base_pay':110.0,'present_days':12,'future_financial_value':555.0}
    monkeypatch.setattr(hr,'calculate_salary',calculate)
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory)
            actor=profile(own=own,salary=salary)
            actor['permissions']['الموارد البشرية']['canViewBranchSalaryReport']=True
            async with factory() as db:
                result=await hr.get_branch_salaries_totals(request(actor),company_code='C1',month='2026-11',branch_code=None,db=db)
                assert result['totals']['employees_count']==2
                assert len(result['employees'])==2
                if salary:
                    assert result['totals']['total_net_salary']==224.0
                    assert all(row['net_salary']==112.0 for row in result['employees'])
                else:
                    assert result['totals']=={'employees_count':2}
                    assert all('net_salary' not in row and 'base_pay' not in row for row in result['employees'])
                    assert all(row['present_days']==12 for row in result['employees'])
    asyncio.run(run())

def test_salary_visibility_shared_nonfinancial_contract():
    import json
    from pathlib import Path
    contract=json.loads((Path(__file__).resolve().parents[2]/'contracts/hr_salary_visibility.json').read_text())
    assert contract['schema_version']==1
    assert set(contract['report_safe_keys'])==hr._SALARY_SAFE_KEYS
    assert set(contract['adjustment_line_safe_keys'])==hr._SALARY_LINE_SAFE_KEYS
    assert set(contract['branch_top_keys'])==hr._BRANCH_REPORT_SAFE_KEYS
    assert set(contract['branch_total_safe_keys'])==hr._BRANCH_TOTAL_SAFE_KEYS
    data={'company_code':'C1','month':'2026-11','branch_code':'B1','future_financial_field':456,
        'totals':{'employees_count':1,'total_net_salary':112,'future_financial_field':456},
        'employees':[{'employee_code':'E1','employee_name':'Synthetic','present_days':12,
            'net_salary':112,'future_financial_field':456,'adjustment_lines':[{'label':'Synthetic','amount':7}]}]}
    masked=hr._branch_report_payload(profile(own=False,salary=False),data)
    assert set(masked)=={'company_code','month','branch_code','totals','employees'}
    assert masked['totals']=={'employees_count':1}
    assert masked['employees']==[{'employee_code':'E1','employee_name':'Synthetic','present_days':12,
        'adjustment_lines':[{'label':'Synthetic'}]}]
    assert data['totals']['total_net_salary']==112


@pytest.mark.parametrize('salary',[False,True])
def test_empty_branch_report_respects_same_financial_mask(salary,tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);actor=profile(own=True,salary=salary)
            actor['permissions']['الموارد البشرية']['canViewBranchSalaryReport']=True
            actor['allowed_branches']=['all']
            async with factory() as db:
                result=await hr.get_branch_salaries_totals(request(actor),company_code='C1',month='2026-11',branch_code='B2',db=db)
                assert result['totals']['employees_count']==0 and result['employees']==[]
                assert ('total_net_salary' in result['totals']) is salary
    asyncio.run(run())


def test_personal_exception_does_not_expand_a_branch_aggregate(tmp_path,monkeypatch):
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);actor=profile(own=True,salary=True,restricted=True)
            actor['permissions']['الموارد البشرية']['canViewBranchSalaryReport']=True
            async with factory() as db:
                result=await hr.get_branch_salaries_totals(request(actor),company_code='C1',month='2026-11',branch_code=None,db=db)
                assert result['totals']['employees_count']==0 and result['employees']==[]
    asyncio.run(run())


def test_legacy_admin_branch_report_keeps_existing_role_policy(tmp_path,monkeypatch):
    async def calculate(**kwargs):return {'net_salary':112.0}
    monkeypatch.setattr(hr,'calculate_salary',calculate)
    async def run():
        async with notification_db(tmp_path,monkeypatch) as factory:
            await seed(factory);actor=profile(own=False,salary=False);actor['role']='admin';actor['permissions']={}
            async with factory() as db:
                result=await hr.get_branch_salaries_totals(request(actor),company_code='C1',month='2026-11',branch_code=None,db=db)
                assert result['totals']['total_net_salary']==224.0
    asyncio.run(run())
