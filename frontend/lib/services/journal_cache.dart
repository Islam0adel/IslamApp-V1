import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

/// Journal identity is company + branch + serial. Legacy keys lacked company.
class JournalCache {
  static String key(String company, String branch, String serial) =>
      '${company}_journal_${jsonEncode([branch, serial])}';

  static bool belongsToCompany(dynamic key, dynamic value, String company) {
    if (value is Map && value.containsKey('company_code')) {
      return value['company_code']?.toString() == company;
    }
    return key.toString().startsWith('${company}_balances_');
  }

  static Future<void> put(Box box, Map<String, dynamic> row,
      {String? expectedCompany}) async {
    final company = row['company_code']?.toString() ?? '';
    final branch = row['branch_code']?.toString() ?? '1';
    final serial = row['serial']?.toString() ?? '';
    if (company.isEmpty || serial.isEmpty ||
        (expectedCompany != null && expectedCompany != company)) {
      throw StateError('Journal cache identity does not match the current company');
    }
    final target = key(company, branch, serial);
    final legacy = 'branch_${branch}_$serial';
    final old = box.get(legacy);
    final removeLegacy = old is Map && old['company_code']?.toString() == company;
    // Replace the legacy value in the same write batch so listeners never
    // calculate a duplicated balance from old and new identities.
    await box.putAll({if (removeLegacy) legacy: <String, dynamic>{}, target: Map<String, dynamic>.from(row)});
    if (removeLegacy) await box.delete(legacy);
  }

  static Future<void> deleteCompany(Box box, String company) async {
    final keys = box.keys.where((key) => belongsToCompany(key, box.get(key), company)).toList();
    await box.deleteAll(keys);
  }

  static Future<void> delete(Box box, {
    required String company, required String branch, required String serial,
  }) async {
    final target = key(company, branch, serial);
    final legacy = 'branch_${branch}_$serial';
    final keys = <String>[];
    for (final candidate in [target, legacy]) {
      final value = box.get(candidate);
      if (value is Map && value['company_code']?.toString() == company) {
        keys.add(candidate);
      }
    }
    await box.deleteAll(keys);
  }
}
