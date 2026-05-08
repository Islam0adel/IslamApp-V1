import 'package:flutter/material.dart';

class AppTheme {
  // ألوان ملكية تناسب التصميم الزجاجي
  static const primaryLight = Color(0xFF1A237E); // كحلي ملكي
  static const primaryDark = Color(0xFF3949AB);  // أزرق مشع للدارك مود

  static final lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: primaryLight,
    scaffoldBackgroundColor: const Color(0xFFF0F2F5),
    fontFamily: 'Cairo',
    inputDecorationTheme: _inputTheme(Colors.black87),
    elevatedButtonTheme: _buttonTheme(primaryLight),
  );

  static final darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: primaryDark,
    scaffoldBackgroundColor: const Color(0xFF0D1117), // أسود احترافي (GitHub style)
    fontFamily: 'Cairo',
    inputDecorationTheme: _inputTheme(Colors.white),
    elevatedButtonTheme: _buttonTheme(primaryDark),
  );

  static InputDecorationTheme _inputTheme(Color textColor) {
    return InputDecorationTheme(
      filled: true,
      fillColor: textColor.withOpacity(0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide.none,
      ),
      labelStyle: TextStyle(color: textColor.withOpacity(0.7)),
    );
  }

  static ElevatedButtonThemeData _buttonTheme(Color color) {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        elevation: 10,
        shadowColor: color.withOpacity(0.4),
      ),
    );
  }
}