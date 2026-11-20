import 'dart:async';
import 'core/constants.dart';
import 'services/permissions_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/employee_service.dart';
import 'services/fcm_service.dart';
import 'core/theme.dart';
import 'services/hr_service.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/phone_entry_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
import 'views/auth/verify_email_screen.dart';
import 'firebase_options.dart';
import 'services/deep_link_service.dart';
import 'core/navigator_key.dart';
import 'services/global_sync_service.dart';
import 'services/daily_service.dart';
import 'services/supplier_service.dart';
import 'services/inventory_service.dart';
import 'services/coding_service.dart';
import 'services/supplier_settlement_service.dart';
import 'services/commercial_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_html/html.dart' as html;
import 'services/company_service.dart';
import 'services/user_service.dart';

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

// ⭐ يخلص لما أول مزامنة تخلص (نجحت أو فشلت)
final Completer<void> _initialSyncCompleter = Completer<void>();

// ⭐ يخلص لما WebSocket يفشل في الاتصال (سيرفر واقع)
final Completer<void> _wsConnectionFailedCompleter = Completer<void>();

Future<void> waitForSyncToComplete({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final startTime = DateTime.now();
  final endTime = startTime.add(timeout);

  print('⏳ waitForSyncToComplete: بداية الانتظار (max ${timeout.inSeconds}s)');

  // المرحلة 1: انتظر لحد ما sync تبدأ
  bool syncStarted = false;
  while (DateTime.now().isBefore(endTime)) {
    if (_isSyncing) {
      syncStarted = true;
      print('✅ sync بدأت — ننتقل لانتظار الانتهاء');
      break;
    }

    if (_wsConnectionFailedCompleter.isCompleted) {
      print('⚠️ WebSocket failed — مفيش sync هتيجي، فتح فوراً');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (!syncStarted) {
    print('⏱️ sync ما بدأتش خلال ${timeout.inSeconds}s — فتح فوراً');
    return;
  }

  // المرحلة 2: انتظر لحد ما sync تخلص (أو timeout)
  while (_isSyncing && DateTime.now().isBefore(endTime)) {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (_isSyncing) {
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    print('⏱️ sync لسه شغالة بعد ${elapsed}s — timeout، فتح بالبيانات المتاحة');
  } else {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    print('✅ sync خلصت — إجمالي الانتظار: ${elapsed}ms');
  }
}

// ============================================================
// Sync Manager — Batching
//
//   Batch 1: [اليوميات, التسويات, التكويد]
//   Batch 2: [الموظفين, HR, الموردين]
//   Batch 2.5: [الشركات (Super Admin), المستخدمين (Admin)]
//   Batch 3: [الجرد]
//   Batch 3.5: [المبيعات + المرتجعات + العملاء + التحويلات]
//   retryPending → الأرصدة
// ============================================================

Future<void> syncAllDataIfNeeded(String companyCode) async {
  if (_isSyncing) {
    print("⚠️ مزامنة قيد التنفيذ، تم تجاهل الطلب الجديد");
    return;
  }

  _isSyncing = true;
  print("🔄 بدء المزامنة للشركة: $companyCode");

  try {
    final prefs = await SharedPreferences.getInstance();
    final syncStartedAt = DateTime.now().toUtc().toIso8601String();

    // ⭐ helper: sync قسم مع lastSync management
    Future<void> syncOneWithLastSync({
      required String name,
      required String lastSyncKey,
      required Future<void> Function() full,
      required Future<void> Function(String since) incremental,
    }) async {
      try {
        final lastSync = prefs.getString(lastSyncKey);
        if (lastSync == null) {
          await full();
          await prefs.setString(lastSyncKey, syncStartedAt);
        } else {
          await incremental(lastSync);
        }
        print("  ✅ $name");
      } catch (e) {
        print("  ❌ $name: $e");
      }
    }

    // ⭐ helper: sync قسم مخصص
    Future<void> syncOneCustom({
      required String name,
      required Future<void> Function() runner,
    }) async {
      try {
        await runner();
        print("  ✅ $name");
      } catch (e) {
        print("  ❌ $name: $e");
      }
    }

    // ──────────────────────────────────────────────────────
    // Batch 1: [اليوميات, التسويات, التكويد]
    // ──────────────────────────────────────────────────────
    print("📦 Batch 1: [اليوميات, التسويات, التكويد]");
    await Future.wait([
      syncOneWithLastSync(
        name: 'اليوميات',
        lastSyncKey: 'last_sync_daily_$companyCode',
        full: () => DailyService().syncAllTransactions(companyCode),
        incremental: (since) =>
            DailyService().syncChangesFromServer(companyCode, since),
      ),
      syncOneWithLastSync(
        name: 'التسويات',
        lastSyncKey: 'last_sync_settlement_$companyCode',
        full: () =>
            SupplierSettlementService().fetchAllSettlements(companyCode),
        incremental: (since) =>
            SupplierSettlementService()
                .syncChangesFromServer(companyCode, since),
      ),
      syncOneWithLastSync(
        name: 'التكويد',
        lastSyncKey: 'last_sync_coding_$companyCode',
        full: () => CodingService().fetchAllCoding(companyCode),
        incremental: (since) =>
            CodingService().syncChangesFromServer(companyCode, since),
      ),
    ]);

    // ──────────────────────────────────────────────────────
    // Batch 2: [الموظفين, HR, الموردين]
    // ──────────────────────────────────────────────────────
    print("📦 Batch 2: [الموظفين, HR, الموردين]");
    await Future.wait([
      syncOneWithLastSync(
        name: 'الموظفين',
        lastSyncKey: 'last_sync_employees_$companyCode',
        full: () => EmployeeService().fetchAllEmployees(companyCode),
        incremental: (since) =>
            EmployeeService().syncChangesFromServer(companyCode, since),
      ),
      syncOneCustom(
        name: 'HR',
        runner: () async {
          await HRService().syncAll(companyCode);
        },
      ),
      syncOneWithLastSync(
        name: 'الموردين',
        lastSyncKey: 'last_sync_supplier_$companyCode',
        full: () => SupplierService().fetchAllSupplier(companyCode),
        incremental: (since) =>
            SupplierService().syncChangesFromServer(companyCode, since),
      ),
    ]);

    // ──────────────────────────────────────────────────────
    // ⭐ مزامنة الشركات — للسوبر أدمن فقط
    // ──────────────────────────────────────────────────────
    if (PermissionsService().isSuperAdmin) {
      print("📦 [Super Admin] مزامنة الشركات...");
      try {
        await CompanyService().fetchAllCompanies();
        print("  ✅ الشركات");
      } catch (e) {
        print("  ❌ الشركات: $e");
      }
    }

    // ──────────────────────────────────────────────────────
    // ⭐ مزامنة المستخدمين — للأدمن فقط (شركته فقط)
    // ──────────────────────────────────────────────────────
    if (PermissionsService().currentRole == 'admin') {
      print("📦 [Admin] مزامنة مستخدمي شركته...");
      try {
        await UserService().fetchAllUsers(companyCode: companyCode);
        print("  ✅ المستخدمين");
      } catch (e) {
        print("  ❌ المستخدمين: $e");
      }
    }

    // ──────────────────────────────────────────────────────
    // Batch 3: [الجرد]
    // ──────────────────────────────────────────────────────
    print("📦 Batch 3: [الجرد]");
    await Future.wait([
      syncOneWithLastSync(
        name: 'الجرد',
        lastSyncKey: 'last_sync_inventory_$companyCode',
        full: () => InventoryService().fetchAllInventory(companyCode),
        incremental: (since) =>
            InventoryService().syncChangesFromServer(companyCode, since),
      ),
    ]);

    // ──────────────────────────────────────────────────────
    // ⭐ Batch 3.5a: push pending FIRST (قبل pull)
    //
    // ترتيب مهم:
    //   1) push pending → السيرفر محدّث
    //   2) pull changes → بيمنع تكرار نفس السجلات
    // ──────────────────────────────────────────────────────
    try {
      await CommercialService().syncPending(companyCode);
      print("  ✅ Commercial pending pushed");
    } catch (e) {
      print("  ❌ Commercial pending: $e");
    }

    // ──────────────────────────────────────────────────────
    // Batch 3.5: [المبيعات + المرتجعات + تحصيلات العملاء + التحويلات]
    // ──────────────────────────────────────────────────────
    print("📦 Batch 3.5: [المبيعات + المرتجعات + العملاء + التحويلات]");
    await Future.wait([
      syncOneWithLastSync(
        name: 'المبيعات',
        lastSyncKey: '${ApiConstants.LAST_SYNC_SALES}$companyCode',
        full: () => CommercialService().fetchAll('sales', companyCode),
        incremental: (since) =>
            CommercialService().syncChangesFromServer(
                'sales', companyCode, since),
      ),
      syncOneWithLastSync(
        name: 'المرتجعات',
        lastSyncKey: '${ApiConstants.LAST_SYNC_RETURNS}$companyCode',
        full: () => CommercialService().fetchAll('returns', companyCode),
        incremental: (since) =>
            CommercialService().syncChangesFromServer(
                'returns', companyCode, since),
      ),
      syncOneWithLastSync(
        name: 'تحصيلات العملاء',
        lastSyncKey:
            '${ApiConstants.LAST_SYNC_CUSTOMER_PAYMENTS}$companyCode',
        full: () =>
            CommercialService().fetchAll('customer-payments', companyCode),
        incremental: (since) =>
            CommercialService().syncChangesFromServer(
                'customer-payments', companyCode, since),
      ),
      syncOneWithLastSync(
        name: 'التحويلات المخزنية',
        lastSyncKey: '${ApiConstants.LAST_SYNC_TRANSFERS}$companyCode',
        full: () => CommercialService().fetchAll('transfers', companyCode),
        incremental: (since) =>
            CommercialService().syncChangesFromServer(
                'transfers', companyCode, since),
      ),
    ]);

    // ──────────────────────────────────────────────────────
    // retryPending (HR)
    // ──────────────────────────────────────────────────────
    try {
      await HRService().retryAllPending(companyCode);
      print("  ✅ retryPending");
    } catch (e) {
      print("  ❌ retryPending: $e");
    }

    // ──────────────────────────────────────────────────────
    // الأرصدة المحلية
    // ──────────────────────────────────────────────────────
    try {
      await DailyService().getDailySummaryLocal(companyCode);
      print("  ✅ الأرصدة المحلية");
    } catch (e) {
      print("  ❌ الأرصدة المحلية: $e");
    }

    print("═══════════════════════════════════════");
    print("✅ اكتملت المزامنة");
    print("═══════════════════════════════════════");
  } catch (e) {
    print("❌ فشلت المزامنة المركزية: $e");
  } finally {
    _isSyncing = false;

    // ⭐ إشارة إن أول مزامنة خلصت
    if (!_initialSyncCompleter.isCompleted) {
      _initialSyncCompleter.complete();
    }
  }
}

// ============================================================
// تشغيل Global Sync
// ============================================================

void initializeGlobalListener(String companyCode) {
  print("🌐 طلب تشغيل المزامنة للشركة: $companyCode");
  CommercialService.startBackgroundSync(companyCode);

  // ربط الـ callback مرة واحدة فقط
  _syncService.onWebSocketConnected ??= () {
    print("🔄 WebSocket اتصل/عاد الاتصال");

    syncAllDataIfNeeded(
      _syncService.currentCompanyCode ?? companyCode,
    );
  };

  // ⭐ WebSocket فشل → إشارة فورية
  _syncService.onWebSocketConnectionFailed ??= () {
    print("⚠️ WebSocket connection failed — signaling main()");

    if (!_wsConnectionFailedCompleter.isCompleted) {
      _wsConnectionFailedCompleter.complete();
    }
  };

  // لو WebSocket شغال بالفعل لنفس الشركة
  if (_syncService.isConnected &&
      _syncService.currentCompanyCode == companyCode) {
    print("✅ WebSocket شغال بالفعل للشركة: $companyCode");
    return;
  }

  print("🌐 بدء WebSocket للشركة: $companyCode");

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

  print("🔌 تم إيقاف المزامنة");
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

  await FcmService.instance.initialize();

  // ==========================================================
  // Hive
  // ==========================================================

  await Hive.initFlutter();

  await Hive.openBox('daily_transactions_box');
  await Hive.openBox('coding_box');
  await Hive.openBox('inventory_box');
  await Hive.openBox('supplier_box');
  await Hive.openBox('supplier_settlement_box');

  // ⭐ Commercial boxes
  await Hive.openBox('sales_box');
  await Hive.openBox('sales_returns_box');
  await Hive.openBox('customer_payments_box');
  await Hive.openBox('stock_transfers_box');
  await Hive.openBox('commercial_stock_events_box');
  await Hive.openBox('commercial_pending_box');

  await Hive.openBox('notifications_box');
  await Hive.openBox('notification_settings_box');
  await Hive.openBox('product_lookup_box');
  await Hive.openBox('hr_pending_box');

  // ⭐ Companies + Users boxes
  await Hive.openBox('companies_box');
  await Hive.openBox('users_box');

  // ==========================================================
  // SharedPreferences
  // ==========================================================

  final prefs = await SharedPreferences.getInstance();

  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');
  final String savedTheme = prefs.getString('theme_mode') ?? 'dark';

  // ==========================================================
  // الشاشة الأولى
  // ==========================================================

  Widget initialScreen;

  if (rememberMe && userName != null && companyCode != null) {
    // --------------------------------------------------------
    // تحميل الصلاحيات أولاً (سريع — من Hive)
    // --------------------------------------------------------
    await PermissionsService().loadPermissions();

    final savedRole = prefs.getString('role');
    if (savedRole != null && savedRole.isNotEmpty) {
      PermissionsService().setRole(savedRole);
    }

    unawaited(FcmService.instance.restoreRegistrationIfEnabled());
    DeepLinkService.instance.initialize();

    // --------------------------------------------------------
    // فحص التحقق من الإيميل
    // --------------------------------------------------------
    bool needsEmailVerification = false;
    String currentEmail = '';
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await currentUser.reload();
        currentEmail = currentUser.email ?? '';
        if (!currentUser.emailVerified && currentEmail.isNotEmpty) {
          try {
            final userDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(currentEmail.toLowerCase())
                .get()
                .timeout(const Duration(seconds: 5));
            if (userDoc.exists) {
              needsEmailVerification =
                  userDoc.data()?['requires_email_verification'] == true;
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      print('⚠️ email verification check: $e');
    }

    if (needsEmailVerification) {
      initialScreen = VerifyEmailScreen(email: currentEmail);
    } else {
      // --------------------------------------------------------
      // فحص الإنترنت فوراً
      // --------------------------------------------------------
      bool isOnline = true;
      if (kIsWeb) {
        try {
          final onlineValue = html.window.navigator.onLine;
          isOnline = onlineValue ?? true;
          print("🌐 navigator.onLine = $onlineValue → isOnline = $isOnline");
        } catch (e) {
          print("⚠️ Failed to check onLine: $e");
        }
      }

      // --------------------------------------------------------
      // تشغيل WebSocket
      // --------------------------------------------------------
      initializeGlobalListener(companyCode);

      // --------------------------------------------------------
      // منطق الانتظار:
      //  • Online → استنى: (المزامنة تخلص) أو (WebSocket يفشل) أو (10s)
      //  • Offline → افتح فوراً
      // --------------------------------------------------------
      if (isOnline) {
        print("⏳ ننتظر المزامنة (max 10s)...");
        try {
          await Future.any([
            _initialSyncCompleter.future,
            _wsConnectionFailedCompleter.future,
          ]).timeout(const Duration(seconds: 10));
          print("✅ المزامنة اكتملت أو الاتصال فشل — فتح التطبيق");
        } on TimeoutException {
          print("⏱️ 10s عدّت — فتح التطبيق بالبيانات الحالية");
        } catch (e) {
          print("⚠️ خطأ أثناء الانتظار: $e — فتح التطبيق");
        }
      } else {
        print("📵 مفيش نت — فتح فوري");
      }

      initialScreen = HomePage(
        userName: userName,
        companyName: companyName ?? 'شركتي',
        companyCode: companyCode,
      );
    }
  } else {
    initialScreen = const LoginScreen();
  }

  // ==========================================================
  // تشغيل التطبيق
  // ==========================================================

  runApp(
    IslamApp(
      initialScreen: initialScreen,
      initialThemeMode:
          savedTheme == 'light' ? ThemeMode.light : ThemeMode.dark,
    ),
  );
}

// ============================================================
// IslamApp
// ============================================================

class IslamApp extends StatefulWidget {
  final Widget initialScreen;
  final ThemeMode initialThemeMode;

  const IslamApp({
    super.key,
    required this.initialScreen,
    this.initialThemeMode = ThemeMode.dark,
  });

  static _IslamAppState of(BuildContext context) {
    return context.findAncestorStateOfType<_IslamAppState>()!;
  }

  @override
  State<IslamApp> createState() => _IslamAppState();
}

// ============================================================
// App State
// ============================================================

class _IslamAppState extends State<IslamApp> with WidgetsBindingObserver {
  late ThemeMode _themeMode;
  bool _resumeSyncInProgress = false;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncWhenAppResumes();
    }
  }

  // ==========================================================
  // Sync عند رجوع التطبيق
  // ==========================================================
  Future<void> _syncWhenAppResumes() async {
    if (_resumeSyncInProgress || _isSyncing) return;

    _resumeSyncInProgress = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      final bool rememberMe = prefs.getBool('remember_me') ?? false;
      final String? companyCode = prefs.getString('company_code');

      if (!rememberMe || companyCode == null || companyCode.isEmpty) {
        return;
      }

      // ⭐ لو WebSocket متصل → syncPending بس (توفير bandwidth)
      if (_syncService.isConnected &&
          _syncService.currentCompanyCode == companyCode) {
        print("✅ WebSocket متصل؛ جاري syncPending فقط...");
        try {
          await CommercialService().syncPending(companyCode);
          print("  ✅ Commercial pending synced (resume)");
        } catch (e) {
          print("  ⚠️ Commercial pending (resume): $e");
        }
        return;
      }

      // WebSocket غير متصل → أعد الاتصال (بيبدأ sync كامل عند النجاح)
      print("🔌 WebSocket غير متصل؛ جاري إعادة الاتصال");
      initializeGlobalListener(companyCode);
    } catch (e) {
      print("❌ تعذر التحقق من اتصال المزامنة بعد العودة: $e");
    } finally {
      _resumeSyncInProgress = false;
    }
  }

  // ==========================================================
  // Theme
  // ==========================================================
  void changeTheme(ThemeMode themeMode) async {
    setState(() {
      _themeMode = themeMode;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'theme_mode',
        themeMode == ThemeMode.light ? 'light' : 'dark',
      );
    } catch (e) {
      print("⚠️ فشل حفظ الثيم: $e");
    }
  }

  // ==========================================================
  // Dispose
  // ==========================================================
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeGlobalListener();
    super.dispose();
  }

  // ==========================================================
  // Build
  // ==========================================================
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IslamApp V1.0',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: widget.initialScreen,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const PhoneEntryScreen(),
        '/forgot-password': (context) => const ForgotPasswordScreen(),
      },
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
    );
  }
}
