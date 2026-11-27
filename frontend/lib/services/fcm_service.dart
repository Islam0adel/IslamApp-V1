// frontend/lib/services/fcm_service.dart
//
// خدمة إشعارات النظام عبر Firebase Cloud Messaging (Web Push).
//
// المسؤوليات:
//   1. تهيئة FCM ومستمعي الرسائل
//   2. طلب الإذن من المستخدم
//   3. الحصول على FCM token
//   4. تسجيل الجهاز في الباك إند (/notifications/register-device)
//   5. حفظ الحالة محلياً (SharedPreferences)
//   6. استعادة التسجيل تلقائياً عند فتح التطبيق
//
// ⚠️ الـ Service Worker (web/firebase-messaging-sw.js) مسؤول عن
// استقبال الإشعارات عندما يكون التطبيق مغلقاً. FirebaseMessaging
// يسجّله تلقائياً عند أول getToken().

import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import 'app_badge.dart';
import 'auth_http.dart';

// معالج رسائل Firebase الواردة والتطبيق في الخلفية
/// معالج الرسائل في الخلفية.
/// على الويب، Service Worker هو الذي يعرض الإشعار فعلياً،
/// لكن Firebase يتطلب تعريف هذه الدالة حتى لا يرمي استثناء.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('FCM background message: ${message.messageId}');
}

// خدمة الإشعارات الفورية عبر Firebase
class FcmService {
  static final FcmService instance = FcmService._();
  FcmService._();

  // مفاتيح SharedPreferences
  static const _prefsKeyEnabled = 'fcm_system_enabled';
  static const _prefsKeyToken = 'fcm_last_token';
  // App-level preference: show pushes without sound/vibration. Separate from
  // the push registration and the browser permission.
  static const _prefsKeyMuted = 'fcm_alerts_muted';

  bool _initialized = false;
  String? _currentToken;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<String>? _onTokenRefreshSub;

  // يحدد هل المنصة مدعومة
  /// هل النظام مدعوم؟
  bool get isSupported => kIsWeb;

  // يهيّئ الخدمة مرة واحدة عند بدء التطبيق
  /// التهيئة الأساسية (تُستدعى مرة واحدة من main.dart)
  Future<void> initialize({
    void Function(RemoteMessage)? onForegroundMessage,
  }) async {
    if (_initialized) return;
    if (!kIsWeb) return;

    try {
      // معالج الخلفية (لو التطبيق اتقفل)
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );

      // ⚠️ في foreground نتجاهل الإشعارات لأن WebSocket يعرضها أصلاً
      // (لا نريد إشعارين متطابقين)
      _onMessageSub = FirebaseMessaging.onMessage.listen((message) {
        debugPrint('ℹ️ FCM foreground ignored (WebSocket handles UI): '
            '${message.data}');
        onForegroundMessage?.call(message);
      });

      // تحديث التوكن تلقائياً (نادراً يحصل، لكنه جزء من العقد)
      _onTokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen(
        (newToken) async {
          _currentToken = newToken;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefsKeyToken, newToken);

          if (prefs.getBool(_prefsKeyEnabled) == true) {
            await _sendRegistrationToServer(newToken);
          }
        },
      );

