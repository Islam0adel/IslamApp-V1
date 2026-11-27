# backend/app/core/permissions.py
from app.core.auth_middleware import can_bypass_permissions
"""
فحص الصلاحيات على الخادم — يعكس عقد الواجهة بالظبط.

العقد (من permissions_service.dart):
- super_admin و admin: تخطي كامل.
- employee: لازم المفتاح يكون True صريح داخل permissions[القسم][المفتاح].
- أي نقص (خريطة/قسم/مفتاح) أو قيمة غير True = رفض.
- مفاتيح الإظهار العامة (صلاحيات عامة) لو موجودة False تمنع القسم كله.
"""
from typing import Any, Dict, Optional

from fastapi import HTTPException, Request

from app.core.auth_middleware import _effective_role

# اسم تصنيف صلاحيات الموارد البشرية
_HR_CATEGORY = "الموارد البشرية"

# مفاتيح الإظهار العامة لكل قسم (نفس أسماء permissions_service)
_SECTION_GLOBAL_TOGGLE = {
    "حركة الخزينة": "إظهار حركة الخزينة",
    "التكويد": "إظهار التكويد",
    "التقارير": "إظهار التقارير",
    "حركة الموردين": "إظهار حركة الموردين",
    "حركة الجرد": "إظهار حركة الجرد",
    "الإشعارات": "إظهار الإشعارات",
    "البحث عن المنتجات": "إظهار البحث عن المنتجات",
}
_HR_GLOBAL_TOGGLE = "إظهار الموارد البشرية"


# يفحص مفتاح الإظهار العام للقسم (لو False يمنع القسم)
def _global_toggle_allows(profile: Dict[str, Any], toggle_key: str) -> bool:
    """لو مفتاح الإظهار العام موجود وقيمته False يمنع القسم. غير موجود = مسموح."""
    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return True
    general = permissions.get("صلاحيات عامة")
    if not isinstance(general, dict):
        return True
    value = general.get(toggle_key)
    if value is None:
        return True
    return value is True


from app.core.permission_hierarchy import ADD_TO_EDIT as _ADD_TO_EDIT, action_allowed as _action_allowed


# يفحص هل المستخدم عنده صلاحية على قسم ومفتاح معين
def has_section_permission(
    profile: Dict[str, Any],
    category: str,
    key: str,
    *,
    respect_global_toggle: bool = True,
) -> bool:
    """
    نفس عقد الواجهة: المدير وصاحب البرنامج مسموح لهم،
    والموظف لازم المفتاح يكون True صراحة، وأي نقص = رفض.
    """
    role = _effective_role(profile)
    if can_bypass_permissions(profile):
        return True

    # ملاحظة: مفاتيح "إظهار ..." في "صلاحيات عامة" تتحكم في ظهور
    # القوائم في الواجهة فقط، وليست حقوق بيانات على الـ API، فلا
    # تُستخدم هنا للرفض (respect_global_toggle محفوظ للتوافق فقط).

    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    section = permissions.get(category)
    if not isinstance(section, dict):
        return False
    return _action_allowed(section, category, key)


# يفحص هل المستخدم عنده صلاحية موارد بشرية معينة
def has_hr_permission(profile: Dict[str, Any], key: str) -> bool:
    """
    صلاحيات الموارد البشرية (مفاتيح camelCase زي canViewEmployees).
    نفس العقد: مدير/صاحب برنامج مسموح، والموظف لازم True صريحة،
    مع احترام مفتاح "إظهار الموارد البشرية" لو موجود False.
    """
    role = _effective_role(profile)
    if can_bypass_permissions(profile):
        return True

    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    hr_permissions = permissions.get(_HR_CATEGORY)
    if not isinstance(hr_permissions, dict):
        return False
    return _action_allowed(hr_permissions, _HR_CATEGORY, key)


# يستخرج بروفايل المستخدم من الطلب
def _profile_from_request(request: Request) -> Dict[str, Any]:
    return getattr(request.state, "auth_user", None) or {}


# يرفض الطلب بـ403 لو المستخدم مش عنده صلاحية القسم
def require_section_permission(
    request: Request, category: str, key: str
) -> Dict[str, Any]:
    """يرمي 403 لو المستخدم مش عنده صلاحية القسم المطلوبة."""
    profile = _profile_from_request(request)
    if not has_section_permission(profile, category, key):
        raise HTTPException(
            status_code=403,
            detail=f"ليس لديك صلاحية {key} في {category}",
        )
    return profile


# يفحص هل المستخدم عنده أي مفتاح من مفاتيح الموارد البشرية
def has_any_hr_permission(profile: Dict[str, Any], keys: list) -> bool:
    """True لو أي مفتاح من مفاتيح الموارد البشرية متاح."""
    return any(has_hr_permission(profile, key) for key in keys)


# يرفض الطلب بـ403 لو مفيش صلاحية موارد بشرية مطلوبة
def require_hr_permission(request: Request, key: str) -> Dict[str, Any]:
    """يرمي 403 لو المستخدم مش عنده صلاحية الموارد البشرية المطلوبة."""
    profile = _profile_from_request(request)
    if not has_hr_permission(profile, key):
        raise HTTPException(
            status_code=403,
            detail=f"ليس لديك صلاحية {key} في {_HR_CATEGORY}",
        )
    return profile


# يرفض الطلب لو المستخدم مش عنده أي صلاحية من أقسام مجموعة
def require_any_section_permission(
    request: Request, checks: list
) -> Dict[str, Any]:
    """
    للمسارات اللي الواجهة بتفتحها بأكثر من صلاحية بديلة
    (زي canShowSales = أي واحدة من مجموعة). يرمي 403 لو ولا واحدة متحققة.
    """
    profile = _profile_from_request(request)
    if can_bypass_permissions(profile):
        return profile
    for category, key in checks:
        if has_section_permission(profile, category, key):
            return profile
    raise HTTPException(status_code=403, detail="ليس لديك صلاحية الوصول لهذه البيانات")
