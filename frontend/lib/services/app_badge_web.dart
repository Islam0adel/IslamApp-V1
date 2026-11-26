// lib/services/app_badge_web.dart

import 'dart:js_interop';
import 'package:flutter/foundation.dart' show debugPrint;

@JS('appBadge.set')
external JSPromise<JSAny?> _jsAppBadgeSet(JSNumber count);

Future<void> jsSyncAppBadge(int count) async {
  try {
    await _jsAppBadgeSet(count.toJS).toDart;
    debugPrint('✅ [Badge] jsSyncAppBadge($count) OK');
  } catch (e) {
    debugPrint('❌ [Badge] jsSyncAppBadge($count) FAILED: $e');
  }
}
@JS('appBadge.setMuted')
external JSPromise<JSAny?> _jsAppBadgeSetMuted(JSBoolean muted);

/// Writes the app-level "alerts muted" preference where the service worker
/// reads it. Does not change the push subscription or browser permission.
Future<void> jsSetAlertsMuted(bool muted) async {
  try {
    await _jsAppBadgeSetMuted(muted.toJS).toDart;
  } catch (e) {
    debugPrint('[Alerts] jsSetAlertsMuted($muted) FAILED: $e');
  }
}
