import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/theme.dart';

import 'views/auth/login_screen.dart';
import 'views/auth/register_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';

import 'firebase_options.dart';

import 'services/global_sync_service.dart';
import 'services/daily_service.dart';
import 'services/supplier_service.dart';
import 'services/inventory_service.dart';
import 'services/coding_service.dart';


// ============================================================
// Global Sync Service
// ============================================================

final GlobalSyncService _syncService = GlobalSyncService();


// ============================================================
// متغيرات قديمة للحفاظ على التوافق
// ============================================================

StreamSubscription? globalSyncSubscription;
StreamSubscription? codingSyncSubscription;
StreamSubscription? inventorySyncSubscription;
StreamSubscription? supplierSyncSubscription;


// ============================================================
// منع تشغيل أكثر من مزامنة في نفس الوقت
// ============================================================

bool _isSyncing = false;


// ============================================================
// Sync Manager
//
// lastSync موجود
//      ↓
// Incremental Sync
//
// lastSync غير موجود
//      ↓
// Full Sync مرة واحدة فقط
// ============================================================

Future<void> syncAllDataIfNeeded(
  String companyCode,
) async {
  if (_isSyncing) {
    print("⚠️ مزامنة قيد التنفيذ، تم تجاهل الطلب الجديد");
    return;
  }

  _isSyncing = true;

  print("🔄 بدء المزامنة للشركة: $companyCode");

  try {
    final prefs = await SharedPreferences.getInstance();

    // ========================================================
    // وقت بداية عملية المزامنة
    // ========================================================
    final syncStartedAt =
        DateTime.now().toUtc().toIso8601String();

    // ========================================================
    // 1) اليوميات
    // ========================================================

    final String dailyKey =
        'last_sync_daily_$companyCode';

    final String? dailyLastSync =
        prefs.getString(dailyKey);

    if (dailyLastSync == null) {
      print("📥 اليوميات: تحميل كامل");

      await DailyService()
          .syncAllTransactions(companyCode);

      // مهم جداً:
      // تسجيل وقت بداية الـ Full Sync
      await prefs.setString(
        dailyKey,
        syncStartedAt,
      );

      print("✅ اليوميات: اكتمل التحميل الكامل");
      print("💾 تم حفظ lastSync لليوميات: $syncStartedAt");
    } else {
      print(
        "📡 اليوميات: مزامنة تزايدية منذ $dailyLastSync",
      );

      await DailyService()
          .syncChangesFromServer(
        companyCode,
        dailyLastSync,
      );

      print("✅ اليوميات: اكتملت المزامنة التزايدية");
    }

    // ========================================================
    // 2) التكويد
    // ========================================================

    final String codingKey =
        'last_sync_coding_$companyCode';

    final String? codingLastSync =
        prefs.getString(codingKey);

    if (codingLastSync == null) {
      print("📥 التكويد: تحميل كامل");

      await CodingService()
          .fetchAllCoding(companyCode);

      await prefs.setString(
        codingKey,
        syncStartedAt,
      );

      print("✅ التكويد: اكتمل التحميل الكامل");
      print("💾 تم حفظ lastSync للتكويد: $syncStartedAt");
    } else {
      print(
        "📡 التكويد: مزامنة تزايدية منذ $codingLastSync",
      );

      await CodingService()
          .syncChangesFromServer(
        companyCode,
        codingLastSync,
      );

      print("✅ التكويد: اكتملت المزامنة التزايدية");
    }

    // ========================================================
    // 3) الموردين
    // ========================================================

    final String supplierKey =
        'last_sync_supplier_$companyCode';

    final String? supplierLastSync =
        prefs.getString(supplierKey);

    if (supplierLastSync == null) {
      print("📥 الموردين: تحميل كامل");

      await SupplierService()
          .fetchAllSupplier(companyCode);

      await prefs.setString(
        supplierKey,
        syncStartedAt,
      );

      print("✅ الموردين: اكتمل التحميل الكامل");
      print("💾 تم حفظ lastSync للموردين: $syncStartedAt");
    } else {
      print(
        "📡 الموردين: مزامنة تزايدية منذ $supplierLastSync",
      );

      await SupplierService()
          .syncChangesFromServer(
        companyCode,
        supplierLastSync,
      );

      print("✅ الموردين: اكتملت المزامنة التزايدية");
    }

    // ========================================================
    // 4) الجرد
    // ========================================================

    final String inventoryKey =
        'last_sync_inventory_$companyCode';

    final String? inventoryLastSync =
        prefs.getString(inventoryKey);

    if (inventoryLastSync == null) {
      print("📥 الجرد: تحميل كامل");

      await InventoryService()
          .fetchAllInventory(companyCode);

      await prefs.setString(
        inventoryKey,
        syncStartedAt,
      );

      print("✅ الجرد: اكتمل التحميل الكامل");
      print("💾 تم حفظ lastSync للجرد: $syncStartedAt");
    } else {
      print(
        "📡 الجرد: مزامنة تزايدية منذ $inventoryLastSync",
      );

      await InventoryService()
          .syncChangesFromServer(
        companyCode,
        inventoryLastSync,
      );

      print("✅ الجرد: اكتملت المزامنة التزايدية");
    }

    // ========================================================
    // تحديث الأرصدة المحلية فقط
    // ========================================================

    await DailyService()
        .getDailySummaryLocal(companyCode);

    print("✅ تم تحديث الأرصدة المحلية");

    print("✅ اكتملت المزامنة المركزية بنجاح");
  } catch (e) {
    print("❌ فشلت المزامنة المركزية: $e");
  } finally {
    _isSyncing = false;
  }
}


