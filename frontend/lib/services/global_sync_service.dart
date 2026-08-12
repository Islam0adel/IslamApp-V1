// lib/services/global_sync_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'daily_service.dart';
import 'websocket_sync_service.dart'; // ✅ استيراد الخدمة الجديدة

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // ✅ إضافة خدمة WebSocket
  final WebSocketSyncService _wsService = WebSocketSyncService();
  
  // ✅ متغير لتحديد وضع المزامنة (true = WebSocket, false = Firestore)
  bool useWebSocket = true; // يمكنك تغييره حسب البيئة أو التفضيل
  
  // ✅ تعيين callback للاتصال (تم التعديل: استخدام setter)
  set onWebSocketConnected(void Function()? callback) {
    _wsService.onConnected = callback;
  }

  Box get _dailyBox => Hive.box('daily_transactions_box');
  Box get _codingBox => Hive.box('coding_box');
  Box get _inventoryBox => Hive.box('inventory_box');
  Box get _supplierBox => Hive.box('supplier_box');

  StreamSubscription<QuerySnapshot>? _codingSubscription;
  StreamSubscription<QuerySnapshot>? _inventorySubscription;
  StreamSubscription<QuerySnapshot>? _supplierSubscription;

  // ========== دالة بدء المزامنة (يتم استدعاؤها من main.dart) ==========
  void startSync(String companyCode) {
  if (useWebSocket) {
    print("🌐 استخدام WebSocket للمزامنة");
    _wsService.connect(companyCode);  // ✅ بدون baseUrl
  } else {
      print("🔥 استخدام Firestore للمزامنة (Legacy Mode)");
      // استدعاء الدوال القديمة
      _startFirestoreListeners(companyCode);
    }
  }

  // ========== إيقاف المزامنة ==========
  void stopSync() {
    if (useWebSocket) {
      _wsService.disconnect();
    } else {
      _codingSubscription?.cancel();
      _inventorySubscription?.cancel();
      _supplierSubscription?.cancel();
    }
  }

  // ========== دوال Firestore القديمة (محفوظة للرجوع) ==========
  void _startFirestoreListeners(String companyCode) {
    // ... الكود القديم (startGlobalListener, startCodingListener, إلخ)
    // نتركه كما هو ولكن نضعه هنا
    // (محذوف للاختصار لكنه موجود في الملف الأصلي)
  }

  // ========== دوال WebSocket العامة ==========
  bool get isConnected => useWebSocket ? _wsService.isConnected : false;

  // ========== الدوال القديمة (تبقى كما هي للتوافق) ==========
  Future<Stream<QuerySnapshot>> startGlobalListener(String companyCode) async {
    // ... الكود القديم
    return _firestore.collection('transactions').doc(companyCode).collection('daily_records').snapshots();
  }

  // ... باقي الدوال القديمة كما هي
}