import '../../services/cache_partitions.dart';
// lib/views/dashboard/notifications_page.dart

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/theme.dart';
import '../../services/notifications_service.dart';
import '../../services/notification_router.dart';
import '../../views/widgets/glass_card.dart';
import '../../services/permissions_service.dart';

class NotificationsPage extends StatefulWidget {
  final String companyCode;
  const NotificationsPage({super.key, required this.companyCode});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final NotificationsService _service = NotificationsService.instance;
  final Map<String, String> _branchNames = {};

  @override
  void initState() {
    super.initState();
    _service.setCompany(widget.companyCode);
    _loadBranches();
  }

  void _loadBranches() {
    if (!CachePartitions.isBoxOpen('coding_box')) return;
    final box = CachePartitions.box('coding_box');
    final branches = box.get('${widget.companyCode}_branches', defaultValue: []);
    if (branches is! List) return;

    for (final branch in branches) {
      if (branch is! Map) continue;
      final code = (branch['code'] ?? '').toString().trim();
      final name = (branch['name'] ?? '').toString().trim();
      if (code.isNotEmpty && name.isNotEmpty) {
        _branchNames[code] = name;
      }
    }
  }

  Future<void> _refresh() async {
return CachePartitions.run(() async {

    await _service.refreshUnreadFromServer(companyCode: widget.companyCode);
    if (mounted) setState(() {});
});
}

  String _branchLabel(Map<String, dynamic> item) {
    final code = (item['branch_code'] ?? '').toString().trim();
    final directName =
        (item['branch_name'] ?? item['branchName'] ?? '').toString().trim();

    if (directName.isNotEmpty) return directName;
    if (code.isEmpty) return '';
    return _branchNames[code] ?? code;
  }

