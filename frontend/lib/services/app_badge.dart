// frontend/lib/services/app_badge.dart
//
// Conditional export:
// - Web → app_badge_web.dart (JS interop)
// - Non-web → app_badge_stub.dart (no-op)

export 'app_badge_stub.dart' if (dart.library.js_interop) 'app_badge_web.dart';
