import 'sync_read_access.dart';
import 'cache_partitions.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';
// lib/services/hr_service.dart

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:async'; // عشان unawaited
import '../models/hr_models.dart';
import '../core/constants.dart';
import '../core/hr_constants.dart';
import 'auth_http.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// خدمة الموارد البشرية — موحدة
///
/// النمط:
/// - Hive أولاً للقراءة السريعة
/// - Delta sync عبر /changes (زي باقي النظام)
/// - Pending Queue في Hive (مش في الذاكرة)
///
/// الملف مقسم على 3 أجزاء (عشان سهولة الصيانة):
/// - Part 1: Setup + Attendance + Pending
/// - Part 2: Vacations + Adjustments
/// - Part 3: Employee Settings
class HRService {
  // ============================================================
  // Setup
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;

  /// بيانات HR (attendance, vacations, adjustments, settings)
  /// بتستخدم نفس نمط باقي النظام — `coding_box` + مفاتيح prefixed
  Box get _codingBox => CachePartitions.box('coding_box');

  /// طابور العمليات المعلقة (pending)
  /// بدل ما كانت في الذاكرة وبتضيع عند قفل التطبيق
  Box get _pendingBox => CachePartitions.box('hr_pending_box');

  /// ⭐ مفاتيح pending شغالة الرفع دلوقتي (in-memory فقط)
  /// الفايدة:
  ///   - الـ UI يعتبرها "محفوظة" فوراً (مفيش انتظار)
  ///   - الـ pending تفضل في Hive كضمان لو المستخدم قفل التطبيق
  ///   - لو الرفع فشل، تشيلها من الـ Set → ترجع pending تاني
  final Set<String> _uploadingKeys = {};

  // ============================================================
  // Hive keys
  // ============================================================

  String _attendanceKey(String companyCode) => '${companyCode}_hr_attendance';

  String _pendingKey(
    String companyCode,
    String employeeCode,
    String date,
  ) =>
      '${companyCode}_${employeeCode}_$date';

  String _coverageKey(String kind, String company, String employee, String month) =>
      '${company}_hr_coverage_${kind}_${employee}_$month';
  bool _covered(String kind, String company, String employee, String month) =>
      _codingBox.get(_coverageKey(kind, company, employee, month)) == PermissionsService().hrCoverageScope ||
      _codingBox.get(_coverageKey(kind, company, '*', month)) == PermissionsService().hrCoverageScope;
  Future<void> _markCovered(String kind, String company, String employee, String month) =>
      _codingBox.put(_coverageKey(kind, company, employee, month), PermissionsService().hrCoverageScope);

  // ============================================================
  // Helpers
  // ============================================================

  /// فحص ناجح للـ HTTP
  bool _ok(int status) => status >= 200 && status < 300;

  /// دمج عناصر جديدة في Hive (مع إزالة التكرار حسب مفتاح فريد)
  Future<void> _mergeIntoHive(
    String localKey,
    List<Map<String, dynamic>> newItems, {
    required String Function(Map<String, dynamic>) uniqueKeyBuilder,
  }) async {
return CachePartitions.run(() async {

    List<Map<String, dynamic>> currentList = [];

    if (_codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        currentList = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    for (final newItem in newItems) {
      final newKey = uniqueKeyBuilder(newItem);
      currentList.removeWhere(
        (e) => uniqueKeyBuilder(e) == newKey,
      );
      currentList.add(newItem);
    }

    await _codingBox.put(localKey, currentList);
});
}

  // ============================================================
  // ================= 1. ATTENDANCE ============================
  // ============================================================

  /// جلب حضور يوم معين (كل الموظفين أو موظف واحد)
  Future<List<HRAttendanceModel>> getAttendanceForDate({
    required String companyCode,
    required String date,
    String? branchCode,
    String? employeeCode,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final localKey = _attendanceKey(companyCode);

    // ---------- 1) Hive ----------
    final coverageKind = 'attendance_day_${branchCode ?? '*'}';
    final covered = _covered(coverageKind, companyCode, employeeCode ?? '*', date) ||
        _covered('attendance', companyCode, employeeCode ?? '*', date.substring(0, 7));
    if (covered && _codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        final models = raw
            .whereType<Map>()
            .map((e) => HRAttendanceModel.fromMap(
                  Map<String, dynamic>.from(e),
                ))
            .where((a) => !a.isDeleted)
            .where((a) => a.date == date)
            .where((a) => branchCode == null || a.branchCode == branchCode)
            .where(
                (a) => employeeCode == null || a.employeeCode == employeeCode)
            .toList();

        // إزالة التكرار (employee_code + date)
        final unique = <String, HRAttendanceModel>{};
        for (final m in models) {
          unique['${m.employeeCode}_${m.date}'] = m;
        }
        return unique.values.toList();
      }
    }

    // ---------- 2) السيرفر ----------
    try {
      final url = Uri.parse("$baseUrl/hr/attendance/list/$companyCode").replace(
        queryParameters: {
          'date': date,
          if (branchCode != null) 'branch_code': branchCode,
          if (employeeCode != null) 'employee_code': employeeCode,
        },
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        print("❌ [attendance day] HTTP ${response.statusCode}");
        throw StateError('تعذر تحميل تاريخ الحضور');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      readScope.check();
      await _mergeIntoHive(
        localKey,
        list,
        uniqueKeyBuilder: (m) => '${m['employee_code']}_${m['date']}',
      );
      readScope.check();

      await _markCovered(coverageKind, companyCode, employeeCode ?? '*', date);
      readScope.check();
      return list.map((e) => HRAttendanceModel.fromMap(e)).toList();
    } catch (e) {
      print("❌ [attendance day] $e");
      rethrow;
    }
});
}

  Future<Map<String, HRAttendanceModel>> getEmployeeMonthAttendance({
    required String companyCode,
    required String employeeCode,
    required String month,
    String? branchCode,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final result = <String, HRAttendanceModel>{};
    final localKey = _attendanceKey(companyCode);

    // ---------- 1) Hive ----------
    if (_codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          try {
            final model = HRAttendanceModel.fromMap(
              Map<String, dynamic>.from(item),
            );
            if (model.isDeleted) continue;
            if (model.employeeCode != employeeCode) continue;
            if (!model.date.startsWith('$month-')) continue;
            result[model.date] = model;
          } catch (_) {}
        }
      }
    }

    // ⭐ لو Hive فيه بيانات → رجّعها فوراً (سريع)
    if (_covered('attendance', companyCode, employeeCode, month)) return result;

