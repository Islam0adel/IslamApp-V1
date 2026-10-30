// lib/services/websocket_sync_service.dart

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'daily_service.dart';
import '../core/constants.dart';
import 'notifications_service.dart';


class WebSocketSyncService {
  // ============================================================
  // WebSocket
  // ============================================================

  WebSocketChannel? _channel;

  String? _companyCode;
  String? _baseUrl;

  bool _isConnected = false;
  bool _isConnecting = false;

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

  
Future<void> connect(String companyCode) async {
  if (_isConnected || _isConnecting) {
    print("✅ WebSocket متصل أو جاري الاتصال بالفعل");
    return;
  }

  _isConnecting = true;
  _manualDisconnect = false;
  _companyCode = companyCode;
  _baseUrl = ApiConstants.baseUrl;

  try {
    final user = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdToken();

    if (token == null || token.isEmpty) {
      print('⚠️ تم إيقاف WebSocket لعدم وجود Firebase ID token صالح');
      _isConnected = false;
      _isConnecting = false;
      return;
    }

    final String url =
        '${ApiConstants.baseUrl}/sync/ws/$companyCode';

    final Uri wsUri = Uri.parse(
      url
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://'),
    );

    print('🔌 محاولة الاتصال بـ WebSocket الموثق للشركة: $companyCode');

    final channel = WebSocketChannel.connect(wsUri);
    _channel = channel;

    // انتظر اكتمال فتح قناة WebSocket قبل إرسال بيانات المصادقة.
    await channel.ready;

    // لو تم إلغاء الاتصال أثناء انتظار فتح القناة، لا تكمل.
    if (_manualDisconnect || !identical(_channel, channel)) {
      await channel.sink.close();
      return;
    }

    // استمع للرسائل قبل إرسال التوكن لتجنب فقد تأكيد المصادقة.
    channel.stream.listen(
      (message) {
        if (!identical(_channel, channel)) return;
        _handleMessage(message);
      },
      onError: (error) {
        if (!identical(_channel, channel)) return;

        print("❌ خطأ في WebSocket: $error");

        _isConnected = false;
        _isConnecting = false;
        _channel = null;

        _scheduleReconnect();
      },
      onDone: () {
        if (!identical(_channel, channel)) return;

        print("🔌 تم قطع اتصال WebSocket");

        _isConnected = false;
        _isConnecting = false;
        _channel = null;

        if (_manualDisconnect) {
          print("ℹ️ الاتصال تم قطعه يدويًا، لن يتم إعادة الاتصال");
          return;
        }

        _scheduleReconnect();
      },
      cancelOnError: true,
    );

    // إرسال التوكن كأول رسالة دون وضعه في عنوان الاتصال.
    channel.sink.add(
      jsonEncode({
        'type': 'auth',
        'token': token,
      }),
    );

    // لا نضع _isConnected = true هنا.
    // يصبح الاتصال جاهزًا فقط عند استلام auth_success.
    print("⏳ تم إرسال بيانات المصادقة، في انتظار تأكيد السيرفر");
  } catch (e) {
    _isConnected = false;
    _isConnecting = false;

    print("❌ فشل الاتصال بـ WebSocket: $e");

    if (!_manualDisconnect) {
      _scheduleReconnect();
    }
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
    _isConnecting = false;


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

  
void _handleMessage(dynamic message) {
  try {
    final dynamic decoded = jsonDecode(message);

    if (decoded is! Map) {
      print("⚠️ رسالة WebSocket غير صحيحة");
      return;
    }

    final Map<String, dynamic> data =
        Map<String, dynamic>.from(decoded);

    final String type = data['type']?.toString() ?? '';

    // تأكيد نجاح المصادقة قبل اعتبار WebSocket متصلًا.
    if (type == 'auth_success') {
      final String confirmedCompany =
          data['company_code']?.toString() ?? '';

      if (confirmedCompany != _companyCode) {
        print("⚠️ تأكيد WebSocket لا يطابق الشركة الحالية");
        _isConnected = false;
        _isConnecting = false;
        _scheduleReconnect();
        return;
      }

      final bool wasConnected = _isConnected;

      _isConnected = true;
      _isConnecting = false;

      print("✅ تم تأكيد مصادقة WebSocket للشركة: $confirmedCompany");

      unawaited(
        NotificationsService.instance.refreshUnreadFromServer(
          companyCode: confirmedCompany,
        ),
      );

      if (!wasConnected) {
        final callback = onConnected;
        if (callback != null) {
          print("🔄 إبلاغ Sync Manager بنجاح اتصال WebSocket");
          callback();
        }
      }

      return;
    }

    final String action = data['action']?.toString() ?? 'update';
    final dynamic rawPayload = data['data'];

    print("📩 استقبال رسالة: type=$type, action=$action");

    if (rawPayload is! Map) {
      print("⚠️ بيانات الرسالة غير صحيحة");
      return;
    }

    final Map<String, dynamic> payload =
        Map<String, dynamic>.from(rawPayload);

    // حفظ الإشعار من نفس حدث المزامنة؛ لا يوجد polling مستقل للإشعارات.
    unawaited(_processNotificationEvent(data));

    // --------------------------------------------------------
    // لو is_deleted=true اعتبرها delete حتى لو
    // action لم يصل بالشكل المتوقع.
    // --------------------------------------------------------

    final bool isDelete =
        action == 'delete' || payload['is_deleted'] == true;

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
          isDelete ? 'delete' : action,
        );
        break;

      // ======================================================
      // الجرد
      // ======================================================

      case 'inventory':
        unawaited(
          _updateInventoryBox(
            payload,
            isDelete ? 'delete' : action,
          ),
        );
        break;

      // ======================================================
      // الموردين
      // ======================================================

      case 'supplier':
        unawaited(
          _updateSupplierBox(
            payload,
            isDelete ? 'delete' : action,
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
            isDelete ? 'delete' : action,
          ),
        );
        break;

      default:
        print("⚠️ نوع غير معروف: $type");
    }
  } catch (e) {
    print("⚠️ خطأ في معالجة رسالة WebSocket: $e");
  }
}



