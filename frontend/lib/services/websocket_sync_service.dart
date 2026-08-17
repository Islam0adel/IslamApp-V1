// lib/services/websocket_sync_service.dart

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'daily_service.dart';
import '../core/constants.dart';


class WebSocketSyncService {
  // ============================================================
  // WebSocket
  // ============================================================

  WebSocketChannel? _channel;

  String? _companyCode;
  String? _baseUrl;

  bool _isConnected = false;

  // يمنع جدولة أكثر من محاولة reconnect في نفس الوقت
  bool _reconnectScheduled = false;

  // يفرق بين:
  // 1) disconnect يدوي من البرنامج
  // 2) انقطاع طبيعي يحتاج reconnect
  bool _manualDisconnect = false;

  Timer? _dailySummaryTimer;

  // ============================================================
  // Callback
  // ============================================================

  /// يتم استدعاؤها عند فتح WebSocket أو إعادة فتحه.
  ///
  /// لا يتم تنفيذ Sync هنا.
  /// main.dart هو المسؤول عن syncAllDataIfNeeded().
  void Function()? onConnected;


  // ============================================================
  // Hive Boxes
  // ============================================================

  final Box _dailyBox =
      Hive.box('daily_transactions_box');

  final Box _codingBox =
      Hive.box('coding_box');

  final Box _inventoryBox =
      Hive.box('inventory_box');

  final Box _supplierBox =
      Hive.box('supplier_box');

  final Box _settlementBox =
      Hive.box('supplier_settlement_box');


  // ============================================================
  // 1. الاتصال
  // ============================================================

  void connect(String companyCode) {
    // ----------------------------------------------------------
    // منع فتح اتصال جديد لو الحالي شغال
    // ----------------------------------------------------------

    if (_isConnected) {
      print(
        "✅ WebSocket متصل بالفعل، تجاهل الاتصال الجديد",
      );
      return;
    }


    // ----------------------------------------------------------
    // محاولة اتصال جديدة
    // ----------------------------------------------------------

    _manualDisconnect = false;

    _companyCode = companyCode;
    _baseUrl = ApiConstants.baseUrl;


    final String url =
        '${ApiConstants.baseUrl}/sync/ws/$companyCode';


    final String wsUrl = url
        .replaceFirst(
          'http://',
          'ws://',
        )
        .replaceFirst(
          'https://',
          'wss://',
        );


    print(
      "🔌 محاولة الاتصال بـ WebSocket: $wsUrl",
    );


    try {
      _channel =
          WebSocketChannel.connect(
        Uri.parse(wsUrl),
      );


      _isConnected = true;


      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },

        // ------------------------------------------------------
        // Error
        // ------------------------------------------------------

        onError: (error) {
          print(
            "❌ خطأ في WebSocket: $error",
          );

          _isConnected = false;

          _scheduleReconnect();
        },


        // ------------------------------------------------------
        // Done
        // ------------------------------------------------------

        onDone: () {
          print(
            "🔌 تم قطع اتصال WebSocket",
          );

          _isConnected = false;

          _channel = null;


          // لو disconnect يدوي
          // لا تعمل reconnect
          if (_manualDisconnect) {
            print(
              "ℹ️ الاتصال تم قطعه يدويًا، "
              "لن يتم إعادة الاتصال",
            );

            return;
          }


          _scheduleReconnect();
        },

        cancelOnError: true,
      );


      print(
        "✅ تم فتح قناة WebSocket",
      );


      // --------------------------------------------------------
      // إبلاغ Global Sync
      // --------------------------------------------------------

      final callback =
          onConnected;


