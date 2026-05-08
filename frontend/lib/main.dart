import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ضرورية لقراءة حالة الدخول
import 'core/theme.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/register_screen.dart';
import 'views/dashboard/home_page.dart'; // استيراد صفحة الهوم

void main() async {
  // لازم نضمن إن كل حاجة جاهزة قبل ما نقرأ من الذاكرة
  WidgetsFlutterBinding.ensureInitialized();
  
  // قراءة حالة "تذكرني" والبيانات المحفوظة
  final prefs = await SharedPreferences.getInstance();
  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');

  // تحديد الصفحة اللي هيبدأ منها البرنامج
  Widget initialScreen;
  if (rememberMe && userName != null) {
    // لو فاكرني ومعايا الاسم، ادخل على الهوم علطول
    initialScreen = HomePage(
      userName: userName,
      companyName: companyName ?? 'شركتي',
      companyCode: companyCode ?? '00',
    );
  } else {
    // لو مش فاكرني، روح لصفحة الدخول
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
  ThemeMode _themeMode = ThemeMode.system;

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
      // البداية من الصفحة اللي حددناها فوق (إما هوم أو لوجين)
      home: widget.initialScreen,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const RegisterScreen(),
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