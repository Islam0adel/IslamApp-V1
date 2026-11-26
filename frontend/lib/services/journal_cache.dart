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

  /// True only when [local] is provably the same stored version as [incoming]:
  /// both carry a parseable `updated_at`, the instants are equal, and every business
  /// field matches. Missing stamps or different content never count as the same version.
  static bool isSameVersion(Object? local, Map<String, dynamic> incoming) {
    if (local is! Map) return false;
    final a = _stamp(local['updated_at']);
    final b = _stamp(incoming['updated_at']);
    if (a == null || b == null || a != b) return false;
    const skip = {'action', 'is_deleted', 'updated_at'};
    final keys = <String>{...local.keys.map((k) => k.toString()), ...incoming.keys.map((k) => k.toString())}..removeAll(skip);
    for (final k in keys) {
      if (local[k]?.toString() != incoming[k]?.toString()) return false;
    }
    return (local['is_deleted'] == true) == (incoming['is_deleted'] == true);
  }

  static DateTime? _stamp(Object? v) {
    if (v == null) return null;
    final t = v.toString();
    final z = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(t);
    return DateTime.tryParse(z ? t : '${t}Z')?.toUtc();
  }

  /// Writes [row] unless the stored copy is provably the same version or provably newer.
  /// Missing or unparseable stamps on either side never skip a write.
  /// Returns 'applied', 'same' or 'stale'.
  static Future<String> putIfNotOlder(Box box, Map<String, dynamic> row, {String? expectedCompany}) async {
    final company = row['company_code']?.toString() ?? '';
    final local = box.get(key(company, row['branch_code']?.toString() ?? '1', row['serial']?.toString() ?? ''));
    if (isSameVersion(local, row)) return 'same';
    if (local is Map) {
      final a = _stamp(local['updated_at']);
      final b = _stamp(row['updated_at']);
      if (a != null && b != null && a.isAfter(b)) return 'stale';
    }
    await put(box, row, expectedCompany: expectedCompany);
    return 'applied';
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

  /// Ledger of rows deleted locally (WebSocket / sync) with the SERVER stamp of the delete.
  /// A staged snapshot that is not newer than that stamp must not bring the row back.
  /// Entries live 14 days; staged batches are dropped after 7 (see StagedChanges.mergeV2), so
  /// pruning by age can never evict an entry a live batch still needs. The count cap is only a
  /// safety limit (5000 deletes inside 14 days).
  static const ledgerMaxAge = Duration(days: 14);
  static const _ledgerMax = 5000;
  static String ledgerKey(String company) => 'last_sync_daily_deleted_$company';

  static Map<String, String> readLedger(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static String writeLedger(Map<String, String> m, String id, String stamp, {DateTime? now}) {
    final out = Map<String, String>.from(m);
    out[id] = stamp;
    final ref = (now ?? DateTime.now()).toUtc();
    out.removeWhere((k, v) {
      final t = DateTime.tryParse(v.endsWith('Z') || v.contains('+') ? v : '${v}Z');
      return t != null && ref.difference(t.toUtc()) > ledgerMaxAge;
    });
    if (out.length > _ledgerMax) {
      final keys = out.keys.toList();
      for (final k in keys.take(out.length - _ledgerMax)) {
        out.remove(k);
      }
    }
    return jsonEncode(out);
  }
}
