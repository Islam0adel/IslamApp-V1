import 'package:flutter/material.dart';
import 'glass_card.dart';
import '../../core/theme.dart';

class PermissionEditorStatus extends StatelessWidget {
  const PermissionEditorStatus(
      {super.key,
      required this.loading,
      required this.saving,
      required this.error,
      required this.onReload});
  final bool loading, saving;
  final String? error;
  final VoidCallback? onReload;
  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GlassStyle.line10For(context))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(error != null ? Icons.info_outline : Icons.verified_user_outlined,
            color: error != null
                ? AppTheme.warningOrangeFor(context)
                : AppTheme.accentFor(context),
            size: 21),
        const SizedBox(width: 10),
        Expanded(
            child: Text(
                error ??
                    (saving
                        ? 'جارٍ انتظار تأكيد الخادم...'
                        : loading
                            ? 'جارٍ التحقق من الصلاحيات الحالية...'
                            : 'التغييرات لا تُطبّق إلا بعد تأكيد الخادم.'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppTheme.textMainFor(context)))),
        if (onReload != null)
          IconButton(
              tooltip: 'إعادة تحميل بيانات الحساب',
              onPressed: onReload,
              icon: Icon(Icons.refresh, color: AppTheme.accentFor(context)),
              visualDensity: VisualDensity.compact),
      ]));
}

class PermissionEditorStartup extends StatelessWidget {
  const PermissionEditorStartup(
      {super.key,
      required this.value,
      required this.choices,
      required this.allowed,
      required this.enabled,
      required this.onChanged});
  final String value;
  final List<Map<String, String>> choices;
  final List<String> allowed;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    final selected = value == 'all' ? '' : value;
    final visible = choices
        .where((b) => allowed.contains('all') || allowed.contains(b['code']))
        .toList();
    final missing =
        selected.isNotEmpty && !visible.any((b) => b['code'] == selected);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: DropdownButtonFormField<String>(
            key: ValueKey('startup:$selected:${allowed.join(',')}'),
            initialValue: selected,
            isExpanded: true,
            dropdownColor: AppTheme.dropdownBackground(context),
            style: TextStyle(
                fontFamily: 'Cairo',
                color: AppTheme.textMainFor(context),
                fontSize: 13),
            decoration: InputDecoration(
                labelText: 'فرع بداية فتح البرنامج',
                helperText: 'لا يغيّر الفروع المسموحة أو فرع العمل',
                helperMaxLines: 2,
                labelStyle: TextStyle(
                    color: AppTheme.textSoftFor(context), fontFamily: 'Cairo'),
                helperStyle: TextStyle(
                    color: AppTheme.textSoftFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 11),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: GlassStyle.line24For(context)))),
            items: [
              const DropdownMenuItem(
                  value: '', child: Text('كل الفروع المسموحة')),
              if (missing)
                DropdownMenuItem(
                    value: selected,
                    enabled: false,
                    child: Text('$selected (غير متاح ضمن النطاق)',
                        overflow: TextOverflow.ellipsis)),
              ...visible.map((b) => DropdownMenuItem(
                  value: b['code'],
                  child: Text(b['name'] ?? b['code']!,
                      overflow: TextOverflow.ellipsis)))
            ],
            onChanged: enabled
                ? (v) {
                    if (v != null) onChanged(v);
                  }
                : null));
  }
}
