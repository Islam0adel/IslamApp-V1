// lib/services/global_sync_service.dart

import 'package:hive_flutter/hive_flutter.dart';
import 'websocket_sync_service.dart';

/// مدير اتصال WebSocket فقط.
///
/// Firebase يظل مسؤولاً عن Authentication / Users / Permissions كما هو.
/// المزامنة هنا خاصة ببيانات التطبيق المخزنة في Hive.
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

  // ============================================================
  // Callback
  // ============================================================

  /// يتم استدعاؤه عند فتح WebSocket أو إعادة الاتصال.
  ///
  /// مهم:
  /// GlobalSyncService لا ينفذ المزامنة بنفسه.
  /// main.dart هو المسؤول عن:
  ///
  /// syncAllDataIfNeeded(companyCode)
  void Function()? onWebSocketConnected;

  // ============================================================
  // Hive Boxes
  // ============================================================

  /// موجودة للتوافق مع أي كود قديم يعتمد عليها.
  Box get dailyBox =>
      Hive.box('daily_transactions_box');

  Box get codingBox =>
      Hive.box('coding_box');

  Box get inventoryBox =>
      Hive.box('inventory_box');

  Box get supplierBox =>
      Hive.box('supplier_box');

  // ============================================================
  // بدء المزامنة / WebSocket
  // ============================================================

  void startSync(String companyCode) {
    // ----------------------------------------------------------
    // منع تشغيل اتصال مكرر لنفس الشركة
    // ----------------------------------------------------------

    if (useWebSocket &&
        _currentCompanyCode == companyCode &&
        _wsService.isConnected) {
      print(
        "✅ WebSocket شغال بالفعل للشركة: $companyCode",
      );
      return;
    }

    // ----------------------------------------------------------
    // لو الشركة تغيرت
    // ----------------------------------------------------------

    if (_currentCompanyCode != null &&
        _currentCompanyCode != companyCode) {
      print(
        "🔄 تغيير الشركة من $_currentCompanyCode إلى $companyCode",
      );

      _wsService.disconnect();
    }

    _currentCompanyCode = companyCode;

    // ----------------------------------------------------------
    // WebSocket Mode
    // ----------------------------------------------------------

    if (useWebSocket) {
      print(
        "🌐 بدء مدير WebSocket للشركة: $companyCode",
      );

      // --------------------------------------------------------
      // عند نجاح الاتصال أو إعادة الاتصال
      // --------------------------------------------------------

      _wsService.onConnected = () {
        print(
          "✅ WebSocket اتصل/عاد الاتصال",
        );

        // ------------------------------------------------------
        // لا تعمل Sync هنا مباشرة.
        //
        // main.dart هو المسؤول الوحيد عن Sync.
        // ------------------------------------------------------

        final callback = onWebSocketConnected;

        if (callback != null) {
          print(
            "🔄 إبلاغ Sync Manager بأن WebSocket اتصل...",
          );

          callback();
        }
      };

      // --------------------------------------------------------
      // فتح WebSocket
      // --------------------------------------------------------

      _wsService.connect(companyCode);

      return;
    }

    // ----------------------------------------------------------
    // Legacy Firestore Mode
    // ----------------------------------------------------------

    print(
      "🔥 استخدام Firestore للمزامنة (Legacy Mode)",
    );

    _startFirestoreListeners(companyCode);
  }

  // ============================================================
  // إيقاف المزامنة
  // ============================================================

  void stopSync() {
    print("🔌 إيقاف Global Sync Service");

    _wsService.disconnect();

    _currentCompanyCode = null;
  }

  // ============================================================
  // Legacy Firestore
  // ============================================================

  /// متروكة فقط للتوافق مع الكود القديم.
  ///
  /// النظام الحالي يعتمد على:
  /// WebSocket + HTTP incremental sync
  void _startFirestoreListeners(
    String companyCode,
  ) {
    print(
      "ℹ️ Firestore Legacy Mode غير مستخدم حاليًا "
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