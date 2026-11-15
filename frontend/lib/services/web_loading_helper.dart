// lib/services/web_loading_helper.dart

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:universal_html/html.dart' as html;

bool _hideCalled = false;

void hideWebLoadingScreen() {
  if (!kIsWeb) return;
  if (_hideCalled) return;
  _hideCalled = true;

  // ⭐ 50ms بس: تضمن إن المتصفح عمل paint بعد frame Flutter
  // (مش بنستنى الأنيميشن ولا أي حاجة تانية)
  Future.delayed(const Duration(milliseconds: 50), () {
    try {
      html.window.dispatchEvent(
        html.CustomEvent('flutter-first-screen-ready'),
      );
      debugPrint('✅ [Loading] hidden as soon as Flutter ready');
    } catch (e) {
      debugPrint('⚠️ [Loading] signal failed: $e');
      try {
        (html.window as dynamic).__hideLoadingScreen?.call();
      } catch (_) {}
    }
  });
}