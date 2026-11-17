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