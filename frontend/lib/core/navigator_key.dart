// lib/core/navigator_key.dart
import 'package:flutter/material.dart';

/// Global NavigatorKey — يسمح بالتنقل من أي مكان
/// (حتى من خدمة push events، خارج شجرة الـ widgets)
final GlobalKey<NavigatorState> appNavigatorKey =
    GlobalKey<NavigatorState>();