# backend/app/core/permission_policy.py
"""Pure permission-set operations for the approved company-ceiling model.

This module neither activates a
legacy policy nor creates company/user/delegation grants. Section visibility,
roles, tenant/branch/employee scope and account status remain caller concerns.
"""
from dataclasses import dataclass
from app.core.page_visibility import PAGE_VISIBILITY_KEYS

from app.core.permission_hierarchy import ADD_TO_EDIT

# نوع الحق: زوج (التصنيف، المفتاح)
Right = tuple[str, str]


# يتحقق من صحة خريطة الصلاحيات المقترحة قبل الحفظ
def validate_permission_map(value) -> None:
    """Validate a proposed write. Runtime reads instead fail closed per key."""
    if not isinstance(value, dict):
        raise ValueError('permissions must be an object')
    for category, section in value.items():
        if not isinstance(category, str) or not category or not isinstance(section, dict):
            raise ValueError('permission sections must be named objects')
        for key, flag in section.items():
            if not isinstance(key, str) or not key or type(flag) is not bool:
                raise ValueError('permission values must be named booleans')


# يحوّل الخريطة لمجموعة حقوق صريحة مع احتساب تعديل = إضافة
def grants(value) -> frozenset[Right]:
    """Explicit true rights plus only the declared edit-to-add implications."""
    result = set()
    if not isinstance(value, dict):
        return frozenset()
    for category, section in value.items():
        if not isinstance(category, str) or not isinstance(section, dict):
            continue
        result.update((category, key) for key, flag in section.items()
                      if isinstance(key, str) and key and flag is True)
        for add, edit in ADD_TO_EDIT.get(category, {}).items():
            if section.get(edit) is True:
                result.add((category, add))
    return frozenset(result)


# يعيد بناء خريطة الصلاحيات من مجموعة الحقوق
def materialize(rights) -> dict[str, dict[str, bool]]:
    result = {}
    for category, key in sorted(rights):
        result.setdefault(category, {})[key] = True
    return result


# يحسب الصلاحيات الفعلية من سقف الشركة وصلاحيات التشغيل
def effective_permissions(company_ceiling, operating_permissions) -> dict:
    """Neither a role nor the delegation map supplies an operating grant."""
    result = materialize(grants(company_ceiling) & grants(operating_permissions))
    general = operating_permissions.get('صلاحيات عامة', {}) if isinstance(operating_permissions, dict) else {}
    for key in PAGE_VISIBILITY_KEYS:
        if general.get(key) is False:
            result.setdefault('صلاحيات عامة', {})[key] = False
    return result


# نتيجة فحص تعيين الصلاحيات (خارج سقف الشركة أو خارج التفويض)
@dataclass(frozen=True)
class AssignmentCheck:
    outside_company: frozenset[Right]
    outside_delegation: frozenset[Right]

    # خاصية بترجّع هل التعيين مسموح
    @property
    def allowed(self) -> bool:
        return not self.outside_company and not self.outside_delegation


# يفحص خريطة بديلة من غير ما يقص حقوق أو يمنح غيرها بشكل صامت
def check_assignment(*, company_ceiling, delegable_permissions,
                     previous_permissions, proposed_permissions,
                     check_delegation: bool = True) -> AssignmentCheck:
    """Check a replacement map without silently clipping or granting rights.

    Unchanged target rights outside an actor's delegation set are preserved.
    Changes, including revocations, are reported separately for the caller to
    enforce/display. A verified platform administrator may explicitly skip the
    delegation check, never the company ceiling. This helper authenticates no
    caller and must not be exposed as an authority decision on its own.
    """
    validate_permission_map(proposed_permissions)
    previous = grants(previous_permissions)
    proposed = grants(proposed_permissions)
    changes = previous ^ proposed
    old_general = previous_permissions.get('صلاحيات عامة', {}) if isinstance(previous_permissions, dict) else {}
    new_general = proposed_permissions.get('صلاحيات عامة', {})
    changes |= {('صلاحيات عامة', key) for key in PAGE_VISIBILITY_KEYS
                if old_general.get(key) != new_general.get(key)}
    return AssignmentCheck(
        outside_company=proposed - grants(company_ceiling),
        outside_delegation=(changes - grants(delegable_permissions)
                            if check_delegation else frozenset()),
    )
