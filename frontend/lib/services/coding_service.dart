// lib/services/coding_service.dart

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/coding_model.dart';
import '../core/constants.dart';
import 'auth_http.dart';


class CodingService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;


  // ============================================================
  // Hive
  // ============================================================

  final Box _codingBox =
      Hive.box('coding_box');


  // ============================================================
  // الأقسام
  // ============================================================

    final List<String> categories = const [
    'safes',
    'types',
    'branches',
    'stores',
    'suppliers',
    'customers',
    'payment_methods',
    'items',
    // ✅ employees انتقل لـ EmployeeService
  ];


  // ============================================================
  // 1. جلب قائمة قسم من Hive أو السيرفر
  //
  // مهم:
  // هذه الدالة ليست مسؤولة عن المزامنة المركزية.
  //
  // لو البيانات موجودة في Hive:
  //     لا API
  //
  // لو غير موجودة:
  //     GET /coding/list
  //
  // أما المزامنة العادية عند تشغيل البرنامج فتتم عن طريق:
  // syncChangesFromServer()
  // ============================================================

  Future<List<CodingModel>> getCodingList({
    required String companyCode,
    required String category,
  }) async {
    final String localKey =
        "${companyCode}_$category";


    // ----------------------------------------------------------
    // 1) Hive
    // ----------------------------------------------------------

    if (_codingBox.containsKey(localKey)) {
      final dynamic rawData =
          _codingBox.get(localKey);

      if (rawData is List) {
        print(
          "⚡ التكويد [$category] من Hive",
        );

        final List<CodingModel> result = [];

        for (final item in rawData) {
          if (item is! Map) {
            continue;
          }

          final map =
              Map<String, dynamic>.from(item);

          // لا نعرض المحذوف
          if (map['is_deleted'] == true) {
            continue;
          }

          try {
            result.add(
              CodingModel.fromMap(map),
            );
          } catch (e) {
            print(
              "⚠️ خطأ في تحويل تكويد [$category]: $e",
            );
          }
        }

        return result;
      }
    }


    // ----------------------------------------------------------
    // 2) السيرفر
    //
    // هذا يحدث فقط إذا لم توجد بيانات محلية.
    // ----------------------------------------------------------

    print(
      "⚠️ لا توجد بيانات محلية للقسم [$category]، "
      "جاري تحميله من السيرفر...",
    );

    try {
      final response = await AuthHttp.get(
        Uri.parse(
          "$baseUrl/coding/list/"
          "$companyCode/$category",
        ),
      );


      if (response.statusCode != 200) {
        print(
          "❌ خطأ من السيرفر [$category]: "
          "${response.statusCode}",
        );

        return [];
      }


      final List<dynamic> decodedData =
          jsonDecode(response.body);


      final List<Map<String, dynamic>>
          cleanList = [];


      for (final item in decodedData) {
        if (item is! Map) {
          continue;
        }

        final map =
            Map<String, dynamic>.from(item);

        if (map['is_deleted'] == true) {
          continue;
        }

        map['is_deleted'] = false;

        cleanList.add(map);
      }


      cleanList.sort(
        (a, b) {
          final int aCode =
              int.tryParse(
                    a['code']?.toString() ?? '0',
                  ) ??
                  0;

          final int bCode =
              int.tryParse(
                    b['code']?.toString() ?? '0',
                  ) ??
                  0;

          return aCode.compareTo(
            bCode,
          );
        },
      );


      await _codingBox.put(
        localKey,
        cleanList,
      );


      print(
        "✅ تم جلب [$category] من السيرفر "
        "وحفظه في Hive (${cleanList.length})",
      );


      return cleanList
          .map(
            (item) =>
                CodingModel.fromMap(item),
          )
          .toList();

    } catch (e) {
      print(
        "❌ فشل الاتصال بالسيرفر [$category]: $e",
      );

      return [];
    }
  }


  // ============================================================
  // 2. Full Sync للتكويد
  //
  // يستخدم فقط:
  // lastSync == null
  //
  // جهاز جديد = نعم
  // جهاز قديم = لا
  // ============================================================

  Future<void> fetchAllCoding(
    String companyCode,
  ) async {
    print(
      "📥 التكويد: بدء FULL SYNC "
      "للشركة $companyCode",
    );


    try {
      // ✅ 1) جلب كل الأقسام بالتوازي
      final responses = await Future.wait(
        categories.map(
          (category) async {
            try {
              return await AuthHttp.get(
                Uri.parse(
                  '$baseUrl/coding/list/'
                  '$companyCode/$category',
                ),
              );
            } catch (_) {
              return null;
            }
          },
        ),
      );


      // ✅ 2) معالجة النتائج بالترتيب (نفس الأصل)
      for (int i = 0; i < categories.length; i++) {
        final category = categories[i];
        final response = responses[i];


        if (response == null) {
          throw Exception(
            'فشل الاتصال بالسيرفر [$category]',
          );
        }


        if (response.statusCode != 200) {
          throw Exception(
            'فشل تحميل التكويد [$category]. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }


        final List<dynamic> data =
            jsonDecode(response.body);


        final List<Map<String, dynamic>>
            list = [];


        for (final item in data) {
          if (item is! Map) {
            continue;
          }


          final map =
              Map<String, dynamic>.from(item);


          // المحذوف لا يدخل Hive
          if (map['is_deleted'] == true) {
            continue;
          }


          map['is_deleted'] = false;

          list.add(map);
        }


        // ------------------------------------------------------
        // ترتيب
        // ------------------------------------------------------

        list.sort(
          (a, b) {
            final int aCode =
                int.tryParse(
                      a['code']
                              ?.toString() ??
                          '0',
                    ) ??
                    0;

            final int bCode =
                int.tryParse(
                      b['code']
                              ?.toString() ??
                          '0',
                    ) ??
                    0;

            return aCode.compareTo(
              bCode,
            );
          },
        );


        final String localKey =
            "${companyCode}_$category";


        await _codingBox.put(
          localKey,
          list,
        );


        print(
          "✅ FULL SYNC: [$category] "
          "(${list.length})",
        );
      }


      print(
        "✅ اكتمل FULL SYNC للتكويد "
        "للشركة $companyCode",
      );

    } catch (e) {
      print(
        "❌ فشل FULL SYNC للتكويد: $e",
      );

      rethrow;
    }
  }


  // ============================================================
  // 3. المزامنة التزايدية للتكويد
  //
  // lastSync موجود:
  //     /coding/changes
  //
  // لا يوجد تحميل كامل.
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences.getInstance();


    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_CODING}$companyCode';


    final String? lastSyncValue =
        lastSync ??
        prefs.getString(
          lastSyncKey,
        );


    // ==========================================================
    // جهاز جديد
    // ==========================================================

    if (lastSyncValue == null ||
        lastSyncValue.isEmpty) {
      print(
        "📥 التكويد: لا يوجد lastSync "
        "→ FULL SYNC",
      );

      await fetchAllCoding(
        companyCode,
      );


      // حفظ وقت المزامنة بعد النجاح
      await prefs.setString(
        lastSyncKey,
        DateTime.now()
            .toUtc()
            .toIso8601String(),
      );


      return;
    }


    // ==========================================================
    // جهاز قديم
    // ==========================================================

    print(
      "📡 التكويد: INCREMENTAL SYNC "
      "منذ $lastSyncValue",
    );


    try {
      final DateTime syncStartedAt =
          DateTime.now().toUtc();


      // --------------------------------------------------------
      // نستخدم UTC
      // --------------------------------------------------------

      final DateTime sinceDt =
          DateTime.parse(
        lastSyncValue,
      ).toUtc();


      final String effectiveSince =
          sinceDt.toIso8601String();


      // --------------------------------------------------------
      // ✅ 1) جلب كل التغييرات بالتوازي
      // --------------------------------------------------------

      final responses = await Future.wait(
        categories.map(
          (category) async {
            try {
              return await AuthHttp.get(
                Uri.parse(
                  '$baseUrl/coding/changes/'
                  '$companyCode'
                  '?category=$category'
                  '&since=$effectiveSince',
                ),
              );
            } catch (_) {
              return null;
            }
          },
        ),
      );


      // --------------------------------------------------------
      // ✅ 2) معالجة كل قسم بالترتيب (نفس الأصل)
      // --------------------------------------------------------

      for (int i = 0; i < categories.length; i++) {
        final category = categories[i];
        final response = responses[i];


        if (response == null) {
          throw Exception(
            'فشل الاتصال بالسيرفر [$category]',
          );
        }


        if (response.statusCode != 200) {
          throw Exception(
            'فشل مزامنة التكويد [$category]. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }


        final List<dynamic> changes =
            jsonDecode(
          response.body,
        );


        // ------------------------------------------------------
        // لا يوجد تغييرات في القسم
        // ------------------------------------------------------

        if (changes.isEmpty) {
          print(
            "⏭️ [$category] لا يوجد تغييرات",
          );

          continue;
        }


        final String localKey =
            '${companyCode}_$category';


        // ------------------------------------------------------
        // قراءة القائمة المحلية
        // ------------------------------------------------------

        List<Map<String, dynamic>>
            currentList = [];


        if (_codingBox.containsKey(
          localKey,
        )) {
          final dynamic raw =
              _codingBox.get(
            localKey,
          );


          if (raw is List) {
            currentList = raw
                .whereType<Map>()
                .map(
                  (e) =>
                      Map<String, dynamic>
                          .from(e),
                )
                .where(
                  (e) =>
                      e['is_deleted'] !=
                      true,
                )
                .toList();
          }
        }


        // ------------------------------------------------------
        // تطبيق التغييرات
        // ------------------------------------------------------

        for (final item in changes) {
          if (item is! Map) {
            continue;
          }


          final Map<String, dynamic>
              map =
              Map<String, dynamic>.from(
            item,
          );


          final String action =
              map['action']
                      ?.toString() ??
                  (
                    map['is_deleted'] ==
                            true
                        ? 'delete'
                        : 'update'
                  );


          final String? code =
              map['code']?.toString();


          if (code == null ||
              code.isEmpty) {
            print(
              "⚠️ تحديث تكويد بدون code "
              "[$category]",
            );

            continue;
          }


          // ----------------------------------------------------
          // حذف السجل من القائمة المحلية
          // ----------------------------------------------------

          currentList.removeWhere(
            (e) =>
                e['code']
                        ?.toString() ==
                    code,
          );


          // ----------------------------------------------------
          // DELETE
          // ----------------------------------------------------

          if (action == 'delete' ||
              map['is_deleted'] == true) {
            print(
              "🗑️ حذف تكويد [$category/$code]",
            );

            continue;
          }


          // ----------------------------------------------------
          // INSERT / UPDATE
          // ----------------------------------------------------

          map.remove(
            'action',
          );


          map['is_deleted'] =
              false;


          currentList.add(
            map,
          );


          print(
            "✅ تحديث تكويد "
            "[$category/$code]",
          );
        }


        // ------------------------------------------------------
        // إزالة أي تكرارات
        // ------------------------------------------------------

        final Map<String,
                Map<String, dynamic>>
            uniqueItems = {};


        for (final item in currentList) {
          final code =
              item['code']
                      ?.toString() ??
                  '';

          if (code.isNotEmpty) {
            uniqueItems[code] = item;
          }
        }


        currentList =
            uniqueItems.values.toList();


        // ------------------------------------------------------
        // ترتيب
        // ------------------------------------------------------

        currentList.sort(
          (a, b) {
            final int aCode =
                int.tryParse(
                      a['code']
                              ?.toString() ??
                          '0',
                    ) ??
                    0;

            final int bCode =
                int.tryParse(
                      b['code']
                              ?.toString() ??
                          '0',
                    ) ??
                    0;

            return aCode.compareTo(
              bCode,
            );
          },
        );


        // ------------------------------------------------------
        // حفظ
        // ------------------------------------------------------

        if (currentList.isEmpty) {
          await _codingBox.delete(
            localKey,
          );
        } else {
          await _codingBox.put(
            localKey,
            currentList,
          );
        }


        print(
          "✅ تم تحديث [$category] "
          "(${changes.length} تغيير)",
        );
      }


      // ========================================================
      // حفظ lastSync
      //
      // فقط بعد نجاح كل الأقسام
      // ========================================================

      await prefs.setString(
        lastSyncKey,
        syncStartedAt
            .toIso8601String(),
      );


      print(
        "✅ اكتملت INCREMENTAL SYNC للتكويد",
      );

    } catch (e) {
      // مهم جدًا:
      // لا نحرك lastSync إذا أي قسم فشل.
      print(
        "❌ فشل INCREMENTAL SYNC للتكويد: $e",
      );

      rethrow;
    }
  }


  // ============================================================
  // 4. حفظ أو تحديث تكويد
  // ============================================================

  Future<Map<String, dynamic>> saveCode({
    required String companyCode,
    required String category,
    required CodingModel model,
  }) async {
    try {
      final Map<String, dynamic>
          bodyData =
          Map<String, dynamic>.from(
        model.toMap(),
      );


      bodyData['company_code'] =
          companyCode;

      bodyData['category'] =
          category;


      final response = await AuthHttp.post(
        Uri.parse(
          "$baseUrl/coding/save",
        ),
        headers: {
          "Content-Type":
              "application/json",
        },
        body: json.encode(
          bodyData,
        ),
      );


      if (response.statusCode != 200) {
        return {
          'success': false,
          'error':
              'فشل الحفظ من السيرفر. '
              'كود الخطأ: '
              '${response.statusCode}',
        };
      }


      final Map<String, dynamic>
          result =
          json.decode(
        response.body,
      );


      final String newCode =
          result['code']
                  ?.toString() ??
              model.code;


      final String action =
          result['action']
                  ?.toString() ??
              'update';


      final String localKey =
          "${companyCode}_$category";


      // --------------------------------------------------------
      // قراءة القائمة الحالية
      // --------------------------------------------------------

      List<Map<String, dynamic>>
          currentList = [];


      if (_codingBox.containsKey(
        localKey,
      )) {
        final dynamic rawData =
            _codingBox.get(
          localKey,
        );


        if (rawData is List) {
          currentList = rawData
              .whereType<Map>()
              .map(
                (item) =>
                    Map<String, dynamic>
                        .from(item),
              )
              .where(
                (item) =>
                    item['is_deleted'] !=
                    true,
              )
              .toList();
        }
      }


      // --------------------------------------------------------
      // البيانات المحلية
      // --------------------------------------------------------

      final Map<String, dynamic>
          newItem =
          Map<String, dynamic>.from(
        model.toMap(),
      );


      newItem['code'] =
          newCode;

      newItem['company_code'] =
          companyCode;

      newItem['category'] =
          category;

      newItem['is_deleted'] =
          false;


      // --------------------------------------------------------
      // حذف النسخة القديمة
      // --------------------------------------------------------

      currentList.removeWhere(
        (item) =>
            item['code']
                    ?.toString() ==
                newCode,
      );


      // --------------------------------------------------------
      // إضافة النسخة الجديدة
      // --------------------------------------------------------

      currentList.add(
        newItem,
      );


      // --------------------------------------------------------
      // منع التكرار
      // --------------------------------------------------------

      final Map<String,
              Map<String, dynamic>>
          uniqueItems = {};


      for (final item in currentList) {
        final String code =
            item['code']
                    ?.toString() ??
                '';

        if (code.isNotEmpty) {
          uniqueItems[code] =
              item;
        }
      }


      currentList =
          uniqueItems.values.toList();


      // --------------------------------------------------------
      // ترتيب
      // --------------------------------------------------------

      currentList.sort(
        (a, b) {
          final int aCode =
              int.tryParse(
                    a['code']
                            ?.toString() ??
                        '0',
                  ) ??
                  0;

          final int bCode =
              int.tryParse(
                    b['code']
                            ?.toString() ??
                        '0',
                  ) ??
                  0;

          return aCode.compareTo(
            bCode,
          );
        },
      );


      await _codingBox.put(
        localKey,
        currentList,
      );


      print(
        "✅ تم الحفظ المحلي للتكويد "
        "[$category/$newCode]",
      );


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
  // 5. حذف تكويد
  // ============================================================

  Future<bool> deleteCode({
    required String companyCode,
    required String category,
    required String code,
  }) async {
    try {
      final response = await AuthHttp.delete(
        Uri.parse(
          "$baseUrl/coding/delete/"
          "$companyCode/"
          "$category/"
          "$code",
        ),
      );


      if (response.statusCode != 200) {
        print(
          "❌ السيرفر رفض حذف التكويد "
          "[$category/$code] "
          "HTTP ${response.statusCode}",
        );

        return false;
      }


      // --------------------------------------------------------
      // حذف محلي فوري
      // --------------------------------------------------------

      final String localKey =
          "${companyCode}_$category";


      if (_codingBox.containsKey(
        localKey,
      )) {
        final dynamic rawData =
            _codingBox.get(
          localKey,
        );


        if (rawData is List) {
          final List<Map<String, dynamic>>
              safeList = [];


          for (final item in rawData) {
            if (item is! Map) {
              continue;
            }


            final Map<String, dynamic>
                safeMap =
                Map<String, dynamic>
                    .from(item);


            if (safeMap['code']
                    ?.toString() ==
                code.toString()) {
              continue;
            }


            if (safeMap['is_deleted'] ==
                true) {
              continue;
            }


            safeList.add(
              safeMap,
            );
          }


          if (safeList.isEmpty) {
            await _codingBox.delete(
              localKey,
            );
          } else {
            await _codingBox.put(
              localKey,
              safeList,
            );
          }


          print(
            "✅ تم حذف التكويد "
            "[$category/$code] من Hive",
          );
        }
      }


      return true;

    } catch (e) {
      print(
        "❌ خطأ أثناء حذف التكويد: $e",
      );

      return false;
    }
  }
}