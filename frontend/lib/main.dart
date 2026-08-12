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
// متغيرات قديمة للحفاظ على التوافق مع أي كود سابق
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
// القاعدة:
//
// lastSync موجود
//      ↓
// Incremental Sync
//
// lastSync غير موجود
//      ↓
// Full Sync
//
// ولا نعتمد على Hive لتحديد هل الجهاز جديد أم لا.
// ============================================================

Future<void> syncAllDataIfNeeded(
  String companyCode,
) async {
  // ----------------------------------------------------------
  // منع التكرار
  // ----------------------------------------------------------

  if (_isSyncing) {
    print(
      "⚠️ مزامنة قيد التنفيذ، تم تجاهل الطلب الجديد",
    );
    return;
  }

  _isSyncing = true;

  print(
    "🔄 بدء المزامنة للشركة: $companyCode",
  );

  try {
    final prefs =
        await SharedPreferences.getInstance();


    // ========================================================
    // 1) اليوميات
    // ========================================================

    final String dailyKey =
        'last_sync_daily_$companyCode';

    final String? dailyLastSync =
        prefs.getString(dailyKey);

    if (dailyLastSync == null) {
      // ------------------------------------------------------
      // جهاز جديد
      // ------------------------------------------------------

      print(
        "📥 اليوميات: تحميل كامل",
      );

      await DailyService()
          .syncAllTransactions(companyCode);

      print(
        "✅ اليوميات: اكتمل التحميل الكامل",
      );
    } else {
      // ------------------------------------------------------
      // جهاز قديم
      // ------------------------------------------------------

      print(
        "📡 اليوميات: مزامنة تزايدية منذ $dailyLastSync",
      );

      await DailyService()
          .syncChangesFromServer(
        companyCode,
        dailyLastSync,
      );

      print(
        "✅ اليوميات: اكتملت المزامنة التزايدية",
      );
    }


    // ========================================================
    // 2) التكويد
    // ========================================================

    final String codingKey =
        'last_sync_coding_$companyCode';

    final String? codingLastSync =
        prefs.getString(codingKey);

    if (codingLastSync == null) {
      // ------------------------------------------------------
      // جهاز جديد
      // ------------------------------------------------------

      print(
        "📥 التكويد: تحميل كامل",
      );

      await CodingService()
          .fetchAllCoding(companyCode);

      print(
        "✅ التكويد: اكتمل التحميل الكامل",
      );
    } else {
      // ------------------------------------------------------
      // جهاز قديم
      // ------------------------------------------------------

      print(
        "📡 التكويد: مزامنة تزايدية منذ $codingLastSync",
      );

      await CodingService()
          .syncChangesFromServer(
        companyCode,
        codingLastSync,
      );

      print(
        "✅ التكويد: اكتملت المزامنة التزايدية",
      );
    }


    // ========================================================
    // 3) الموردين
    // ========================================================

    final String supplierKey =
        'last_sync_supplier_$companyCode';

    final String? supplierLastSync =
        prefs.getString(supplierKey);

    if (supplierLastSync == null) {
      // ------------------------------------------------------
      // جهاز جديد
      // ------------------------------------------------------

      print(
        "📥 الموردين: تحميل كامل",
      );

      await SupplierService()
          .fetchAllSupplier(companyCode);

      print(
        "✅ الموردين: اكتمل التحميل الكامل",
      );
    } else {
      // ------------------------------------------------------
      // جهاز قديم
      // ------------------------------------------------------

      print(
        "📡 الموردين: مزامنة تزايدية منذ $supplierLastSync",
      );

      await SupplierService()
          .syncChangesFromServer(
        companyCode,
        supplierLastSync,
      );

      print(
        "✅ الموردين: اكتملت المزامنة التزايدية",
      );
    }


    // ========================================================
    // 4) الجرد
    // ========================================================

    final String inventoryKey =
        'last_sync_inventory_$companyCode';

    final String? inventoryLastSync =
        prefs.getString(inventoryKey);

    if (inventoryLastSync == null) {
      // ------------------------------------------------------
      // جهاز جديد
      // ------------------------------------------------------

      print(
        "📥 الجرد: تحميل كامل",
      );

      await InventoryService()
          .fetchAllInventory(companyCode);

      print(
        "✅ الجرد: اكتمل التحميل الكامل",
      );
    } else {
      // ------------------------------------------------------
      // جهاز قديم
      // ------------------------------------------------------

      print(
        "📡 الجرد: مزامنة تزايدية منذ $inventoryLastSync",
      );

      await InventoryService()
          .syncChangesFromServer(
        companyCode,
        inventoryLastSync,
      );

      print(
        "✅ الجرد: اكتملت المزامنة التزايدية",
      );
    }


    // ========================================================
    // تحديث الأرصدة المحلية
    //
    // Local فقط
    // لا يوجد API Request هنا
    // ========================================================

    await DailyService()
        .getDailySummaryLocal(companyCode);

    print(
      "✅ تم تحديث الأرصدة المحلية",
    );

    print(
      "✅ اكتملت المزامنة المركزية بنجاح",
    );
  } catch (e) {
    print(
      "❌ فشلت المزامنة المركزية: $e",
    );
  } finally {
    _isSyncing = false;
  }
}


