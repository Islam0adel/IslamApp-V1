
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../services/notifications_service.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

class NotificationSettingsPage extends StatefulWidget {
  final String companyCode;
  const NotificationSettingsPage({super.key, required this.companyCode});

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final NotificationsService _service = NotificationsService.instance;

  static const sections = <String, String>{
    'daily': 'اليوميات',
    'purchases': 'المشتريات والموردين',
    'settlements': 'التسويات',
    'coding': 'التكويد',
    'inventory': 'الجرد',
  };

  static const events = <String, String>{
    'add': 'الإضافة',
    'edit': 'التعديل',
    'delete': 'الحذف',
  };

  @override
  void initState() {
    super.initState();
    _service.setCompany(widget.companyCode);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _service.loadSettingsFromServer();
    if (mounted) setState(() {});
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
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        title: Text(
          title,
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontSize: 14,
          ),
        ),
        value: value,
        activeThumbColor: AppTheme.accentFor(context),
        activeTrackColor: AppTheme.accentFor(context).withValues(alpha: 0.35),
        inactiveThumbColor: AppTheme.textMutedFor(context),
        inactiveTrackColor: AppTheme.textMutedFor(context).withValues(alpha: 0.20),
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

  @override
Widget build(BuildContext context) {
  // ============================================================
  // حماية بالصلاحية الجديدة
  // ============================================================
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

  // ============================================================
  // المحتوى الطبيعي
  // ============================================================
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
            _buildSectionTitle('الأقسام'),
            _buildSwitchSection(
              items: sections,
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
                  dropdownColor: AppTheme.dashGradientDeep(context).last,
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
                'تُحفظ الإعدادات في Neon وتُخزّن نسخة محلية سريعة في Hive. '
                'سجل الإشعارات محفوظ مركزيًا ويُحدّث عند وصول حدث WebSocket ',
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