  String _formatDate(String value) {
    if (value.trim().isEmpty) return '';

    try {
      final input = value.trim();
      final hasTimezone =
          RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false)
              .hasMatch(input);
      final parsed =
          DateTime.parse(hasTimezone ? input : '${input}Z').toUtc();
      final year = parsed.year;

      final aprilEnd = DateTime.utc(year, 5, 0);
      final lastThursdayApril = aprilEnd.subtract(
        Duration(days: (aprilEnd.weekday - DateTime.thursday + 7) % 7),
      );
      final dstStart = DateTime.utc(year, 4, lastThursdayApril.day, 22);

      final octoberEnd = DateTime.utc(year, 11, 0);
      final lastThursdayOctober = octoberEnd.subtract(
        Duration(days: (octoberEnd.weekday - DateTime.thursday + 7) % 7),
      );
      final dstEnd = DateTime.utc(year, 10, lastThursdayOctober.day, 21);

      final isDaylightSaving =
          !parsed.isBefore(dstStart) && parsed.isBefore(dstEnd);
      final date = parsed.add(Duration(hours: isDaylightSaving ? 3 : 2));

      String two(int number) => number.toString().padLeft(2, '0');
      return '${two(date.day)}/${two(date.month)}/${date.year}  '
          '${two(date.hour)}:${two(date.minute)}';
    } catch (_) {
      return value.replaceFirst('T', ' ').split('.').first;
    }
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
            'الإشعارات',
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
        title: Text(
          'الإشعارات',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'تحديث الإشعارات',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'تحديد الكل كمقروء',
            icon: const Icon(Icons.done_all),
            onPressed: () async {
return CachePartitions.run(() async {

              await _service.markAllRead(companyCode: widget.companyCode);
              if (mounted) setState(() {});

});
},
          ),
          IconButton(
            tooltip: 'مسح الإشعارات',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
return CachePartitions.run(() async {

              await _service.clear(companyCode: widget.companyCode);
              if (mounted) setState(() {});

});
},
          ),
        ],
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
          child: ValueListenableBuilder(
            valueListenable: CachePartitions.box('notifications_box').listenable(),
            builder: (context, box, _) {
              final items = _service.getNotifications(
                companyCode: widget.companyCode,
              );

              return RefreshIndicator(
                onRefresh: _refresh,
                child: items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height:
                                MediaQuery.of(context).size.height * 0.55,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.notifications_none_rounded,
                                    size: 54,
                                    color: AppTheme.textMutedFor(context),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'لا توجد إشعارات حتى الآن',
                                    style: TextStyle(
                                      color: AppTheme.textMutedFor(context),
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return _buildSwipeableItem(item);
                        },
                      ),
              );
            },
          ),
        ),
      ),
    );
  }

  // ============================================================
  // ⭐ Swipeable Item — الحل 2
  //
  // - Swipe يمين → [✓] markRead (يرجع مكانه)
  // - Swipe يسار → [🗑️] حذف (يتشال)
  // - Tap عادي → markRead + فتح الصفحة
  // ============================================================

  Widget _buildSwipeableItem(Map<String, dynamic> item) {
    final read = item['read'] == true;
    // ⭐ key فريد لكل إشعار — مطلوب لـ Dismissible
    final itemKey = ValueKey(
      'notif_${item['id']}_${item['read']}_${read ? 'r' : 'u'}',
    );

    return Dismissible(
      key: itemKey,
      direction: DismissDirection.horizontal,

      // ────────────────────────────────────────────
      // Swipe يمين → [✓] markRead
      // ────────────────────────────────────────────
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: AppTheme.successStrongFor(context).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              read ? Icons.check_circle_rounded : Icons.done_rounded,
              color: Colors.white,
              size: 28,
            ),
            const SizedBox(width: 8),
            Text(
              'تم القراءة',
              style: const TextStyle(
                fontFamily: 'Cairo',
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),

      // ────────────────────────────────────────────
      // Swipe يسار → [🗑️] حذف
      // ────────────────────────────────────────────
      secondaryBackground: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: AppTheme.dangerStrongFor(context).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(
              'حذف',
              style: const TextStyle(
                fontFamily: 'Cairo',
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.delete_outline_rounded,
              color: Colors.white,
              size: 28,
            ),
          ],
        ),
      ),

      // ⭐ confirmDismiss → نتحكم في هل العنصر يتشال ولا يرجع
      confirmDismiss: (direction) async {
return CachePartitions.run(() async {

        if (direction == DismissDirection.startToEnd) {
          // ─── Swipe يمين → markRead فقط ───
          if (!read) {
            await _service.markRead(item['id'].toString());
          }
          if (mounted) setState(() {});
          // ⭐ return false → يرجع مكانه (مش يتشال)
          return false;
        } else if (direction == DismissDirection.endToStart) {
          // ─── Swipe يسار → حذف ───
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppTheme.dialogBackground(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              title: Text(
                'حذف الإشعار',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMainFor(context),
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                'هل تريد حذف هذا الإشعار نهائياً؟',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppTheme.textMutedFor(context),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    'إلغاء',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.textMutedFor(context),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    'حذف',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppTheme.dangerStrongFor(context),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );

          if (confirmed == true) {
            await _service.deleteNotification(
              notificationId: item['id'].toString(),
            );
            return true; // ⭐ يتشال
          }
          return false; // المستخدم لغى → يرجع
        }
        return false;
});
},

      // ────────────────────────────────────────────
      // المحتوى (البطاقة نفسها)
      // ────────────────────────────────────────────
      child: _buildNotificationCard(item),
    );
  }

  Widget _buildNotificationCard(Map<String, dynamic> item) {
    final read = item['read'] == true;
    final branch = _branchLabel(item);
    final createdAt = (item['created_at'] ?? '').toString();

    return GlassCard(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: Icon(
            read
                ? Icons.notifications_none_rounded
                : Icons.notifications_active_rounded,
            color: read
                ? AppTheme.textMutedFor(context)
                : AppTheme.accentFor(context),
            size: 28,
          ),
          title: Text(
            (item['title'] ?? 'تغيير').toString(),
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontWeight: read ? FontWeight.normal : FontWeight.bold,
              fontFamily: 'Cairo',
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              [
                if ((item['actor_name'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty)
                  'بواسطة: ${item['actor_name']}',
                if ((item['body'] ?? '').toString().trim().isNotEmpty)
                  item['body'].toString(),
                if (branch.isNotEmpty) 'الفرع: $branch',
                if (createdAt.isNotEmpty) _formatDate(createdAt),
              ].join('\n'),
              style: TextStyle(
                color: AppTheme.textMutedFor(context),
                fontFamily: 'Cairo',
                height: 1.6,
              ),
            ),
          ),
          onTap: () async {
return CachePartitions.run(() async {

            if (!read) {
              await _service.markRead(item['id'].toString());
              if (mounted) setState(() {});
            }

            await NotificationRouter.openNotification(
              Map<String, dynamic>.from(item),
            );

});
},
        ),
      ),
    );
  }
}
