# Owner rule confirmed 2026-11-22: edit includes add, never the reverse.
# No view, delete, cost, export or ambiguous adjustment rights are inferred.
ADD_TO_EDIT = {
    "إدارة المستخدمين": {"إضافة": "تعديل"},
    "حركة الخزينة": {"ادخال اذون": "التعديل"},
    "حركة الجرد": {"اضافة": "تعديل"},
    "حسابات الموردين": {"اضافة": "تعديل"},
    "تسويات الموردين": {"إضافة": "تعديل"},
    "المبيعات": {"إضافة": "تعديل"},
    "المرتجعات": {"إضافة": "تعديل"},
    "حسابات العملاء": {"إضافة تحصيل": "تعديل تحصيل"},
    "التحويلات المخزنية": {"إضافة": "تعديل"},
    "تحويلات الخزائن": {"إضافة": "تعديل"},
    "الموارد البشرية": {"canAddAttendance": "canEditAttendance", "canAddVacation": "canEditVacation"},
}


def action_allowed(section, category, key):
    if section.get(key) is True:
        return True
    higher = ADD_TO_EDIT.get(category, {}).get(key)
    return higher is not None and section.get(higher) is True