    // ---------- 2) Server fallback (للشهور القديمة) ----------
    try {
      final url = Uri.parse(
        "$baseUrl/hr/attendance/employee/$companyCode/$employeeCode",
      ).replace(queryParameters: {'month': month});

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) throw StateError('تعذر تحميل حضور الشهر');

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);

        final model = HRAttendanceModel.fromMap(map);
        result[model.date] = model;
      }

      if (list.isNotEmpty) {
        readScope.check();
        await _mergeIntoHive(
          localKey,
          list,
          uniqueKeyBuilder: (m) => '${m['employee_code']}_${m['date']}',
        );
        readScope.check();
      }

      readScope.check();
      await _markCovered('attendance', companyCode, employeeCode, month);
      readScope.check();
      return result;
    } catch (e) {
      rethrow;
    }
});
}

  /// حفظ / تحديث حضور
  ///
  /// ⚠️ ملاحظة: هيرجع id من السيرفر (مهم للتعديل لاحقًا)
  Future<Map<String, dynamic>> saveAttendance({
    required HRAttendanceModel model,
  }) async {
return CachePartitions.run(() async {

    final cacheScope = await ReadAuthorizationSnapshot.capture();
    try {
      cacheScope.check();
      final response = await AuthHttp.post(
        Uri.parse("$baseUrl/hr/attendance/save"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(model.toMap()),
      );

      if (!_ok(response.statusCode)) {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final Map<String, dynamic> result = jsonDecode(response.body);
      if (!cacheScope.isCurrent)
        return {
          'success': true,
          'id': result['id'],
          'action': result['action'],
          'scope_changed': true
        };
      final localKey = _attendanceKey(model.companyCode);

      // تحديث Hive
      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      final newItem = model.toMap();
      newItem['is_deleted'] = false;
      if (result['id'] != null) {
        newItem['id'] = result['id'];
      }

      // إزالة أي عنصر بنفس id
      if (result['id'] != null) {
        currentList.removeWhere(
          (e) => e['id']?.toString() == result['id'].toString(),
        );
      }

      // إزالة أي عنصر بنفس (employee_code + date) — defense in depth
      currentList.removeWhere(
        (e) =>
            e['employee_code']?.toString() == model.employeeCode &&
            e['date']?.toString() == model.date,
      );

      currentList.add(newItem);

      await _codingBox.put(localKey, currentList);

      return {
        'success': true,
        'id': result['id'],
        'action': result['action'],
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
});
}

  /// حذف حضور (Soft Delete)
  Future<bool> deleteAttendance({
    required String companyCode,
    required int attendanceId,
  }) async {
return CachePartitions.run(() async {

    try {
      final response = await AuthHttp.delete(
        Uri.parse(
          "$baseUrl/hr/attendance/delete/$companyCode/$attendanceId",
        ),
      );

      if (!_ok(response.statusCode)) {
        print("❌ [attendance delete] HTTP ${response.statusCode}");
        return false;
      }

      // حذف محلي
      final localKey = _attendanceKey(companyCode);
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          final safeList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where(
                (e) =>
                    e['id']?.toString() != attendanceId.toString() &&
                    e['is_deleted'] != true,
              )
              .toList();

          if (safeList.isEmpty) {
            await _codingBox.delete(localKey);
          } else {
            await _codingBox.put(localKey, safeList);
          }
        }
      }

      return true;
    } catch (e) {
      print("❌ [attendance delete] $e");
      return false;
    }
});
}

  /// Full sync للحضور — آخر 6 شهور
  ///
  /// ⚠️ إصلاح جوهري:
  /// النسخة القديمة كانت بتحمّل "اليوم فقط" → بيانات ناقصة للأبد.
  /// النسخة الجديدة بتحمّل آخر 6 شهور في طلب واحد.
  Future<void> fetchAllAttendance(String companyCode) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    print("📥 [attendance] FULL SYNC (آخر 6 شهور) — $companyCode");

    try {
      final now = DateTime.now();
      final fromDate = DateTime(now.year, now.month - 6, 1);
      final toDate = now;

      final fromStr = HRConstants.dateToStr(fromDate);
      final toStr = HRConstants.dateToStr(toDate);

      final url = Uri.parse("$baseUrl/hr/attendance/list/$companyCode").replace(
        queryParameters: {
          'from_date': fromStr,
          'to_date': toStr,
        },
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception(
          'فشل تحميل الحضور. HTTP ${response.statusCode}',
        );
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      readScope.check();
      final previous = _codingBox.get(_attendanceKey(companyCode));
      final older = previous is List ? previous.whereType<Map>().where((row) =>
          (row['date']?.toString() ?? '').compareTo(fromStr) < 0).toList() : <Map>[];
      await _codingBox.put(_attendanceKey(companyCode), [...older, ...list]);
      readScope.check();
      for (var i = 0; i <= 6; i++) {
        final m = DateTime(now.year, now.month - i, 1);
        await _markCovered('attendance', companyCode, '*', HRConstants.monthToStr(m));
        readScope.check();
      }

      print(
        "✅ [attendance] FULL SYNC: ${list.length} سجل "
        "($fromStr → $toStr)",
      );
    } catch (e) {
      print("❌ [attendance] FULL SYNC فشل: $e");
      rethrow;
    }
});
}

  /// Delta sync للحضور
  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    readScope.check();
    final lastSyncKey = 'last_sync_hr_attendance_$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    // جهاز جديد → full sync
    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      await fetchAllAttendance(companyCode);
      readScope.check();
      await prefs.setString(
        lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );
      readScope.check();
      return;
    }

    print("📡 [attendance] INCREMENTAL منذ $lastSyncValue");

    try {
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final url = Uri.parse("$baseUrl/hr/attendance/changes/$companyCode")
          .replace(queryParameters: {'since': effectiveSince});

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception(
          'فشل مزامنة الحضور. HTTP ${response.statusCode}',
        );
      }

      final List<dynamic> changes = jsonDecode(response.body);

      if (changes.isEmpty) {
        print("⏭️ [attendance] لا يوجد تغييرات");
        readScope.check();
        await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
        readScope.check();
        return;
      }

      final localKey = _attendanceKey(companyCode);

      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      for (final item in changes) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final action = map['action']?.toString() ??
            (map['is_deleted'] == true ? 'delete' : 'update');

        final empCode = map['employee_code']?.toString() ?? '';
        final date = map['date']?.toString() ?? '';
        if (empCode.isEmpty || date.isEmpty) continue;

        currentList.removeWhere(
          (e) =>
              e['employee_code']?.toString() == empCode &&
              e['date']?.toString() == date,
        );

        if (action == 'delete' || map['is_deleted'] == true) continue;

        map.remove('action');
        map['is_deleted'] = false;
        currentList.add(map);
      }

      if (currentList.isEmpty) {
        await _codingBox.delete(localKey);
        readScope.check();
      } else {
        readScope.check();
        await _codingBox.put(localKey, currentList);
        readScope.check();
      }

      readScope.check();
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      readScope.check();
      print("✅ [attendance] تم تحديث ${changes.length} تغيير");
    } catch (e) {
      print("❌ [attendance] INCREMENTAL فشل: $e");
      rethrow;
    }
});
}

  /// جلب الـ pending model (لو موجود وaction=save)
  HRAttendanceModel? getPendingModel(
    String companyCode,
    String employeeCode,
    String date,
  ) {
    final raw = _pendingBox.get(
      _pendingKey(companyCode, employeeCode, date),
    );

    if (raw is! Map) return null;

    final map = Map<String, dynamic>.from(raw);
    if (map['action'] != 'save') return null;

    final data = map['data'];
    if (data is! Map) return null;

    return HRAttendanceModel.fromMap(
      Map<String, dynamic>.from(data),
    );
  }

  /// هل الـ pending من نوع delete؟
  bool isPendingDelete(
    String companyCode,
    String employeeCode,
    String date,
  ) {
    final raw = _pendingBox.get(
      _pendingKey(companyCode, employeeCode, date),
    );

    if (raw is! Map) return false;
    return raw['action'] == 'delete';
  }

  Future<void> addPendingSave(HRAttendanceModel model) async {
return CachePartitions.run(() async {

    final key = _pendingKey(model.companyCode, model.employeeCode, model.date);
    // ⭐ لو كان بيترفع دلوقتي، نلغي علامة الرفع عشان الـ UI يشوف الـ pending الجديد
    _uploadingKeys.remove(key);
    await _pendingBox.put(key, {
      'action': 'save',
      'data': model.toMap(),
      // وسم الملكية: لا يرفعها ولا يرفع عنها التعليق إلا مالكها
      'company_code': model.companyCode,
      'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
    });
});
}

  Future<void> addPendingDelete({
    required String companyCode,
    required String employeeCode,
    required String date,
  }) async {
return CachePartitions.run(() async {

    final key = _pendingKey(companyCode, employeeCode, date);
    _uploadingKeys.remove(key);
    await _pendingBox.put(key, {
      'action': 'delete',
      'data': null,
      'company_code': companyCode,
      'user_uid': FirebaseAuth.instance.currentUser?.uid ?? '',
    });
});
}

  /// إزالة pending (بعد ما اترفع بنجاح)
  Future<void> removePending(
    String companyCode,
    String employeeCode,
    String date,
  ) async {
return CachePartitions.run(() async {

    await _pendingBox.delete(
      _pendingKey(companyCode, employeeCode, date),
    );
});
}

  /// هل فيه pending لهذا الموظف/اليوم؟ (بيستثني اللي under upload)
  bool hasPending(
    String companyCode,
    String employeeCode,
    String date,
  ) {
    final key = _pendingKey(companyCode, employeeCode, date);
    if (_uploadingKeys.contains(key)) return false;
    return _pendingBox.containsKey(key);
  }

  /// كل الـ pending للشركة (بيستثني اللي under upload)
  List<Map<String, dynamic>> getAllPendingForCompany(String companyCode) {
    final prefix = '${companyCode}_';
    final result = <Map<String, dynamic>>[];

    for (final key in _pendingBox.keys) {
      final keyStr = key.toString();
      if (!keyStr.startsWith(prefix)) continue;
      if (_uploadingKeys.contains(keyStr)) continue; // ⭐

      final raw = _pendingBox.get(key);
      if (raw is! Map) continue;

      final map = Map<String, dynamic>.from(raw);
      map['_key'] = keyStr;
      result.add(map);
    }

    return result;
  }

  /// ⭐ هل فيه رفع شغال دلوقتي للشركة؟
  bool hasUploadingForCompany(String companyCode) {
    return _uploadingKeys.any((k) => k.startsWith('${companyCode}_'));
  }

  /// حذف كل pending لشركة معينة (عند logout أو reset)
  Future<void> clearPending(String companyCode) async {
return CachePartitions.run(() async {

    final prefix = '${companyCode}_';
    final toDelete = <dynamic>[];

    for (final key in _pendingBox.keys) {
      if (key.toString().startsWith(prefix)) {
        toDelete.add(key);
      }
    }

    for (final key in toDelete) {
      await _pendingBox.delete(key);
    }
});
}

  /// رفع كل pending لموظف معين (يُستخدم في زر "حفظ")
  ///
  /// رفع كل pending لموظف معين (يُستخدم في زر "حفظ")
  ///
  /// ⭐ تحسين: كل السجلات بترفع متوازية (batched 5 at a time)
  /// عشان 3 أيام ماتاخدش 3 ثواني — تاخد ~500ms
  ///
  /// ⭐ onProgress: عشان الـ UI يعرض "2 من 5"
  // The fast-save button and reconnect retry share one per-record upload
  // lane, across HRService instances. UI stays local-first; requests for the
  // same employee/day cannot reach the server out of order.
  static final Map<String, Future<void>> _attendanceUploadTails = {};

  Future<T> _attendanceUpload<T>(String key, Future<T> Function() work) async {
return CachePartitions.run(() async {

    final previous = _attendanceUploadTails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _attendanceUploadTails[key] = done.future;
    await previous;
    try {
      return await work();
    } finally {
      done.complete();
      if (identical(_attendanceUploadTails[key], done.future)) {
        _attendanceUploadTails.remove(key);
      }
    }
});
}

  bool _mayUploadPending(Map op) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return uid.isNotEmpty &&
        op['user_uid'] == uid &&
        op['discarded'] != true &&
        op['revoked_hold'] != true;
  }

  Future<Map<String, dynamic>?> _pendingSnapshot(dynamic key) async {
return CachePartitions.run(() async {

    final raw = _pendingBox.get(key);
    if (raw is! Map) return null;
    final op = Map<String, dynamic>.from(raw);
    if ((op['user_uid']?.toString() ?? '').isEmpty) {
      if (op['ownership_unverified'] != true) {
        op['ownership_unverified'] = true;
        await _pendingBox.put(key, op);
      }
      return null;
    }
    return _mayUploadPending(op) ? op : null;
});
}

  Future<String?> _uploadPendingEntry(
          String companyCode, dynamic key, Map<String, dynamic> expected) =>
      _attendanceUpload(key.toString(), () async {
        final raw = _pendingBox.get(key);
        if (raw is! Map ||
            !_mayUploadPending(raw) ||
            jsonEncode(raw) != jsonEncode(expected)) return null;
        final prefix = '${companyCode}_';
        final suffix = key.toString().substring(prefix.length);
        final divider = suffix.lastIndexOf('_');
        if (divider <= 0) return 'invalid attendance queue key';
        final employee = suffix.substring(0, divider);
        final date = suffix.substring(divider + 1);
        if (expected['action'] == 'delete') {
          int? existingId;
          final rows = _codingBox.get(_attendanceKey(companyCode));
          if (rows is List) {
            for (final item in rows.whereType<Map>()) {
              if (item['employee_code']?.toString() == employee &&
                  item['date']?.toString() == date &&
                  item['is_deleted'] != true) {
                existingId = int.tryParse(item['id']?.toString() ?? '');
                break;
              }
            }
          }
          if (existingId == null) {
            // A prior save may have committed with its reply lost. Resolve the
            // exact employee/day from the server before acknowledging a delete.
            final response = await AuthHttp.get(
                Uri.parse('$baseUrl/hr/attendance/list/$companyCode').replace(
                    queryParameters: {
                  'date': date,
                  'employee_code': employee
                }));
            if (!_ok(response.statusCode)) return 'delete lookup $date failed';
            final items = jsonDecode(response.body);
            if (items is! List) return 'invalid attendance delete lookup';
            for (final item in items.whereType<Map>()) {
              if (item['employee_code']?.toString() == employee &&
                  item['date']?.toString() == date &&
                  item['is_deleted'] != true) {
                existingId = int.tryParse(item['id']?.toString() ?? '');
                if (existingId == null) return 'invalid attendance id';
                break;
              }
            }
          }
          if (existingId != null) {
            // Recheck authority after the lookup and before any mutation.
            final latest = _pendingBox.get(key);
            if (latest is! Map ||
                !_mayUploadPending(latest) ||
                jsonEncode(latest) != jsonEncode(expected)) return null;
            final ok = await deleteAttendance(
                companyCode: companyCode, attendanceId: existingId);
            if (!ok) return 'delete $date failed';
          }
        } else {
          final data = expected['data'];
          if (data is! Map) return 'invalid attendance save payload';
          final model =
              HRAttendanceModel.fromMap(Map<String, dynamic>.from(data));
          if (model.companyCode != companyCode ||
              model.employeeCode != employee ||
              model.date != date) {
            return 'attendance queue target mismatch';
          }
          final result = await saveAttendance(model: model);
          if (result['success'] != true)
            return 'save $date: ${result['error']}';
        }
        await _safeDeletePending(key, expected);
        return null;
      });

  Future<Map<String, dynamic>> commitPending({
    required String companyCode,
    required String employeeCode,
    void Function(int done, int total)? onProgress,
  }) async {
return CachePartitions.run(() async {

    final prefix = '${companyCode}_${employeeCode}_';
    final snapshot = <dynamic, Map<String, dynamic>>{};
    for (final key in _pendingBox.keys.toList()) {
      if (!key.toString().startsWith(prefix)) continue;
      final op = await _pendingSnapshot(key);
      if (op != null) snapshot[key] = op;
    }
    return _uploadAttendanceSnapshot(companyCode, snapshot,
        onProgress: onProgress);
});
}

  Future<Map<String, dynamic>> commitPendingFast({
    required String companyCode,
    required String employeeCode,
    void Function()? onCompleted,
  }) async {
return CachePartitions.run(() async {

    final prefix = '${companyCode}_${employeeCode}_';
    final snapshot = <dynamic, Map<String, dynamic>>{};
    for (final key in _pendingBox.keys.toList()) {
      if (!key.toString().startsWith(prefix)) continue;
      final op = await _pendingSnapshot(key);
      if (op != null) {
        snapshot[key] = op;
        _uploadingKeys.add(key.toString());
      }
    }
    unawaited(() async {
      await _uploadAttendanceSnapshot(companyCode, snapshot);
      if (onCompleted != null) {
        try {
          onCompleted();
        } catch (_) {}
      }
    }());
    return {
      'success': true,
      'pending_count': snapshot.length,
      'saved_count': 0,
      'deleted_count': 0
    };
});
}

  Future<Map<String, dynamic>> _uploadAttendanceSnapshot(
      String companyCode, Map<dynamic, Map<String, dynamic>> snapshot,
      {void Function(int done, int total)? onProgress}) async {
return CachePartitions.run(() async {

    int done = 0, saved = 0, deleted = 0;
    final errors = <String>[];
    final entries = snapshot.entries.toList();
    onProgress?.call(0, entries.length);
    // Retain existing five-at-a-time concurrency for different days/employees.
    for (int i = 0; i < entries.length; i += 5) {
      final end = (i + 5).clamp(0, entries.length);
      await Future.wait(entries.sublist(i, end).map((entry) async {
        try {
          final error =
              await _uploadPendingEntry(companyCode, entry.key, entry.value);
          if (error != null) {
            errors.add(error);
          } else if (entry.value['action'] == 'delete') {
            deleted++;
          } else {
            saved++;
          }
        } catch (e) {
          errors.add('${entry.key}: $e');
        } finally {
          _uploadingKeys.remove(entry.key.toString());
          done++;
          onProgress?.call(done, entries.length);
        }
      }));
    }
    return {
      'success': errors.isEmpty,
      'saved_count': saved,
      'deleted_count': deleted,
      'errors': errors
    };
});
}

  Future<void> _safeDeletePending(
      dynamic key, Map<String, dynamic> uploadedMap) async {
return CachePartitions.run(() async {

    final current = _pendingBox.get(key);
    // Include ownership and holds, not only action/data. A revocation applied
    // during the request must not be erased by its acknowledgement.
    if (current is Map &&
        _mayUploadPending(current) &&
        jsonEncode(current) == jsonEncode(uploadedMap)) {
      await _pendingBox.delete(key);
    }
});
}

  /// ⭐ هل المفتاح ده تحت الرفع؟
  bool isUploadingKey(String companyCode, String employeeCode, String date) {
    return _uploadingKeys.contains(
      _pendingKey(companyCode, employeeCode, date),
    );
  }

  /// ⭐ جديد: إعادة رفع كل pending للشركة (يُستخدم عند WebSocket reconnect)
  ///
  /// لو المستخدم قفل التطبيق أثناء الحفظ، الـ pending بيفضل في Hive.
  /// الدالة دي بتحاول ترفعه في المرة الجاية.
  Future<void> retryAllPending(String companyCode) async {
return CachePartitions.run(() async {

    final prefix = '${companyCode}_';
    final byEmployee = <String, Set<String>>{};

    for (final key in _pendingBox.keys) {
      final keyStr = key.toString();
      if (!keyStr.startsWith(prefix)) continue;

      // key = "{company}_{employee}_{date}"
      final withoutCompany = keyStr.substring(prefix.length);
      final lastUnderscore = withoutCompany.lastIndexOf('_');
      if (lastUnderscore <= 0) continue;
      final employee = withoutCompany.substring(0, lastUnderscore);
      if (employee.isEmpty) continue;

      byEmployee.putIfAbsent(employee, () => {}).add(keyStr);
    }

    for (final emp in byEmployee.keys) {
      try {
        await commitPending(companyCode: companyCode, employeeCode: emp);
        print('✅ [retry] pending saved for employee $emp');
      } catch (e) {
        print('❌ [retry] failed for employee $emp: $e');
      }
    }
});
}

  // ============================================================
  // ================= 3. VACATIONS ============================
  // ============================================================

  String _vacationKey(String companyCode) => '${companyCode}_hr_vacations';

  /// جلب الإجازات (لفترة أو لكل التاريخ)
  Future<List<HRVacationModel>> getVacations({
    required String companyCode,
    String? fromDate,
    String? toDate,
    String? branchCode,
    String? employeeCode,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final localKey = _vacationKey(companyCode);

    // ---------- 1) Hive ----------
    if (_codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        final models = raw
            .whereType<Map>()
            .map((e) => HRVacationModel.fromMap(
                  Map<String, dynamic>.from(e),
                ))
            .where((v) => !v.isDeleted)
            .where((v) => fromDate == null || v.date.compareTo(fromDate) >= 0)
            .where((v) => toDate == null || v.date.compareTo(toDate) <= 0)
            .where((v) => v.appliesTo(
                  targetBranch: branchCode,
                  targetEmployee: employeeCode,
                ))
            .toList();

        // إزالة التكرار
        final unique = <String, HRVacationModel>{};
        for (final m in models) {
          unique['${m.id}_${m.date}_${m.branchCode}_${m.employeeCode}'] = m;
        }
        return unique.values.toList();
      }
    }

    // ---------- 2) السيرفر ----------
    try {
      final url = Uri.parse("$baseUrl/hr/vacations/list/$companyCode").replace(
        queryParameters: {
          if (fromDate != null) 'from_date': fromDate,
          if (toDate != null) 'to_date': toDate,
          if (branchCode != null) 'branch_code': branchCode,
          if (employeeCode != null) 'employee_code': employeeCode,
        },
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        print("❌ [vacations list] HTTP ${response.statusCode}");
        return [];
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      // نستخدم put مباشر (مش merge) عشان ده fetch كامل
      // بنستبدل القائمة المحلية بالكامل
      readScope.check();
      await _codingBox.put(localKey, list);
      readScope.check();

      return list.map((e) => HRVacationModel.fromMap(e)).toList();
    } catch (e) {
      print("❌ [vacations list] $e");
      return [];
    }
});
}

  /// حفظ / تحديث إجازة
  Future<Map<String, dynamic>> saveVacation({
    required HRVacationModel model,
  }) async {
return CachePartitions.run(() async {

    final cacheScope = await ReadAuthorizationSnapshot.capture();
    try {
      cacheScope.check();
      final response = await AuthHttp.post(
        Uri.parse("$baseUrl/hr/vacations/save"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(model.toMap()),
      );

      if (!_ok(response.statusCode)) {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final Map<String, dynamic> result = jsonDecode(response.body);
      if (!cacheScope.isCurrent)
        return {
          'success': true,
          'id': result['id'],
          'action': result['action'],
          'scope_changed': true
        };
      final localKey = _vacationKey(model.companyCode);

      // تحديث Hive
      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      final newItem = model.toMap();
      newItem['is_deleted'] = false;
      if (result['id'] != null) {
        newItem['id'] = result['id'];
      }

      // إزالة أي عنصر بنفس id
      if (result['id'] != null) {
        currentList.removeWhere(
          (e) => e['id']?.toString() == result['id'].toString(),
        );
      }

      // إزالة أي عنصر بنفس (date + branch_code + employee_code)
      currentList.removeWhere(
        (e) =>
            e['date']?.toString() == model.date &&
            (e['branch_code']?.toString() ?? '') == (model.branchCode ?? '') &&
            (e['employee_code']?.toString() ?? '') ==
                (model.employeeCode ?? ''),
      );

      currentList.add(newItem);

      await _codingBox.put(localKey, currentList);

      return {
        'success': true,
        'id': result['id'],
        'action': result['action'],
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
});
}

  /// حذف إجازة
  Future<bool> deleteVacation({
    required String companyCode,
    required int vacationId,
  }) async {
return CachePartitions.run(() async {

    try {
      final response = await AuthHttp.delete(
        Uri.parse(
          "$baseUrl/hr/vacations/delete/$companyCode/$vacationId",
        ),
      );

      if (!_ok(response.statusCode)) {
        print("❌ [vacation delete] HTTP ${response.statusCode}");
        return false;
      }

      final localKey = _vacationKey(companyCode);
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          final safeList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where(
                (e) =>
                    e['id']?.toString() != vacationId.toString() &&
                    e['is_deleted'] != true,
              )
              .toList();

          if (safeList.isEmpty) {
            await _codingBox.delete(localKey);
          } else {
            await _codingBox.put(localKey, safeList);
          }
        }
      }

      return true;
    } catch (e) {
      print("❌ [vacation delete] $e");
      return false;
    }
});
}

  /// Full sync للإجازات
  ///
  /// الإجازات عادةً قليلة (10-30 سجل/سنة) → ناخد كل التاريخ
  /// في طلب واحد (مش محتاجين from_date/to_date).
  Future<void> fetchAllVacations(String companyCode) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    print("📥 [vacations] FULL SYNC — $companyCode");

    try {
      final url = Uri.parse("$baseUrl/hr/vacations/list/$companyCode");

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception('فشل تحميل الإجازات. HTTP ${response.statusCode}');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      readScope.check();
      await _codingBox.put(_vacationKey(companyCode), list);
      readScope.check();

      print("✅ [vacations] FULL SYNC: ${list.length} سجل");
    } catch (e) {
      print("❌ [vacations] FULL SYNC فشل: $e");
      rethrow;
    }
});
}

  /// Delta sync للإجازات
  Future<void> syncVacationsChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    readScope.check();
    final lastSyncKey = 'last_sync_hr_vacations_$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      await fetchAllVacations(companyCode);
      readScope.check();
      await prefs.setString(
        lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );
      readScope.check();
      return;
    }

    print("📡 [vacations] INCREMENTAL منذ $lastSyncValue");

    try {
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final url = Uri.parse("$baseUrl/hr/vacations/changes/$companyCode")
          .replace(queryParameters: {'since': effectiveSince});

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception('فشل مزامنة الإجازات. HTTP ${response.statusCode}');
      }

      final List<dynamic> changes = jsonDecode(response.body);

      if (changes.isEmpty) {
        print("⏭️ [vacations] لا يوجد تغييرات");
        readScope.check();
        await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
        readScope.check();
        return;
      }

      final localKey = _vacationKey(companyCode);

      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      for (final item in changes) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final action = map['action']?.toString() ??
            (map['is_deleted'] == true ? 'delete' : 'update');

        final id = map['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        currentList.removeWhere(
          (e) => e['id']?.toString() == id,
        );

        if (action == 'delete' || map['is_deleted'] == true) continue;

        map.remove('action');
        map['is_deleted'] = false;
        currentList.add(map);
      }

      if (currentList.isEmpty) {
        await _codingBox.delete(localKey);
        readScope.check();
      } else {
        readScope.check();
        await _codingBox.put(localKey, currentList);
        readScope.check();
      }

      readScope.check();
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      readScope.check();
      print("✅ [vacations] تم تحديث ${changes.length} تغيير");
    } catch (e) {
      print("❌ [vacations] INCREMENTAL فشل: $e");
      rethrow;
    }
});
}

  // ============================================================
  // ================= 4. ADJUSTMENTS ==========================
  // ============================================================

  String _adjustmentsKey(String companyCode) => '${companyCode}_hr_adjustments';

  /// جلب تسويات شهر معين (كل الموظفين)
  Future<List<HRAdjustmentModel>> getAdjustmentsForMonth({
    required String companyCode,
    required String month,
    String? branchCode,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final localKey = _adjustmentsKey(companyCode);

    // ---------- 1) Hive ----------
    final coverageKind = 'adjustments_branch_${branchCode ?? '*'}';
    final covered = _covered(coverageKind, companyCode, '*', month) || _covered('adjustments', companyCode, '*', month);
    if (covered && _codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        final models = raw
            .whereType<Map>()
            .map((e) => HRAdjustmentModel.fromMap(
                  Map<String, dynamic>.from(e),
                ))
            .where((a) => !a.isDeleted)
            .where((a) => a.month == month)
            .where((a) => branchCode == null || a.branchCode == branchCode)
            .toList();

        // إزالة التكرار
        final unique = <String, HRAdjustmentModel>{};
        for (final m in models) {
          unique['${m.id}_${m.employeeCode}_${m.type}_${m.amount}'] = m;
        }
        return unique.values.toList();
      }
    }

    // ---------- 2) السيرفر ----------
    try {
      final url =
          Uri.parse("$baseUrl/hr/adjustments/list/$companyCode").replace(
        queryParameters: {
          'month': month,
          if (branchCode != null) 'branch_code': branchCode,
        },
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        print("❌ [adjustments list] HTTP ${response.statusCode}");
        throw StateError('تعذر تحميل شهر التسويات');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      readScope.check();
      await _mergeIntoHive(
        localKey,
        list,
        uniqueKeyBuilder: (m) =>
            m['id']?.toString() ??
            '${m['employee_code']}_${m['month']}_${m['type']}',
      );
      readScope.check();

      await _markCovered(coverageKind, companyCode, '*', month);
      readScope.check();
      return list.map((e) => HRAdjustmentModel.fromMap(e)).toList();
    } catch (e) {
      print("❌ [adjustments list] $e");
      rethrow;
    }
});
}

  /// جلب تسويات موظف في شهر معين
  Future<List<HRAdjustmentModel>> getEmployeeAdjustments({
    required String companyCode,
    required String employeeCode,
    required String month,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final localKey = _adjustmentsKey(companyCode);

    // ---------- 1) Hive ----------
    if (_covered('adjustments', companyCode, employeeCode, month) && _codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        final models = raw
            .whereType<Map>()
            .map((e) => HRAdjustmentModel.fromMap(
                  Map<String, dynamic>.from(e),
                ))
            .where((a) =>
                !a.isDeleted &&
                a.employeeCode == employeeCode &&
                a.month == month)
            .toList();

        // إزالة التكرار
        final unique = <String, HRAdjustmentModel>{};
        for (final m in models) {
          unique['${m.id}_${m.type}'] = m;
        }
        return unique.values.toList();
      }
    }

    // ---------- 2) السيرفر ----------
    try {
      final url = Uri.parse(
        "$baseUrl/hr/adjustments/employee/$companyCode/$employeeCode",
      ).replace(
        queryParameters: {'month': month},
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        print("❌ [employee adjustments] HTTP ${response.statusCode}");
        throw StateError('تعذر تحميل تسويات الشهر');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        list.add(map);
      }

      readScope.check();
      final prior = _codingBox.get(localKey);
      final kept = prior is List ? prior.whereType<Map>().where((row) =>
          row['employee_code'] != employeeCode || row['month'] != month).toList() : <Map>[];
      await _codingBox.put(localKey, [...kept, ...list]);
      readScope.check();

      readScope.check();
      await _markCovered('adjustments', companyCode, employeeCode, month);
      readScope.check();
      return list.map((e) => HRAdjustmentModel.fromMap(e)).toList();
    } catch (e) {
      print("❌ [employee adjustments] $e");
      rethrow;
    }
});
}

  /// حفظ تسوية (خصم/مكافأة/سلفة)
  Future<Map<String, dynamic>> saveAdjustment({
    required HRAdjustmentModel model,
  }) async {
return CachePartitions.run(() async {

    final cacheScope = await ReadAuthorizationSnapshot.capture();
    try {
      cacheScope.check();
      final response = await AuthHttp.post(
        Uri.parse("$baseUrl/hr/adjustments/save"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(model.toMap()),
      );

      if (!_ok(response.statusCode)) {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final Map<String, dynamic> result = jsonDecode(response.body);
      if (!cacheScope.isCurrent)
        return {
          'success': true,
          'id': result['id'],
          'action': result['action'],
          'scope_changed': true
        };
      final localKey = _adjustmentsKey(model.companyCode);

      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      final newItem = model.toMap();
      newItem['is_deleted'] = false;
      if (result['id'] != null) {
        newItem['id'] = result['id'];
      }

      if (result['id'] != null) {
        currentList.removeWhere(
          (e) => e['id']?.toString() == result['id'].toString(),
        );
      }

      currentList.add(newItem);

      await _codingBox.put(localKey, currentList);

      return {
        'success': true,
        'id': result['id'],
        'action': result['action'],
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
});
}

  /// حذف تسوية
  Future<bool> deleteAdjustment({
    required String companyCode,
    required int adjustmentId,
  }) async {
return CachePartitions.run(() async {

    try {
      final response = await AuthHttp.delete(
        Uri.parse(
          "$baseUrl/hr/adjustments/delete/$companyCode/$adjustmentId",
        ),
      );

      if (!_ok(response.statusCode)) {
        print("❌ [adjustment delete] HTTP ${response.statusCode}");
        return false;
      }

      final localKey = _adjustmentsKey(companyCode);
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          final safeList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where(
                (e) =>
                    e['id']?.toString() != adjustmentId.toString() &&
                    e['is_deleted'] != true,
              )
              .toList();

          if (safeList.isEmpty) {
            await _codingBox.delete(localKey);
          } else {
            await _codingBox.put(localKey, safeList);
          }
        }
      }

      return true;
    } catch (e) {
      print("❌ [adjustment delete] $e");
      return false;
    }
});
}

  /// Full sync للتسويات — آخر 6 شهور
  ///
  /// ملاحظة: الباك بيحتاج month إجباري، فبنلف على 6 شهور.
  /// 6 طلبات بس (مش كثيرة) — تتم مرة واحدة لكل جهاز.
  Future<void> fetchAllAdjustments(String companyCode) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    print("📥 [adjustments] FULL SYNC (آخر 6 شهور) — $companyCode");

    try {
      final now = DateTime.now();
      var failed = false;
      final completed = <String, List<Map<String, dynamic>>>{};

      // نلف على 6 شهور (الحالي + 5 قبله)
      for (int i = 0; i < 6; i++) {
        final monthDate = DateTime(now.year, now.month - i, 1);
        final monthStr = HRConstants.monthToStr(monthDate);

        if (_covered('adjustments', companyCode, '*', monthStr)) continue;
        try {
          final allItems = <Map<String, dynamic>>[];
          final url = Uri.parse(
            "$baseUrl/hr/adjustments/list/$companyCode",
          ).replace(
            queryParameters: {'month': monthStr},
          );

          readScope.check();
          final response = await AuthHttp.get(url);
          readScope.check();

          if (!_ok(response.statusCode)) {
            print("⚠️ [adjustments] $monthStr: HTTP ${response.statusCode}");
            failed = true;
            continue;
          }

          final List<dynamic> data = jsonDecode(response.body);
          for (final item in data) {
            if (item is! Map) continue;
            final map = Map<String, dynamic>.from(item);
            if (map['is_deleted'] == true) continue;
            allItems.add(map);
          }
          completed[monthStr] = allItems;
        } catch (e) {
          if (e is ReadAuthorizationChanged) rethrow;
          print("⚠️ [adjustments] $monthStr: $e");
          failed = true;
        }
      }

      readScope.check();
      for (final entry in completed.entries) {
        readScope.check();
        final old = _codingBox.get(_adjustmentsKey(companyCode));
        final kept = old is List ? old.whereType<Map>().where((row) =>
            row['month'] != entry.key).toList() : <Map>[];
        await _codingBox.put(_adjustmentsKey(companyCode), [...kept, ...entry.value]);
        readScope.check();
        await _markCovered('adjustments', companyCode, '*', entry.key);
        readScope.check();
      }
      if (failed) throw StateError('لم يكتمل تحميل شهور التسويات. ستتم إعادة المحاولة');
    } catch (e) {
      print("❌ [adjustments] FULL SYNC فشل: $e");
      rethrow;
    }
});
}

  /// Delta sync للتسويات
  Future<void> syncAdjustmentsChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    readScope.check();
    final lastSyncKey = 'last_sync_hr_adjustments_$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      await fetchAllAdjustments(companyCode);
      readScope.check();
      await prefs.setString(
        lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );
      readScope.check();
      return;
    }

    print("📡 [adjustments] INCREMENTAL منذ $lastSyncValue");

    try {
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final url = Uri.parse("$baseUrl/hr/adjustments/changes/$companyCode")
          .replace(queryParameters: {'since': effectiveSince});

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception('فشل مزامنة التسويات. HTTP ${response.statusCode}');
      }

      final List<dynamic> changes = jsonDecode(response.body);

      if (changes.isEmpty) {
        print("⏭️ [adjustments] لا يوجد تغييرات");
        readScope.check();
        await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
        readScope.check();
        return;
      }

      final localKey = _adjustmentsKey(companyCode);

      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      for (final item in changes) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final action = map['action']?.toString() ??
            (map['is_deleted'] == true ? 'delete' : 'update');

        final id = map['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        currentList.removeWhere(
          (e) => e['id']?.toString() == id,
        );

        if (action == 'delete' || map['is_deleted'] == true) continue;

        map.remove('action');
        map['is_deleted'] = false;
        currentList.add(map);
      }

      if (currentList.isEmpty) {
        await _codingBox.delete(localKey);
        readScope.check();
      } else {
        readScope.check();
        await _codingBox.put(localKey, currentList);
        readScope.check();
      }

      readScope.check();
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      readScope.check();
      print("✅ [adjustments] تم تحديث ${changes.length} تغيير");
    } catch (e) {
      print("❌ [adjustments] INCREMENTAL فشل: $e");
      rethrow;
    }
});
}

  // ============================================================
  // ============ 5. EMPLOYEE SETTINGS =========================
  // ============================================================
  //
  // إعدادات الموظف (مواعيد العمل + قواعد التأخير + يوم الراحة)
  //
  // ⚠️ مهم:
  // - الـ defaults بتجي من HRConstants.defaultDelayRules (3.0/1.0)
  // - Delta sync زي باقي الوحدات (كان ناقص في النسخة القديمة)
  // - WebSocket يبث hr_employee_settings لما تتغير

  String _employeeSettingsKey(String companyCode) =>
      '${companyCode}_hr_employee_settings';

  Future<HREmployeeSettingsModel> getEmployeeSettings({
    required String companyCode,
    required String employeeCode,
  }) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final localKey = _employeeSettingsKey(companyCode);

    // ---------- 1) Hive ----------
    if (_codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          if (map['employee_code']?.toString() == employeeCode) {
            return HREmployeeSettingsModel.fromMap(map);
          }
        }
      }
    }

    // ---------- 2) Server fallback ----------
    try {
      readScope.check();
      final response = await AuthHttp.get(
        Uri.parse(
          "$baseUrl/hr/employee-settings/$companyCode/$employeeCode",
        ),
      );
      readScope.check();

      if (_ok(response.statusCode)) {
        final data = jsonDecode(response.body);
        final model = HREmployeeSettingsModel.fromMap(
          Map<String, dynamic>.from(data),
        );
        await _saveToSettingsHive(localKey, model);
        readScope.check();
        return model;
      }
    } catch (e) {
      print("❌ [employee-settings get] $e");
    }

    return HREmployeeSettingsModel(
      companyCode: companyCode,
      employeeCode: employeeCode,
    );
});
}

  /// حفظ إعدادات الموظف
  Future<Map<String, dynamic>> saveEmployeeSettings({
    required HREmployeeSettingsModel model,
  }) async {
return CachePartitions.run(() async {

    final cacheScope = await ReadAuthorizationSnapshot.capture();
    try {
      cacheScope.check();
      final response = await AuthHttp.post(
        Uri.parse("$baseUrl/hr/employee-settings/save"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(model.toMap()),
      );

      if (!_ok(response.statusCode)) {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
        };
      }

      final result = jsonDecode(response.body);
      if (!cacheScope.isCurrent)
        return {
          'success': true,
          'id': result['id'],
          'action': result['action'],
          'scope_changed': true
        };

      final localKey = _employeeSettingsKey(model.companyCode);
      final updated = model.copyWith(id: result['id']);
      await _saveToSettingsHive(localKey, updated);

      return {
        'success': true,
        'id': result['id'],
        'action': result['action'],
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
});
}

  /// Full sync لإعدادات كل الموظفين
  ///
  /// ⚠️ ملاحظة:
  /// الباك مفيهوش endpoint لجلب "كل الإعدادات" مرة واحدة.
  /// فبنستخدم delta sync من الصفر:
  ///   GET /hr/employee-settings/changes?since=1970-01-01
  ///
  /// ده بيرجع كل السجلات اللي اتعدلت من 1970 (يعني كلهم).
  Future<void> fetchAllEmployeeSettings(String companyCode) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    print("📥 [employee-settings] FULL SYNC — $companyCode");

    try {
      // since = 1970 → يجيب كل التغييرات (يعني كل السجلات)
      final url = Uri.parse(
        "$baseUrl/hr/employee-settings/changes/$companyCode",
      ).replace(
        queryParameters: {'since': '1970-01-01T00:00:00Z'},
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception(
          'فشل تحميل إعدادات الموظفين. HTTP ${response.statusCode}',
        );
      }

      final List<dynamic> data = jsonDecode(response.body);
      final list = <Map<String, dynamic>>[];

      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        list.add(map);
      }

      readScope.check();
      await _codingBox.put(_employeeSettingsKey(companyCode), list);
      readScope.check();

      print("✅ [employee-settings] FULL SYNC: ${list.length} سجل");
    } catch (e) {
      print("❌ [employee-settings] FULL SYNC فشل: $e");
      rethrow;
    }
});
}

  /// Delta sync لإعدادات الموظفين
  ///
  /// ⚠️ جديد: كان ناقص في النسخة القديمة.
  /// دلوقتي لما HR Admin يعدل delay_rules على جهاز A،
  /// جهاز B بياخد التحديث تلقائيًا.
  Future<void> syncEmployeeSettingsChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    readScope.check();
    final lastSyncKey = 'last_sync_hr_employee_settings_$companyCode';
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    // جهاز جديد → full sync
    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      await fetchAllEmployeeSettings(companyCode);
      readScope.check();
      await prefs.setString(
        lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );
      readScope.check();
      return;
    }

    print("📡 [employee-settings] INCREMENTAL منذ $lastSyncValue");

    try {
      final syncStartedAt = DateTime.now().toUtc();
      final sinceDt = DateTime.parse(lastSyncValue).toUtc();
      final effectiveSince = sinceDt.toIso8601String();

      final url = Uri.parse(
        "$baseUrl/hr/employee-settings/changes/$companyCode",
      ).replace(
        queryParameters: {'since': effectiveSince},
      );

      readScope.check();
      final response = await AuthHttp.get(url);
      readScope.check();

      if (!_ok(response.statusCode)) {
        throw Exception(
          'فشل مزامنة الإعدادات. HTTP ${response.statusCode}',
        );
      }

      final List<dynamic> changes = jsonDecode(response.body);

      if (changes.isEmpty) {
        print("⏭️ [employee-settings] لا يوجد تغييرات");
        readScope.check();
        await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
        readScope.check();
        return;
      }

      final localKey = _employeeSettingsKey(companyCode);

      List<Map<String, dynamic>> currentList = [];
      if (_codingBox.containsKey(localKey)) {
        final raw = _codingBox.get(localKey);
        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }

      for (final item in changes) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final empCode = map['employee_code']?.toString() ?? '';
        if (empCode.isEmpty) continue;

        // HREmployeeSettings مفيش is_deleted — كلها updates/inserts
        currentList.removeWhere(
          (e) => e['employee_code']?.toString() == empCode,
        );

        map.remove('action');
        currentList.add(map);
      }

      if (currentList.isEmpty) {
        await _codingBox.delete(localKey);
        readScope.check();
      } else {
        readScope.check();
        await _codingBox.put(localKey, currentList);
        readScope.check();
      }

      readScope.check();
      await prefs.setString(lastSyncKey, syncStartedAt.toIso8601String());
      readScope.check();
      print("✅ [employee-settings] تم تحديث ${changes.length} تغيير");
    } catch (e) {
      print("❌ [employee-settings] INCREMENTAL فشل: $e");
      rethrow;
    }
});
}

  /// Helper: حفظ إعدادات موظف في Hive (يستبدل السجل بنفس employee_code)
  Future<void> _saveToSettingsHive(
    String localKey,
    HREmployeeSettingsModel model,
  ) async {
return CachePartitions.run(() async {

    List<Map<String, dynamic>> currentList = [];

    if (_codingBox.containsKey(localKey)) {
      final raw = _codingBox.get(localKey);
      if (raw is List) {
        currentList = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }

    currentList.removeWhere(
      (e) => e['employee_code']?.toString() == model.employeeCode,
    );

    currentList.add(model.toMap());

    await _codingBox.put(localKey, currentList);
});
}

  // ============================================================
  // ============ 6. SYNC ALL — 4 submodules parallel ===========
  // ============================================================
  //
  // ⚡ 4 submodules parallel (بدل 8s sequential → 2-3s)
  //
  // كل submodule:
  //   - بيمسك أخطاءه بنفسه (try/catch)
  //   - بيكتب مفاتيح مختلفة في Hive → مفيش race

  Future<Map<String, dynamic>> syncAll(String companyCode) async {
return CachePartitions.run(() async {

    final readScope = await ReadAuthorizationSnapshot.capture();
    final results = <String, dynamic>{};

    final prefs = await CachePartitions.preferences();
    readScope.check();
    final syncStartedAt = DateTime.now().toUtc().toIso8601String();

    Future<void> syncAttendance() async {
return CachePartitions.run(() async {

      if (!SyncReadAccess.allows('attendance')) {
        results['attendance'] = 'skipped';
        return;
      }
      try {
        final key = 'last_sync_hr_attendance_$companyCode';
        final lastSync = prefs.getString(key);

        if (lastSync == null) {
          await fetchAllAttendance(companyCode);
          readScope.check();
          await prefs.setString(key, syncStartedAt);
          readScope.check();
        } else {
          await syncChangesFromServer(companyCode, lastSync);
          readScope.check();
        }
        results['attendance'] = 'ok';
        print('  ✅ [HR] attendance');
      } catch (e) {
        results['attendance'] = 'error: $e';
        print('  ❌ [HR] attendance: $e');
      }

});
}

    Future<void> syncVacations() async {
return CachePartitions.run(() async {

      if (!SyncReadAccess.allows('vacations')) {
        results['vacations'] = 'skipped';
        return;
      }
      try {
        final key = 'last_sync_hr_vacations_$companyCode';
        final lastSync = prefs.getString(key);

        if (lastSync == null) {
          await fetchAllVacations(companyCode);
          readScope.check();
          await prefs.setString(key, syncStartedAt);
          readScope.check();
        } else {
          await syncVacationsChangesFromServer(companyCode, lastSync);
          readScope.check();
        }
        results['vacations'] = 'ok';
        print('  ✅ [HR] vacations');
      } catch (e) {
        results['vacations'] = 'error: $e';
        print('  ❌ [HR] vacations: $e');
      }

});
}

    Future<void> syncAdjustments() async {
return CachePartitions.run(() async {

      if (!SyncReadAccess.allows('adjustments')) {
        results['adjustments'] = 'skipped';
        return;
      }
      try {
        final key = 'last_sync_hr_adjustments_$companyCode';
        final lastSync = prefs.getString(key);

        if (lastSync == null) {
          await fetchAllAdjustments(companyCode);
          readScope.check();
          await prefs.setString(key, syncStartedAt);
          readScope.check();
        } else {
          await syncAdjustmentsChangesFromServer(companyCode, lastSync);
          readScope.check();
        }
        results['adjustments'] = 'ok';
        print('  ✅ [HR] adjustments');
      } catch (e) {
        results['adjustments'] = 'error: $e';
        print('  ❌ [HR] adjustments: $e');
      }

});
}

    Future<void> syncSettings() async {
return CachePartitions.run(() async {

      if (!SyncReadAccess.allows('employee_settings')) {
        results['employee_settings'] = 'skipped';
        return;
      }
      try {
        final key = 'last_sync_hr_employee_settings_$companyCode';
        final lastSync = prefs.getString(key);

        if (lastSync == null) {
          await fetchAllEmployeeSettings(companyCode);
          readScope.check();
          await prefs.setString(key, syncStartedAt);
          readScope.check();
        } else {
          await syncEmployeeSettingsChangesFromServer(companyCode, lastSync);
          readScope.check();
        }
        results['employee_settings'] = 'ok';
        print('  ✅ [HR] settings');
      } catch (e) {
        results['employee_settings'] = 'error: $e';
        print('  ❌ [HR] settings: $e');
      }

});
}

    // ⚡ الأربعة في نفس الوقت
    await Future.wait([
      syncAttendance(),
      syncVacations(),
      syncAdjustments(),
      syncSettings(),
    ]);
    readScope.check();

    return results;
});
}
}

// ============================================================
// نهاية ملف hr_service.dart
//
// الأقسام:
// 1. Setup + Helpers
// 2. Attendance (6 methods) + Pending Queue (9 methods)
// 3. Vacations (6 methods)
// 4. Adjustments (6 methods)
// 5. Employee Settings (4 methods)
// 6. syncAll (convenience للـ main.dart)
//
// الملف بيستخدم:
// - Hive: _codingBox (data) + _pendingBox (pending operations)
// - SharedPreferences: last_sync keys
// - AuthHttp: HTTP client مع Firebase token
// - HRConstants: delay rules defaults + date helpers
//
// ⚠️ قبل الاستخدام:
// - لازم CachePartitions.openBox('hr_pending_box') في main.dart
// - لازم CachePartitions.openBox('coding_box') في main.dart
// ============================================================
