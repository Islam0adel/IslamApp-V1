// lib/services/global_sync_service.dart

import 'package:hive_flutter/hive_flutter.dart';

import 'websocket_sync_service.dart';


/// مدير اتصال WebSocket فقط.
///
/// Firebase يظل مسؤولاً عن:
/// Authentication / Users / Permissions
///
/// المزامنة هنا خاصة ببيانات التطبيق الموجودة في Hive.
class GlobalSyncService {
  // ============================================================
  // WebSocket Service
  // ============================================================

  final WebSocketSyncService _wsService =
      WebSocketSyncService();


  // ============================================================
  // إعدادات
  // ============================================================

  bool useWebSocket = true;

  String? _currentCompanyCode;
  bool _callbackAttached = false;


  // ============================================================
  // Callback
  // ============================================================

  /// يتم استدعاؤه عند:
  ///
  /// 1. فتح WebSocket
  /// 2. إعادة اتصال WebSocket بعد انقطاع
  ///
  /// GlobalSyncService لا يقوم بالمزامنة بنفسه.
  /// main.dart هو المسؤول عن:
  ///
  /// syncAllDataIfNeeded(companyCode)
  void Function()? onWebSocketConnected;


  // ============================================================
  // Hive Boxes
  // ============================================================

  /// موجودة للتوافق مع أي كود قديم يعتمد عليها.

  Box get dailyBox =>
      Hive.box(
        'daily_transactions_box',
      );

  Box get codingBox =>
      Hive.box(
        'coding_box',
      );

  Box get inventoryBox =>
      Hive.box(
        'inventory_box',
      );

  Box get supplierBox =>
      Hive.box(
        'supplier_box',
      );


  // ============================================================
  // بدء WebSocket
  // ============================================================

  void startSync(
    String companyCode,
  ) {
    // ----------------------------------------------------------
    // حماية إضافية:
    // لو نفس الشركة والـWebSocket شغال
    // لا نعمل أي شيء.
    // ----------------------------------------------------------

    if (useWebSocket &&
        _currentCompanyCode ==
            companyCode &&
        _wsService.isConnected) {
      print(
        "✅ WebSocket شغال بالفعل "
        "للشركة: $companyCode",
      );

      return;
    }


    // ----------------------------------------------------------
    // لو الشركة اتغيرت
    // نفصل الاتصال القديم
    // ----------------------------------------------------------

    if (_currentCompanyCode != null &&
    _currentCompanyCode != companyCode) {
  print(
    "🔄 تغيير الشركة من "
    "$_currentCompanyCode إلى "
    "$companyCode",
  );

  _wsService.disconnect();

  _callbackAttached = false;
  _wsService.onConnected = null;
}


    _currentCompanyCode =
        companyCode;


    // ==========================================================
    // WebSocket Mode
    // ==========================================================

    if (useWebSocket) {
      print(
        "🌐 بدء مدير WebSocket "
        "للشركة: $companyCode",
      );


      // --------------------------------------------------------
      // Callback عند الاتصال أو إعادة الاتصال
      // --------------------------------------------------------
      
      if (!_callbackAttached) {
  _callbackAttached = true;

  _wsService.onConnected = () {
    print("✅ WebSocket اتصل/عاد الاتصال");

    final callback = onWebSocketConnected;

    if (callback != null) {
      print("🔄 إبلاغ Sync Manager بأن WebSocket اتصل...");
      callback();
    }
  };
};


      // --------------------------------------------------------
      // فتح الاتصال
      // --------------------------------------------------------

      _wsService.connect(
        companyCode,
      );


      return;
    }


    // ==========================================================
    // Legacy Mode
    // ==========================================================

    print(
      "🔥 استخدام Firestore "
      "للمزامنة (Legacy Mode)",
    );


    _startFirestoreListeners(
      companyCode,
    );
  }


  // ============================================================
  // إيقاف المزامنة
  // ============================================================

  void stopSync() {
    print(
      "🔌 إيقاف Global Sync Service",
    );


    _wsService.disconnect();


    _currentCompanyCode =
        null;


    // مهم:
    // نزيل callback حتى لا يحصل
    // أي Sync بعد إغلاق الخدمة.
    onWebSocketConnected =
        null;
        _callbackAttached = false;
  }


  // ============================================================
  // Legacy Firestore
  // ============================================================

  /// متروكة فقط للتوافق مع الكود القديم.
  ///
  /// النظام الحالي يعتمد على:
  ///
  /// WebSocket
  /// +
  /// HTTP Incremental Sync
  void _startFirestoreListeners(
    String companyCode,
  ) {
    print(
      "ℹ️ Firestore Legacy Mode "
      "غير مستخدم حاليًا "
      "للشركة: $companyCode",
    );
  }


  // ============================================================
  // حالة الاتصال
  // ============================================================

  bool get isConnected {
    if (!useWebSocket) {
      return false;
    }


    return _wsService.isConnected;
  }


  // ============================================================
  // الشركة الحالية
  // ============================================================

  String? get currentCompanyCode =>
      _currentCompanyCode;
}