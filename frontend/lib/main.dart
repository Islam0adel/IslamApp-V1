import 'package:flutter/material.dart';
import 'views/auth/login_screen.dart';
import 'views/dashboard/home_page.dart';

void main() {
  runApp(const IslamApp());
}

class IslamApp extends StatelessWidget {
  const IslamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IslamApp 1.0',
      debugShowCheckedModeBanner: false, // إخفاء علامة الـ Debug
      
      // إعدادات الثيم فائق الجمال
      theme: ThemeData(
        useMaterial3: true,
        // اللون الأساسي (الكحلي الملكي)
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A237E),
          primary: const Color(0xFF1A237E),
          secondary: const Color(0xFF00C853), // الأخضر للنجاح والإيرادات
          surface: Colors.white,
        ),
        
        // ضبط الخطوط (Cairo بيدي شكل احترافي جداً)
        fontFamily: 'Cairo', 
        
        // تنسيق الـ AppBar بشكل موحد
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          backgroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Color(0xFF1A237E),
            fontSize: 20,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
          ),
          iconTheme: IconThemeData(color: Color(0xFF1A237E)),
        ),

        // تنسيق الأزرار بشكل دائري وشيك
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFamily: 'Cairo',
            ),
          ),
        ),

        // تنسيق حقول الإدخال (TextFields)
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey[50],
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: Colors.grey[300]!),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: Colors.grey[200]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFF1A237E), width: 2),
          ),
        ),
      ),

      // الصفحة التي يبدأ منها البرنامج
      home: LoginScreen(),

      // تعريف المسارات لسهولة التنقل
      routes: {
        '/login': (context) => LoginScreen(),
        '/home': (context) => const HomePage(),
      },

      // دعم اللغة العربية والاتجاه من اليمين لليسار
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
    );
  }
}