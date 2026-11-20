// lib/views/dashboard/notification_settings_page.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../services/notifications_service.dart';
import '../../services/fcm_service.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

class NotificationSettingsPage extends StatefulWidget {
  final String companyCode;
  const NotificationSettingsPage({super.key, required this.companyCode});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final NotificationsService _service = NotificationsService.instance;
  final FcmService _fcm = FcmService.instance;

  static const sections = <String, String>{
    'daily': 'اليوميات',
    'purchases': 'المشتريات والموردين',
    'settlements': 'التسويات',
    'coding': 'التكويد',
    'inventory': 'الجرد',
    'hr_attendance': 'حضور الموارد البشرية',
    'hr_vacations': 'إجازات الموارد البشرية',
    'hr_adjustments': 'تسويات الموارد البشرية',
    'hr_employees': 'بيانات الموظفين',
    // ⭐ جديد — يظهر فقط للسوبر أدمن
    'registration_requests': 'طلبات الانضمام',
    'commercial': 'المبيعات والمرتجعات والتحصيلات والتحويلات',
  };

  static const events = <String, String>{
    'add': 'الإضافة',
    'edit': 'التعديل',
    'delete': 'الحذف',
  };

  bool _systemPushEnabled = false;
  bool _systemPushBusy = false;

  @override
  void initState() {
    super.initState();
    _service.setCompany(widget.companyCode);
    _loadSettings();
    _loadSystemPushState();
  }

  Future<void> _loadSettings() async {
    await _service.loadSettingsFromServer();
    if (mounted) setState(() {});
  }

  Future<void> _loadSystemPushState() async {
    final enabled = await _fcm.isSystemNotificationsEnabled();
    if (mounted) setState(() => _systemPushEnabled = enabled);
  }

  Future<void> _toggleSystemPush(bool value) async {
    if (_systemPushBusy) return;
    setState(() => _systemPushBusy = true);

    Map<String, dynamic> result;
    try {
      if (value) {
        result = await _fcm.enableSystemNotifications();
      } else {
        result = await _fcm.disableSystemNotifications();
      }
    } catch (e) {
      result = {'success': false, 'error': e.toString()};
    }

    if (!mounted) return;

    setState(() => _systemPushBusy = false);

    if (result['success'] == true) {
      setState(() => _systemPushEnabled = value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'تم تفعيل إشعارات النظام ✅'
                : 'تم إيقاف إشعارات النظام',
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: value
              ? AppTheme.successStrongFor(context)
              : AppTheme.textMutedFor(context),
        ),
      );
    } else {
      final err = result['error']?.toString() ?? '';
      final msg = err == 'permission_denied'
          ? 'تم رفض الإذن. افتح إعدادات المتصفح للسماح بالإشعارات'
          : err == 'no_token'
              ? 'تعذر الحصول على FCM token. تحقق من VAPID Key.'
              : 'تعذر تفعيل الإشعارات: $err';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: AppTheme.dangerStrongFor(context),
        ),
      );
    }
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          color: AppTheme.textMainFor(context),
          fontSize: 17,
          fontWeight: FontWeight.bold,
          fontFamily: 'Cairo',
        ),
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        title: Text(
          title,
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontSize: 14,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 11,
                ),
              ),
        value: value,
        activeThumbColor: AppTheme.accentFor(context),
        activeTrackColor: AppTheme.accentFor(context).withValues(alpha: 0.35),
        inactiveThumbColor: AppTheme.textMutedFor(context),
        inactiveTrackColor:
            AppTheme.textMutedFor(context).withValues(alpha: 0.20),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildSwitchSection({
    required Map<String, String> items,
    required bool Function(String) isEnabled,
    required Future<void> Function(String, bool) update,
  }) {
    return GlassCard(
      child: Column(
        children: items.entries.map((entry) {
          return _buildSwitchTile(
            title: entry.value,
            value: isEnabled(entry.key),
            onChanged: (value) async {
              await update(entry.key, value);
              if (mounted) setState(() {});
            },
          );
        }).toList(),
      ),
    );
  }

  // ============================================================
  // ⭐ قسم إشعارات النظام (Web Push)
  // ============================================================
  Widget _buildSystemPushSection() {
    if (!kIsWeb) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle('إشعارات النظام (Push)'),
        GlassCard(
          child: Column(
            children: [
              _buildSwitchTile(
                title: 'تفعيل إشعارات النظام',
                subtitle:
                    'استقبل إشعارات على مستوى النظام حتى لو التطبيق مغلق',
                value: _systemPushEnabled,
                onChanged: _systemPushBusy ? null : _toggleSystemPush,
              ),
              if (_systemPushBusy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(
                    color: AppTheme.accentFor(context),
                    backgroundColor:
                        AppTheme.accentFor(context).withValues(alpha: 0.15),
                  ),
                ),
              // تلميح iOS
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: AppTheme.infoFor(context),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'على iPhone/iPad: لازم تضيف التطبيق للشاشة الرئيسية '
                        '(Add to Home Screen) عشان الإشعارات تشتغل.',
                        style: TextStyle(
                          color: AppTheme.textMutedFor(context),
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!PermissionsService().canShowNotifications) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Text(
            'إعدادات الإشعارات',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: AppTheme.dashGradientDeep(context),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 54,
                    color: AppTheme.textMutedFor(context),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'غير مصرح بالوصول لهذه الصفحة',
                    style: TextStyle(
                      color: AppTheme.textMutedFor(context),
                      fontFamily: 'Cairo',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final gradient = AppTheme.dashGradientDeep(context);

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'إعدادات الإشعارات',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // ⭐ إشعارات النظام أولاً (macro-switch)
              _buildSystemPushSection(),

              _buildSectionTitle('الأقسام'),
              _buildSwitchSection(
                items: PermissionsService().isSuperAdmin
                    ? sections
                    : (Map<String, String>.from(sections)
                        ..remove('registration_requests')),
                isEnabled: _service.sectionEnabled,
                update: _service.setSectionEnabled,
              ),
              const SizedBox(height: 20),
              _buildSectionTitle('أنواع العمليات'),
              _buildSwitchSection(
                items: events,
                isEnabled: _service.eventEnabled,
                update: _service.setEventEnabled,
              ),
              const SizedBox(height: 20),
              _buildSectionTitle('مدة الاحتفاظ'),
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: DropdownButtonFormField<int>(
                    initialValue: _service.retentionDays,
                    isExpanded: true,
                    dropdownColor:
                        AppTheme.dashGradientDeep(context).last,
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontFamily: 'Cairo',
                      fontSize: 14,
                    ),
                    iconEnabledColor: AppTheme.accentFor(context),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      labelText: 'حذف الإشعارات القديمة تلقائيًا',
                      labelStyle: TextStyle(
                        color: AppTheme.textMutedFor(context),
                        fontFamily: 'Cairo',
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 30,
                        child: Text(
                          '30 يومًا',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 90,
                        child: Text(
                          '90 يومًا',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 365,
                        child: Text(
                          'سنة',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 0,
                        child: Text(
                          'بدون حذف تلقائي',
                          style: TextStyle(
                            color: AppTheme.textMainFor(context),
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      await _service.setRetentionDays(value);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'الإشعارات داخل التطبيق (In-App) وصلت عبر WebSocket '
                  'وتُحفظ في Hive. إشعارات النظام (Push) تُرسل عبر Firebase '
                  'وتظهر حتى لو التطبيق مغلق.',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontSize: 12,
                    fontFamily: 'Cairo',
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
