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
  // 1) قطع اتصال حصل فعليًا من البرنامج
  // 2) انقطاع طبيعي يحتاج reconnect
  bool _manualDisconnect = false;

  // ============================================================
  // Callback
  // ============================================================

  /// يتم استدعاؤها عند فتح WebSocket أو إعادة فتحه.
  ///
  /// لا يتم تنفيذ Sync هنا.
  /// main.dart هو المسؤول عن تشغيل syncAllDataIfNeeded().
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
    // منع فتح اتصال جديد لو الاتصال الحالي شغال
    // ----------------------------------------------------------

    if (_isConnected) {
      print(
        "✅ WebSocket متصل بالفعل، تجاهل الاتصال الجديد",
      );
      return;
    }

    // ----------------------------------------------------------
    // هذه محاولة اتصال جديدة، لذلك ليست disconnect يدوي
    // ----------------------------------------------------------

    _manualDisconnect = false;

    _companyCode = companyCode;
    _baseUrl = ApiConstants.baseUrl;

    final url =
        '${ApiConstants.baseUrl}/sync/ws/$companyCode';

    final wsUrl = url
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://');

    print(
      "🔌 محاولة الاتصال بـ WebSocket: $wsUrl",
    );

    try {
      _channel = WebSocketChannel.connect(
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
        // Connection Closed
        // ------------------------------------------------------

        onDone: () {
          print(
            "🔌 تم قطع اتصال WebSocket",
          );

          _isConnected = false;

          _channel = null;

          // لو إحنا اللي قطعناه يدويًا
          // لا تعمل reconnect.
          if (_manualDisconnect) {
            print(
              "ℹ️ الاتصال تم قطعه يدويًا، لن يتم إعادة الاتصال",
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

      final callback = onConnected;

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
  // 2. جدولة إعادة الاتصال
  // ============================================================

  void _scheduleReconnect() {
    // ----------------------------------------------------------
    // لا يوجد شركة
    // ----------------------------------------------------------

    if (_companyCode == null ||
        _baseUrl == null) {
      return;
    }

    // ----------------------------------------------------------
    // الاتصال مفصول يدويًا
    // ----------------------------------------------------------

    if (_manualDisconnect) {
      return;
    }

    // ----------------------------------------------------------
    // يوجد بالفعل reconnect مجدول
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
        // انتهى موعد الجدولة
        _reconnectScheduled = false;

        // ------------------------------------------------------
        // لو الاتصال رجع بالفعل
        // ------------------------------------------------------

        if (_isConnected) {
          return;
        }

        // ------------------------------------------------------
        // لو تم فصل الاتصال يدويًا أثناء الانتظار
        // ------------------------------------------------------

        if (_manualDisconnect) {
          return;
        }

        // ------------------------------------------------------
        // تأكد من وجود الشركة
        // ------------------------------------------------------

        final companyCode = _companyCode;

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
  // 3. قطع الاتصال يدويًا
  // ============================================================

  void disconnect() {
    print(
      "🔌 طلب قطع اتصال WebSocket",
    );

    // ----------------------------------------------------------
    // إعلام النظام أن القطع يدوي
    // ----------------------------------------------------------

    _manualDisconnect = true;

    // ----------------------------------------------------------
    // إلغاء أي reconnect مستقبلي
    // ----------------------------------------------------------

    _reconnectScheduled = false;

    _isConnected = false;

    // ----------------------------------------------------------
    // إغلاق الـChannel
    // ----------------------------------------------------------

    try {
      _channel?.sink.close();
    } catch (_) {}

    _channel = null;

    // ----------------------------------------------------------
    // تنظيف بيانات الاتصال
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

  bool get isConnected => _isConnected;

  // ============================================================
  // 5. معالجة الرسائل
  // ============================================================

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);

      final type = data['type'];
      final action = data['action'];
      final payload = data['data'];

      print(
        "📩 استقبال رسالة: type=$type, action=$action",
      );

      if (payload is! Map) {
        print(
          "⚠️ بيانات الرسالة غير صحيحة",
        );
        return;
      }

      final Map<String, dynamic> safePayload =
          Map<String, dynamic>.from(payload);

      switch (type) {
        // ======================================================
        // اليومية
        // ======================================================

        case 'transaction':
          _updateBox(
            _dailyBox,
            safePayload,
            action?.toString() ?? 'update',
          );

          // مهم:
          // لا نعيد حساب الرصيد لكل رسالة إذا كانت هناك
          // تحديثات متتالية بسرعة.
          //
          // لكن نحافظ على السلوك الحالي.
          if (_companyCode != null) {
            unawaited(
              DailyService()
                  .getDailySummaryLocal(_companyCode!),
            );
          }

          break;

        // ======================================================
        // التكويد
        // ======================================================

        case 'coding':
          _updateCodingBox(
            safePayload,
            action?.toString() ?? 'update',
          );
          break;

        // ======================================================
        // الجرد
        // ======================================================

        case 'inventory':
          _updateInventoryBox(
            safePayload,
            action?.toString() ?? 'update',
          );
          break;

        // ======================================================
        // الموردين
        // ======================================================

        case 'supplier':
          unawaited(
            _updateSupplierBox(
              safePayload,
              action?.toString() ?? 'update',
            ),
          );
          break;

        // ======================================================
        // التسويات
        // ======================================================

        case 'settlement':
          unawaited(
            _updateSettlementBox(
              safePayload,
              action?.toString() ?? 'update',
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
  // 6. تحديث اليوميات
  // ============================================================

  void _updateBox(
    Box box,
    Map<String, dynamic> payload,
    String action,
  ) {
    final branchCode =
        payload['branch_code']?.toString() ?? '1';

    final serial =
        payload['serial']?.toString();

    if (serial == null) {
      print(
        "⚠️ لا يوجد serial في رسالة اليومية",
      );
      return;
    }

    final id =
        "branch_${branchCode}_$serial";

    if (action == 'insert' ||
        action == 'update') {
      unawaited(
        box.put(
          id,
          payload,
        ),
      );

      print(
        "✅ تم تحديث [$id] في Hive",
      );
    } else if (action == 'delete') {
      unawaited(
        box.delete(id),
      );

      print(
        "🗑️ تم حذف [$id] من Hive",
      );
    }
  }

  // ============================================================
  // 7. تحديث التكويد
  // ============================================================

  void _updateCodingBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final companyCode =
        payload['company_code'];

    final category =
        payload['category'];

    final code =
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

    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map(
              (e) =>
                  Map<String, dynamic>.from(e),
            )
            .toList();
      }
    }

    if (action == 'insert' ||
        action == 'update') {
      list.removeWhere(
        (item) =>
            item['code']?.toString() ==
            code.toString(),
      );

      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere(
        (item) =>
            item['code']?.toString() ==
            code.toString(),
      );
    }

    list.sort(
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

        return aCode.compareTo(bCode);
      },
    );

    unawaited(
      _codingBox.put(
        key,
        list,
      ),
    );

    print(
      "🔄 تم تحديث التكويد [$category]، الكود [$code]",
    );
  }

  // ============================================================
  // 8. تحديث الجرد
  // ============================================================

  void _updateInventoryBox(
    Map<String, dynamic> payload,
    String action,
  ) {
    final docId =
        payload['doc_id'];

    if (docId == null) {
      print(
        "⚠️ لا يوجد doc_id في رسالة الجرد",
      );
      return;
    }

    final companyCode =
        payload['company_code'] ?? '';

    final branchCode =
        payload['branch_code'] ?? '';

    final storeCode =
        payload['store_code'] ?? '';

    final date =
        payload['date'] ?? '';

    final String key =
        "${companyCode}_${branchCode}_${storeCode}_$date";

    List<Map<String, dynamic>> list = [];

    if (_inventoryBox.containsKey(key)) {
      final raw =
          _inventoryBox.get(key);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map(
              (e) =>
                  Map<String, dynamic>.from(e),
            )
            .toList();
      }
    }

    if (action == 'insert' ||
        action == 'update') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );

      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );
    }

    if (list.isNotEmpty) {
      unawaited(
        _inventoryBox.put(
          key,
          list,
        ),
      );
    } else {
      unawaited(
        _inventoryBox.delete(key),
      );
    }

    print(
      "🔄 تم تحديث الجرد [$docId]",
    );
  }

  // ============================================================
  // 9. تحديث الموردين
  // ============================================================

  Future<void> _updateSupplierBox(
    Map<String, dynamic> payload,
    String action,
  ) async {
    final docId =
        payload['doc_id'];

    if (docId == null) {
      print(
        "⚠️ لا يوجد doc_id في رسالة المورد",
      );
      return;
    }

    final companyCode =
        payload['company_code'] ?? '';

    final branchCode =
        payload['branch_code'] ?? '';

    final date =
        payload['date'] ?? '';

    final String key =
        "${companyCode}_${branchCode}_$date";

    List<Map<String, dynamic>> list = [];

    if (_supplierBox.containsKey(key)) {
      final raw =
          _supplierBox.get(key);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map(
              (e) =>
                  Map<String, dynamic>.from(e),
            )
            .toList();
      }
    }

    if (action == 'insert' ||
        action == 'update') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );

      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );
    }

    if (list.isNotEmpty) {
      await _supplierBox.put(
        key,
        list,
      );
    } else {
      await _supplierBox.delete(key);
    }

    print(
      "🔄 تم تحديث المورد [$docId] في Hive",
    );
  }

  // ============================================================
  // 10. تحديث التسويات
  // ============================================================

  Future<void> _updateSettlementBox(
    Map<String, dynamic> payload,
    String action,
  ) async {
    final docId =
        payload['doc_id'];

    if (docId == null) {
      print(
        "⚠️ لا يوجد doc_id في رسالة التسوية",
      );
      return;
    }

    final companyCode =
        payload['company_code'] ?? '';

    final branchCode =
        payload['branch_code'] ?? '';

    final date =
        payload['date'] ?? '';

    final String key =
        "${companyCode}_${branchCode}_$date";

    List<Map<String, dynamic>> list = [];

    if (_settlementBox.containsKey(key)) {
      final raw =
          _settlementBox.get(key);

      if (raw is List) {
        list = raw
            .whereType<Map>()
            .map(
              (e) =>
                  Map<String, dynamic>.from(e),
            )
            .toList();
      }
    }

    if (action == 'insert' ||
        action == 'update') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );

      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere(
        (item) =>
            item['doc_id']?.toString() ==
            docId.toString(),
      );
    }

    if (list.isNotEmpty) {
      await _settlementBox.put(
        key,
        list,
      );
    } else {
      await _settlementBox.delete(key);
    }

    print(
      "🔄 تم تحديث التسوية [$docId] في Hive",
    );
  }
}