// frontend/lib/services/company_service.dart
import 'cache_partitions.dart';
import 'admin_cache_events.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'package:flutter/foundation.dart';

// خدمة الشركات: تُدار عبر التخزين المحلي والمزامنة
/// خدمة الشركات — تدار بالكامل عبر Hive + Sync
///
/// - Super Admin فقط يستخدمها
/// - تُحفظ الشركات في companies_box
/// - العمليات (add/edit/delete/toggle) تُرسل للـ API ثم تُحدّث Hive
class CompanyService {
  static final CompanyService _instance = CompanyService._();

  // يعيد النسخة الوحيدة من الخدمة
  factory CompanyService() => _instance;

  // منشئ خاص يربط مستمع تغيّر دليل الشركات
  CompanyService._() {
    AdminCacheEvents.companies.addListener(() {
      _verifiedScope = null;
      _revision++;
    });
    ReadAuthorizationEpoch.changes.addListener(() {
      if (_verifiedScope?.isCurrent != true) {
        _verifiedScope = null;
        _revision++;
        if (CachePartitions.isBoxOpen(_boxName)) _box.delete(_allKey);
      }
    });
  }
  ReadAuthorizationSnapshot? _verifiedScope;
  int _revision = 0;

  // يحدد هل توجد لقطة صالحة للشركات
  bool get hasSnapshot =>
      PermissionsService().isLoaded &&
      PermissionsService().isSuperAdmin &&
      (_verifiedScope?.isCurrent ?? false);

  Future<void>? _ensureWork;
  int? _ensureRevision;

  // يضمن تحميل الشركات في الذاكرة المؤقتة
  Future<void> ensureCached() {
    if (hasSnapshot) return Future<void>.value();
    if (_ensureWork != null && _ensureRevision == _revision)
      return _ensureWork!;
    _ensureRevision = _revision;
    final work = fetchAllCompanies();
    _ensureWork = work;
    return work.whenComplete(() {
      if (identical(_ensureWork, work)) _ensureWork = null;
    });
  }

  final String baseUrl = ApiConstants.baseUrl;
  static const String _boxName = 'companies_box';
  static const String _allKey = 'all_companies';

  // يعيد صندوق الشركات المحلي
  Box get _box => CachePartitions.box(_boxName);

  // ============================================================
  // 1. قراءة الشركات من Hive
  // ============================================================

  // يعيد الشركات من التخزين المحلي
  List<Map<String, dynamic>> getCompaniesFromHive() {
    if (!hasSnapshot) return [];
    try {
      final raw = _box.get(_allKey);
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      print('❌ [CompanyService] قراءة من Hive فشلت: $e');
    }
    return [];
  }

  // يوفر مستمعًا لتحديث الواجهة عند تغيّر الشركات
  /// ValueListenableBuilder للـ UI
  ValueListenable<Box> get companiesListenable => _box.listenable();

  // ============================================================
  // 2. جلب كل الشركات من السيرفر (Full Sync)
  // ============================================================

  // يجلب كل الشركات من الخادم ويخزنها محليًا
  Future<void> fetchAllCompanies({String adminJobCode = '99'}) async {
    return CachePartitions.run(() async {
      if (!PermissionsService().isSuperAdmin)
        throw StateError('Company directory unavailable');
      final scope = await ReadAuthorizationSnapshot.capture();
      final revision = _revision;
      print('📥 [Companies] بدء FULL SYNC...');

      try {
        final response = await AuthHttp.get(
          Uri.parse('$baseUrl/auth/companies/all?admin_job_code=$adminJobCode'),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'فشل تحميل الشركات. HTTP ${response.statusCode}',
          );
        }

        final List<dynamic> data = jsonDecode(response.body);

        final List<Map<String, dynamic>> companies = [];
        for (final item in data) {
          if (item is! Map) continue;
          companies.add(Map<String, dynamic>.from(item));
        }

        // ترتيب حسب الكود
        companies.sort((a, b) {
          final aCode = a['code']?.toString() ?? '';
          final bCode = b['code']?.toString() ?? '';
          return aCode.compareTo(bCode);
        });

        scope.check();
        if (!PermissionsService().isSuperAdmin || revision != _revision)
          throw const ReadAuthorizationChanged();
        _verifiedScope = scope;
        await _box.put(_allKey, companies);
        if (!scope.isCurrent || revision != _revision) _verifiedScope = null;

        print('✅ [Companies] تم حفظ ${companies.length} شركة في Hive');
      } catch (e) {
        print('❌ [Companies] فشل FULL SYNC: $e');
        rethrow;
      }
    });
  }

  // ============================================================
  // 3. العمليات (Add/Edit/Delete/Toggle)
  // ============================================================

  // يضيف شركة
  Future<void> addCompany({
    required String code,
    required String name,
    String adminJobCode = '99',
  }) async {
    return CachePartitions.run(() async {
      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/companies/add?admin_job_code=$adminJobCode'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'code': code.trim(), 'name': name.trim()}),
      );

      if (response.statusCode != 200) {
        final detail =
            jsonDecode(response.body)['detail'] ?? 'فشل إضافة الشركة';
        throw Exception(detail);
      }

      // بعد الإضافة، حدّث Hive
      await fetchAllCompanies(adminJobCode: adminJobCode);
    });
  }

  // يعدّل بيانات شركة
  Future<void> updateCompany({
    required String oldCode,
    required String newCode,
    required String newName,
    String adminJobCode = '99',
  }) async {
    return CachePartitions.run(() async {
      final response = await AuthHttp.put(
        Uri.parse('$baseUrl/auth/companies/update'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'old_code': oldCode,
          'new_code': newCode,
          'new_name': newName,
          'admin_job_code': adminJobCode,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        final detail =
            jsonDecode(response.body)['detail'] ?? 'فشل تحديث الشركة';
        throw Exception(detail);
      }

      await fetchAllCompanies(adminJobCode: adminJobCode);
    });
  }

  // يحذف شركة
  Future<void> deleteCompany({
    required String code,
    String adminJobCode = '99',
  }) async {
    return CachePartitions.run(() async {
      final response = await AuthHttp.delete(
        Uri.parse(
          '$baseUrl/auth/companies/delete/$code?admin_job_code=$adminJobCode',
        ),
      );

      if (response.statusCode != 200) {
        final detail = jsonDecode(response.body)['detail'] ?? 'فشل حذف الشركة';
        throw Exception(detail);
      }

      await fetchAllCompanies(adminJobCode: adminJobCode);
    });
  }

  // يبدّل حالة تفعيل الشركة
  Future<void> toggleCompanyStatus({
    required String code,
    required bool isActive,
    String adminJobCode = '99',
  }) async {
    return CachePartitions.run(() async {
      final response = await AuthHttp.post(
        Uri.parse('$baseUrl/auth/companies/toggle'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'is_active': isActive,
          'admin_job_code': adminJobCode,
        }),
      );

      if (response.statusCode != 200) {
        final detail =
            jsonDecode(response.body)['detail'] ?? 'فشل تغيير حالة الشركة';
        throw Exception(detail);
      }

      await fetchAllCompanies(adminJobCode: adminJobCode);
    });
  }

  // ============================================================
  // 4. مسح الـ Cache (عند logout)
  // ============================================================

  // يمسح الذاكرة المؤقتة للشركات
  Future<void> clearCache() async {
    return CachePartitions.run(() async {
      _verifiedScope = null;
      _revision++;
      await _box.delete(_allKey);
    });
  }
}