      _initialized = true;
      debugPrint('✅ FcmService initialized');
    } catch (e) {
      debugPrint('⚠️ FcmService init error: $e');
    }
  }

  // يحرّر اشتراكات الخدمة
  Future<void> dispose() async {
    await _onMessageSub?.cancel();
    await _onTokenRefreshSub?.cancel();
    _onMessageSub = null;
    _onTokenRefreshSub = null;
    _initialized = false;
  }

  // يحدد هل فعّل المستخدم إشعارات النظام
  /// هل المستخدم فعّل إشعارات النظام سابقاً؟
  Future<bool> isSystemNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKeyEnabled) ?? false;
  }

  // يحدد هل التنبيهات مكتومة
  /// Alerts muted: pushes still arrive (and feed background sync), but the
  /// service worker shows them without sound or vibration.
  Future<bool> isAlertsMuted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKeyMuted) ?? false;
  }

  // يضبط كتم التنبيهات على مستوى التطبيق
  /// Turn the app-level alerts off/on WITHOUT touching the token, the server
  /// registration or the browser permission. If push was never enabled there
  /// is nothing to keep: returns not_registered so the caller can say so.
  Future<Map<String, dynamic>> setAlertsMuted(bool muted) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefsKeyEnabled) != true) {
      return {'success': false, 'error': 'not_registered'};
    }
    await prefs.setBool(_prefsKeyMuted, muted);
    await jsSetAlertsMuted(muted);
    return {'success': true, 'muted': muted};
  }

  // يفعّل إشعارات النظام ويسجّل الجهاز
  /// ⭐ تفعيل إشعارات النظام:
  ///   1. طلب إذن
  ///   2. الحصول على token
  ///   3. إرساله للسيرفر
  ///   4. حفظ الحالة
  Future<Map<String, dynamic>> enableSystemNotifications() async {
    if (!kIsWeb) {
      return {'success': false, 'error': 'system_push_web_only'};
    }

    try {
      // 1) طلب الإذن
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        return {
          'success': false,
          'error': 'permission_denied',
          'status': settings.authorizationStatus.name,
        };
      }

      // 2) الحصول على token (يستخدم VAPID)
      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: ApiConstants.fcmVapidKey,
      );

      if (token == null || token.isEmpty) {
        return {'success': false, 'error': 'no_token'};
      }

      _currentToken = token;

      // 3) إرساله للسيرفر
      await _sendRegistrationToServer(token);

      // 4) حفظ الحالة
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyEnabled, true);
      await prefs.setString(_prefsKeyToken, token);
      await prefs.setBool(_prefsKeyMuted, false);
      await jsSetAlertsMuted(false);

      return {'success': true, 'token': token};
    } catch (e) {
      debugPrint('⚠️ enableSystemNotifications error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // يوقف إشعارات النظام ويلغي تسجيل الجهاز
  /// ⭐ إيقاف إشعارات النظام:
  ///   1. إبلاغ السيرفر
  ///   2. حذف الـ token محلياً
  Future<Map<String, dynamic>> disableSystemNotifications() async {
    try {
      final token = _currentToken ??
          await FirebaseMessaging.instance.getToken(
            vapidKey: ApiConstants.fcmVapidKey,
          );

      if (token != null && token.isNotEmpty) {
        await _sendUnregistrationToServer(token);
      }

      try {
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}

      _currentToken = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyEnabled, false);
      await prefs.remove(_prefsKeyToken);
      await prefs.remove(_prefsKeyMuted);
      await jsSetAlertsMuted(false);

      return {'success': true};
    } catch (e) {
      debugPrint('⚠️ disableSystemNotifications error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // يستعيد تسجيل الجهاز عند فتح التطبيق إذا كان مفعّلًا
  /// ⭐ عند فتح التطبيق: لو المستخدم فعّل الإشعارات قبل كده،
  /// نعيد تسجيل الجهاز تلقائياً (بدون طلب إذن جديد).
  Future<void> restoreRegistrationIfEnabled() async {
    if (!kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsKeyEnabled) != true) return;
      // Keep the service worker's copy of the preference in step.
      await jsSetAlertsMuted(prefs.getBool(_prefsKeyMuted) ?? false);

      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        return;
      }

      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: ApiConstants.fcmVapidKey,
      );

      if (token == null || token.isEmpty) return;

      _currentToken = token;
      await _sendRegistrationToServer(token);
      debugPrint('✅ FCM registration restored');
    } catch (e) {
      debugPrint('⚠️ restoreRegistrationIfEnabled: $e');
    }
  }

  // ============================================================
  // الاتصال مع الباك إند
  // ============================================================

  // يرسل رمز الجهاز إلى الخادم لتسجيله
  Future<void> _sendRegistrationToServer(String token) async {
    try {
      final response = await AuthHttp.post(
        Uri.parse('${ApiConstants.baseUrl}/notifications/register-device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fcm_token': token,
          'platform': 'web',
        }),
      );
      debugPrint(
        '✅ FCM token registered: ${response.statusCode}',
      );
    } catch (e) {
      debugPrint('⚠️ FCM register error: $e');
    }
  }

  // يرسل رمز الجهاز إلى الخادم لإلغاء تسجيله
  Future<void> _sendUnregistrationToServer(String token) async {
    try {
      await AuthHttp.delete(
        Uri.parse(
          '${ApiConstants.baseUrl}/notifications/register-device'
          '?fcm_token=${Uri.encodeQueryComponent(token)}',
        ),
      );
      debugPrint('✅ FCM token unregistered');
    } catch (e) {
      debugPrint('⚠️ FCM unregister error: $e');
    }
  }
}
