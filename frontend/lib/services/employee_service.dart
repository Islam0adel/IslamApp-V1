// lib/services/employee_service.dart

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/employee_model.dart';
import '../core/constants.dart';
import 'auth_http.dart';


class EmployeeService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;


  // ============================================================
  // Hive
  // ============================================================

  final Box _codingBox = Hive.box('coding_box');


  // ============================================================
  // مفتاح Hive (بنفس نمط CodingService للتوافق)
  // ============================================================

  String _localKey(String companyCode) =>
      "${companyCode}_employees";


  // ============================================================
  // 1. جلب قائمة الموظفين (من Hive أو السيرفر)
  // ============================================================

  Future<List<EmployeeModel>> getEmployeesList({
    required String companyCode,
  }) async {
    final String localKey = _localKey(companyCode);

    // ----------------------------------------------------------
    // 1) Hive
    // ----------------------------------------------------------

    if (_codingBox.containsKey(localKey)) {
      final dynamic rawData = _codingBox.get(localKey);

      if (rawData is List) {
        print("⚡ الموظفين من Hive");

        final List<EmployeeModel> result = [];

        for (final item in rawData) {
          if (item is! Map) continue;

          final map = Map<String, dynamic>.from(item);

          if (map['is_deleted'] == true) continue;

          try {
            result.add(EmployeeModel.fromMap(map));
          } catch (e) {
            print("⚠️ خطأ في تحويل موظف: $e");
          }
        }

        return result;
      }
    }

    // ----------------------------------------------------------
    // 2) السيرفر
    // ----------------------------------------------------------

    print(
      "⚠️ لا توجد بيانات محلية للموظفين، "
      "جاري تحميلها من السيرفر...",
    );

    try {
      final response = await AuthHttp.get(
        Uri.parse("$baseUrl/employees/list/$companyCode"),
      );

      if (response.statusCode != 200) {
        print(
          "❌ خطأ من السيرفر [employees]: "
          "${response.statusCode}",
        );
        return [];
      }

      final List<dynamic> decodedData = jsonDecode(response.body);

      final List<Map<String, dynamic>> cleanList = [];

      for (final item in decodedData) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) continue;

        map['is_deleted'] = false;
        cleanList.add(map);
      }

      cleanList.sort((a, b) {
        final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
        final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
        return aCode.compareTo(bCode);
      });

      await _codingBox.put(localKey, cleanList);

      print(
        "✅ تم جلب الموظفين من السيرفر "
        "وحفظهم في Hive (${cleanList.length})",
      );

      return cleanList
          .map((item) => EmployeeModel.fromMap(item))
          .toList();

    } catch (e) {
      print("❌ فشل الاتصال بالسيرفر [employees]: $e");
      return [];
    }
  }


  // ============================================================
  // 2. Full Sync (جهاز جديد — lastSync == null)
  // ============================================================

  Future<void> fetchAllEmployees(String companyCode) async {
    print("📥 الموظفين: بدء FULL SYNC للشركة $companyCode");

    try {
      final response = await AuthHttp.get(
        Uri.parse('$baseUrl/employees/list/$companyCode'),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'فشل تحميل الموظفين. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> data = jsonDecode(response.body);

      final List<Map<String, dynamic>> list = [];

      for (final item in data) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) continue;

        map['is_deleted'] = false;
        list.add(map);
      }

      list.sort((a, b) {
        final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
        final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
        return aCode.compareTo(bCode);
      });

      final String localKey = _localKey(companyCode);
      await _codingBox.put(localKey, list);

      print("✅ FULL SYNC: [employees] (${list.length})");
      print("✅ اكتمل FULL SYNC للموظفين للشركة $companyCode");

    } catch (e) {
      print("❌ فشل FULL SYNC للموظفين: $e");
      rethrow;
    }
  }


  // ============================================================
  // 3. المزامنة التزايدية (lastSync موجود)
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs = await SharedPreferences.getInstance();

    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_CODING}_employees_$companyCode';

    final String? lastSyncValue =
        lastSync ?? prefs.getString(lastSyncKey);

    // ----------------------------------------------------------
    // جهاز جديد
    // ----------------------------------------------------------

    if (lastSyncValue == null || lastSyncValue.isEmpty) {
      print("📥 الموظفين: لا يوجد lastSync → FULL SYNC");

      await fetchAllEmployees(companyCode);

      await prefs.setString(
        lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );

      return;
    }

    // ----------------------------------------------------------
    // جهاز قديم
    // ----------------------------------------------------------

    print("📡 الموظفين: INCREMENTAL SYNC منذ $lastSyncValue");

    try {
      final DateTime syncStartedAt = DateTime.now().toUtc();

      final DateTime sinceDt =
          DateTime.parse(lastSyncValue).toUtc();

      final String effectiveSince = sinceDt.toIso8601String();

      final response = await AuthHttp.get(
        Uri.parse(
          '$baseUrl/employees/changes/'
          '$companyCode'
          '?since=$effectiveSince',
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'فشل مزامنة الموظفين. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }

      final List<dynamic> changes = jsonDecode(response.body);

      // ------------------------------------------------------
      // لا يوجد تغييرات
      // ------------------------------------------------------

      if (changes.isEmpty) {
        print("⏭️ [employees] لا يوجد تغييرات");

        await prefs.setString(
          lastSyncKey,
          syncStartedAt.toIso8601String(),
        );
        return;
      }

      final String localKey = _localKey(companyCode);

      // ------------------------------------------------------
      // قراءة القائمة المحلية
      // ------------------------------------------------------

      List<Map<String, dynamic>> currentList = [];

      if (_codingBox.containsKey(localKey)) {
        final dynamic raw = _codingBox.get(localKey);

        if (raw is List) {
          currentList = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => e['is_deleted'] != true)
              .toList();
        }
      }

      // ------------------------------------------------------
      // تطبيق التغييرات
      // ------------------------------------------------------

      for (final item in changes) {
        if (item is! Map) continue;

        final Map<String, dynamic> map =
            Map<String, dynamic>.from(item);

        final String action =
            map['action']?.toString() ??
                (map['is_deleted'] == true ? 'delete' : 'update');

        final String? code = map['code']?.toString();

        if (code == null || code.isEmpty) {
          print("⚠️ تحديث موظف بدون code");
          continue;
        }

        // إزالة النسخة القديمة
        currentList.removeWhere(
          (e) => e['code']?.toString() == code,
        );

        // DELETE
        if (action == 'delete' || map['is_deleted'] == true) {
          print("🗑️ حذف موظف [$code]");
          continue;
        }

        // INSERT / UPDATE
        map.remove('action');
        map['is_deleted'] = false;
        currentList.add(map);

        print("✅ تحديث موظف [$code]");
      }

      // ------------------------------------------------------
      // إزالة أي تكرارات + ترتيب
      // ------------------------------------------------------

      final Map<String, Map<String, dynamic>> uniqueItems = {};

      for (final item in currentList) {
        final code = item['code']?.toString() ?? '';
        if (code.isNotEmpty) {
          uniqueItems[code] = item;
        }
      }

      currentList = uniqueItems.values.toList();

      currentList.sort((a, b) {
        final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
        final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
        return aCode.compareTo(bCode);
      });

      // ------------------------------------------------------
      // حفظ
      // ------------------------------------------------------

      if (currentList.isEmpty) {
        await _codingBox.delete(localKey);
      } else {
        await _codingBox.put(localKey, currentList);
      }

      // ------------------------------------------------------
      // حفظ lastSync (فقط بعد النجاح)
      // ------------------------------------------------------

      await prefs.setString(
        lastSyncKey,
        syncStartedAt.toIso8601String(),
      );

      print(
        "✅ تم تحديث الموظفين "
        "(${changes.length} تغيير)",
      );

    } catch (e) {
      print("❌ فشل INCREMENTAL SYNC للموظفين: $e");
      rethrow;
    }
  }


  // ============================================================
  // 4. حفظ موظف (إضافة أو تحديث)
  // ============================================================

  Future<Map<String, dynamic>> saveEmployee({
    required String companyCode,
    required EmployeeModel model,
  }) async {
    try {
      final Map<String, dynamic> bodyData =
          Map<String, dynamic>.from(model.toMap());

      bodyData['company_code'] = companyCode;

      final response = await AuthHttp.post(
        Uri.parse("$baseUrl/employees/save"),
        headers: {"Content-Type": "application/json"},
        body: json.encode(bodyData),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'فشل الحفظ من السيرفر. '
              'كود الخطأ: ${response.statusCode}',
        };
      }

      final Map<String, dynamic> result = json.decode(response.body);

      final String newCode =
          result['code']?.toString() ?? model.code;

      final String action =
          result['action']?.toString() ?? 'update';

      final String localKey = _localKey(companyCode);

      // --------------------------------------------------------
      // قراءة القائمة الحالية
      // --------------------------------------------------------

      List<Map<String, dynamic>> currentList = [];

      if (_codingBox.containsKey(localKey)) {
        final dynamic rawData = _codingBox.get(localKey);

        if (rawData is List) {
          currentList = rawData
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .where((item) => item['is_deleted'] != true)
              .toList();
        }
      }

      // --------------------------------------------------------
      // البيانات الجديدة
      // --------------------------------------------------------

      final Map<String, dynamic> newItem =
          Map<String, dynamic>.from(model.toMap());

      newItem['code'] = newCode;
      newItem['company_code'] = companyCode;
      newItem['is_deleted'] = false;

      // --------------------------------------------------------
      // حذف النسخة القديمة + إضافة الجديدة
      // --------------------------------------------------------

      currentList.removeWhere(
        (item) => item['code']?.toString() == newCode,
      );

      currentList.add(newItem);

      // --------------------------------------------------------
      // إزالة التكرار + ترتيب
      // --------------------------------------------------------

      final Map<String, Map<String, dynamic>> uniqueItems = {};

      for (final item in currentList) {
        final String code = item['code']?.toString() ?? '';
        if (code.isNotEmpty) {
          uniqueItems[code] = item;
        }
      }

      currentList = uniqueItems.values.toList();

      currentList.sort((a, b) {
        final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
        final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
        return aCode.compareTo(bCode);
      });

      await _codingBox.put(localKey, currentList);

      print("✅ تم الحفظ المحلي للموظف [$newCode]");

      return {
        'success': true,
        'code': newCode,
        'action': action,
      };

    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }


  // ============================================================
  // 5. حذف موظف
  // ============================================================

  Future<bool> deleteEmployee({
    required String companyCode,
    required String code,
  }) async {
    try {
      final response = await AuthHttp.delete(
        Uri.parse(
          "$baseUrl/employees/delete/$companyCode/$code",
        ),
      );

      if (response.statusCode != 200) {
        print(
          "❌ السيرفر رفض حذف الموظف [$code] "
          "HTTP ${response.statusCode}",
        );
        return false;
      }

      // --------------------------------------------------------
      // حذف محلي فوري
      // --------------------------------------------------------

      final String localKey = _localKey(companyCode);

      if (_codingBox.containsKey(localKey)) {
        final dynamic rawData = _codingBox.get(localKey);

        if (rawData is List) {
          final List<Map<String, dynamic>> safeList = [];

          for (final item in rawData) {
            if (item is! Map) continue;

            final Map<String, dynamic> safeMap =
                Map<String, dynamic>.from(item);

            if (safeMap['code']?.toString() == code.toString()) {
              continue;
            }

            if (safeMap['is_deleted'] == true) {
              continue;
            }

            safeList.add(safeMap);
          }

          if (safeList.isEmpty) {
            await _codingBox.delete(localKey);
          } else {
            await _codingBox.put(localKey, safeList);
          }

          print("✅ تم حذف الموظف [$code] من Hive");
        }
      }

      return true;

    } catch (e) {
      print("❌ خطأ أثناء حذف الموظف: $e");
      return false;
    }
  }


  // ============================================================
  // 6. جلب موظف واحد بالتفصيل
  // ============================================================

  Future<EmployeeModel?> getEmployee({
    required String companyCode,
    required String code,
  }) async {
    try {
      final response = await AuthHttp.get(
        Uri.parse(
          "$baseUrl/employees/get/$companyCode/$code",
        ),
      );

      if (response.statusCode != 200) {
        print(
          "❌ فشل جلب الموظف [$code]: "
          "${response.statusCode}",
        );
        return null;
      }

      final Map<String, dynamic> data = jsonDecode(response.body);
      return EmployeeModel.fromMap(data);

    } catch (e) {
      print("❌ خطأ في جلب الموظف: $e");
      return null;
    }
  }
}