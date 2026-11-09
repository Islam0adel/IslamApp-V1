// lib/services/deep_link_service.dart
//
// ⭐ نمط "Pending Notification":
//    بدل ما نفتح الصفحة مباشرة (قبل المزامنة)، نخزن الإشعار
//    ونسيبه لحد ما HomePage يخلص syncAllDataIfNeeded.
//
// المصادر:
//   1. postMessage من SW (التطبيق مفتوح)
//   2. ?notif=<json> في URL (التطبيق كان مقفول)
//
// المستهلك:
//   HomePage → consumePendingNotification() بعد المزامنة

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_html/html.dart' as html;

class DeepLinkService {
  static final DeepLinkService instance = DeepLinkService._();
  DeepLinkService._();

  bool _initialized = false;
  bool _handledInitialUrl = false;

  // ⭐ الإشعار المعلق (ينتظر المزامنة)
  Map<String, dynamic>? _pendingNotification;

  // ⭐ Stream يبث عند وصول إشعار جديد (لـ HomePage)
  final StreamController<Map<String, dynamic>> _pendingStream =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get pendingStream => _pendingStream.stream;

  Map<String, dynamic>? get pendingNotification => _pendingNotification;

  void initialize() {
    if (_initialized) return;
    if (!kIsWeb) return;
    _initialized = true;

    _listenServiceWorkerMessages();
    Future.delayed(const Duration(milliseconds: 500), _checkInitialUrl);
  }

  // ────────────────────────────────────────────────────────
  // 1) SW messages (التطبيق مفتوح)
  // ────────────────────────────────────────────────────────
  void _listenServiceWorkerMessages() {
    try {
      html.window.onMessage.listen((event) {
        final data = event.data;
        if (data is! Map) return;
        if (data['type'] != 'deep_link') return;

        final payload = data['payload'];
        if (payload is! Map) return;

        final map = Map<String, dynamic>.from(payload);
        debugPrint('🔗 Deep link (SW message) queued: $map');
        _queuePending(map);
      });
      debugPrint('✅ DeepLinkService: listening to SW messages');
    } catch (e) {
      debugPrint('⚠️ DeepLinkService message listener failed: $e');
    }
  }

  // ────────────────────────────────────────────────────────
  // 2) URL param (التطبيق كان مقفول)
  // ────────────────────────────────────────────────────────
  Future<void> _checkInitialUrl() async {
    if (_handledInitialUrl) return;
    _handledInitialUrl = true;

    try {
      final href = html.window.location.href;
      final uri = Uri.parse(href);
      final notifParam = uri.queryParameters['notif'];
      if (notifParam == null || notifParam.isEmpty) return;

      _cleanUrl();

      final decoded = jsonDecode(notifParam);
      if (decoded is! Map) return;

      final map = Map<String, dynamic>.from(decoded);
      debugPrint('🔗 Deep link (URL) queued: $map');
      _queuePending(map);
    } catch (e) {
      debugPrint('⚠️ DeepLinkService initial URL failed: $e');
      _cleanUrl();
    }
  }

  void _cleanUrl() {
    try {
      html.window.history.replaceState(null, '', '/');
    } catch (_) {}
  }

  // ────────────────────────────────────────────────────────
  // ⭐ Queue + Consume
  // ────────────────────────────────────────────────────────

  /// يضيف إشعار معلق + يبلّغ أي مستمع (HomePage)
  void _queuePending(Map<String, dynamic> notification) {
    _pendingNotification = notification;
    if (!_pendingStream.isClosed) {
      _pendingStream.add(notification);
    }
  }

  /// يستدعيه HomePage بعد ما المزامنة تخلص
  /// يرجع الإشعار (ويحذفه من pending) أو null.
  Map<String, dynamic>? consumePendingNotification() {
    final n = _pendingNotification;
    _pendingNotification = null;
    return n;
  }
}