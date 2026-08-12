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

// المتغيرات العالمية للرادار (للتوافق مع الكود القديم)
StreamSubscription? globalSyncSubscription;
StreamSubscription? codingSyncSubscription;
StreamSubscription? inventorySyncSubscription;
StreamSubscription? supplierSyncSubscription;

final GlobalSyncService _syncService = GlobalSyncService();

bool _isSyncing = false;

// ✅ دالة المزامنة الذكية: تعتمد على lastSync لتحديد إذا كان الجهاز جديداً
// إذا كان lastSync == null → تحميل كامل، وإلا → تزايدي
Future<void> syncAllDataIfNeeded(String companyCode) async {
  // منع التزامن المتكرر
  if (_isSyncing) {
    print("⚠️ مزامنة قيد التنفيذ، تم تجاهل الطلب");
    return;
  }
  _isSyncing = true;
  try {
    final prefs = await SharedPreferences.getInstance();

    // 1️⃣ اليوميات
    final dailyKey = 'last_sync_daily_$companyCode';
    final dailyLastSync = prefs.getString(dailyKey);
    print("🔍 dailyLastSync قبل المزامنة: $dailyLastSync");

    // التحقق من وجود بيانات في Hive كحالة استثنائية (جهاز جديد)
    final Box dailyBox = Hive.box('daily_transactions_box');
    bool hasLocalData = dailyBox.values.any((tx) => tx is Map && tx['company_code'] == companyCode);

    if (dailyLastSync == null || !hasLocalData) {
      // لا يوجد last_sync أو Hive فارغة → تحميل كامل
      print("📥 تحميل كامل (${dailyLastSync == null ? 'لا يوجد last_sync' : 'Hive فارغة'})");
      await DailyService().syncAllTransactions(companyCode);
    } else {
      // مزامنة تزايدية
      print("📡 مزامنة تزايدية منذ: $dailyLastSync (UTC)");
      await DailyService().syncChangesFromServer(companyCode, dailyLastSync);
    }
    // حفظ وقت المزامنة بصيغة UTC
    final newSyncTime = DateTime.now().toUtc().toIso8601String();
    await prefs.setString(dailyKey, newSyncTime);
    print("✅ تم تحديث dailyLastSync إلى: $newSyncTime (UTC)");

    // 2️⃣ التكويد (نحمله كاملاً إذا لم يكن موجوداً في Hive)
    final codingBox = Hive.box('coding_box');
    bool hasCodingData = false;
    List<String> categories = ['items', 'safes', 'types', 'branches', 'stores', 'suppliers', 'customers', 'payment_methods'];
    for (String cat in categories) {
      if (codingBox.containsKey("${companyCode}_$cat")) {
        final data = codingBox.get("${companyCode}_$cat");
        if (data is List && data.isNotEmpty) {
          hasCodingData = true;
          break;
        }
      }
    }
    if (!hasCodingData) {
      await CodingService().fetchAllCoding(companyCode);
      print("✅ تم تحميل التكويدات بالكامل (أول تشغيل)");
    }

    // 3️⃣ الموردين
    final supplierKey = 'last_sync_supplier_$companyCode';
    final supplierLastSync = prefs.getString(supplierKey);
    if (supplierLastSync == null || !hasLocalData) {
      await SupplierService().fetchAllSupplier(companyCode);
      print("✅ تم تحميل الموردين بالكامل (أول تشغيل)");
    } else {
      await SupplierService().syncChangesFromServer(companyCode, supplierLastSync);
      print("✅ تم تحديث الموردين تزايديًا");
    }
    await prefs.setString(supplierKey, DateTime.now().toUtc().toIso8601String());

    // 4️⃣ الجرد
    final inventoryKey = 'last_sync_inventory_$companyCode';
    final inventoryLastSync = prefs.getString(inventoryKey);
    if (inventoryLastSync == null || !hasLocalData) {
      await InventoryService().fetchAllInventory(companyCode);
      print("✅ تم تحميل الجرد بالكامل (أول تشغيل)");
    } else {
      await InventoryService().syncChangesFromServer(companyCode, inventoryLastSync);
      print("✅ تم تحديث الجرد تزايديًا");
    }
    await prefs.setString(inventoryKey, DateTime.now().toUtc().toIso8601String());

    // تحديث الأرصدة
    await DailyService().getDailySummaryLocal(companyCode);
    print("✅ تم تحديث الأرصدة المحلية");

  } catch (e) {
    print("⚠️ خطأ في المزامنة: $e");
  } finally {
    _isSyncing = false;
  }
}

// 🌟 دالة تشغيل WebSocket وتعيين المزامنة التلقائية
void initializeGlobalListener(String companyCode) {
  // إلغاء الاشتراكات السابقة
  globalSyncSubscription?.cancel(); 
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();

  print("🌐 بدء WebSocket للشركة: $companyCode");

  // ✅ تعيين callback لاستدعاء المزامنة عند اتصال WebSocket
  // نستخدم `_isSyncing` لمنع التكرار، وسيتم استدعاء `syncAllDataIfNeeded`
  _syncService.onWebSocketConnected = () {
    print("🔄 WebSocket متصل، جاري تحديث البيانات...");
    // نستخدم `Future.microtask` لتجنب التعارض مع المزامنة الجارية
    Future.microtask(() => syncAllDataIfNeeded(companyCode));
  };

  _syncService.startSync(companyCode);
}

void disposeGlobalListener() {
  globalSyncSubscription?.cancel();
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();
  _syncService.stopSync();
  print("🔌 تم إيقاف المزامنة");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Hive.initFlutter();
  await Hive.openBox('daily_transactions_box');
  await Hive.openBox('coding_box');
  await Hive.openBox('inventory_box');
  await Hive.openBox('supplier_box');
  await Hive.openBox('supplier_settlement_box');

  final prefs = await SharedPreferences.getInstance();
  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');

  Widget initialScreen;
  if (rememberMe && userName != null && companyCode != null) {
    // تشغيل المزامنة في الخلفية (لا تمنع عرض الصفحة)
    initializeGlobalListener(companyCode);
    // نستخدم Future.microtask لتأخير المزامنة قليلاً حتى تظهر الصفحة
    Future.microtask(() => syncAllDataIfNeeded(companyCode));

    initialScreen = HomePage(
      userName: userName,
      companyName: companyName ?? 'شركتي',
      companyCode: companyCode,
    );
  } else {
    initialScreen = const LoginScreen();
  }

  runApp(IslamApp(initialScreen: initialScreen));
}

class IslamApp extends StatefulWidget {
  final Widget initialScreen;
  const IslamApp({super.key, required this.initialScreen});
  static _IslamAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_IslamAppState>()!;
  @override State<IslamApp> createState() => _IslamAppState();
}

class _IslamAppState extends State<IslamApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  void changeTheme(ThemeMode themeMode) => setState(() => _themeMode = themeMode);
  @override void dispose() { disposeGlobalListener(); super.dispose(); }
  @override Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IslamApp V1.0',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: widget.initialScreen,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
        '/forgot-password': (context) => const ForgotPasswordScreen(),
      },
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
    );
  }
}