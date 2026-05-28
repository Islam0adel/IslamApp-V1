import 'dart:async'; 
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart'; // 🌟 استيراد الفايربيز
import 'core/theme.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/register_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
import 'firebase_options.dart'; 
import 'services/global_sync_service.dart'; // 🌟 استيراد ملف الخدمة ليتعرف على GlobalSyncService

// 🌟 المتغيرات العالمية للرادار المركزي
StreamSubscription? globalSyncSubscription;
final GlobalSyncService _syncService = GlobalSyncService(); // 🌟 الآن سيتعرف عليها بدون أي خطأ

// 🌟 دالة تشغيل الرادار اللحظي المحدثة بالمنظومة الموضعية الذكية
void initializeGlobalListener(String companyCode) {
  globalSyncSubscription?.cancel(); 
  
  globalSyncSubscription = _syncService.startGlobalListener(companyCode).listen((snapshot) {
    for (var change in snapshot.docChanges) {
      final Map<String, dynamic> updateData = change.doc.data() as Map<String, dynamic>? ?? {};
      
      // جلب السيريال بأمان (سواء من الحقل أو من اسم المستند نفسه كحائط صد)
      int serial = int.tryParse(updateData['serial']?.toString() ?? change.doc.id) ?? 0;

      if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
        // 🔄 أ) في حالة إضافة إذن جديد أو تعديل إذن حالي -> تحديث موضعي بالـ Hive وإعادة حساب الأرصدة
        _syncService.processIncomingUpdate(companyCode, updateData);
      } 
      else if (change.type == DocumentChangeType.removed) {
        // 🗑️ ب) في حالة حذف إذن -> حذفه هو فقط من الـ Hive محلياً وإعادة ضبط الأرصدة المتأثرة
        _syncService.processIncomingDelete(companyCode, serial);
      }
    }
  });
}

// 🌟 دالة إيقاف الرادار عند تسجيل الخروج
void disposeGlobalListener() {
  globalSyncSubscription?.cancel();
}

void main() async {
  // 1. تأمين ربط العناصر قبل أي عمليات أخرى
  WidgetsFlutterBinding.ensureInitialized();

  // 2. تهيئة فايربيز 
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // 3. 🔥 تهيئة الذاكرة المحلية Hive وفتح الصناديق الأساسية لتخزين البيانات
  await Hive.initFlutter(); // تهيئة Hive للعمل على الفلوتر
  
  // فتح صندوق لتخزين الأذون اليومية (daily_records)
  await Hive.openBox('daily_transactions_box');
  // 🌟 سطر مؤقت: قم بإلغاء التعليق عنه لمسح كل البيانات المحلية وتصفيرها تماماً، ثم قفل السطر بعد أول تشغيل
  // Hive.box('daily_transactions_box').clear();
  
  // فتح صندوق لتخزين التكويدات (الخزائن، الفروع، التصنيفات)
  await Hive.openBox('coding_box'); 

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
    disposeGlobalListener(); // 🌟 غلق الرادار عند إغلاق التطبيق بالكامل
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