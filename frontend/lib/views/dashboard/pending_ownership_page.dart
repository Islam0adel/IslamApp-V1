// frontend/lib/views/dashboard/pending_ownership_page.dart
import '../../services/cache_partitions.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/permissions_service.dart';
import '../../services/revocation_service.dart';
import '../widgets/glass_card.dart';

// صفحة تسوية العمليات المعلقة
/// مسار التسوية المرئي للعمليات المعلقة مجهولة المالك.
///
/// عمليات أنشئت قبل نظام تتبع المالك (بلا user_uid) لا تُرفع
/// ولا تُحذف ولا تُنسب تلقائياً لأي حساب. هذه الصفحة لمدير
/// النظام فقط (بوابة صلاحية داخل الصفحة نفسها، لا في الرابط
/// الذي يفتحها فقط). يتخذ المدير قراراً صريحاً لكل عملية بعد
/// الاطلاع على تفاصيلها:
/// - نسبها لحسابه هو (الخدمة تقرأ هويته من الجلسة ولا تقبل
///   معرّفاً خارجياً)، فتخضع لنطاقه وتُرفع ضمن المزامنة.
/// - استبعادها: تخرج من القوائم ومن الرفع لكنها تبقى محفوظة
///   وقابلة للاسترجاع — لا حذف فعلياً لبيانات معلقة.
class PendingOwnershipPage extends StatefulWidget {
  final String companyCode;

  const PendingOwnershipPage({super.key, required this.companyCode});

  // ينشئ كائن الحالة المرتبط بهذا العنصر
  @override
  State<PendingOwnershipPage> createState() => _PendingOwnershipPageState();
}

// حالة صفحة تسوية العمليات المعلقة
class _PendingOwnershipPageState extends State<PendingOwnershipPage> {
  List<Map<String, dynamic>> _ops = [];
  List<Map<String, dynamic>> _discarded = [];
  bool _loading = true;
  bool _showDiscarded = false;

  // يحدد هل المستخدم مدير
  bool get _isAdmin => PermissionsService().canManageUsers;

  // يهيّئ حالة الشاشة عند إنشائها
  @override
  void initState() {
    super.initState();
    _reload();
  }

  // يعيد تحميل العمليات المعلقة
  void _reload() {
    final service = RevocationService.instance;
    setState(() {
      _ops = _isAdmin
          ? service.listUnverifiedOwnershipOps(widget.companyCode)
          : [];
      _discarded =
          _isAdmin ? service.listDiscardedOwnershipOps(widget.companyCode) : [];
      _loading = false;
    });
  }

