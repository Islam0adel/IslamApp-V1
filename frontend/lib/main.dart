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

// 🌟 المتغيرات العالمية للرادار المركزي (تم إلغاؤها لاستخدام WebSocket)
// لكن نتركها مؤقتاً للتوافق
StreamSubscription? globalSyncSubscription;
StreamSubscription? codingSyncSubscription;
StreamSubscription? inventorySyncSubscription;
StreamSubscription? supplierSyncSubscription;

final GlobalSyncService _syncService = GlobalSyncService(); // 🌟 الآن يستخدم WebSocket داخلياً

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

  // 🌟 سطر مؤقت: قم بإلغاء التعليق عنه لمسح كل البيانات المحلية وتصفيرها تماماً، ثم قفل السطر بعد أول تشغيل
  // Hive.box('daily_transactions_box').clear();
  // Hive.box('coding_box').clear();
  // Hive.box('inventory_box').clear();
  // Hive.box('supplier_box').clear();
  
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