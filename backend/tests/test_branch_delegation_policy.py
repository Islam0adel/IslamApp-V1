"""Independent branch delegation with no inferred operating grants."""
import asyncio
from copy import deepcopy
import pytest
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.core import models
from app.core.branch_scope import validate_branch_scope, check_branch_assignment, InvalidOperatingBranchScope
from app.core.company_policy_store import policy_profile, save_policy_draft, read_policy, validate_configuration
from app.core.auth_middleware import allowed_branches_for_profile
from app.core.notification_events import _branch_allowed
from test_company_policy_store import config

INVALID = [None, 'all', True, {}, [1], [''], [' B1'], ['B1 '], ['B1','B1'], ['all','B1'], ['ALL']]

@pytest.mark.parametrize('scope', INVALID)
def test_malformed_delegation_is_not_an_explicit_grant(scope):
    value=config(); value['admin_profiles']['uid-admin']['delegable_branches']=scope
    with pytest.raises(ValueError): validate_configuration(value)

@pytest.mark.parametrize('scope', [None, [], {}, [1], [''], [' B1'], ['B1','B1'], ['all','B1'], ['ALL']])
def test_active_bad_operating_scope_never_falls_back_to_all(scope):
    source={'uid':'uid-admin','allowed_branches':scope}
    with pytest.raises(InvalidOperatingBranchScope): policy_profile(source, config(), role='admin')
    profile={**source,'role':'admin','company_policy_active':True}
    with pytest.raises(InvalidOperatingBranchScope): allowed_branches_for_profile(profile)
    assert _branch_allowed(profile,'B2') is False
    assert _branch_allowed(profile,'') is False

@pytest.mark.parametrize('delegation', [[], ['B2'], ['all']])
def test_delegation_and_operating_branches_are_independent(delegation):
    value=config(); value['admin_profiles']['uid-admin']['delegable_branches']=delegation
    source={'uid':'uid-admin','allowed_branches':['B1'],'branch_code':'B1', 'delegable_branches':['forged']}
    result=policy_profile(source,value,role='admin')
    assert result['allowed_branches']==['B1'] and result['branch_code']=='B1'
    assert result['delegable_branches']==delegation
    assert _branch_allowed(result,'B2') is False
    source['uid']='someone-else'
    assert policy_profile(source,value,role='admin')['delegable_branches']==[]
    source['uid']='uid-admin'
    assert policy_profile(source,value,role='employee')['delegable_branches']==[]
    assert 'delegable_branches' not in policy_profile(source,None,role='admin')


def test_old_draft_has_no_branch_delegation_and_explicit_string_all_is_compatible():
    result=policy_profile({'uid':'uid-admin','allowed_branches':'all'},config(),role='admin')
    assert result['delegable_branches']==[] and result['allowed_branches']==['all']

@pytest.mark.parametrize('before,after,delegation,allowed', [
    (['B1'],['B1','B2'],['B2'],True), (['B1','B2'],['B1'],['B2'],True),
    (['B1','B2'],['B2'],['B2'],False), (['B1'],['B1'],[],True),
    (['B1'],['all'],['B1','B2'],False), (['all'],['B1','B2'],['B1','B2'],False),
    (['B1'],['all'],['all'],True), (['all'],['B1'],['all'],True),
    (['B1'],['foreign'],['all'],False),
])
def test_replacement_checks_grants_revocations_and_future_branch_wildcard(before,after,delegation,allowed):
    result=check_branch_assignment(previous_branches=before,proposed_branches=after,
        delegable_branches=delegation,company_branches=['B1','B2'])
    assert result.allowed is allowed


def test_draft_scope_is_company_bound_and_does_not_activate(tmp_path):
    async def run():
        engine=create_async_engine('sqlite+aiosqlite:///'+str(tmp_path/'branch-draft.db'))
        factory=async_sessionmaker(engine,expire_on_commit=False)
        async with engine.begin() as connection: await connection.run_sync(models.Base.metadata.create_all)
        try:
            async with factory() as db:
                db.add_all([models.Company(code='C1',name='One'),models.Company(code='C2',name='Two'),
                    models.Branch(company_code='C1',code='B1',name='One'),
                    models.Branch(company_code='C2',code='B2',name='Foreign')])
                await db.commit()
                value=config(); value['admin_profiles']['uid-admin']['delegable_branches']=['B2']
                with pytest.raises(ValueError): await save_policy_draft(db,'C1',value,expected_revision=0)
                assert (await read_policy(db,'C1'))['revision']==0
                value['admin_profiles']['uid-admin']['delegable_branches']=['B1']
                before=deepcopy(value)
                saved=await save_policy_draft(db,'C1',value,expected_revision=0)
                assert saved['draft']==before and saved['active'] is None and saved['active_revision'] is None
                value['admin_profiles']['uid-admin']['delegable_branches']=['all']
                saved=await save_policy_draft(db,'C1',value,expected_revision=1)
                assert saved['draft']==value and saved['active'] is None
        finally: await engine.dispose()
    asyncio.run(run())