  Future<void> _processNotificationEvent(Map<String, dynamic> event) async {
    // الحدث الحالي يُحفظ محليًا فورًا؛ سجل Neon يُحدّث عند فتح الصفحة أو إعادة الاتصال فقط.
    await NotificationsService.instance.handleSyncEvent(event);
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
  //
  // ✅ تم تعديل المنطق لضمان حذف النسخة القديمة
  // من جميع المفاتيح (حتى لو تغير التاريخ/الفرع/المخزن)
  // ============================================================

  Future<void> _updateInventoryBox(
    Map<String, dynamic> payload,
    String action,
  ) async {
    final String? docId =
        payload['doc_id']?.toString();

    if (docId == null ||
        docId.isEmpty) {
      print(
        "⚠️ لا يوجد doc_id في رسالة الجرد",
      );
      return;
    }

    // ========================================================
    // الخطوة 1: حذف doc_id من جميع المفاتيح
    // ========================================================

    final keys = _inventoryBox.keys.toList();

    for (final oldKey in keys) {
      final raw = _inventoryBox.get(oldKey);

      if (raw is! List) {
        continue;
      }

      final List<Map<String, dynamic>> updatedList = [];
      bool found = false;

      for (final value in raw) {
        if (value is! Map) {
          continue;
        }

        final map = Map<String, dynamic>.from(value);

        if (map.isEmpty) {
          continue;
        }

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
        await _inventoryBox.delete(oldKey);
      } else {
        await _inventoryBox.put(oldKey, updatedList);
      }
    }

    // ========================================================
    // الخطوة 2: لو حذف، توقف هنا
    // ========================================================

    if (action == 'delete' ||
        payload['is_deleted'] == true) {
      print(
        "🗑️ تم حذف الجرد [$docId] من Hive",
      );

      return;
    }

    // ========================================================
    // الخطوة 3: إضافة في المفتاح الجديد
    // ========================================================

    final String companyCode =
        payload['company_code']?.toString() ?? '';
    final String branchCode =
        payload['branch_code']?.toString() ?? '';
    final String storeCode =
        payload['store_code']?.toString() ?? '';
    final String date =
        payload['date']?.toString() ?? '';

    if (companyCode.isEmpty ||
        branchCode.isEmpty ||
        storeCode.isEmpty ||
        date.isEmpty) {
      print(
        "⚠️ بيانات المفتاح ناقصة للجرد [$docId]",
      );
      return;
    }

    final String newKey =
        "${companyCode}_${branchCode}_${storeCode}_$date";

    List<Map<String, dynamic>> list = [];

    final raw = _inventoryBox.get(newKey);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(
            (e) => Map<String, dynamic>.from(e),
          )
          .where(
            (e) => e['is_deleted'] != true,
          )
          .toList();
    }

    // منع التكرار (مرة أخرى للتأكيد)
    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() == docId,
    );

    payload['is_deleted'] = false;

    list.add(
      Map<String, dynamic>.from(payload),
    );

    await _inventoryBox.put(newKey, list);

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
  // ✅ تم تعديل المنطق لضمان حذف النسخة القديمة
  // من جميع المفاتيح (حتى لو تغير التاريخ/الفرع)
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

    // ========================================================
    // الخطوة 1: حذف doc_id من جميع المفاتيح
    // ========================================================

    final keys = _settlementBox.keys.toList();

    for (final oldKey in keys) {
      final raw = _settlementBox.get(oldKey);

      if (raw is! List) {
        continue;
      }

      final List<Map<String, dynamic>> updatedList = [];
      bool found = false;

      for (final value in raw) {
        if (value is! Map) {
          continue;
        }

        final map = Map<String, dynamic>.from(value);

        if (map.isEmpty) {
          continue;
        }

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
        await _settlementBox.delete(oldKey);
      } else {
        await _settlementBox.put(oldKey, updatedList);
      }
    }

    // ========================================================
    // الخطوة 2: لو حذف، توقف هنا
    // ========================================================

    if (action == 'delete' ||
        payload['is_deleted'] == true) {
      print(
        "🗑️ تم حذف التسوية [$docId] من Hive",
      );

      return;
    }

    // ========================================================
    // الخطوة 3: إضافة في المفتاح الجديد
    // ========================================================

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
        "⚠️ بيانات المفتاح ناقصة للتسوية [$docId]",
      );
      return;
    }

    final String newKey =
        "${companyCode}_${branchCode}_$date";

    List<Map<String, dynamic>> list = [];

    final raw = _settlementBox.get(newKey);

    if (raw is List) {
      list = raw
          .whereType<Map>()
          .map(
            (e) => Map<String, dynamic>.from(e),
          )
          .where(
            (e) => e['is_deleted'] != true,
          )
          .toList();
    }

    // منع التكرار (مرة أخرى للتأكيد)
    list.removeWhere(
      (item) =>
          item['doc_id']?.toString() == docId,
    );

    payload['is_deleted'] = false;

    list.add(
      Map<String, dynamic>.from(payload),
    );

    await _settlementBox.put(newKey, list);

    print(
      "✅ تم تحديث التسوية [$docId] في Hive",
    );
  }
}