// ============================================================
// تشغيل Global Sync
//
// WebSocket عند الاتصال أو إعادة الاتصال
// يطلب مزامنة مركزية واحدة.
// ============================================================

void initializeGlobalListener(String companyCode) {
  print(
    "🌐 طلب تشغيل المزامنة للشركة: $companyCode",
  );

  // ربط الـ callback مرة واحدة فقط
  _syncService.onWebSocketConnected ??= () {
    print(
      "🔄 WebSocket اتصل/عاد الاتصال",
    );

    syncAllDataIfNeeded(
      _syncService.currentCompanyCode ?? companyCode,
    );
  };

  // لو WebSocket شغال بالفعل لنفس الشركة
  if (_syncService.isConnected &&
      _syncService.currentCompanyCode == companyCode) {
    print(
      "✅ WebSocket شغال بالفعل للشركة: $companyCode",
    );
    return;
  }

  print(
    "🌐 بدء WebSocket للشركة: $companyCode",
  );

  _syncService.startSync(companyCode);
}


// ============================================================
// إيقاف Global Sync
// ============================================================

void disposeGlobalListener() {
  globalSyncSubscription?.cancel();
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();

  _syncService.stopSync();

  print(
    "🔌 تم إيقاف المزامنة",
  );
}


// ============================================================
// Main
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();


  // ==========================================================
  // Firebase
  // ==========================================================

  await Firebase.initializeApp(
    options:
        DefaultFirebaseOptions.currentPlatform,
  );


  // ==========================================================
  // Hive
  // ==========================================================

  await Hive.initFlutter();

  await Hive.openBox(
    'daily_transactions_box',
  );

  await Hive.openBox(
    'coding_box',
  );

  await Hive.openBox(
    'inventory_box',
  );

  await Hive.openBox(
    'supplier_box',
  );

  await Hive.openBox(
    'supplier_settlement_box',
  );


  // ==========================================================
  // SharedPreferences
  // ==========================================================

  final prefs =
      await SharedPreferences.getInstance();

  final bool rememberMe =
      prefs.getBool('remember_me') ??
          false;

  final String? userName =
      prefs.getString('user_name');

  final String? companyName =
      prefs.getString('company_name');

  final String? companyCode =
      prefs.getString('company_code');


  // ==========================================================
  // الشاشة الأولى
  // ==========================================================

  Widget initialScreen;

  if (rememberMe &&
      userName != null &&
      companyCode != null) {

    // --------------------------------------------------------
    // تشغيل WebSocket
    //
    // عند نجاح الاتصال:
    // onWebSocketConnected
    // ↓
    // syncAllDataIfNeeded
    // --------------------------------------------------------

    initializeGlobalListener(
      companyCode,
    );


    // --------------------------------------------------------
    // لا يوجد Sync إضافي هنا
    //
    // لمنع تكرار المزامنة.
    // --------------------------------------------------------

    initialScreen = HomePage(
      userName: userName,
      companyName:
          companyName ?? 'شركتي',
      companyCode: companyCode,
    );
  } else {

    initialScreen =
        const LoginScreen();
  }


  // ==========================================================
  // تشغيل التطبيق
  // ==========================================================

  runApp(
    IslamApp(
      initialScreen:
          initialScreen,
    ),
  );
}


