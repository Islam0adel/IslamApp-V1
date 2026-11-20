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

  // ⭐ جديد: يتم استدعاؤها لما الاتصال يفشل (سيرفر واقع، DNS، timeout)
  void Function()? onConnectionFailed;

  // ⭐ يمنع إطلاق onConnectionFailed أكتر من مرة لنفس محاولة الاتصال
  bool _connectionFailedNotified = false;

  void _notifyConnectionFailed() {
    if (_connectionFailedNotified) return;
    _connectionFailedNotified = true;
    print('⚠️ WebSocket connection failed — notifying listeners');
    final cb = onConnectionFailed;
    if (cb != null) cb();
  }


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
      _notifyConnectionFailed();
      return;
    }

    final String url = '${ApiConstants.baseUrl}/sync/ws/$companyCode';
    final Uri wsUri = Uri.parse(
      url.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://'),
    );

    print('🔌 محاولة الاتصال بـ WebSocket الموثق للشركة: $companyCode');

    final channel = WebSocketChannel.connect(wsUri);
    _channel = channel;

    // ⭐⭐⭐ استمع للرسائل قبل ready — يمنع ضياع auth_success على الويب
    channel.stream.listen(
      (message) {
        if (!identical(_channel, channel)) return;
        print('🔔 WebSocket raw: $message');   // ← log تشخيصي
        _handleMessage(message);
      },
      onError: (error) {
        if (!identical(_channel, channel)) return;
        print("❌ خطأ في WebSocket: $error");
        _isConnected = false;
        _isConnecting = false;
        _channel = null;
        _notifyConnectionFailed();
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

    // انتظر فتح القناة (بعد listen — عشان ما تضيعش رسائل)
    await channel.ready;

    if (_manualDisconnect || !identical(_channel, channel)) {
      await channel.sink.close();
      return;
    }

    // إرسال auth
    channel.sink.add(
      jsonEncode({
        'type': 'auth',
        'token': token,
      }),
    );

    print("⏳ تم إرسال بيانات المصادقة، في انتظار تأكيد السيرفر");

    // ⭐ Timeout 15s — لو auth_success ما وصلش، أعد المحاولة
    Future.delayed(const Duration(seconds: 15), () {
      if (!_isConnected &&
          identical(_channel, channel) &&
          !_manualDisconnect) {
        print('⚠️ لم يتم استقبال auth_success بعد 15 ثانية — إعادة المحاولة');
        try {
          channel.sink.close();
        } catch (_) {}
        _channel = null;
        _isConnecting = false;
        _notifyConnectionFailed();
        _scheduleReconnect();
      }
    });
  } catch (e) {
    _isConnected = false;
    _isConnecting = false;

    print("❌ فشل الاتصال بـ WebSocket: $e");
    _notifyConnectionFailed();

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

    _connectionFailedNotified = false;


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
      _connectionFailedNotified = false;

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
      case 'sale':
        unawaited(_updateCommercialBox('sales_box', payload, isDelete));
        break;
      case 'sale_return':
        unawaited(_updateCommercialBox('sales_returns_box', payload, isDelete));
        break;
      case 'customer_payment':
        unawaited(_updateCommercialBox('customer_payments_box', payload, isDelete));
        break;
      case 'stock_transfer':
        unawaited(_updateCommercialBox('stock_transfers_box', payload, isDelete));
        break;
            // ======================================================
      // حضور HR
      // ======================================================

      case 'hr_attendance':
        _updateHRAttendanceBox(
          payload,
          isDelete ? 'delete' : action,
        );
        break;

      // ======================================================
      // إجازات HR
      // ======================================================

      case 'hr_vacation':
        _updateHRVacationBox(
          payload,
          isDelete ? 'delete' : action,
        );
        break;

            // ======================================================
      // تسويات HR
      // ======================================================

      case 'hr_adjustment':
        _updateHRAdjustmentBox(
          payload,
          isDelete ? 'delete' : action,
        );
        break;

      // ======================================================
      // إعدادات الموظف في HR (جديد — كان ناقص)
      // ======================================================

      case 'hr_employee_settings':
        _updateHREmployeeSettingsBox(
          payload,
          isDelete ? 'delete' : action,
        );
        break;

      // ======================================================
      // الموظفين
      // ======================================================

      case 'employee':
        _updateEmployeeBox(
          payload,
          isDelete ? 'delete' : action,
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
    if (event['suppress_notification'] == true) return;
    // الحدث الحالي يُحفظ محليًا فورًا؛ سجل Neon يُحدّث عند فتح الصفحة أو إعادة الاتصال فقط.
    await NotificationsService.instance.handleSyncEvent(event);
  }

  Future<void> _updateCommercialBox(String name, Map<String, dynamic> payload, bool isDelete) async {
    await Hive.box('commercial_stock_events_box').delete('${payload['company_code']}_synced_at');
    final box = Hive.box(name);
    final id = payload['id']?.toString() ?? '';
    if (id.isEmpty) return;
    const kindsByBox = {
      'sales_box': 'sales',
      'sales_returns_box': 'returns',
      'customer_payments_box': 'customer-payments',
      'stock_transfers_box': 'transfers',
    };
    final kind = kindsByBox[name];
    if (kind != null && Hive.isBoxOpen('commercial_pending_box')) {
      final pending = Hive.box('commercial_pending_box').get('$kind:$id');
      if (pending is Map) return;
    }
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! List) continue;
      final list = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      list.removeWhere((e) => e['id']?.toString() == id);
      if (list.isEmpty) {
        await box.delete(key);
      } else {
        await box.put(key, list);
      }
    }
    if (isDelete) return;
    final company = payload['company_code']?.toString() ?? '';
    final date = payload['date']?.toString() ?? '';
    final branch = name == 'stock_transfers_box'
        ? payload['from_branch_code']?.toString() ?? ''
        : payload['branch_code']?.toString() ?? '';
    final key = '${company}_${branch}_$date';
    final raw = box.get(key);
    final list = raw is List
        ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    payload['is_deleted'] = false;
    list.add(payload);
    await box.put(key, list);
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

    // ============================================================
  // 11. تحديث الموظفين
  //
  // الموظفين بيخزنوا في نفس coding_box بمفتاح
  // "${companyCode}_employees"
  // ============================================================

  void _updateEmployeeBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode = payload['company_code'];
    final dynamic code = payload['code'];

    if (companyCode == null || code == null) {
      print("⚠️ بيانات موظف ناقصة");
      return;
    }

    final String key = "${companyCode}_employees";

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    // إزالة النسخة القديمة
    list.removeWhere(
      (item) => item['code']?.toString() == code.toString(),
    );

    // DELETE
    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(_codingBox.delete(key));
      } else {
        unawaited(_codingBox.put(key, list));
      }

      print("🗑️ تم حذف الموظف [$code] من Hive");
      return;
    }

    // INSERT / UPDATE
    payload['is_deleted'] = false;
    list.add(payload);

    list.sort((a, b) {
      final int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
      final int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
      return aCode.compareTo(bCode);
    });

    unawaited(_codingBox.put(key, list));

    print("✅ تم تحديث الموظف [$code]");
  }
    // ============================================================
  // 11. تحديث حضور HR
  // ============================================================

  void _updateHRAttendanceBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode = payload['company_code'];
    final dynamic empCode = payload['employee_code'];
    final dynamic date = payload['date'];

    if (companyCode == null || empCode == null || date == null) {
      print("⚠️ بيانات حضور HR ناقصة");
      return;
    }

    final String key = "${companyCode}_hr_attendance";

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);
      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    list.removeWhere((e) =>
        e['employee_code']?.toString() == empCode.toString() &&
        e['date']?.toString() == date.toString());

    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(_codingBox.delete(key));
      } else {
        unawaited(_codingBox.put(key, list));
      }
      print("🗑️ حذف حضور HR [$empCode/$date]");
      return;
    }

    payload['is_deleted'] = false;
    list.add(payload);

    unawaited(_codingBox.put(key, list));
    print("✅ تحديث حضور HR [$empCode/$date]");
  }

  // ============================================================
  // 12. تحديث إجازات HR
  // ============================================================

  void _updateHRVacationBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode = payload['company_code'];
    final dynamic id = payload['id'];

    if (companyCode == null || id == null) {
      print("⚠️ بيانات إجازة HR ناقصة");
      return;
    }

    final String key = "${companyCode}_hr_vacations";

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);
      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    list.removeWhere((e) => e['id']?.toString() == id.toString());

    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(_codingBox.delete(key));
      } else {
        unawaited(_codingBox.put(key, list));
      }
      print("🗑️ حذف إجازة HR [$id]");
      return;
    }

    payload['is_deleted'] = false;
    list.add(payload);

    unawaited(_codingBox.put(key, list));
    print("✅ تحديث إجازة HR [$id]");
  }

  // ============================================================
  // 13. تحديث تسويات HR
  // ============================================================

  void _updateHRAdjustmentBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode = payload['company_code'];
    final dynamic id = payload['id'];

    if (companyCode == null || id == null) {
      print("⚠️ بيانات تسوية HR ناقصة");
      return;
    }

    final String key = "${companyCode}_hr_adjustments";

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);
      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['is_deleted'] != true)
            .toList();
      }
    }

    list.removeWhere((e) => e['id']?.toString() == id.toString());

    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(_codingBox.delete(key));
      } else {
        unawaited(_codingBox.put(key, list));
      }
      print("🗑️ حذف تسوية HR [$id]");
      return;
    }

    payload['is_deleted'] = false;
    list.add(payload);

    unawaited(_codingBox.put(key, list));
    print("✅ تحديث تسوية HR [$id]");
  }
  
  // ============================================================
  // 14. تحديث إعدادات HR (جديد)
  //
  // ⚠️ HREmployeeSettings مفيش is_deleted
  // (الإعدادات بتتعدل، مش بتتحذف)
  // ============================================================

  void _updateHREmployeeSettingsBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final dynamic companyCode = payload['company_code'];
    final dynamic empCode = payload['employee_code'];

    if (companyCode == null || empCode == null) {
      print("⚠️ بيانات إعدادات HR ناقصة");
      return;
    }

    final String key = "${companyCode}_hr_employee_settings";

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);
      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }

    // إزالة النسخة القديمة (سجل واحد لكل موظف)
    list.removeWhere(
      (e) => e['employee_code']?.toString() == empCode.toString(),
    );

    // delete (نادرًا ما يحصل — للإكمال فقط)
    if (action == 'delete') {
      if (list.isEmpty) {
        unawaited(_codingBox.delete(key));
      } else {
        unawaited(_codingBox.put(key, list));
      }
      print("🗑️ حذف إعدادات HR [$empCode]");
      return;
    }

    // insert / update
    payload.remove('action');
    list.add(payload);

    unawaited(_codingBox.put(key, list));

    print("✅ تحديث إعدادات HR [$empCode]");
  }
  
}
