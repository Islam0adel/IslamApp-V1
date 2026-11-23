import 'cache_partitions.dart';
import 'permission_hierarchy.dart';

class TreasuryCacheScope {
  static const recordsBox = 'treasury_transfers_box';
  static const effectsBox = 'treasury_effects_box';
  static const effectRights = [
    ['حركة الخزينة', 'شاشات الارصدة'],
    ['حركة الخزينة', 'المعاينة'],
    ['حركة الخزينة', 'ادخال اذون'],
    ['التقارير', 'تقرير فترة'],
    ['التقارير', 'التقرير الموسع (صافي الجرد)'],
    ['التقارير', 'تقرير التدفق النقدي'],
    ['التقارير', 'تحليل الخزائن النقدية'],
  ];
  static bool hasRight(
          Map<String, dynamic>? permissions, String section, String right) =>
      PermissionHierarchy.allows(permissions, section, right);
  static bool hasEffects(Map<String, dynamic>? permissions) =>
      effectRights.any((right) => hasRight(permissions, right[0], right[1]));

  /// Current-owner snapshots only. A permission change never restores old rows.
  static Future<bool> apply(
      {required String company,
      required String? ownerUid,
      required Map<String, dynamic>? permissions,
      List<String>? branches}) async {
    return CachePartitions.run(() async {
      var changed = false;
      for (final name in [recordsBox, effectsBox]) {
        if (!CachePartitions.isBoxOpen(name)) continue;
        final box = CachePartitions.box(name);
        final allowed = name == recordsBox
            ? hasRight(permissions, 'تحويلات الخزائن', 'معاينة')
            : hasEffects(permissions);
        for (final key in box.keys.toList()) {
          final envelope = box.get(key);
          if (envelope is! Map ||
              envelope['company_code'] != company ||
              envelope['owner_uid'] != ownerUid) continue;
          if (!allowed) {
            await box.delete(key);
            changed = true;
          } else if (branches != null && !branches.contains('all')) {
            final rows = envelope['records'];
            if (rows is! List) {
              await box.delete(key);
              changed = true;
              continue;
            }
            final kept = rows
                .whereType<Map>()
                .where((r) => branches.contains(r['branch_code']?.toString()))
                .toList();
            final entries = envelope['entries'];
            final hiddenEntries = entries is List &&
                entries.whereType<Map>().any(
                    (r) => !branches.contains(r['branch_code']?.toString()));
            if (kept.length != rows.length || hiddenEntries) {
              await box.put(key, {
                ...Map<String, dynamic>.from(envelope),
                'records': kept,
                'entries': <dynamic>[],
                'protocol': 1,
                'cursor': 0,
                'server_scope': ''
              });
              changed = true;
            }
          }
        }
      }
      return changed;
    });
  }
}