// ============================================================
// IslamApp
// ============================================================

class IslamApp extends StatefulWidget {
  final Widget initialScreen;

  const IslamApp({
    super.key,
    required this.initialScreen,
  });

  static _IslamAppState of(
    BuildContext context,
  ) {
    return context
        .findAncestorStateOfType<
            _IslamAppState>()!;
  }

  @override
  State<IslamApp> createState() =>
      _IslamAppState();
}


// ============================================================
// App State
// ============================================================

class _IslamAppState
    extends State<IslamApp>
    with WidgetsBindingObserver {

  ThemeMode _themeMode =
      ThemeMode.dark;


  // ==========================================================
  // Init
  // ==========================================================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addObserver(this);
  }


  // ==========================================================
  // App Lifecycle
  // ==========================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state ==
        AppLifecycleState.resumed) {
      _syncWhenAppResumes();
    }
  }


  // ==========================================================
  // Sync عند رجوع التطبيق
  // ==========================================================

  Future<void>
      _syncWhenAppResumes() async {

    final prefs =
        await SharedPreferences
            .getInstance();

    final bool rememberMe =
        prefs.getBool(
      'remember_me',
    ) ??
            false;

    final String? companyCode =
        prefs.getString(
      'company_code',
    );


    if (!rememberMe ||
        companyCode == null ||
        companyCode.isEmpty) {
      return;
    }


    print(
      "🔙 التطبيق عاد للعمل، جاري التحقق من التحديثات...",
    );


    // --------------------------------------------------------
    // لو WebSocket غير متصل:
    // نعيد تشغيله فقط.
    //
    // عند نجاح الاتصال callback
    // سيشغل المزامنة.
    // --------------------------------------------------------

    if (!_syncService.isConnected) {
      initializeGlobalListener(
        companyCode,
      );

      return;
    }


    // --------------------------------------------------------
    // WebSocket متصل بالفعل:
    // مزامنة واحدة فقط.
    // --------------------------------------------------------

    await syncAllDataIfNeeded(
      companyCode,
    );
  }


  // ==========================================================
  // Theme
  // ==========================================================

  void changeTheme(
    ThemeMode themeMode,
  ) {
    setState(() {
      _themeMode =
          themeMode;
    });
  }


  // ==========================================================
  // Dispose
  // ==========================================================

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this);

    disposeGlobalListener();

    super.dispose();
  }


  // ==========================================================
  // Build
  // ==========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      title:
          'IslamApp V1.0',

      debugShowCheckedModeBanner:
          false,

      theme:
          AppTheme.lightTheme,

      darkTheme:
          AppTheme.darkTheme,

      themeMode:
          _themeMode,

      home:
          widget.initialScreen,

      routes: {
        '/login':
            (context) =>
                const LoginScreen(),

        '/register':
            (context) =>
                const RegisterScreen(),

        '/forgot-password':
            (context) =>
                const ForgotPasswordScreen(),
      },

      builder:
          (context, child) {
        return Directionality(
          textDirection:
              TextDirection.rtl,

          child:
              child!,
        );
      },
    );
  }
}