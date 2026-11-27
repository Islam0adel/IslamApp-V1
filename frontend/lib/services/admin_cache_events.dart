// frontend/lib/services/admin_cache_events.dart
import 'package:flutter/foundation.dart';

// أحداث إبطال الذاكرة المؤقتة لشاشات الإدارة (تلميحات فقط وليست صلاحية)
/// Identity-free invalidation hints. Never an authorization grant or data source.
class AdminCacheEvents {
  static final users = ValueNotifier<({String company, int revision})>(
      (company: '', revision: 0));
  static final companies = ValueNotifier<int>(0);

  // يرسل تلميحًا بتغيّر دليل مستخدمي الشركة
  static void userDirectory(String company) {
    users.value = (company: company, revision: users.value.revision + 1);
  }

  // يرسل تلميحًا بتغيّر دليل الشركات
  static void companyDirectory() {
    companies.value++;
  }
}
