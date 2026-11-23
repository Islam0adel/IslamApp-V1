"""Conditional reviewed-policy enforcement, without activating any company."""
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from app.core.auth_middleware import can_bypass_permissions, allowed_branches_for_profile
from app.core.permissions import has_section_permission, has_hr_permission
from app.core.notification_events import _branch_allowed, _can_view_section
from app.core.sync import _ws_can_view_costs, _ws_can_view_salary, _ws_can_view_hr
from app.routes.commercial import _check_permission, _check_extra_permission


def profile(*, active=True, rights=None, role='admin'):
    return {'uid':'fixture', 'role':role, 'company_code':'C1', 'company_policy_active':active,
            'allowed_branches':['B1'], 'permissions':rights or {}}


@pytest.mark.parametrize('active,role,expected', [
    (False,'admin',True),(None,'admin',True),(True,'admin',False),
    (True,'super_admin',True),(True,'employee',False),(False,'employee',False),
])
def test_bypass_is_explicitly_legacy_or_platform_admin(active,role,expected):
    actor=profile(active=active,role=role)
    assert can_bypass_permissions(actor) is expected
    assert has_section_permission(actor,'المبيعات','حذف') is expected
    assert has_hr_permission(actor,'canViewSalaryAmounts') is expected
    assert _branch_allowed(actor,'B2') is expected


@pytest.mark.parametrize('checker', [_ws_can_view_costs,_ws_can_view_salary,_ws_can_view_hr])
def test_active_admin_no_longer_bypasses_live_payload_masks(checker):
    assert checker(profile(active=False)) is True
    assert checker(profile(active=True)) is False


def test_active_admin_branch_restrictions_apply_without_changing_identity():
    actor=profile()
    assert allowed_branches_for_profile(actor)==['B1']
    assert _branch_allowed(actor,'B1')
    assert not _branch_allowed(actor,'B2')
    assert actor['role']=='admin'
    assert allowed_branches_for_profile(profile(active=False)) is None


def test_exact_action_hierarchy_applies_to_active_admin_routes():
    actor=profile(rights={'المبيعات':{'تعديل':True}})
    request=SimpleNamespace(state=SimpleNamespace(auth_user=actor))
    for action in ('add','edit'):
        assert _check_permission(request,'sales',action) is actor
    for action in ('view','delete'):
        with pytest.raises(HTTPException) as error:_check_permission(request,'sales',action)
        assert error.value.status_code==403
    for key in ('تغيير سعر البيع','تصدير'):
        with pytest.raises(HTTPException):_check_extra_permission(request,'المبيعات',key)
    assert not _can_view_section(actor,'sales',data_only=True)
    actor['permissions']['المبيعات']['معاينة']=True
    assert _can_view_section(actor,'sales',data_only=True)
    assert not _can_view_section(actor,'sales')
    actor['permissions']['صلاحيات عامة']={'إظهار الإشعارات':True}
    assert _can_view_section(actor,'sales')
