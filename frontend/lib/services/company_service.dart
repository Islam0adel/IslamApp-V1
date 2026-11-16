// lib/services/company_service.dart

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'package:flutter/foundation.dart';

/// خدمة الشركات — تدار بالكامل عبر Hive + Sync
///
/// - Super Admin فقط يستخدمها
/// - تُحفظ الشركات في companies_box
/// - العمليات (add/edit/delete/toggle) تُرسل للـ API ثم تُحدّث Hive
class CompanyService {
  static final CompanyService _instance = CompanyService._();
  factory CompanyService() => _instance;
  CompanyService._();

  final String baseUrl = ApiConstants.baseUrl;
  static const String _boxName = 'companies_box';
  static const String _allKey = 'all_companies';

  Box get _box => Hive.box(_boxName);

  // ============================================================
  // 1. قراءة الشركات من Hive
  // ============================================================

  List<Map<String, dynamic>> getCompaniesFromHive() {
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

  /// ValueListenableBuilder للـ UI
  ValueListenable<Box> get companiesListenable => _box.listenable();

  // ============================================================
  // 2. جلب كل الشركات من السيرفر (Full Sync)
  // ============================================================

  Future<void> fetchAllCompanies({String adminJobCode = '99'}) async {
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

      await _box.put(_allKey, companies);

      print('✅ [Companies] تم حفظ ${companies.length} شركة في Hive');
    } catch (e) {
      print('❌ [Companies] فشل FULL SYNC: $e');
      rethrow;
    }
  }

  // ============================================================
  // 3. العمليات (Add/Edit/Delete/Toggle)
  // ============================================================

  Future<void> addCompany({
    required String code,
    required String name,
    String adminJobCode = '99',
  }) async {
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
  }

  Future<void> updateCompany({
    required String oldCode,
    required String newCode,
    required String newName,
    String adminJobCode = '99',
  }) async {
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
  }

  Future<void> deleteCompany({
    required String code,
    String adminJobCode = '99',
  }) async {
    final response = await AuthHttp.delete(
      Uri.parse(
        '$baseUrl/auth/companies/delete/$code?admin_job_code=$adminJobCode',
      ),
    );

    if (response.statusCode != 200) {
      final detail =
          jsonDecode(response.body)['detail'] ?? 'فشل حذف الشركة';
      throw Exception(detail);
    }

    await fetchAllCompanies(adminJobCode: adminJobCode);
  }

  Future<void> toggleCompanyStatus({
    required String code,
    required bool isActive,
    String adminJobCode = '99',
  }) async {
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
  }

  // ============================================================
  // 4. مسح الـ Cache (عند logout)
  // ============================================================

  Future<void> clearCache() async {
    await _box.delete(_allKey);
  }
}