// frontend/lib/services/startup_push_state.dart
//
// Decides at startup whether closed-app push can have prepared data for this device.
// Pure logic, so it can be tested without a browser.

// حالات إذن الإشعارات في المتصفح
/// Browser notification permission as the page sees it.
enum BrowserPushPermission { granted, denied, defaultState, unsupported }

// يحوّل نص إذن الإشعارات إلى الحالة المقابلة
BrowserPushPermission parseBrowserPushPermission(String? raw,
    {required bool supported}) {
  if (!supported) return BrowserPushPermission.unsupported;
  switch (raw) {
    case 'granted':
      return BrowserPushPermission.granted;
    case 'denied':
      return BrowserPushPermission.denied;
    default:
      return BrowserPushPermission.defaultState;
  }
}

// يحدد هل لا يمكن توقع بيانات مجهزة بالإشعارات عند بدء التطبيق
/// True when push-prepared data cannot be expected: permission is not granted, or the app never
/// registered this device (or the user switched registration off earlier). A device that is
/// registered but only has alerts muted is NOT in this state.
bool pushUnavailableAtStart({
  required BrowserPushPermission permission,
  required bool registrationEnabled,
}) =>
    permission != BrowserPushPermission.granted || !registrationEnabled;

// ملاحظة تظهر في صفحة التحميل عند عدم توفر الإشعارات
/// Shown on the loading page in that state. Approved wording (user's thumbs-up, WhatsApp 19:37).
const String pushUnavailableLoadingNote =
    'تفعيل إشعارات النظام بيساعد على تجهيز تحديثات البيانات والبرنامج مقفول، '
    'وده ممكن يقلل وقت الانتظار عند الفتح.';
