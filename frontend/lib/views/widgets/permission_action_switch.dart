import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'glass_card.dart';

/// One permission row, shared by ordinary and HR permission editors.
class PermissionActionSwitch extends StatelessWidget {
  const PermissionActionSwitch({super.key, required this.label,
    required this.value, required this.included, this.onChanged,
    this.activeColor, this.fontSize = 16});
  final String label;
  final bool value;
  final bool included;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    activeThumbColor: activeColor ?? AppTheme.accentFor(context),
    thumbColor: included ? WidgetStatePropertyAll(activeColor ?? AppTheme.accentFor(context)) : null,
    trackColor: included ? WidgetStatePropertyAll((activeColor ?? AppTheme.accentFor(context)).withValues(alpha: .38)) : null,
    trackOutlineColor: included ? const WidgetStatePropertyAll(Colors.transparent) : null,
    thumbIcon: included ? const WidgetStatePropertyAll(Icon(Icons.check, size: 14, color: Colors.white)) : null,
    inactiveTrackColor: GlassStyle.switchTrackOffFor(context),
    title: Text(label, style: TextStyle(color: AppTheme.textMainFor(context),
      fontSize: fontSize, fontFamily: 'Cairo')),
    subtitle: included ? Text('مفعلة ضمن صلاحية التعديل', style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 12)) : null,
    value: value || included,
    onChanged: included ? null : onChanged,
  );
}
