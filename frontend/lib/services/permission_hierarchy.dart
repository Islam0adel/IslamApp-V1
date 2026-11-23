/// The owner's permission rule: editing includes adding, not the reverse.
/// Only declared, unambiguous action pairs are listed here.
class PermissionHierarchy {
  static const addToEdit = <String, Map<String,String>>{
    'إدارة المستخدمين': {'إضافة':'تعديل'},
    'حركة الخزينة': {'ادخال اذون':'التعديل'},
    'حركة الجرد': {'اضافة':'تعديل'},
    'حسابات الموردين': {'اضافة':'تعديل'},
    'تسويات الموردين': {'إضافة':'تعديل'},
    'المبيعات': {'إضافة':'تعديل'},
    'المرتجعات': {'إضافة':'تعديل'},
    'حسابات العملاء': {'إضافة تحصيل':'تعديل تحصيل'},
    'التحويلات المخزنية': {'إضافة':'تعديل'},
    'تحويلات الخزائن': {'إضافة':'تعديل'},
    'الموارد البشرية': {'canAddAttendance':'canEditAttendance','canAddVacation':'canEditVacation'},
  };
  static bool allows(Map<String,dynamic>? permissions,String category,String key) {
    final section=permissions?[category];
    if(section is! Map)return false;
    if(section[key]==true)return true;
    final higher=addToEdit[category]?[key];
    return higher!=null && section[higher]==true;
  }
}
