import 'dart:async'; 
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart'; 
// import 'package:cloud_firestore/cloud_firestore.dart'; // 🌟 استيراد الفايربيز (يبقى للتوافق مع الكود القديم)
import 'core/theme.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/register_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
import 'firebase_options.dart'; 
import 'services/global_sync_service.dart'; // 🌟 استيراد ملف الخدمة (الذي يحتوي على WebSocket الآن)
// ✅ استيراد الخدمات المطلوبة للمزامنة التزايدية
import 'services/daily_service.dart';
import 'services/supplier_service.dart';
import 'services/inventory_service.dart';

import 'services/coding_service.dart';

// 🌟 المتغيرات العالمية للرادار المركزي (تم إلغاؤها لاستخدام WebSocket)
// لكن نتركها مؤقتاً للتوافق
StreamSubscription? globalSyncSubscription;
StreamSubscription? codingSyncSubscription;
StreamSubscription? inventorySyncSubscription;
StreamSubscription? supplierSyncSubscription;

final GlobalSyncService _syncService = GlobalSyncService(); // 🌟 الآن يستخدم WebSocket داخلياً


// ✅ دالة المزامنة التزايدية لجميع أنواع البيانات
Future<void> _syncAllData(String companyCode) async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // 1️⃣ اليوميات (Daily Transactions)
    final dailyKey = 'last_sync_daily_$companyCode';
    final dailyLastSync = prefs.getString(dailyKey);
    if (dailyLastSync == null) {
      // جهاز جديد → تحميل كل البيانات
      await DailyService().syncAllTransactions(companyCode);
      print("✅ تم تحميل اليوميات بالكامل (جهاز جديد)");
    } else {
      // جهاز موجود → مزامنة تزايدية
      await DailyService().syncChangesFromServer(companyCode);
      print("✅ تم تحديث اليوميات من آخر مزامنة");
    }
    // تحديث آخر وقت مزامنة
    await prefs.setString(dailyKey, DateTime.now().toIso8601String());

    // 2️⃣ التكويد (Coding) – لا يتغير كثيراً، نحمله مرة واحدة
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
      print("✅ تم تحميل التكويدات بالكامل (جهاز جديد)");
    }

    // 3️⃣ الموردين (Suppliers)
    final supplierKey = 'last_sync_supplier_$companyCode';
    final supplierLastSync = prefs.getString(supplierKey);
    if (supplierLastSync == null) {
      await SupplierService().fetchAllSupplier(companyCode);
      print("✅ تم تحميل الموردين بالكامل (جهاز جديد)");
    } else {
      await SupplierService().syncChangesFromServer(companyCode);
      print("✅ تم تحديث الموردين من آخر مزامنة");
    }
    await prefs.setString(supplierKey, DateTime.now().toIso8601String());

    // 4️⃣ الجرد (Inventory)
    final inventoryKey = 'last_sync_inventory_$companyCode';
    final inventoryLastSync = prefs.getString(inventoryKey);
    if (inventoryLastSync == null) {
      await InventoryService().fetchAllInventory(companyCode);
      print("✅ تم تحميل الجرد بالكامل (جهاز جديد)");
    } else {
      await InventoryService().syncChangesFromServer(companyCode);
      print("✅ تم تحديث الجرد من آخر مزامنة");
    }
    await prefs.setString(inventoryKey, DateTime.now().toIso8601String());

    // 🔄 تحديث الأرصدة (بعد مزامنة اليوميات)
    await DailyService().getDailySummaryLocal(companyCode);
    print("✅ تم تحديث الأرصدة المحلية");

  } catch (e) {
    print("⚠️ خطأ في المزامنة التزايدية: $e");
  }
}

