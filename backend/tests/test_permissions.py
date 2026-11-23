"""عقد الصلاحيات على الخادم يعكس الواجهة: المدير/المالك يتجاوزان،
والموظف يحتاج True صريحة، وأي غياب أو فراغ = رفض."""
import pytest
from fastapi import HTTPException

from app.core.permissions import (
    has_hr_permission,
    has_section_permission,
    require_any_section_permission,
    require_section_permission,
)

EMP = {"role": "employee", "job_code": "1"}
ADMIN = {"role": "admin", "job_code": "201", "permissions": {}}
SUPER = {"role": "super_admin", "job_code": "99"}


def _emp(perms):
    return {**EMP, "permissions": perms}


def test_super_admin_bypasses_everything():
    assert has_section_permission(SUPER, "المبيعات", "إضافة") is True


def test_admin_bypasses_with_empty_permissions():
    assert has_section_permission(ADMIN, "التكويد", "اضافة فرع") is True


def test_employee_explicit_true_allowed():
    p = _emp({"المبيعات": {"إضافة": True}})
    assert has_section_permission(p, "المبيعات", "إضافة") is True


def test_employee_missing_permissions_map_denied():
    assert has_section_permission(EMP, "المبيعات", "إضافة") is False


def test_employee_empty_permissions_denied():
    assert has_section_permission(_emp({}), "المبيعات", "إضافة") is False


def test_employee_absent_section_denied():
    p = _emp({"المرتجعات": {"إضافة": True}})
    assert has_section_permission(p, "المبيعات", "إضافة") is False


def test_employee_false_key_denied():
    p = _emp({"المبيعات": {"إضافة": False}})
    assert has_section_permission(p, "المبيعات", "إضافة") is False


def test_employee_non_boolean_truthy_denied():
    for v in (1, "true", "نعم", [True]):
        p = _emp({"المبيعات": {"إضافة": v}})
        assert has_section_permission(p, "المبيعات", "إضافة") is False


def test_menu_toggle_is_not_a_data_right():
    # مفاتيح "إظهار ..." للقوائم فقط: لا تمنع بيانات الـ API
    p = _emp({
        "التكويد": {"اضافة فرع": True},
        "صلاحيات عامة": {"إظهار التكويد": False},
    })
    assert has_section_permission(p, "التكويد", "اضافة فرع") is True
    assert has_section_permission(p, "المبيعات", "إضافة") is False


def test_global_toggle_absent_allows():
    p = _emp({"التكويد": {"اضافة فرع": True}})
    assert has_section_permission(p, "التكويد", "اضافة فرع") is True


def test_hr_camelcase_keys():
    p = _emp({"الموارد البشرية": {"canViewEmployees": True}})
    assert has_hr_permission(p, "canViewEmployees") is True
    assert has_hr_permission(p, "canManageEmployees") is False


def test_hr_menu_toggle_is_not_a_data_right():
    p = _emp({
        "الموارد البشرية": {"canViewEmployees": True},
        "صلاحيات عامة": {"إظهار الموارد البشرية": False},
    })
    assert has_hr_permission(p, "canViewEmployees") is True


def test_require_raises_403(make_request):
    req = make_request(_emp({"المبيعات": {"إضافة": False}}))
    with pytest.raises(HTTPException) as exc:
        require_section_permission(req, "المبيعات", "إضافة")
    assert exc.value.status_code == 403


def test_require_returns_profile(make_request):
    profile = _emp({"المبيعات": {"إضافة": True}})
    req = make_request(profile)
    assert require_section_permission(req, "المبيعات", "إضافة") is profile


def test_require_any_one_match_passes(make_request):
    profile = _emp({"حسابات العملاء": {"إضافة تحصيل": True}})
    req = make_request(profile)
    out = require_any_section_permission(
        req, [("المبيعات", "إضافة"), ("حسابات العملاء", "إضافة تحصيل")]
    )
    assert out is profile


def test_require_any_none_raises(make_request):
    req = make_request(_emp({}))
    with pytest.raises(HTTPException) as exc:
        require_any_section_permission(
            req, [("المبيعات", "إضافة"), ("التكويد", "معاينة")]
        )
    assert exc.value.status_code == 403


def test_require_any_admin_bypass(make_request):
    req = make_request(ADMIN)
    assert require_any_section_permission(req, [("المبيعات", "إضافة")])


from app.core.permissions import _ADD_TO_EDIT

@pytest.mark.parametrize('category,add,edit',[(category,add,edit) for category,pairs in _ADD_TO_EDIT.items() for add,edit in pairs.items()])
def test_edit_implies_add_but_no_other_rights(category,add,edit):
    edit_only=_emp({category:{edit:True,add:False}})
    add_only=_emp({category:{add:True}})
    assert has_section_permission(edit_only,category,add)
    assert has_section_permission(edit_only,category,edit)
    assert not has_section_permission(add_only,category,edit)
    if category=='الموارد البشرية':
        assert has_hr_permission(edit_only,add)
        assert not has_hr_permission(add_only,edit)
    for other in ['معاينة','حذف','تصدير','سعر الشراء','canViewAttendance','canDeleteAttendance']:
        assert not has_section_permission(edit_only,category,other)

def test_specialized_adjustment_add_rights_not_inferred():
    profile=_emp({'الموارد البشرية':{'canEditAdjustment':True}})
    for right in ['canAddBonus','canAddLoan','canAddDirectDiscount']:
        assert not has_hr_permission(profile,right)
