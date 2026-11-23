import 'work_pool.dart';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Application-account isolation, not encryption. Original Hive boxes are a
/// read-only legacy archive, never attributed to whoever first opens the app.
class CachePartitions {
  static const boxes = <String>[
    'daily_transactions_box',
    'treasury_transfers_box',
    'treasury_effects_box',
    'coding_box',
    'inventory_box',
    'supplier_box',
    'supplier_settlement_box',
    'sales_box',
    'sales_returns_box',
    'customer_payments_box',
    'stock_transfers_box',
    'commercial_stock_events_box',
    'commercial_pending_box',
    'notifications_box',
    'notification_settings_box',
    'product_lookup_box',
    'hr_pending_box',
    'companies_box',
    'users_box',
    'journal_save_intents_box',
    'journal_import_batches_box',
  ];
  static const _zoneKey = #islamAppCachePartition;
  static bool _enabled = false;
  static _CacheSession? _active;
  static Future<void> _tail = Future<void>.value();
  static int _generation = 0;
  static bool get enabled => _enabled;
  static int get generation => _generation;
  static String? get ownerUid => _active?.uid;
  static String? get companyCode => _active?.company;

  static String physicalName(String name, String uid, String company) =>
      'p2_${sha256.convert(utf8.encode(jsonEncode([uid, company])))}_$name';

  /// Must run before any application service is constructed.
  static void enable() {
    _enabled = true;
  }

  static String? _uid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// Synchronous invalidation also closes the window before signOut completes.
  static void suspend() {
    _active = null;
    _generation++;
  }

  static bool get isReady {
    final scope = _active;
    return !_enabled ||
        (scope != null &&
            scope.uid == _uid() &&
            scope.company == scope.preferences.getString('company_code'));
  }

  static void _check(_CacheSession? scope) {
    if (!_enabled) return;
    if (scope == null || !identical(scope, _active) || !isReady) {
      throw StateError(
          'Cache account/company changed. Retry in the current account.');
    }
  }

  static _CacheSession? get _scope =>
      Zone.current[_zoneKey] as _CacheSession? ?? _active;

  /// Every async service entry retains its originating cache, even after await
  /// or queued callbacks. It never resolves a late response into a new cache.
  static T run<T>(T Function() work) {
    if (!_enabled) return work();
    final scope = _scope;
    _check(scope);
    return runZoned(work, zoneValues: {_zoneKey: scope});
  }

  static void checkCurrent() => _check(_scope);
  static bool get boundWorkIsCurrent {
    try {
      checkBoundWork();
      return true;
    } catch (_) {
      return false;
    }
  }

  static void checkBoundWork() {
    if (_enabled && Zone.current[_zoneKey] != null) _check(_scope);
  }