      if (callback != null) {
        print(
          "🔄 إبلاغ Sync Manager بأن WebSocket اتصل...",
        );

        callback();
      }
    } catch (e) {
      _isConnected = false;

      print(
        "❌ فشل الاتصال بـ WebSocket: $e",
      );

      _scheduleReconnect();
    }
  }


  // ============================================================
  // 2. إعادة الاتصال
  // ============================================================

  void _scheduleReconnect() {
    // ----------------------------------------------------------
    // لا توجد شركة
    // ----------------------------------------------------------

    if (_companyCode == null ||
        _baseUrl == null) {
      return;
    }


    // ----------------------------------------------------------
    // قطع يدوي
    // ----------------------------------------------------------

    if (_manualDisconnect) {
      return;
    }


    // ----------------------------------------------------------
    // يوجد reconnect مجدول
    // ----------------------------------------------------------

    if (_reconnectScheduled) {
      return;
    }


    _reconnectScheduled = true;


    print(
      "⏳ سيتم إعادة الاتصال بـ WebSocket بعد 5 ثوانٍ...",
    );


    Future.delayed(
      const Duration(seconds: 5),
      () {
        _reconnectScheduled = false;


        // ------------------------------------------------------
        // لو رجع الاتصال
        // ------------------------------------------------------

        if (_isConnected) {
          return;
        }


        // ------------------------------------------------------
        // لو تم disconnect يدوي أثناء الانتظار
        // ------------------------------------------------------

        if (_manualDisconnect) {
          return;
        }


        final companyCode =
            _companyCode;


        if (companyCode == null) {
          return;
        }


        print(
          "🔄 محاولة إعادة الاتصال بـ WebSocket...",
        );


        connect(companyCode);
      },
    );
  }


  // ============================================================
  // 3. قطع الاتصال
  // ============================================================

  void disconnect() {
    _dailySummaryTimer?.cancel();
_dailySummaryTimer = null;
    print(
      "🔌 طلب قطع اتصال WebSocket",
    );


    // ----------------------------------------------------------
    // disconnect يدوي
    // ----------------------------------------------------------

    _manualDisconnect = true;


    // ----------------------------------------------------------
    // إلغاء reconnect
    // ----------------------------------------------------------

    _reconnectScheduled = false;

    _isConnected = false;


    // ----------------------------------------------------------
    // إغلاق Channel
    // ----------------------------------------------------------

    try {
      _channel?.sink.close();
    } catch (_) {}


    _channel = null;


    // ----------------------------------------------------------
    // تنظيف الحالة
    // ----------------------------------------------------------

    _companyCode = null;
    _baseUrl = null;


    print(
      "🔌 تم قطع اتصال WebSocket",
    );
  }


  // ============================================================
  // 4. حالة الاتصال
  // ============================================================

  bool get isConnected =>
      _isConnected;


  // ============================================================
  // 5. معالجة الرسائل
  // ============================================================

  void _handleMessage(
    dynamic message,
  ) {
    try {
      final dynamic decoded =
          jsonDecode(message);


      if (decoded is! Map) {
        print(
          "⚠️ رسالة WebSocket غير صحيحة",
        );
        return;
      }


      final Map<String, dynamic> data =
          Map<String, dynamic>.from(
        decoded,
      );


      final String type =
          data['type']
                  ?.toString() ??
              '';


      final String action =
          data['action']
                  ?.toString() ??
              'update';


      final dynamic rawPayload =
          data['data'];


      print(
        "📩 استقبال رسالة: "
        "type=$type, action=$action",
      );


      if (rawPayload is! Map) {
        print(
          "⚠️ بيانات الرسالة غير صحيحة",
        );
        return;
      }


      final Map<String, dynamic>
          payload =
          Map<String, dynamic>.from(
        rawPayload,
      );


      // --------------------------------------------------------
      // لو is_deleted=true اعتبرها delete حتى لو
      // action لم يصل بالشكل المتوقع.
      // --------------------------------------------------------

      final bool isDelete =
          action == 'delete' ||
          payload['is_deleted'] == true;


      switch (type) {

        // ======================================================
        // اليومية
        // ======================================================

        case 'transaction':
  unawaited(
    _updateTransactionBox(
      payload,
      isDelete ? 'delete' : action,
    ),
  );

  break;


        // ======================================================
        // التكويد
        // ======================================================

        case 'coding':
          _updateCodingBox(
            payload,
            isDelete
                ? 'delete'
                : action,
          );

          break;


        // ======================================================
        // الجرد
        // ======================================================

        case 'inventory':
          _updateInventoryBox(
            payload,
            isDelete
                ? 'delete'
                : action,
          );

          break;


        // ======================================================
        // الموردين
        // ======================================================

        case 'supplier':
          unawaited(
            _updateSupplierBox(
              payload,
              isDelete
                  ? 'delete'
                  : action,
            ),
          );

          break;


        // ======================================================
        // التسويات
        // ======================================================

        case 'settlement':
          unawaited(
            _updateSettlementBox(
              payload,
              isDelete
                  ? 'delete'
                  : action,
            ),
          );

          break;


        default:
          print(
            "⚠️ نوع غير معروف: $type",
          );
      }
    } catch (e) {
      print(
        "⚠️ خطأ في معالجة رسالة WebSocket: $e",
      );
    }
  }


  // ============================================================
  // 6. تحديث اليومية
  // ============================================================

  Future<void> _updateTransactionBox(
  Map<String, dynamic> payload,
  String action,
) async {
  final String branchCode =
      payload['branch_code']?.toString() ?? '1';

  final String? serial =
      payload['serial']?.toString();

  if (serial == null || serial.isEmpty) {
    print("⚠️ لا يوجد serial في رسالة اليومية");
    return;
  }

  final String id =
      "branch_${branchCode}_$serial";

  try {
    if (action == 'delete') {
      await _dailyBox.delete(id);

      print(
        "🗑️ تم حذف اليومية [$id] من Hive",
      );
    } else {
      payload['is_deleted'] = false;

      await _dailyBox.put(
        id,
        payload,
      );

      print(
        "✅ تم تحديث اليومية [$id] في Hive",
      );
    }

    // تحديث الرصيد بعد اكتمال تعديل Hive فعليًا
    _scheduleDailySummaryRefresh(
  branchCode: branchCode,
);
  } catch (e) {
    print(
      "❌ خطأ في تحديث اليومية [$id]: $e",
    );
  }
}


  // ============================================================
  // تحديث أرصدة اليومية
  //
  // حماية من عدم وجود companyCode
  // ============================================================