// ============================================================
// تشغيل Global Sync
//
// مهم جدًا:
// قبل تشغيل WebSocket نربط callback.
// وبكده أي reconnect للـWebSocket
// سيشغل incremental sync تلقائيًا.
// ============================================================

void initializeGlobalListener(
  String companyCode,
) {
  print(
    "🌐 طلب تشغيل المزامنة للشركة: $companyCode",
  );

  // ----------------------------------------------------------
  // Callback عند اتصال / إعادة اتصال WebSocket
  // ----------------------------------------------------------

  _syncService.onWebSocketConnected = () {
    print(
      "🔄 WebSocket اتصل/عاد الاتصال",
    );

    // --------------------------------------------------------
    // تشغيل Sync واحد فقط
    //
    // لو فيه Sync شغال _isSyncing هيتعامل مع التكرار.
    // --------------------------------------------------------

    Future.microtask(() {
      syncAllDataIfNeeded(companyCode);
    });
  };


  // ----------------------------------------------------------
  // لو WebSocket بالفعل شغال لنفس الشركة
  // لا نفتح اتصال جديد
  // ----------------------------------------------------------

  if (_syncService.isConnected &&
      _syncService.currentCompanyCode ==
          companyCode) {
    print(
      "✅ WebSocket شغال بالفعل للشركة: $companyCode",
    );

    return;
  }


  // ----------------------------------------------------------
  // بدء WebSocket
  // ----------------------------------------------------------

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
    options: DefaultFirebaseOptions.currentPlatform,
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
      prefs.getBool('remember_me') ?? false;

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
    // المستخدم مسجل دخول مسبقًا
    // --------------------------------------------------------

    // تشغيل WebSocket.
    //
    // الـcallback الموجود داخل
    // initializeGlobalListener
    // سيبدأ الـSync عند نجاح الاتصال.
    initializeGlobalListener(
      companyCode,
    );


    // --------------------------------------------------------
    // نضمن مزامنة أولية واحدة فقط.
    //
    // لو WebSocket اتصل في نفس اللحظة
    // _isSyncing يمنع التكرار.
    // --------------------------------------------------------

    Future.microtask(() {
      syncAllDataIfNeeded(
        companyCode,
      );
    });


    // --------------------------------------------------------
    // افتح الصفحة مباشرة
    // --------------------------------------------------------

    initialScreen = HomePage(
      userName: userName,
      companyName:
          companyName ?? 'شركتي',
      companyCode: companyCode,
    );
  } else {

    // --------------------------------------------------------
    // مفيش Login محفوظ
    // --------------------------------------------------------

    initialScreen =
        const LoginScreen();
  }


  // ==========================================================
  // تشغيل التطبيق
  // ==========================================================

  runApp(
    IslamApp(
      initialScreen: initialScreen,
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
        prefs.getBool('remember_me') ??
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
    // لو WebSocket مش شغال
    // نحاول تشغيله من جديد.
    // --------------------------------------------------------

    initializeGlobalListener(
      companyCode,
    );


    // --------------------------------------------------------
    // Incremental Sync
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
      title: 'IslamApp V1.0',

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
          child: child!,
        );
      },
    );
  }
}