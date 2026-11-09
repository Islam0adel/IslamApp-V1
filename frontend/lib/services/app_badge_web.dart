// lib/services/app_badge_web.dart
//
// نسخة الويب — تستدعي window.appBadge.set(count)
// (الـ JS helper في index.html)
// يكتب العدد في IndexedDB (يقرأه SW) ويحدّث أيقونة التطبيق.

import 'dart:js_interop';

@JS('appBadge.set')
external JSPromise<JSAny?> _jsAppBadgeSet(JSNumber count);

Future<void> jsSyncAppBadge(int count) async {
  try {
    await _jsAppBadgeSet(count.toJS).toDart;
  } catch (_) {
    // Ignore: badge API not available or PWA not installed
  }
}