// 🌟 دالة تشغيل الرادار اللحظي - الآن تستخدم WebSocket بدلاً من Firestore Listeners
void initializeGlobalListener(String companyCode) async {
  // إلغاء الاشتراكات السابقة (إن وجدت)
  globalSyncSubscription?.cancel(); 
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();
  
  // ✅ استخدام WebSocket للمزامنة بدلاً من Firestore Listeners
  print("🌐 بدء المزامنة عبر WebSocket للشركة: $companyCode");
  _syncService.startSync(companyCode); // استخدام WebSocketSyncService
  
  // ملاحظة: لم نعد بحاجة إلى مستمعات Firestore، كل شيء يتم عبر WebSocket
  // لكننا نترك الكود القديم معلقاً للرجوع إليه إذا دعت الحاجة
  /*
  // 1. تشغيل مستمع اليوميات (القديم) - ملغى لصالح WebSocket
  Stream<QuerySnapshot> stream = await _syncService.startGlobalListener(companyCode);
  globalSyncSubscription = stream.listen((snapshot) {
    for (var change in snapshot.docChanges) {
      final String docId = change.doc.id;
      final Map<String, dynamic> updateData = change.doc.data() as Map<String, dynamic>? ?? {};

      if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
        _syncService.processIncomingUpdate(companyCode, docId, updateData);
      } else if (change.type == DocumentChangeType.removed) {
        _syncService.processIncomingDelete(companyCode, docId);
      }
    }
  });

  // 2. تشغيل مستمع التكويد (القديم) - ملغى لصالح WebSocket
  Stream<QuerySnapshot> codingStream = await _syncService.startCodingListener(companyCode);
  codingSyncSubscription = codingStream.listen((snapshot) {
    print("📦 استقبلت لقطة جديدة من التكويد، عدد التغييرات: ${snapshot.docChanges.length}");
    for (var change in snapshot.docChanges) {
      final String docId = change.doc.id;
      final Map<String, dynamic> data = change.doc.data() as Map<String, dynamic>? ?? {};

      if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
        _syncService.processCodingUpdate(companyCode, docId, data);
      } else if (change.type == DocumentChangeType.removed) {
        _syncService.processCodingDelete(companyCode, docId, '');
      }
    }
  });

  // 3. تشغيل مستمع الجرد (القديم) - ملغى لصالح WebSocket
  Stream<QuerySnapshot> inventoryStream = await _syncService.startInventoryListener(companyCode);
  inventorySyncSubscription = inventoryStream.listen((snapshot) {
    for (var change in snapshot.docChanges) {
      final String docId = change.doc.id;
      final Map<String, dynamic> data = change.doc.data() as Map<String, dynamic>? ?? {};
      if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
        _syncService.processInventoryUpdate(companyCode, docId, data);
      } else if (change.type == DocumentChangeType.removed) {
        _syncService.processInventoryDelete(companyCode, docId);
      }
    }
  });
  */
}

// 🌟 دالة إيقاف الرادار عند تسجيل الخروج
void disposeGlobalListener() {
  globalSyncSubscription?.cancel();
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();
  
  // ✅ إيقاف اتصال WebSocket
  _syncService.stopSync();
  print("🔌 تم إيقاف المزامنة (WebSocket)");
}

void main() async {
  // 1. تأمين ربط العناصر قبل أي عمليات أخرى
  WidgetsFlutterBinding.ensureInitialized();

  // 2. تهيئة فايربيز (يبقى للتحقق والمصادقة)
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // 3. 🔥 تهيئة الذاكرة المحلية Hive وفتح الصناديق الأساسية لتخزين البيانات
  await Hive.initFlutter(); // تهيئة Hive للعمل على الفلوتر
  
  // فتح صندوق لتخزين الأذون اليومية (daily_records)
  await Hive.openBox('daily_transactions_box');
  // فتح صندوق لتخزين التكويدات (الخزائن، الفروع، التصنيفات)
  await Hive.openBox('coding_box'); 
  await Hive.openBox('inventory_box');
  await Hive.openBox('supplier_box');
  await Hive.openBox('supplier_settlement_box'); // ✅ صندوق التسويات

  // 🌟 سطر مؤقت: قم بإلغاء التعليق عنه لمسح كل البيانات المحلية وتصفيرها تماماً، ثم قفل السطر بعد أول تشغيل
  // Hive.box('daily_transactions_box').clear();
  // Hive.box('coding_box').clear();
  // Hive.box('inventory_box').clear();
  // Hive.box('supplier_box').clear();
  // Hive.box('supplier_settlement_box').clear();
  
  // 4. قراءة حالة الدخول من الذاكرة المحلية (SharedPreferences مخصصة لبيانات الحساب فقط)
  final prefs = await SharedPreferences.getInstance();
  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');


  
  Widget initialScreen;
  if (rememberMe && userName != null && companyCode != null) {
    // 🌟 تفعيل الرادار اللحظي فوراً لو المستخدم مسجل دخول بالفعل لتحديث البيانات بالخلفية
    initializeGlobalListener(companyCode);
    
    // ✅ المزامنة التزايدية في الخلفية (لا تمنع عرض الصفحة)
    _syncAllData(companyCode);
    
    // بعد تحميل بيانات المستخدم
    // await PermissionsService().loadPermissions();
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

  @override
  State<IslamApp> createState() => _IslamAppState();
}

class _IslamAppState extends State<IslamApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void changeTheme(ThemeMode themeMode) {
    setState(() {
      _themeMode = themeMode;
    });
  }

  @override
  void dispose() {
    disposeGlobalListener(); // 🌟 غلق الرادار عند إغلاق التطبيق بالكامل (يغلق WebSocket أيضاً)
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
    );
  }
}