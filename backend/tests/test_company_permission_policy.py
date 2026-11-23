"""Pure policy groundwork, not proof of route/UI integration or legacy activation."""
from itertools import product
import pytest
from app.core.permission_hierarchy import ADD_TO_EDIT
from app.core.permission_policy import (
    check_assignment, effective_permissions, grants, validate_permission_map,
)

PAIRS=[(category,add,edit) for category,pairs in ADD_TO_EDIT.items() for add,edit in pairs.items()]

@pytest.mark.parametrize('category,add,edit',PAIRS)
@pytest.mark.parametrize('ca,ce,ua,ue',list(product([False,True],repeat=4)))
def test_ceiling_operating_matrix_preserves_directional_hierarchy(category,add,edit,ca,ce,ua,ue):
    company={category:{add:ca,edit:ce}}
    user={category:{add:ua,edit:ue}}
    result=grants(effective_permissions(company,user))
    assert ((category,add) in result)==((ca or ce) and (ua or ue))
    assert ((category,edit) in result)==(ce and ue)
    assert all(key in (add,edit) for _,key in result)


def check(before,after,*,company=None,delegable=None,skip=False):
    return check_assignment(company_ceiling=company if company is not None else {'المبيعات':{'تعديل':True}},
        delegable_permissions=delegable if delegable is not None else {},
        previous_permissions=before,proposed_permissions=after,check_delegation=not skip)


def test_delegation_is_separate_from_operating_rights():
    ceiling={'المبيعات':{'تعديل':True}}
    assert effective_permissions(ceiling,{})=={}
    assert check({},ceiling,delegable=ceiling).allowed
    assert not check({},ceiling,delegable={}).allowed


def test_add_only_delegation_does_not_grant_edit():
    decision=check({}, {'المبيعات':{'تعديل':True}},delegable={'المبيعات':{'إضافة':True}})
    assert decision.outside_delegation=={('المبيعات','تعديل')}
    assert not decision.allowed


def test_unchanged_target_rights_outside_delegation_are_not_silently_removed():
    before={'المبيعات':{'تعديل':True}}
    assert check(before,before).allowed
    assert check(before,{'المبيعات':{'تعديل':True,'إضافة':False}}).allowed
    assert check(before,{'المبيعات':{'إضافة':True}}).outside_delegation=={('المبيعات','تعديل')}


def test_skipping_delegation_never_skips_company_ceiling():
    decision=check({}, {'المبيعات':{'تعديل':True}},company={'المبيعات':{'إضافة':True}},skip=True)
    assert decision.outside_company=={('المبيعات','تعديل')}
    assert not decision.allowed


@pytest.mark.parametrize('value',[None,[],True,{'المبيعات':[]},{'المبيعات':{'إضافة':1}},
    {'المبيعات':{'إضافة':'true'}},{'المبيعات':{'إضافة':None}},{'':{}},{'المبيعات':{'':True}}])
def test_proposed_maps_are_strict_and_never_truthy_grants(value):
    with pytest.raises(ValueError):validate_permission_map(value)
    with pytest.raises(ValueError):check({},value)


def test_bad_runtime_values_fail_closed_without_creating_grants():
    assert grants({'المبيعات':{'إضافة':1,'تعديل':'true'}})==set()
    assert effective_permissions(None,{'المبيعات':{'تعديل':True}})=={}
    assert effective_permissions({'المبيعات':{'تعديل':True}},None)=={}


def test_no_view_delete_cost_export_or_specialized_adjustment_is_implied():
    result=grants({'المبيعات':{'تعديل':True},'الموارد البشرية':{'canEditAdjustment':True}})
    assert result=={('المبيعات','إضافة'),('المبيعات','تعديل'),('الموارد البشرية','canEditAdjustment')}


def test_backend_matches_shared_hierarchy_contract():
    import json
    from pathlib import Path
    contract=json.loads((Path(__file__).resolve().parents[2]/'contracts/permission_hierarchy.json').read_text())
    assert contract['schema_version']==1
    assert ADD_TO_EDIT==contract['edit_includes_add']
