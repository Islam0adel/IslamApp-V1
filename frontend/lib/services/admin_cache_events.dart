import 'package:flutter/foundation.dart';

/// Identity-free invalidation hints. Never an authorization grant or data source.
class AdminCacheEvents {
  static final users = ValueNotifier<({String company, int revision})>(
      (company: '', revision: 0));
  static final companies = ValueNotifier<int>(0);
  static void userDirectory(String company) {
    users.value = (company: company, revision: users.value.revision + 1);
  }
  static void companyDirectory() { companies.value++; }
}
