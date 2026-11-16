import 'dart:async';
import 'services/permissions_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/employee_service.dart';   // ← NEW
import 'services/fcm_service.dart';   // ⭐ FCM
import 'core/theme.dart';
import 'services/hr_service.dart';   // ← NEW (موحد)
import 'views/auth/login_screen.dart';
import 'views/auth/phone_entry_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
import 'views/auth/verify_email_screen.dart';
import 'firebase_options.dart';
import 'services/deep_link_service.dart';   // ⭐ Deep Link
import 'core/navigator_key.dart';           // ⭐ Global NavigatorKey
import 'services/global_sync_service.dart';
import 'services/daily_service.dart';
import 'services/supplier_service.dart';
import 'services/inventory_service.dart';
import 'services/coding_service.dart';
import 'services/supplier_settlement_service.dart';
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
// ⭐ آلية انتظار المزامنة للاستخدام من شاشات تانية (زي LoginScreen)
Completer<void>? _waitSyncCompleter;

Future<void> waitForSyncToComplete({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final startTime = DateTime.now();
  final endTime = startTime.add(timeout);

  print('⏳ waitForSyncToComplete: بداية الانتظار (max ${timeout.inSeconds}s)');

  // ══════════════════════════════════════════════════════════
  // المرحلة 1: انتظر لحد ما sync تبدأ
  // (لأن initializeGlobalListener بيبدأ WebSocket async،
  //  والـ sync مش هتبدأ غير بعد ما auth_success يرجع)
  // ══════════════════════════════════════════════════════════
  bool syncStarted = false;
  while (DateTime.now().isBefore(endTime)) {
    // لو sync بدأت → ننتقل للمرحلة 2
    if (_isSyncing) {
      syncStarted = true;
      print('✅ sync بدأت — ننتقل لانتظار الانتهاء');
      break;
    }

    // لو WebSocket فشل → مفيش sync هتيجي
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

  // ══════════════════════════════════════════════════════════
  // المرحلة 2: انتظر لحد ما sync تخلص (أو timeout)
  // ══════════════════════════════════════════════════════════
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
// الترتيب:
//   Batch 1: [اليوميات, التسويات, التكويد]   — 3 parallel
//   Batch 2: [الموظفين, HR, الموردين]         — 3 parallel
//   Batch 3: [الجرد]                          — 1
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

    // ⭐ helper: sync قسم مخصص (زي HR اللي بيدير lastSync بنفسه)
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
    //
    // الشركات "بيانات خاصة بالسوبر أدمن" — مش بتنزل عند أي حد تاني.
    // الأدمن والموظفين مش بيعملوا sync للشركات (بياناتهم بتوصل من user.company_code)
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
    //
    // الأدمن: عنده صلاحية إدارة مستخدمين شركته → نجيبهم مع الـ sync
    // السوبر أدمن: بيجيب مستخدمي أي شركة عند فتح "إدارة المستخدمين"
    //              (مش بنجيب "كل المستخدمين من كل الشركات" في الـ sync عشان قائمة ضخمة)
    // الموظف العادي: مش بيعمل sync للمستخدمين خالص
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
    // retryPending
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

    // ⭐ إشارة لأي شاشة منتظرة (زي LoginScreen)
    if (_waitSyncCompleter != null && !_waitSyncCompleter!.isCompleted) {
      _waitSyncCompleter!.complete();
    }
  }
}

// ============================================================
// تشغيل Global Sync
//
// WebSocket عند الاتصال أو إعادة الاتصال
// يطلب مزامنة مركزية واحدة.
// ============================================================

void initializeGlobalListener(String companyCode) {
  print("🌐 طلب تشغيل المزامنة للشركة: $companyCode");

  // ربط الـ callback مرة واحدة فقط
  _syncService.onWebSocketConnected ??= () {
    print("🔄 WebSocket اتصل/عاد الاتصال");

    syncAllDataIfNeeded(
      _syncService.currentCompanyCode ?? companyCode,
    );
  };

  // ⭐ جديد: WebSocket فشل → إشارة فورية
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

  // ⭐ تهيئة FCM (Service Worker مسجل في index.html)
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

  await Hive.openBox('notifications_box');
  await Hive.openBox('notification_settings_box');
  await Hive.openBox('product_lookup_box');
   // ✅ HR: طابور العمليات المعلقة (بدل الذاكرة)
  await Hive.openBox('hr_pending_box');
    // ⭐ Boxes جديدة — Companies + Users
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
    // ✅ تحميل الصلاحيات أولاً (سريع — من Hive)
    //
    // لماذا؟
    // - يضمن إن الصلاحيات جاهزة قبل ما WebSocket يستقبل أي event
    // - يمنع إشعارات تظهر لمستخدمين مش مصرح لهم في أول ثانية
    // - يمنع إشعارات مصرح لهم تضيع (لأن الصلاحيات = null)
    //
    // الأثر: يضيف ~50-70ms لزمن بدء التطبيق (مقبول جدًا)
    // --------------------------------------------------------
    await PermissionsService().loadPermissions();

    // ⭐ بعد loadPermissions، الدور محمّل تلقائياً من prefs
    final savedRole = prefs.getString('role');
    if (savedRole != null && savedRole.isNotEmpty) {
      PermissionsService().setRole(savedRole);
    }

    // ⭐ استعادة تسجيل جهاز FCM
    unawaited(FcmService.instance.restoreRegistrationIfEnabled());

    // ⭐ Deep Link Service (يستمع لرسائل SW + URL param)
    DeepLinkService.instance.initialize();

    // --------------------------------------------------------
    // ⭐ فحص التحقق من الإيميل قبل فتح HomePage
    // --------------------------------------------------------
    bool needsEmailVerification = false;
    String currentEmail = '';
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await currentUser.reload();
        currentEmail = currentUser.email ?? '';
        if (!currentUser.emailVerified && currentEmail.isNotEmpty) {
          // فحص هل الحساب يحتاج تحقق (مستخدم جديد) أم لا (مستخدم قديم)
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
          } catch (_) {
            // offline → نفترض الحساب قديم (لا نحجب)
          }
        }
      }
    } catch (e) {
      print('⚠️ email verification check: $e');
    }

    if (needsEmailVerification) {
      // ⭐ يحتاج تحقق → شاشة التحقق (بدون WebSocket)
      initialScreen = VerifyEmailScreen(email: currentEmail);
    } else {
      // --------------------------------------------------------
      // تشغيل WebSocket
      //
      // عند نجاح الاتصال:
      // onWebSocketConnected
      // ↓
      // syncAllDataIfNeeded
      // --------------------------------------------------------
      // --------------------------------------------------------
      // ⭐ فحص الإنترنت فوراً (بدون انتظار)
      // --------------------------------------------------------
      bool isOnline = true;
      if (kIsWeb) {
        try {
          // ⭐ navigator.onLine بيرجع bool? (nullable)
          // بناخد القيمة بـ ?? true يعني لو null نعتبره online
          final onlineValue = html.window.navigator.onLine;
          isOnline = onlineValue ?? true;
          print("🌐 navigator.onLine = $onlineValue → isOnline = $isOnline");
        } catch (e) {
          print("⚠️ Failed to check onLine: $e");
        }
      }

      // --------------------------------------------------------
      // تشغيل WebSocket (في الخلفية — بدون انتظار)
      // --------------------------------------------------------
      initializeGlobalListener(companyCode);

      // --------------------------------------------------------
      // ⭐ منطق الانتظار:
      //  • Online → استنى: (المزامنة تخلص) أو (WebSocket يفشل) أو (15s)
      //  • Offline → افتح فوراً
      // --------------------------------------------------------
      if (isOnline) {
        print("⏳ ننتظر المزامنة (max 15s)...");
        try {
          await Future.any([
            _initialSyncCompleter.future,
            _wsConnectionFailedCompleter.future,
          ]).timeout(const Duration(seconds: 15));
          print("✅ المزامنة اكتملت أو الاتصال فشل — فتح التطبيق");
        } on TimeoutException {
          print("⏱️ 15s عدّت — فتح التطبيق بالبيانات الحالية");
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
  late ThemeMode _themeMode; // ✅ بدون قيمة ابتدائية

  // منع تكرار فحص الاستئناف إذا كان فحص سابق لا يزال يعمل.
  bool _resumeSyncInProgress = false;

  // // منع أحداث الاستئناف المتكررة خلال فترة قصيرة.
  // DateTime? _lastResumeSyncAt;

  // ==========================================================
  // Init
  // ==========================================================

  @override
  void initState() {
    super.initState();

    // ✅ استخدام الثيم المحفوظ من SharedPreferences
    _themeMode = widget.initialThemeMode;

    WidgetsBinding.instance.addObserver(this);
  }

  // ==========================================================
  // App Lifecycle
  // ==========================================================

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
  // لو فيه مزامنة أو فحص سابق شغال، لا تبدأ طلبًا جديدًا.
  if (_resumeSyncInProgress || _isSyncing) return;

  _resumeSyncInProgress = true;

  try {
    final prefs = await SharedPreferences.getInstance();

    final bool rememberMe = prefs.getBool('remember_me') ?? false;
    final String? companyCode = prefs.getString('company_code');

    if (!rememberMe || companyCode == null || companyCode.isEmpty) {
      return;
    }

    // لو WebSocket متصل بالفعل، لا تشغّل مزامنة إضافية
    // لمجرد الرجوع للمتصفح؛ المزامنة اللحظية مستمرة.
    if (_syncService.isConnected &&
        _syncService.currentCompanyCode == companyCode) {
      print("✅ WebSocket متصل؛ لا حاجة لمزامنة عند الرجوع للمتصفح");
      return;
    }

    // لو الاتصال غير متاح، أعد تشغيله فقط.
    // المزامنة ستبدأ من callback عند نجاح الاتصال.
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

    // ✅ حفظ الاختيار على الجهاز
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
      navigatorKey: appNavigatorKey,   // ⭐ Deep Linking
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