"""Permission-safe access to derived effects, not raw transfer details."""
from app.core.permissions import has_section_permission

EFFECT_RIGHTS = (
    ("حركة الخزينة", "شاشات الارصدة"),
    ("حركة الخزينة", "المعاينة"),
    ("حركة الخزينة", "ادخال اذون"),
    ("التقارير", "تقرير فترة"),
    ("التقارير", "التقرير الموسع (صافي الجرد)"),
    ("التقارير", "تقرير التدفق النقدي"),
    ("التقارير", "تحليل الخزائن النقدية"),
)


def can_view_treasury_effects(profile):
    return any(has_section_permission(profile, category, key)
               for category, key in EFFECT_RIGHTS)
