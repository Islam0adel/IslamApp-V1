// lib/services/websocket_sync_service.dart
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'daily_service.dart';
import '../core/constants.dart';

class WebSocketSyncService {
  WebSocketChannel? _channel;
  String? _companyCode;
  String? _baseUrl;
  bool _isConnected = false;

  // صناديق Hive
  final Box _dailyBox = Hive.box('daily_transactions_box');
  final Box _codingBox = Hive.box('coding_box');
  final Box _inventoryBox = Hive.box('inventory_box');
  final Box _supplierBox = Hive.box('supplier_box');

  // ========== الاتصال بالـ WebSocket ==========
  void connect(String companyCode) {
    _companyCode = companyCode;
    _baseUrl = ApiConstants.baseUrl;
    final url = '${ApiConstants.baseUrl}/sync/ws/$companyCode';
    final wsUrl = url.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');

    print("🔌 محاولة الاتصال بـ WebSocket: $wsUrl");

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _isConnected = true;

      _channel!.stream.listen(
        (message) => _handleMessage(message),
        onError: (error) {
          print("❌ خطأ في WebSocket: $error");
          _reconnect();
        },
        onDone: () {
          print("🔌 تم قطع اتصال WebSocket");
          _isConnected = false;
          _reconnect();
        },
      );

      print("✅ تم الاتصال بـ WebSocket بنجاح");
    } catch (e) {
      print("❌ فشل الاتصال بـ WebSocket: $e");
      _reconnect();
    }
  }

  // ========== معالجة الرسائل الواردة ==========
  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final type = data['type'];
      final action = data['action'];
      final payload = data['data'];

      print("📩 استقبال رسالة: type=$type, action=$action");

      switch (type) {
        case 'transaction':
          _updateBox(_dailyBox, payload, action);
          // تحديث الأرصدة بعد أي تغيير في اليوميات
          if (_companyCode != null) {
            DailyService().getDailySummaryLocal(_companyCode!);
          }
          break;
        case 'coding':
          _updateCodingBox(payload, action);
          break;
        case 'inventory':
          _updateInventoryBox(payload, action);
          break;
        case 'supplier':
          // ✅ معالجة رسائل الموردين باستخدام دالة خاصة
          _updateSupplierBox(payload, action);
          break;
        default:
          print("⚠️ نوع غير معروف: $type");
      }
    } catch (e) {
      print("⚠️ خطأ في معالجة رسالة WebSocket: $e");
    }
  }

  // ========== تحديث صندوق عام (لليوميات) ==========
  void _updateBox(Box box, Map<String, dynamic> payload, String action) {
    final branchCode = payload['branch_code']?.toString() ?? '1';
    final serial = payload['serial']?.toString();
    if (serial == null) {
      print("⚠️ لا يوجد serial في الرسالة");
      return;
    }
    final id = "branch_${branchCode}_$serial";

    if (action == 'insert' || action == 'update') {
      box.put(id, payload);
      print("✅ تم تحديث [$id] في Hive");
    } else if (action == 'delete') {
      box.delete(id);
      print("🗑️ تم حذف [$id] من Hive");
    }
  }

  // ========== تحديث صندوق التكويد (معالجة خاصة) ==========
  void _updateCodingBox(Map<String, dynamic> payload, String action) {
    final companyCode = payload['company_code'];
    final category = payload['category'];
    final code = payload['code'];

    if (companyCode == null || category == null || code == null) {
      print("⚠️ بيانات تكويد ناقصة");
      return;
    }

    final String key = "${companyCode}_$category";
    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      final raw = _codingBox.get(key);
      if (raw is List) {
        list = raw.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }

    if (action == 'insert' || action == 'update') {
      list.removeWhere((item) => item['code']?.toString() == code.toString());
      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere((item) => item['code']?.toString() == code.toString());
    }

    list.sort((a, b) {
      int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
      int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
      return aCode.compareTo(bCode);
    });

    _codingBox.put(key, list);
    print("🔄 تم تحديث التكويد [$category]، الكود [$code]");
  }

  // ========== تحديث صندوق الجرد (معالجة خاصة) ==========
  void _updateInventoryBox(Map<String, dynamic> payload, String action) {
    final docId = payload['doc_id'];

    if (docId == null) {
      print("⚠️ لا يوجد doc_id في رسالة الجرد");
      return;
    }

    final companyCode = payload['company_code'] ?? '';
    final branchCode = payload['branch_code'] ?? '';
    final storeCode = payload['store_code'] ?? '';
    final date = payload['date'] ?? '';

    final String key = "${companyCode}_${branchCode}_${storeCode}_$date";
    List<Map<String, dynamic>> list = [];

    if (_inventoryBox.containsKey(key)) {
      final raw = _inventoryBox.get(key);
      if (raw is List) {
        list = raw.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }

    if (action == 'insert' || action == 'update') {
      list.removeWhere((item) => item['doc_id'] == docId);
      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere((item) => item['doc_id'] == docId);
    }

    if (list.isNotEmpty) {
      _inventoryBox.put(key, list);
    } else {
      _inventoryBox.delete(key);
    }
    print("🔄 تم تحديث الجرد [$docId]");
  }

  // ========== تحديث صندوق الموردين (معالجة خاصة) ==========
  Future<void> _updateSupplierBox(Map<String, dynamic> payload, String action) async {
    final docId = payload['doc_id'];
    if (docId == null) {
      print("⚠️ لا يوجد doc_id في رسالة المورد");
      return;
    }

    final companyCode = payload['company_code'] ?? '';
    final branchCode = payload['branch_code'] ?? '';
    final date = payload['date'] ?? '';

    // المفتاح المستخدم في تخزين الموردين (نفس المنطق المستخدم في supplier_service)
    final String key = "${companyCode}_${branchCode}_$date";
    List<Map<String, dynamic>> list = [];

    if (_supplierBox.containsKey(key)) {
      final raw = _supplierBox.get(key);
      if (raw is List) {
        list = raw.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }

    if (action == 'insert' || action == 'update') {
      // إزالة السجل القديم إذا وجد
      list.removeWhere((item) => item['doc_id'] == docId);
      // إضافة السجل الجديد
      list.add(payload);
    } else if (action == 'delete') {
      list.removeWhere((item) => item['doc_id'] == docId);
    }

    if (list.isNotEmpty) {
      await _supplierBox.put(key, list);
    } else {
      await _supplierBox.delete(key);
    }
    print("🔄 تم تحديث المورد [$docId] في Hive");
  }

  // ========== إعادة الاتصال التلقائي ==========
  void _reconnect() {
    if (_companyCode == null || _baseUrl == null) return;
    Future.delayed(const Duration(seconds: 5), () {
      if (!_isConnected) {
        print("🔄 محاولة إعادة الاتصال بـ WebSocket...");
        connect(_companyCode!);
      }
    });
  }

  // ========== قطع الاتصال ==========
  void disconnect() {
    _channel?.sink.close();
    _isConnected = false;
    _companyCode = null;
    _baseUrl = null;
    print("🔌 تم قطع اتصال WebSocket");
  }

  // ========== حالة الاتصال ==========
  bool get isConnected => _isConnected;
}