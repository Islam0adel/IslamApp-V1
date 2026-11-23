import 'package:flutter/material.dart';

/// A visible menu entry supplies no right to construct a data-loading page.
class VisibilityPageShell extends StatelessWidget {
  final String title;
  const VisibilityPageShell({super.key, required this.title});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('لا توجد صلاحية لاستخدام هذا القسم. ظهور الصفحة لا يمنح صلاحية للبيانات أو العمليات.', textAlign: TextAlign.center))));
}