  static Future<void> activate(String uid, String company) {
    final result = _tail.then((_) async {
      if (!_enabled) return;
      final prefs = await SharedPreferences.getInstance();
      if (uid.isEmpty ||
          company.isEmpty ||
          _uid() != uid ||
          prefs.getString('company_code') != company) {
        suspend();
        throw StateError(
            'Cannot activate a cache without its current owner/company');
      }
      if (isReady && _active?.uid == uid && _active?.company == company) return;
      suspend();
      final opened = <String, Box>{};
      final opening = WorkPool(4);
      await (() => Future.wait(
          [...boxes, 'cache_metadata_box'].map((name) => opening.run(() async {
                opened[name] =
                    await Hive.openBox(physicalName(name, uid, company));
              }))))();
      if (_uid() != uid || prefs.getString('company_code') != company) {
        throw StateError('Account changed while opening its cache');
      }
      await _migrateOwnedPending(uid, company, opened);
      await _removeHeldMigrationRows(uid, company, opened);
      if (_uid() != uid || prefs.getString('company_code') != company) {
        throw StateError('Account changed while preserving its pending work');
      }
      _active = _CacheSession(uid, company, prefs, opened);
      _generation++;
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  /// Copy only explicit immutable ownership. A completed migration marker is
  /// stored in the destination AFTER all copies; interruptions safely retry.
  /// Source entries are never deleted. Unknown ownership stays in the archive.
  static Future<void> _migrateOwnedPending(
      String uid, String company, Map<String, Box> opened) async {
    final metadata = opened['cache_metadata_box']!;
    if (metadata.get('legacy_pending_copied_v2') == true) return;
    for (final name in [
      'commercial_pending_box',
      'hr_pending_box',
      'journal_save_intents_box',
      'journal_import_batches_box'
    ]) {
      final source = await Hive.openBox(name);
      final destination = opened[name]!;
      for (final key in source.keys.toList()) {
        final raw = source.get(key);
        if (raw is! Map) continue;
        final owner = raw['user_uid'] ?? raw['owner_uid'];
        final code = raw['company_code'];
        var owned = owner == uid && code == company;
        if (name == 'journal_import_batches_box') {
          // Batch identity predates envelope fields; every embedded intention
          // must independently name the same owner and company.
          final intents = raw['intents'];
          owned = intents is List &&
              intents.isNotEmpty &&
              intents.every((v) =>
                  v is Map &&
                  v['owner_uid'] == uid &&
                  v['company_code'] == company);
          try {
            final identity = jsonDecode(key.toString());
            owned = owned &&
                identity is List &&
                identity.length == 5 &&
                identity[1] == uid &&
                identity[2] == company;
          } catch (_) {
            owned = false;
          }
        }
        if (!owned) continue;
        if (!destination.containsKey(key)) await destination.put(key, raw);
        if (name == 'commercial_pending_box' &&
            raw['revoked_hold'] != true &&
            raw['discarded'] != true &&
            raw['data'] is Map) {
          final kind = raw['kind'];
          final target = {
            'sales': 'sales_box',
            'returns': 'sales_returns_box',
            'customer-payments': 'customer_payments_box',
            'transfers': 'stock_transfers_box'
          }[kind];
          if (target != null) {
            // Only the owner's pending payload, never adjacent clean rows.
            final data = Map<String, dynamic>.from(raw['data'] as Map);
            if (data['company_code'] == company && data['id'] == raw['id']) {
              data['sync_status'] = 'pending';
              final branch =
                  data['branch_code'] ?? data['from_branch_code'] ?? 'all';
              final localKey = '${company}_${branch}_${data['date'] ?? ''}';
              final old = opened[target]!.get(localKey);
              final rows = old is List ? List<dynamic>.from(old) : <dynamic>[];
              if (!rows.whereType<Map>().any((v) => v['id'] == data['id'])) {
                rows.add(data);
                await opened[target]!.put(localKey, rows);
              }
            }
          }
        }
      }
    }
    await metadata.put('legacy_pending_copied_v2', true);
  }

  /// Also repairs an already-created v2 space from the preceding patch.
  /// Only exact payload-derived pending copies of the current owner's held or
  /// discarded operations are removed from display lists. A same-ID row with
  /// different contents is not assumed to come from migration. The queue and archive are untouched.
  static Future<void> _removeHeldMigrationRows(
      String uid, String company, Map<String, Box> opened) async {
    final pending = opened['commercial_pending_box']!;
    for (final op in pending.values.whereType<Map>()) {
      if (op['user_uid'] != uid ||
          op['company_code'] != company ||
          (op['revoked_hold'] != true && op['discarded'] != true)) continue;
      final target = {
        'sales': 'sales_box',
        'returns': 'sales_returns_box',
        'customer-payments': 'customer_payments_box',
        'transfers': 'stock_transfers_box'
      }[op['kind']];
      final id = op['id']?.toString();
      final payload = op['data'];
      if (target == null || id == null || id.isEmpty || payload is! Map)
        continue;
      final derived = {...payload, 'sync_status': 'pending'};
      if (derived['company_code'] != company || derived['id']?.toString() != id)
        continue;
      bool sameValue(dynamic a, dynamic b) {
        if (a is Map && b is Map)
          return a.length == b.length &&
              a.keys.every(
                  (key) => b.containsKey(key) && sameValue(a[key], b[key]));
        if (a is List && b is List)
          return a.length == b.length &&
              List.generate(a.length, (i) => i)
                  .every((i) => sameValue(a[i], b[i]));
        return a == b;
      }

      var changed = false;
      final box = opened[target]!;
      for (final key in box.keys.toList()) {
        final rows = box.get(key);
        if (rows is! List) continue;
        final kept = rows
            .where((row) =>
                row is! Map ||
                row['company_code'] != company ||
                row['id']?.toString() != id ||
                !sameValue(row, derived))
            .toList();
        if (kept.length == rows.length) continue;
        changed = true;
        if (kept.isEmpty) {
          await box.delete(key);
        } else {
          await box.put(key, kept);
        }
      }
      if (changed)
        await opened['commercial_stock_events_box']!
            .delete('${company}_synced_at');
    }
  }

  /// Stable identity for a live physical cache, unlike disposable Box wrappers.
  /// Does not expose the raw Box or permit bypassing its scope checks.
  static final _boxIdentities = Expando<Object>();
  static Object boxIdentity(String name) {
    if (!_enabled) {
      final raw = Hive.box(name);
      return _boxIdentities[raw] ??= Object();
    }
    final scope = _scope;
    _check(scope);
    if (!scope!.opened.containsKey(name))
      throw StateError('Unregistered account cache: $name');
    return scope
        .identity; // Token only, never the session or its physical Boxes.
  }

  static Box<E> box<E>(String name) {
    if (!_enabled) return Hive.box<E>(name);
    final scope = _scope;
    _check(scope);
    final raw = scope!.opened[name];
    if (raw == null) throw StateError('Unregistered account cache: $name');
    return _PartitionBox<E>(scope, raw as Box<E>);
  }

  static bool isBoxOpen(String name) {
    if (!_enabled) return Hive.isBoxOpen(name);
    try {
      _check(_scope);
      return _scope!.opened[name]?.isOpen ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<Box<E>> openBox<E>(String name) async {
    if (!_enabled) return Hive.openBox<E>(name);
    return box<E>(name);
  }

  static Future<CachePreferences> preferences() async => CachePreferences(
      await SharedPreferences.getInstance(), _enabled ? _scope : null);
}

class _CacheSession {
  _CacheSession(this.uid, this.company, this.preferences, this.opened);
  final String uid, company;
  final SharedPreferences preferences;
  final Map<String, Box> opened;
  final Object identity = Object();
}

/// Cursor reads/writes are in the same partition as their cached records.
/// Login credentials, user choices and appearance preferences are untouched.
class CachePreferences {
  CachePreferences(this.raw, this.scope);
  final SharedPreferences raw;
  final _CacheSession? scope;
  bool _cursor(String key) => key.startsWith('last_sync_');
  Box get _metadata {
    CachePartitions._check(scope);
    return scope!.opened['cache_metadata_box']!;
  }

  String? getString(String key) => CachePartitions.enabled && _cursor(key)
      ? _metadata.get(key) as String?
      : raw.getString(key);
  bool? getBool(String key) => raw.getBool(key);
  Future<bool> setString(String key, String value) async {
    if (CachePartitions.enabled && _cursor(key)) {
      await _metadata.put(key, value);
      return true;
    }
    return raw.setString(key, value);
  }

  Future<bool> setBool(String key, bool value) => raw.setBool(key, value);
  Future<bool> remove(String key) async {
    if (CachePartitions.enabled && _cursor(key)) {
      await _metadata.delete(key);
      return true;
    }
    return raw.remove(key);
  }
}

/// A retained Box cannot be reused across logout/company changes. Watchers
/// stop delivering immediately when their original session is no longer live.
class _PartitionBox<E> implements Box<E> {
  _PartitionBox(this.scope, this.raw);
  final _CacheSession scope;
  final Box<E> raw;
  Box<E> get _box {
    CachePartitions._check(scope);
    return raw;
  }

  @override
  String get name => raw.name;
  @override
  bool get isOpen {
    try {
      return _box.isOpen;
    } catch (_) {
      return false;
    }
  }

  @override
  String? get path => raw.path;
  @override
  bool get lazy => false;
  @override
  Iterable<dynamic> get keys => _box.keys.toList();
  @override
  Iterable<E> get values => _box.values.toList();
  @override
  int get length => _box.length;
  @override
  bool get isEmpty => _box.isEmpty;
  @override
  bool get isNotEmpty => _box.isNotEmpty;
  @override
  dynamic keyAt(int index) => _box.keyAt(index);
  @override
  bool containsKey(dynamic key) => _box.containsKey(key);
  @override
  E? get(dynamic key, {E? defaultValue}) =>
      _box.get(key, defaultValue: defaultValue);
  @override
  E? getAt(int index) => _box.getAt(index);
  @override
  Map<dynamic, E> toMap() => _box.toMap();
  @override
  Iterable<E> valuesBetween({dynamic startKey, dynamic endKey}) =>
      _box.valuesBetween(startKey: startKey, endKey: endKey).toList();
  @override
  Stream<BoxEvent> watch({dynamic key}) => _box.watch(key: key).where((_) {
        try {
          CachePartitions._check(scope);
          return true;
        } catch (_) {
          return false;
        }
      });
  @override
  Future<void> put(dynamic key, E value) => _box.put(key, value);
  @override
  Future<void> putAt(int index, E value) => _box.putAt(index, value);
  @override
  Future<void> putAll(Map<dynamic, E> entries) => _box.putAll(entries);
  @override
  Future<int> add(E value) => _box.add(value);
  @override
  Future<Iterable<int>> addAll(Iterable<E> values) => _box.addAll(values);
  @override
  Future<void> delete(dynamic key) => _box.delete(key);
  @override
  Future<void> deleteAt(int index) => _box.deleteAt(index);
  @override
  Future<void> deleteAll(Iterable<dynamic> keys) => _box.deleteAll(keys);
  @override
  Future<void> compact() => _box.compact();
  @override
  Future<int> clear() => _box.clear();
  @override
  Future<void> flush() => _box.flush();
  @override
  Future<void> close() =>
      throw StateError('Account cache lifecycle is centrally managed');
  @override
  Future<void> deleteFromDisk() =>
      throw StateError('Account caches cannot be deleted implicitly');
}
