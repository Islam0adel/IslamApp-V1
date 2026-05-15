import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart'; // سطر جديد
import 'package:shared_preferences/shared_preferences.dart';
import 'core/theme.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/register_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
// تأكد من استيراد ملف firebase_options.dart الذي ينتج عن ربط المشروع بفايربيز
import 'firebase_options.dart'; 

void main() async {
  // 1. تأمين ربط العناصر قبل أي عمليات أخرى
  WidgetsFlutterBinding.ensureInitialized();

  // 2. تهيئة فايربيز (ضروري جداً لشغل المحترفين الجديد)
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform, // فك التعليق بعد ربط المشروع
  );
  
  // 3. قراءة حالة الدخول من الذاكرة المحلية
  final prefs = await SharedPreferences.getInstance();
  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');

  Widget initialScreen;
  if (rememberMe && userName != null) {
    initialScreen = HomePage(
      userName: userName,
      companyName: companyName ?? 'شركتي',
      companyCode: companyCode ?? '00',
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
  // التعديل هنا: تم تغيير القيمة من system إلى dark لتفعيل الربط الديناميكي
  ThemeMode _themeMode = ThemeMode.dark;

  void changeTheme(ThemeMode themeMode) {
    setState(() {
      _themeMode = themeMode;
    });
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