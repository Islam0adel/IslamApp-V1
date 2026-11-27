// frontend/lib/views/widgets/permission_bulk_actions.dart
import 'package:flutter/material.dart';

// أزرار الإجراءات الجماعية للصلاحيات
class PermissionBulkActions extends StatelessWidget {
  const PermissionBulkActions(
      {super.key,
      required this.selected,
      required this.total,
      required this.onSelect,
      required this.onClear});
  final int selected, total;
  final VoidCallback? onSelect, onClear;

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('المحدد: $selected من $total'),
            TextButton.icon(
                onPressed: onSelect,
                icon: const Icon(Icons.select_all),
                label: const Text('تحديد الكل')),
            TextButton(
                onPressed: onClear, child: const Text('إلغاء تحديد الكل')),
            const Text('للصلاحيات القابلة للتعديل فقط',
                style: TextStyle(fontSize: 11)),
          ]));
}