void _scheduleDailySummaryRefresh({
  String? branchCode,
}) {
  _dailySummaryTimer?.cancel();

  _dailySummaryTimer = Timer(
    const Duration(milliseconds: 150),
    () async {
      final companyCode = _companyCode;

      if (companyCode == null) {
        return;
      }

      try {
        await DailyService().getDailySummaryLocal(
          companyCode,
          branchCode: branchCode,
        );

        print(
          "✅ تم تحديث رصيد اليومية"
          "${branchCode != null ? ' للفرع $branchCode' : ' لكل الفروع'}"
          " بعد WebSocket",
        );
      } catch (e) {
        print(
          "❌ خطأ في تحديث أرصدة اليومية: $e",
        );
      }
    },
  );
}


  // ============================================================
  // 7. تحديث التكويد
  // ============================================================

  void _updateCodingBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode =
        payload['company_code'];


    final dynamic category =
        payload['category'];


    final dynamic code =
        payload['code'];


    if (companyCode == null ||
        category == null ||
        code == null) {
      print(
        "⚠️ بيانات تكويد ناقصة",
      );
      return;
    }


    final String key =
        "${companyCode}_$category";


    List<Map<String, dynamic>>
        list = [];


    if (_codingBox.containsKey(key)) {
      final raw =
          _codingBox.get(key);


      if (raw is List) {
        list = raw
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


    // ----------------------------------------------------------
    // إزالة النسخة القديمة
    // ----------------------------------------------------------

    list.removeWhere(
      (item) =>
          item['code']?.toString() ==
          code.toString(),
    );


    // ----------------------------------------------------------
    // DELETE
    // ----------------------------------------------------------

    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(
          _codingBox.delete(key),
        );
      } else {
        unawaited(
          _codingBox.put(
            key,
            list,
          ),
        );
      }


      print(
        "🗑️ تم حذف التكويد "
        "[$category/$code] من Hive",
      );

      return;
    }


    // ----------------------------------------------------------
    // INSERT / UPDATE
    // ----------------------------------------------------------

    payload['is_deleted'] =
        false;


    list.add(
      payload,
    );


    list.sort(
      (a, b) {
        final int aCode =
            int.tryParse(
                  a['code']?.toString() ??
                      '0',
                ) ??
                0;


        final int bCode =
            int.tryParse(
                  b['code']?.toString() ??
                      '0',
                ) ??
                0;


        return aCode.compareTo(
          bCode,
        );
      },
    );


    unawaited(
      _codingBox.put(
        key,
        list,
      ),
    );


    print(
      "✅ تم تحديث التكويد "
      "[$category/$code]",
    );
  }


  // ============================================================
  // 8. تحديث الجرد
  // ============================================================

  void _updateInventoryBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final String? docId =
        payload['doc_id']?.toString();


    if (docId == null ||
        docId.isEmpty) {
      print(
        "⚠️ لا يوجد doc_id في رسالة الجرد",
      );
      return;
    }


    final String companyCode =
        payload['company_code']
                ?.toString() ??
            '';


    final String branchCode =
        payload['branch_code']
                ?.toString() ??
            '';


    final String storeCode =
        payload['store_code']
                ?.toString() ??
            '';


    final String date =
        payload['date']
                ?.toString() ??
            '';


    final String key =
        "${companyCode}_${branchCode}_${storeCode}_$date";


    List<Map<String, dynamic>>
        list = [];


    if (_inventoryBox.containsKey(key)) {
      final raw =
          _inventoryBox.get(key);


      if (raw is List) {
        list = raw
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


    // ----------------------------------------------------------
    // إزالة النسخة القديمة
    // ----------------------------------------------------------

    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() ==
          docId,
    );


    // ----------------------------------------------------------
    // DELETE
    // ----------------------------------------------------------

    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(
          _inventoryBox.delete(key),
        );
      } else {
        unawaited(
          _inventoryBox.put(
            key,
            list,
          ),
        );
      }


      print(
        "🗑️ تم حذف الجرد [$docId] من Hive",
      );

      return;
    }


    // ----------------------------------------------------------
    // INSERT / UPDATE
    // ----------------------------------------------------------

    payload['is_deleted'] =
        false;


    list.add(
      payload,
    );


    unawaited(
      _inventoryBox.put(
        key,
        list,
      ),
    );


    print(
      "✅ تم تحديث الجرد [$docId] في Hive",
    );
  }


  // ============================================================
  // 9. تحديث الموردين
  // ============================================================

  Future<void> _updateSupplierBox(
  Map<String, dynamic> payload,
  String action,
) async {
  final String? docId =
      payload['doc_id']?.toString();

  if (docId == null || docId.isEmpty) {
    print(
      '⚠️ لا يوجد doc_id في رسالة المورد',
    );
    return;
  }

  // ============================================================
  // 1. حذف النسخة القديمة من جميع مفاتيح supplier_box
  // ============================================================

  final keys =
      _supplierBox.keys.toList();

  for (final oldKey in keys) {
    final raw =
        _supplierBox.get(oldKey);

    if (raw is! List) {
      continue;
    }

    final List<Map<String, dynamic>> updatedList = [];

    bool found = false;

    for (final value in raw) {
      if (value is! Map) {
        continue;
      }

      final map =
          Map<String, dynamic>.from(
        value.map(
          (k, v) => MapEntry(
            k.toString(),
            v,
          ),
        ),
      );

      if (map['doc_id']?.toString() == docId) {
        found = true;
        continue;
      }

      if (map['is_deleted'] == true) {
        continue;
      }

      updatedList.add(map);
    }

    if (!found) {
      continue;
    }

    if (updatedList.isEmpty) {
      await _supplierBox.delete(oldKey);
    } else {
      await _supplierBox.put(
        oldKey,
        updatedList,
      );
    }
  }

  // ============================================================
  // 2. لو حذف → خلاص
  // ============================================================

  if (action == 'delete' ||
      payload['is_deleted'] == true) {
    print(
      '🗑️ تم حذف فاتورة المورد [$docId] من Hive',
    );

    return;
  }

  // ============================================================
  // 3. تجهيز المفتاح الجديد
  // ============================================================

  final String companyCode =
      payload['company_code']?.toString() ?? '';

  final String branchCode =
      payload['branch_code']?.toString() ?? '';

  final String date =
      payload['date']?.toString() ?? '';

  if (companyCode.isEmpty ||
      branchCode.isEmpty ||
      date.isEmpty) {
    print(
      '⚠️ بيانات المفتاح ناقصة للمورد [$docId]',
    );
    return;
  }

  final String newKey =
      '${companyCode}_${branchCode}_$date';

  // ============================================================
  // 4. قراءة البيانات الموجودة في المفتاح الجديد
  // ============================================================

  List<Map<String, dynamic>> list = [];

  final raw =
      _supplierBox.get(newKey);

  if (raw is List) {
    list = raw
        .whereType<Map>()
        .map(
          (e) => Map<String, dynamic>.from(
            e.map(
              (k, v) => MapEntry(
                k.toString(),
                v,
              ),
            ),
          ),
        )
        .where(
          (e) =>
              e.isNotEmpty &&
              e['is_deleted'] != true,
        )
        .toList();
  }

  // ============================================================
  // 5. منع التكرار
  // ============================================================

  list.removeWhere(
    (item) =>
        item['doc_id']?.toString() == docId,
  );

  // ============================================================
  // 6. إضافة النسخة الجديدة
  // ============================================================

  payload['is_deleted'] = false;

  list.add(
    Map<String, dynamic>.from(payload),
  );

  await _supplierBox.put(
    newKey,
    list,
  );

  print(
    '✅ تم تحديث فاتورة المورد [$docId] من المزامنة',
  );
}


  // ============================================================
  // 10. تحديث التسويات
  //
  // حاليًا احتفظنا بها كما هي للتوافق.
  // ============================================================

  Future<void> _updateSettlementBox(
    Map<String, dynamic> payload,
    String action,
  ) async {
    final String? docId =
        payload['doc_id']?.toString();


    if (docId == null ||
        docId.isEmpty) {
      print(
        "⚠️ لا يوجد doc_id في رسالة التسوية",
      );
      return;
    }


    final String companyCode =
        payload['company_code']
                ?.toString() ??
            '';


    final String branchCode =
        payload['branch_code']
                ?.toString() ??
            '';


    final String date =
        payload['date']
                ?.toString() ??
            '';


    final String key =
        "${companyCode}_${branchCode}_$date";


    List<Map<String, dynamic>>
        list = [];


    if (_settlementBox.containsKey(key)) {
      final raw =
          _settlementBox.get(key);


      if (raw is List) {
        list = raw
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


    // إزالة النسخة القديمة
    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() ==
          docId,
    );


    // DELETE
    if (action == 'delete') {
      if (list.isEmpty) {
        await _settlementBox.delete(
          key,
        );
      } else {
        await _settlementBox.put(
          key,
          list,
        );
      }


      print(
        "🗑️ تم حذف التسوية [$docId] من Hive",
      );

      return;
    }


    // INSERT / UPDATE
    payload['is_deleted'] =
        false;


    list.add(
      payload,
    );


    if (list.isEmpty) {
      await _settlementBox.delete(
        key,
      );
    } else {
      await _settlementBox.put(
        key,
        list,
      );
    }


    print(
      "✅ تم تحديث التسوية [$docId] في Hive",
    );
  }
}