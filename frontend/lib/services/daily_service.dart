import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';


class DailyService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;


  // ============================================================
  // Hive
  // ============================================================

  final Box _transactionBox =
      Hive.box('daily_transactions_box');


  // ============================================================
  // 1. حساب الأرصدة محلياً من Hive
  // ============================================================

  Future<Map<String, dynamic>> getDailySummaryLocal(
    String companyCode, {
    String? branchCode,
  }) async {
    try {
      // --------------------------------------------------------
      // قراءة الخزائن من التكويد المحلي
      // --------------------------------------------------------

      final Box codingBox =
          Hive.box('coding_box');

      final String localKey =
          "${companyCode}_safes";

      List<String> activeTreasuries = [];

      if (codingBox.containsKey(localKey)) {
        final dynamic rawData =
            codingBox.get(localKey);

        if (rawData is List) {
          activeTreasuries = rawData
              .whereType<Map>()
              .map(
                (item) =>
                    item['name']?.toString() ?? "",
              )
              .where(
                (name) => name.isNotEmpty,
              )
              .toList();
        }
      }


      // --------------------------------------------------------
      // إنشاء الأرصدة
      // --------------------------------------------------------

      Map<String, double> treasuryBalances = {};

      for (final name in activeTreasuries) {
        treasuryBalances[name] = 0.0;
      }


      // --------------------------------------------------------
      // قراءة كل الحركات من Hive
      // --------------------------------------------------------

      final List<dynamic> allTx =
          _transactionBox.values.toList();


      // --------------------------------------------------------
      // ترتيب آمن بالسيريال
      // --------------------------------------------------------

      allTx.sort(
        (a, b) {
          final int aSerial =
              int.tryParse(
                    a is Map
                        ? a['serial']?.toString() ?? '0'
                        : '0',
                  ) ??
                  0;

          final int bSerial =
              int.tryParse(
                    b is Map
                        ? b['serial']?.toString() ?? '0'
                        : '0',
                  ) ??
                  0;

          return aSerial.compareTo(
            bSerial,
          );
        },
      );


      // --------------------------------------------------------
      // حساب الأرصدة
      // --------------------------------------------------------

      for (final rawTx in allTx) {
        if (rawTx is! Map) {
          continue;
        }

        final tx =
            Map<String, dynamic>.from(
          rawTx,
        );


        // ======================================================
        // تجاهل السجلات المحذوفة
        // ======================================================

        if (tx['is_deleted'] == true) {
          continue;
        }


        // ======================================================
        // التأكد من الشركة
        // ======================================================

        if (tx['company_code'] != companyCode) {
          continue;
        }


        // ======================================================
        // فلترة الفرع
        // ======================================================

        if (branchCode != null &&
            ![
              'الكل',
              'كل الفروع',
              'all',
              '',
            ].contains(branchCode) &&
            tx['branch_code']?.toString() !=
                branchCode) {
          continue;
        }


        // ======================================================
        // بيانات الحركة
        // ======================================================

        final String treasury =
            tx['treasury']?.toString() ?? "";

        final double amount =
            double.tryParse(
                  tx['amount']?.toString() ?? '0.0',
                ) ??
                0.0;

        final String type =
            tx['type']?.toString() ?? "وارد";


        // ======================================================
        // إضافة / خصم
        // ======================================================

        if (treasuryBalances.containsKey(
          treasury,
        )) {
          if (type == "وارد") {
            treasuryBalances[treasury] =
                treasuryBalances[treasury]! +
                    amount;
          } else if (type == "صادر") {
            treasuryBalances[treasury] =
                treasuryBalances[treasury]! -
                    amount;
          }
        }
      }


      // --------------------------------------------------------
      // حفظ الأرصدة محلياً
      // --------------------------------------------------------

      await _transactionBox.put(
        "${companyCode}_balances",
        treasuryBalances,
      );


      return {
        "status": "success",
        "balances": treasuryBalances,
      };
    } catch (e) {
      print(
        "❌ خطأ في حساب الأرصدة: $e",
      );

      return {
        "status": "error",
        "balances": {},
      };
    }
  }


  // ============================================================
  // 2. جلب جميع اليوميات من السيرفر
  //    Full Sync - جهاز جديد فقط
  // ============================================================

  Future<List<dynamic>> fetchAllTransactions(
    String companyCode,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/transactions/list/$companyCode'
          '?start_date=2020-01-01'
          '&end_date=2100-12-31',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل جلب اليوميات '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic> serverData =
          jsonDecode(response.body);


      // --------------------------------------------------------
      // حفظ البيانات
      // --------------------------------------------------------

      for (final rawItem in serverData) {
        if (rawItem is! Map) {
          continue;
        }

        final Map<String, dynamic> item =
            Map<String, dynamic>.from(
          rawItem,
        );


        // ------------------------------------------------------
        // لو المحذوف وصل لأي سبب، لا نحفظه
        // ------------------------------------------------------

        if (item['is_deleted'] == true) {
          continue;
        }


        final String branchCode =
            item['branch_code']
                    ?.toString() ??
                '1';

        final String serial =
            item['serial']?.toString() ?? '';


        if (serial.isEmpty) {
          continue;
        }


        final String key =
            "branch_${branchCode}_$serial";


        await _transactionBox.put(
          key,
          item,
        );
      }


      // --------------------------------------------------------
      // تحديث الأرصدة
      // --------------------------------------------------------

      await getDailySummaryLocal(
        companyCode,
      );


      print(
        "✅ تم جلب ${serverData.length} يومية "
        "من السيرفر وتخزينها محلياً",
      );


      return serverData;
    } catch (e) {
      print(
        "❌ فشل جلب جميع اليوميات: $e",
      );

      rethrow;
    }
  }


  // ============================================================
  // 3. المزامنة التزايدية
  //
  // lastSync موجود
  //      ↓
  // changes فقط
  //
  // delete
  //      ↓
  // حذف من Hive
  //
  // update / insert
  //      ↓
  // تحديث Hive
  // ============================================================

  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    final prefs =
        await SharedPreferences.getInstance();

    final String lastSyncKey =
        '${ApiConstants.LAST_SYNC_DAILY}$companyCode';

    final String? lastSyncValue =
        lastSync ??
        prefs.getString(
          lastSyncKey,
        );


    // ==========================================================
    // لا يوجد lastSync
    // ==========================================================

    if (lastSyncValue == null ||
        lastSyncValue.isEmpty) {
      print(
        '📥 لا يوجد lastSync لليوميات، '
        'جاري التحميل الكامل...',
      );

      await syncAllTransactions(
        companyCode,
      );

      await prefs.setString(
        lastSyncKey,
        DateTime.now()
            .toUtc()
            .toIso8601String(),
      );

      return;
    }


    try {
      // --------------------------------------------------------
      // وقت بداية المزامنة
      //
      // نستخدمه كحد أعلى للتحديثات التي نعتبرها مكتملة.
      // أي تغيير يحصل بعده سيظهر في المرة القادمة.
      // --------------------------------------------------------

      final DateTime syncStartedAt =
          DateTime.now().toUtc();


      // --------------------------------------------------------
      // آخر وقت مزامنة
      //
      // Backend يستقبل UTC بدون timezone داخل SQL.
      // --------------------------------------------------------

      DateTime sinceDt = DateTime.parse(lastSyncValue).toUtc();

sinceDt = sinceDt.subtract(
  const Duration(minutes: 1),
);

final String effectiveSince =
    sinceDt.toIso8601String();


      print(
        '📡 اليوميات: جلب التغييرات منذ '
        '$effectiveSince',
      );


      // --------------------------------------------------------
      // Request
      // --------------------------------------------------------

      final response = await http.get(
        Uri.parse(
          '$baseUrl/transactions/changes/'
          '$companyCode?since=$effectiveSince',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل مزامنة اليوميات. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      // --------------------------------------------------------
      // Decode
      // --------------------------------------------------------

      final List<dynamic> changes =
          jsonDecode(response.body);


      // --------------------------------------------------------
      // تطبيق التغييرات
      // --------------------------------------------------------

      for (final rawItem in changes) {
        if (rawItem is! Map) {
          continue;
        }


        final Map<String, dynamic> map =
            Map<String, dynamic>.from(
          rawItem,
        );


        final String action =
            map['action']
                    ?.toString() ??
                'update';


        final String branchCode =
            map['branch_code']
                    ?.toString() ??
                '1';


        final String? serial =
            map['serial']?.toString();


        if (serial == null ||
            serial.isEmpty) {
          throw Exception(
            'تحديث يومية بدون serial',
          );
        }


        final String key =
            'branch_${branchCode}_$serial';


        // ======================================================
        // DELETE
        // ======================================================

        if (action == 'delete' ||
            map['is_deleted'] == true) {
          await _transactionBox.delete(
            key,
          );

          print(
            '🗑️ تم حذف اليومية [$key] من Hive',
          );

          continue;
        }


        // ======================================================
        // INSERT / UPDATE
        // ======================================================

        map.remove('action');


        // لا نحتاج حفظ is_deleted=false
        // لكن تركه مش مشكلة.
        // نخليه لضمان وضوح حالة السجل محلياً.
        map['is_deleted'] = false;


        await _transactionBox.put(
          key,
          map,
        );


        print(
          '✅ تم تحديث اليومية [$key] في Hive',
        );
      }


      // --------------------------------------------------------
      // تحديث الأرصدة
      // --------------------------------------------------------

      await getDailySummaryLocal(
        companyCode,
      );


      // --------------------------------------------------------
      // تحديث lastSync فقط بعد نجاح العملية كاملة
      // --------------------------------------------------------

      await prefs.setString(
        lastSyncKey,
        syncStartedAt
            .toIso8601String(),
      );


      print(
        '✅ تمت مزامنة '
        '${changes.length} تحديث لليوميات',
      );
    } catch (e) {
      print(
        '❌ فشل مزامنة اليوميات: $e',
      );

      // مهم:
      // لا نغير lastSync عند الفشل.
      rethrow;
    }
  }


  // ============================================================
  // 4. حفظ / تعديل حركة
  // ============================================================

  Future<Map<String, dynamic>> saveTransaction({
    required String companyCode,
    required int serial,
    required String treasury,
    required double amount,
    required String statement,
    required String category,
    required String date,
    required String type,
    String? employee,
    required String branchCode,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(
          '$baseUrl/transactions/save',
        ),
        headers: {
          'Content-Type':
              'application/json',
        },
        body: jsonEncode({
          'company_code':
              companyCode,

          'serial':
              serial,

          'treasury':
              treasury,

          'amount':
              amount,

          'statement':
              statement,

          'category':
              category,

          'date':
              date,

          'type':
              type,

          'employee':
              employee ??
              "غير محدد",

          'branch_code':
              branchCode,
        }),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final Map<String, dynamic> result =
          jsonDecode(
        response.body,
      );


      if (result['status'] != 'success') {
        throw Exception(
          result['message'] ??
              'فشل حفظ الحركة',
        );
      }


      final int assignedSerial =
          (result['serial'] as num?)?.toInt() ??
              serial;


      // --------------------------------------------------------
      // بيانات محلية
      // --------------------------------------------------------

      final Map<String, dynamic>
          transactionData = {
        'company_code':
            companyCode,

        'serial':
            assignedSerial,

        'treasury':
            treasury,

        'amount':
            amount,

        'statement':
            statement,

        'category':
            category,

        'date':
            date,

        'type':
            type,

        'employee':
            employee ??
            "غير محدد",

        'branch_code':
            branchCode,

        'is_deleted':
            false,
      };


      final String uniqueId =
          "branch_${branchCode}_$assignedSerial";


      print(
        "🚀 Sending to server: "
        "company_code=$companyCode, "
        "branch_code=$branchCode",
      );


      // --------------------------------------------------------
      // تحديث محلي فوري
      // --------------------------------------------------------

      await _transactionBox.put(
        uniqueId,
        transactionData,
      );


      return {
        "success": true,
        "serial": assignedSerial,
      };
    } catch (e) {
      throw Exception(
        'فشل عملية الحفظ: $e',
      );
    }
  }


  // ============================================================
  // 5. مزامنة قديمة حسب Serial
  //
  // للتوافق مع أي كود قديم.
  // ============================================================

  Future<void> syncCacheFromServer(
    String companyCode,
    int fromSerial,
  ) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/transactions/updates/'
          '$companyCode/$fromSerial',
        ),
      );


      if (response.statusCode != 200) {
        return;
      }


      final List<dynamic> updates =
          jsonDecode(
        response.body,
      );


      for (final rawItem in updates) {
        if (rawItem is! Map) {
          continue;
        }


        final Map<String, dynamic> item =
            Map<String, dynamic>.from(
          rawItem,
        );


        if (!item.containsKey('serial')) {
          continue;
        }


        // ------------------------------------------------------
        // المحذوف
        // ------------------------------------------------------

        if (item['is_deleted'] == true ||
            item['action'] == 'delete') {
          final String bCode =
              item['branch_code']
                      ?.toString() ??
                  "1";

          final String serial =
              item['serial']
                  .toString();

          await _transactionBox.delete(
            "branch_${bCode}_$serial",
          );

          continue;
        }


        // ------------------------------------------------------
        // العادي
        // ------------------------------------------------------

        final String bCode =
            item['branch_code']
                    ?.toString() ??
                "1";


        await _transactionBox.put(
          "branch_${bCode}_${item['serial']}",
          item,
        );
      }
    } catch (e) {
      print(
        "⚠️ خطأ في المزامنة الخلفية: $e",
      );
    }
  }


  // ============================================================
  // 6. جلب التاريخ
  //
  // Hive أولاً
  // ثم السيرفر عند الحاجة
  // ============================================================

  Future<List<dynamic>> getTransactionsHistory(
    String companyCode,
    String startDate,
    String endDate, {
    String? branchCode,
  }) async {
    try {
      List<dynamic> resultData =
          [];


      // --------------------------------------------------------
      // قراءة من Hive
      // --------------------------------------------------------

      if (_transactionBox.isNotEmpty) {
        final List<dynamic> localData =
            _transactionBox.values
                .where(
                  (tx) {
                    if (tx is! Map) {
                      return false;
                    }

                    if (tx['company_code'] !=
                        companyCode) {
                      return false;
                    }

                    if (tx['is_deleted'] ==
                        true) {
                      return false;
                    }

                    final String txDate =
                        tx['date']
                                ?.toString() ??
                            '';

                    return txDate
                                .compareTo(
                                  startDate,
                                ) >=
                            0 &&
                        txDate
                                .compareTo(
                                  endDate,
                                ) <=
                            0;
                  },
                )
                .toList();


        if (localData.isNotEmpty) {
          resultData =
              localData;
        }
      }


      // --------------------------------------------------------
      // لو مفيش محلي
      // نجيب من السيرفر
      // --------------------------------------------------------

      if (resultData.isEmpty) {
        final response =
            await http.get(
          Uri.parse(
            '$baseUrl/transactions/list/'
            '$companyCode'
            '?start_date=$startDate'
            '&end_date=$endDate',
          ),
        );


        if (response.statusCode != 200) {
          throw Exception(
            'خطأ من السيرفر: '
            '${response.statusCode}',
          );
        }


        final List<dynamic>
            serverData =
            jsonDecode(
          response.body,
        );


        for (final rawItem
            in serverData) {
          if (rawItem is! Map) {
            continue;
          }


          final Map<String, dynamic>
              item =
              Map<String, dynamic>.from(
            rawItem,
          );


          if (item['is_deleted'] ==
              true) {
            continue;
          }


          final String bCode =
              item['branch_code']
                      ?.toString() ??
                  "1";


          final String serial =
              item['serial']
                      ?.toString() ??
                  '';


          if (serial.isEmpty) {
            continue;
          }


          await _transactionBox.put(
            "branch_${bCode}_$serial",
            item,
          );
        }


        resultData =
            serverData
                .where(
                  (item) =>
                      item is Map &&
                      item['is_deleted'] != true,
                )
                .toList();
      }


      // --------------------------------------------------------
      // فلترة الفرع
      // --------------------------------------------------------

      if (branchCode != null &&
          ![
            'الكل',
            'كل الفروع',
            'all',
            '',
          ].contains(branchCode)) {
        resultData =
            resultData
                .where(
                  (tx) =>
                      tx is Map &&
                      tx['branch_code']
                              ?.toString() ==
                          branchCode,
                )
                .toList();
      }


      return resultData;
    } catch (e) {
      // --------------------------------------------------------
      // Offline fallback
      // --------------------------------------------------------

      List<dynamic> fallbackData =
          _transactionBox.values
              .where(
                (tx) {
                  if (tx is! Map) {
                    return false;
                  }

                  if (tx['company_code'] !=
                      companyCode) {
                    return false;
                  }

                  if (tx['is_deleted'] ==
                      true) {
                    return false;
                  }

                  final String txDate =
                      tx['date']
                              ?.toString() ??
                          '';

                  return txDate
                              .compareTo(
                                startDate,
                              ) >=
                          0 &&
                      txDate
                              .compareTo(
                                endDate,
                              ) <=
                          0;
                },
              )
              .toList();


      if (branchCode != null &&
          ![
            'الكل',
            'كل الفروع',
            'all',
            '',
          ].contains(branchCode)) {
        fallbackData =
            fallbackData
                .where(
                  (tx) =>
                      tx is Map &&
                      tx['branch_code']
                              ?.toString() ==
                          branchCode,
                )
                .toList();
      }


      return fallbackData;
    }
  }


  // ============================================================
  // 7. حذف حركة
  // ============================================================

  Future<void> deleteTransaction(
    String companyCode,
    int serial,
    String branchCode,
  ) async {
    try {
      final response =
          await http.delete(
        Uri.parse(
          '$baseUrl/transactions/delete/'
          '$companyCode/'
          '$branchCode/'
          '$serial',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل حذف الحركة من السيرفر. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      // --------------------------------------------------------
      // السيرفر عمل Soft Delete بنجاح
      // نحذف محليًا فورًا
      // --------------------------------------------------------

      final String docId =
          "branch_${branchCode}_$serial";


      await _transactionBox.delete(
        docId,
      );


      // --------------------------------------------------------
      // تحديث الأرصدة
      // --------------------------------------------------------

      await getDailySummaryLocal(
        companyCode,
      );
    } catch (e) {
      throw Exception(
        'خطأ أثناء الحذف: $e',
      );
    }
  }


  // ============================================================
  // 8. آخر Serial محلي
  // ============================================================

  int getLastLocalSerial(
    String companyCode,
  ) {
    final List<dynamic> localTx =
        _transactionBox.values
            .where(
              (e) =>
                  e is Map &&
                  e['company_code'] ==
                      companyCode &&
                  e['is_deleted'] != true,
            )
            .toList();


    if (localTx.isEmpty) {
      return 0;
    }


    localTx.sort(
      (a, b) {
        final int aSerial =
            int.tryParse(
                  a['serial']
                          ?.toString() ??
                      '0',
                ) ??
                0;

        final int bSerial =
            int.tryParse(
                  b['serial']
                          ?.toString() ??
                      '0',
                ) ??
                0;

        return aSerial.compareTo(
          bSerial,
        );
      },
    );


    return int.tryParse(
          localTx.last['serial']
              ?.toString() ??
              '0',
        ) ??
        0;
  }


  // ============================================================
  // 9. Full Sync
  // ============================================================

  Future<void> syncAllTransactions(
    String companyCode,
  ) async {
    try {
      final String startDate =
          '2020-01-01';

      final String endDate =
          '2100-12-31';


      final response =
          await http.get(
        Uri.parse(
          '$baseUrl/transactions/list/'
          '$companyCode'
          '?start_date=$startDate'
          '&end_date=$endDate',
        ),
      );


      if (response.statusCode != 200) {
        throw Exception(
          'فشل جلب البيانات من السيرفر. '
          'HTTP ${response.statusCode}: '
          '${response.body}',
        );
      }


      final List<dynamic>
          serverData =
          jsonDecode(
        response.body,
      );


      // --------------------------------------------------------
      // تخزين البيانات
      // --------------------------------------------------------

      for (final rawItem
          in serverData) {
        if (rawItem is! Map) {
          continue;
        }


        final Map<String, dynamic>
            item =
            Map<String, dynamic>.from(
          rawItem,
        );


        if (item['is_deleted'] ==
            true) {
          continue;
        }


        final String bCode =
            item['branch_code']
                    ?.toString() ??
                '1';


        final String serial =
            item['serial']
                    ?.toString() ??
                '';


        if (serial.isEmpty) {
          continue;
        }


        await _transactionBox.put(
          "branch_${bCode}_$serial",
          item,
        );
      }


      // --------------------------------------------------------
      // تحديث الأرصدة
      // --------------------------------------------------------

      await getDailySummaryLocal(
        companyCode,
      );


      print(
        "✅ تم مزامنة جميع الحركات "
        "من السيرفر بنجاح "
        "(عدد: ${serverData.length})",
      );
    } catch (e) {
      print(
        "❌ خطأ في مزامنة جميع الحركات: $e",
      );

      rethrow;
    }
  }
}