  // يطلب تأكيد المستخدم
  Future<bool> _confirm({
    required String title,
    required String body,
    required String actionLabel,
    required Color actionColor,
  }) async {
    return CachePartitions.run(() async {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.dialogBackground(context),
          title: Text(
            title,
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontFamily: 'Cairo',
            ),
          ),
          content: Text(
            body,
            style: TextStyle(
              color: AppTheme.textSoftFor(context),
              fontFamily: 'Cairo',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                actionLabel,
                style: TextStyle(color: actionColor),
              ),
            ),
          ],
        ),
      );
      return confirm == true;
    });
  }

  // يصف العملية المعلقة
  String _opDescription(Map<String, dynamic> op) {
    final parts = <String>[
      'القسم: ${op['section']}',
      'النوع: ${op['kind']}',
      'الإجراء: ${op['action']}',
    ];
    if ((op['date']?.toString() ?? '').isNotEmpty) {
      parts.add('التاريخ: ${op['date']}');
    }
    if ((op['branch_code']?.toString() ?? '').isNotEmpty) {
      parts.add('الفرع: ${op['branch_code']}');
    }
    if (op['held'] == true) parts.add('معلقة بسحب صلاحية');
    return parts.join(' — ');
  }

  // يسند العملية إلى المستخدم
  Future<void> _assignToMe(Map<String, dynamic> op) async {
    return CachePartitions.run(() async {
      final ok = await _confirm(
        title: 'نسب العملية لحسابك؟',
        body: '${_opDescription(op)}\n\n'
            'ستُنسب العملية لحسابك أنت (تُقرأ هويتك من جلسة '
            'الدخول) وستُرفع ضمن المزامنة بصلاحياتك. لا يمكن '
            'نسبها لحساب آخر من هنا.',
        actionLabel: 'نسبها لحسابي',
        actionColor: AppTheme.successFor(context),
      );
      if (!ok) return;
      final done = await RevocationService.instance.assignPendingOpToUser(
        boxName: op['box']?.toString() ?? '',
        key: op['key']?.toString() ?? '',
        companyCode: widget.companyCode,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            done
                ? 'تم نسب العملية لحسابك وستُرفع ضمن المزامنة'
                : 'تعذر نسب العملية',
          ),
        ),
      );
      _reload();
    });
  }

  // يتجاهل العملية
  Future<void> _discard(Map<String, dynamic> op) async {
    return CachePartitions.run(() async {
      final ok = await _confirm(
        title: 'استبعاد العملية؟',
        body: '${_opDescription(op)}\n\n'
            'ستخرج العملية من القوائم ولن تُرفع أبداً، لكنها '
            'تبقى محفوظة على الجهاز ويمكن استرجاعها لاحقاً من '
            'قائمة المستبعدة.',
        actionLabel: 'استبعاد',
        actionColor: AppTheme.dangerStrongFor(context),
      );
      if (!ok) return;
      final done = await RevocationService.instance.discardUnverifiedPendingOp(
        boxName: op['box']?.toString() ?? '',
        key: op['key']?.toString() ?? '',
        companyCode: widget.companyCode,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(done ? 'تم استبعاد العملية' : 'تعذر الاستبعاد'),
        ),
      );
      _reload();
    });
  }

  // يستعيد العملية
  Future<void> _recover(Map<String, dynamic> op) async {
    return CachePartitions.run(() async {
      final done = await RevocationService.instance.recoverDiscardedPendingOp(
        boxName: op['box']?.toString() ?? '',
        key: op['key']?.toString() ?? '',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            done
                ? 'تم الاسترجاع: عادت العملية لقائمة التسوية'
                : 'تعذر الاسترجاع',
          ),
        ),
      );
      _reload();
    });
  }

  // يبني بطاقة عملية
  Widget _opCard(
    Map<String, dynamic> op, {
    required List<Widget> actions,
  }) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'القسم: ${op['section']}',
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _opDescription(op),
              style: TextStyle(
                color: AppTheme.textSoftFor(context),
                fontFamily: 'Cairo',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              op['key']?.toString() ?? '',
              style: TextStyle(
                color: AppTheme.textSoftFor(context),
                fontSize: 10,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }

  // يبني واجهة العنصر ويعيد شجرة العناصر
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'عمليات معلقة مجهولة المالك',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
            color: AppTheme.textMainFor(context),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppTheme.appBarBgGlass,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textMainFor(context)),
      ),
      backgroundColor: AppTheme.dialogBackground(context),
      body: !_isAdmin
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'هذه الصفحة لمدير النظام فقط',
                  style: TextStyle(
                    color: AppTheme.textSoftFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 16,
                  ),
                ),
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_ops.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'لا توجد عمليات مجهولة المالك',
                            style: TextStyle(
                              color: AppTheme.textSoftFor(context),
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                      )
                    else
                      ..._ops.map(
                        (op) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _opCard(
                            op,
                            actions: [
                              TextButton.icon(
                                onPressed: () => _assignToMe(op),
                                icon: Icon(
                                  Icons.person_add_alt,
                                  color: AppTheme.successFor(context),
                                  size: 18,
                                ),
                                label: Text(
                                  'نسبها لحسابي',
                                  style: TextStyle(
                                    color: AppTheme.successFor(context),
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: () => _discard(op),
                                icon: Icon(
                                  Icons.visibility_off_outlined,
                                  color: AppTheme.dangerStrongFor(context),
                                  size: 18,
                                ),
                                label: Text(
                                  'استبعاد',
                                  style: TextStyle(
                                    color: AppTheme.dangerStrongFor(context),
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_discarded.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () => setState(
                          () => _showDiscarded = !_showDiscarded,
                        ),
                        icon: Icon(
                          _showDiscarded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          color: AppTheme.textSoftFor(context),
                        ),
                        label: Text(
                          'المستبعدة (${_discarded.length}) — قابلة للاسترجاع',
                          style: TextStyle(
                            color: AppTheme.textSoftFor(context),
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                      if (_showDiscarded)
                        ..._discarded.map(
                          (op) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _opCard(
                              op,
                              actions: [
                                TextButton.icon(
                                  onPressed: () => _recover(op),
                                  icon: Icon(
                                    Icons.restore,
                                    color: AppTheme.successFor(context),
                                    size: 18,
                                  ),
                                  label: Text(
                                    'استرجاع',
                                    style: TextStyle(
                                      color: AppTheme.successFor(context),
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }
}
