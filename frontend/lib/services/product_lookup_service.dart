
import 'dart:async';
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'auth_http.dart';

class ProductLookupService {
  static const String _boxName = 'product_lookup_box';
  static const Duration _cacheDuration = Duration(days: 7);
  static const Duration _negativeCacheDuration = Duration(minutes: 15);
  static const Duration _nameCacheDuration = Duration(hours: 1);

  Future<Map<String, dynamic>> lookup(String rawBarcode, {bool forceRefresh = false}) async {
    final barcode = rawBarcode.trim();
    if (!RegExp(r'^\d{8,14}$').hasMatch(barcode)) {
      throw Exception('اكتب باركودًا رقميًا من 8 إلى 14 خانة');
    }

    final box = Hive.box(_boxName);
    final cached = box.get(barcode);
    if (!forceRefresh && cached is Map) {
      final savedAt = DateTime.tryParse(cached['_cached_at']?.toString() ?? '');
      final cacheDuration = cached['found'] == true ? _cacheDuration : _negativeCacheDuration;
      if (savedAt != null && DateTime.now().difference(savedAt) < cacheDuration) {
        return Map<String, dynamic>.from(cached)..remove('_cached_at');
      }
    }

    try {
      final response = await AuthHttp.get(
        Uri.parse('${ApiConstants.baseUrl}/products/lookup/$barcode${forceRefresh ? '?refresh=true' : ''}'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          await box.put(barcode, {...data, '_cached_at': DateTime.now().toIso8601String()});
          return data;
        }
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception('انتهت الجلسة أو لا توجد صلاحية للوصول. سجل الدخول مرة أخرى.');
      }
      final body = jsonDecode(response.body);
      throw Exception(body is Map ? (body['detail'] ?? 'تعذر البحث عن المنتج').toString() : 'تعذر البحث عن المنتج');
    } catch (e) {
      if (cached is Map) return Map<String, dynamic>.from(cached)..remove('_cached_at');
      if (e is TimeoutException) {
        throw Exception('البحث استغرق وقتًا أطول من المتوقع. حاول مرة أخرى بعد قليل.');
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> searchByName(String rawQuery, {bool forceRefresh = false}) async {
    final query = rawQuery.trim();
    if (query.length < 2) throw Exception('اكتب اسم المنتج بشكل أوضح');

    final box = Hive.box(_boxName);
    final cacheKey = 'web_search:${query.toLowerCase()}';
    final cached = box.get(cacheKey);

    if (!forceRefresh && cached is Map) {
      final savedAt = DateTime.tryParse(cached['_cached_at']?.toString() ?? '');
      if (savedAt != null && DateTime.now().difference(savedAt) < _nameCacheDuration) {
        return Map<String, dynamic>.from(cached)..remove('_cached_at');
      }
    }

    try {
      final uri = Uri.parse('${ApiConstants.baseUrl}/products/search')
          .replace(queryParameters: {'query': query});
      final response = await AuthHttp.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          await box.put(cacheKey, {...decoded, '_cached_at': DateTime.now().toIso8601String()});
          return decoded;
        }
        throw Exception('استجابة البحث غير متوقعة');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception('انتهت الجلسة أو لا توجد صلاحية للوصول. سجل الدخول مرة أخرى.');
      }
      final body = jsonDecode(response.body);
      throw Exception(body is Map ? (body['detail'] ?? 'تعذر البحث عن المنتج').toString() : 'تعذر البحث عن المنتج');
    } on TimeoutException {
      if (cached is Map) return Map<String, dynamic>.from(cached)..remove('_cached_at');
      throw Exception('البحث استغرق وقتًا أطول من المتوقع. حاول مرة أخرى.');
    } catch (e) {
      if (cached is Map) return Map<String, dynamic>.from(cached)..remove('_cached_at');
      rethrow;
    }
  }
}
