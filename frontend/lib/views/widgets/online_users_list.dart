// lib/views/widgets/online_users_list.dart

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/theme.dart';
import 'glass_card.dart';

class OnlineUsersList extends StatelessWidget {
  final String companyCode;
  final String selectedBranchCode;
  final List<String>? myAllowedBranches;

  const OnlineUsersList({
    super.key,
    required this.companyCode,
    required this.selectedBranchCode,
    this.myAllowedBranches,
  });

  /// هل أنا عندي صلاحية "كل الفروع"؟
  bool get _hasAllBranches =>
      myAllowedBranches?.contains('all') ?? false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance.ref('presence').onValue,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.snapshot.value == null) {
          return _emptyCard(context);
        }

        final data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;
        final now = DateTime.now();
        final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

        final users = <Map<String, dynamic>>[];

        for (final entry in data.entries) {
          if (entry.value is! Map) continue;

          final u = Map<String, dynamic>.from(
            (entry.value as Map).map((k, v) => MapEntry(k.toString(), v)),
          );

          // 1) فلتر الشركة فقط — كل مستخدمي نفس الشركة يظهروا
          if ((u['company_code'] ?? '').toString() != companyCode) continue;

          final otherBranch = (u['current_branch'] ?? '').toString();
          final isInMyBranch = otherBranch == selectedBranchCode;
          final isOnlineRaw = u['state'] == 'online';

          // 2) الحالة:
          // - أنا عندي all → online لو state=online
          // - أنا عندي فرع معين → online بس لو state=online AND نفس الفرع
          // - غير كده → offline (حتى لو متصل في فرع تاني)
          final bool isOnline;
          if (_hasAllBranches) {
            isOnline = isOnlineRaw;
          } else {
            isOnline = isOnlineRaw && isInMyBranch;
          }

          final lastChangedMs = u['last_changed'] as int?;
          DateTime? lastSeen;
          if (lastChangedMs != null) {
            lastSeen = DateTime.fromMillisecondsSinceEpoch(lastChangedMs);
          }

          // 3) نص الحالة
          // لو مستخدم متصل في فرع تاني (وأنا لست all) → يظهر offline عادي
          // بنستخدم last_seen الحقيقي عشان "آخر ظهور" يبقى منطقي
          final String statusText;
          if (isOnline) {
            statusText = 'متصل الآن';
          } else if (lastSeen == null) {
            statusText = 'لم يسجل حضوره بعد';
          } else {
            statusText = 'آخر ظهور ${_formatDuration(now.difference(lastSeen))}';
          }

          users.add({
            'uid': u['uid'] ?? entry.key,
            'name': (u['name'] ?? 'مستخدم').toString(),
            'email': (u['email'] ?? '').toString(),
            'branch': (u['current_branch_name'] ?? otherBranch).toString(),
            'last_seen': lastSeen,
            'is_online': isOnline,
            'is_me': (u['uid'] ?? entry.key) == currentUid,
            'status_text': statusText,
          });
        }

        if (users.isEmpty) return _emptyCard(context);

        // ترتيب: المتصلين أولاً، بعدها أبجدي
        users.sort((a, b) {
          if (a['is_online'] != b['is_online']) {
            return a['is_online'] == true ? -1 : 1;
          }
          return (a['name'] as String).compareTo(b['name'] as String);
        });

        final onlineCount = users.where((u) => u['is_online'] == true).length;
        final totalCount = users.length;

        return GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.group_rounded,
                        color: AppTheme.warningFor(context), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'المستخدمون',
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: onlineCount > 0
                            ? Colors.green.withValues(alpha: 0.15)
                            : Colors.red.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$onlineCount / $totalCount',
                        style: TextStyle(
                          color: onlineCount > 0
                              ? Colors.green
                              : Colors.red,
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: users.length,
                separatorBuilder: (_, __) => Divider(
                    color: GlassStyle.line10For(context), height: 1),
                itemBuilder: (context, index) {
                  final u = users[index];
                  final isOnline = u['is_online'] == true;
                  final isMe = u['is_me'] == true;
                  final branch = (u['branch'] ?? '').toString();
                  final statusText = (u['status_text'] ?? '').toString();

                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 2),
                    leading: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: GlassStyle.fill10For(context),
                          child: Text(
                            (u['name'] as String).isNotEmpty
                                ? (u['name'] as String)[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: isOnline ? Colors.green : Colors.red,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppTheme.modalPanelFor(context),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            u['name'] as String,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textMainFor(context),
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              fontWeight: isMe
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.warningFor(context)
                                  .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'أنت',
                              style: TextStyle(
                                color: AppTheme.warningFor(context),
                                fontFamily: 'Cairo',
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          statusText,
                          style: TextStyle(
                            color: isOnline
                                ? Colors.green
                                : AppTheme.textMutedFor(context),
                            fontFamily: 'Cairo',
                            fontSize: 11,
                          ),
                        ),
                        if (branch.isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.storefront,
                                  size: 11,
                                  color: AppTheme.textMutedFor(context)),
                              const SizedBox(width: 3),
                              Text(
                                branch,
                                style: TextStyle(
                                  color: AppTheme.textMutedFor(context),
                                  fontFamily: 'Cairo',
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyCard(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            'لا يوجد مستخدمون',
            style: TextStyle(
              color: AppTheme.textMutedFor(context),
              fontFamily: 'Cairo',
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return 'منذ لحظات';
    if (d.inMinutes < 60) {
      final m = d.inMinutes;
      if (m == 1) return 'منذ دقيقة';
      if (m == 2) return 'منذ دقيقتين';
      if (m <= 10) return 'منذ $m دقائق';
      return 'منذ $m دقيقة';
    }
    if (d.inHours < 24) {
      final h = d.inHours;
      if (h == 1) return 'منذ ساعة';
      if (h == 2) return 'منذ ساعتين';
      if (h <= 10) return 'منذ $h ساعات';
      return 'منذ $h ساعة';
    }
    final days = d.inDays;
    if (days == 1) return 'منذ يوم';
    if (days == 2) return 'منذ يومين';
    if (days <= 10) return 'منذ $days أيام';
    return 'منذ $days يوم';
  }
}