import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../views/widgets/glass_card.dart';
import '../auth/login_screen.dart';
import 'coding_page.dart';
import 'daily_page.dart';
import 'reports_dashboard_page.dart';
import 'settings_page.dart';
import '../../main.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/coding_service.dart';
import '../../models/coding_model.dart';
import '../../services/permissions_service.dart';
import '../../views/dashboard/inventory_page.dart';
import 'stock_balance_page.dart';
import 'suppliers_dashboard_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'notifications_page.dart';
import 'product_lookup_page.dart';
import '../../services/notifications_service.dart';
import '../../services/presence_service.dart';
import '../../views/widgets/online_users_list.dart';

class HomePage extends StatefulWidget {
  final String userName;
  final String companyName;
  final String companyCode;

  const HomePage({
    super.key,
    required this.userName,
    required this.companyName,
    required this.companyCode,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late Timer _timer;
  int _secondsElapsed = 0;
  String _currentTime = "";
  String _currentDate = "";
  late AnimationController _mainController;

  final CodingService _codingService = CodingService();
  String _selectedBranchName = "كل الفروع";
  String _selectedBranchCode = "all";
  List<Map<String, String>> _branches = [{'name': 'كل الفروع', 'code': 'all'}];
  bool _isLoadingBranches = true;
  bool _permissionsLoaded = false;

  Timer? _permissionsDebounce;
  bool _branchCheckInProgress = false;
  bool _branchDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationsService.instance.setCompany(widget.companyCode);
    PresenceService.instance.start();
    PermissionsService().addListener(_onPermissionsChanged);

    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
          _currentTime = DateFormat('hh:mm a').format(DateTime.now());
          _currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAllData();
    });
  }

  void _onPermissionsChanged() {
    if (!mounted) return;

    setState(() {
      _permissionsLoaded = PermissionsService().isLoaded;
    });

    _permissionsDebounce?.cancel();
    _permissionsDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _loadBranchesAndCheck(showDialog: false);
    });
  }

  Future<void> _loadAllData() async {
    try {
      if (!PermissionsService().isLoaded) {
        await PermissionsService().loadPermissions();
      }

      if (!mounted) return;

      setState(() {
        _permissionsLoaded = true;
      });

      await _loadBranchesAndCheck(showDialog: true);
    } catch (e) {
      print("خطأ في تحميل البيانات: $e");

      if (mounted) {
        setState(() {
          _permissionsLoaded = true;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PresenceService.instance.refresh();
    }
  }

  Future<void> _loadBranchesAndCheck({bool showDialog = true}) async {
    if (_branchCheckInProgress) return;
    _branchCheckInProgress = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final Box codingBox = Hive.box('coding_box');
      final String localKey = "${widget.companyCode}_branches";

      List<Map<String, String>> fetchedBranches = [];

      final dynamic rawData = codingBox.get(localKey, defaultValue: []);

      if (rawData is List) {
        for (final item in rawData) {
          if (item is Map && item['name'] != null && item['code'] != null) {
            fetchedBranches.add({
              'name': item['name'].toString(),
              'code': item['code'].toString(),
            });
          }
        }
      }

      if (fetchedBranches.isEmpty) {
        print("📥 الفروع غير موجودة محلياً.. جاري الجلب من السيرفر");

        final List<CodingModel> branchesData = await _codingService.getCodingList(
          companyCode: widget.companyCode,
          category: "branches",
        );

        fetchedBranches = branchesData.map((item) => {
          'name': item.name,
          'code': item.code,
        }).toList();
      }

      final List<String>? allowed = PermissionsService().allowedBranches;

      List<Map<String, String>> filteredBranches;

      if (allowed != null && !allowed.contains('all')) {
        filteredBranches = fetchedBranches.where((branch) => allowed.contains(branch['code'])).toList();
      } else {
        filteredBranches = List<Map<String, String>>.from(fetchedBranches);
      }

      if (allowed == null || allowed.contains('all')) {
        filteredBranches.insert(0, {'name': 'كل الفروع', 'code': 'all'});
      }

      if (filteredBranches.isEmpty) {
        filteredBranches = [{'name': 'لا توجد فروع مسموحة', 'code': 'none'}];
      }

      final String email = prefs.getString('user_email') ?? '';
      final bool showBranchDialog = prefs.getBool('show_branch_dialog_$email') ?? true;

      String selectedCode = 'all';
      String selectedName = 'كل الفروع';

      final String? savedBranchCode = prefs.getString('selected_branch_code');
      final String? savedBranchName = prefs.getString('selected_branch_name');

      final bool savedBranchIsAllowed = savedBranchCode != null &&
          filteredBranches.any((branch) => branch['code'] == savedBranchCode) &&
          savedBranchCode != 'none';

      if (savedBranchIsAllowed) {
        selectedCode = savedBranchCode;
        selectedName = savedBranchName ?? 'كل الفروع';
      } else {
        final List<Map<String, String>> realBranches = filteredBranches
            .where((branch) => branch['code'] != 'all' && branch['code'] != 'none')
            .toList();

        if (realBranches.length == 1) {
          selectedCode = realBranches.first['code'] ?? 'all';
          selectedName = realBranches.first['name'] ?? 'فرع';

          await prefs.setString('selected_branch_code', selectedCode);
          await prefs.setString('selected_branch_name', selectedName);

          print("✅ تم اختيار الفرع الوحيد: $selectedName ($selectedCode)");
        } else if (realBranches.length > 1) {
          selectedCode = realBranches.first['code'] ?? 'all';
          selectedName = realBranches.first['name'] ?? 'فرع';

          await prefs.setString('selected_branch_code', selectedCode);
          await prefs.setString('selected_branch_name', selectedName);

          print("✅ تم اختيار الفرع الافتراضي: $selectedName ($selectedCode)");
        } else if (filteredBranches.any((branch) => branch['code'] == 'all')) {
          selectedCode = 'all';
          selectedName = 'كل الفروع';
        } else {
          selectedCode = 'none';
          selectedName = 'لا توجد فروع';
        }
      }

      if (!mounted) return;

      setState(() {
        _branches = filteredBranches;
        _selectedBranchCode = selectedCode;
        _selectedBranchName = selectedName;
        _isLoadingBranches = false;
      });
      PresenceService.instance.refresh();

      if (showDialog) {
        final List<Map<String, String>> realBranches = filteredBranches
            .where((branch) => branch['code'] != 'all' && branch['code'] != 'none')
            .toList();

        if (realBranches.length > 1 &&
            showBranchDialog &&
            PermissionsService().canChangeBranch) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_branchDialogOpen) {
              _showBranchSelectionDialog();
            }
          });
        }
      }
    } catch (e) {
      print("❌ خطأ في جلب الفروع: $e");

      if (mounted) {
        setState(() {
          _isLoadingBranches = false;
        });
      }
    } finally {
      _branchCheckInProgress = false;
    }
  }

  void _showBranchSelectionDialog() {
    if (_branchDialogOpen) return;
    _branchDialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: _selectedBranchCode != "all",
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(
          "اختر فرع العمل الحالي",
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMainFor(context), fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _branches.length,
            itemBuilder: (context, index) {
              String branchName = _branches[index]['name']!;
              String branchCode = _branches[index]['code']!;
              bool isCurrent = _selectedBranchCode == branchCode;
              return Card(
                color: isCurrent ? GlassStyle.warningFill20For(context) : GlassStyle.fill05For(context),
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  title: Text(
                    branchName,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: isCurrent ? AppTheme.warningFor(context) : AppTheme.textMainFor(context), fontFamily: 'Cairo', fontSize: 14),
                  ),
                  onTap: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('selected_branch_code', branchCode);
                    await prefs.setString('selected_branch_name', branchName);
                    if (mounted) {
                      setState(() {
                        _selectedBranchCode = branchCode;
                        _selectedBranchName = branchName;
                      });
                    }
                    PresenceService.instance.refresh();
                    Navigator.pop(context);
                  },
                ),
              );
            },
          ),
        ),
      ),
    ).then((_) {
      _branchDialogOpen = false;
    });
  }

  String _formatDuration(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  Future<void> _showNotificationsPreview() async {
    if (!mounted) return;

    String formatNotificationDate(String value) {
      if (value.trim().isEmpty) return '';

      try {
        final input = value.trim();
        final hasTimezone = RegExp(
          r'(Z|[+-]\d{2}:?\d{2})$',
          caseSensitive: false,
        ).hasMatch(input);

        final parsed = DateTime.parse(
          hasTimezone ? input : '${input}Z',
        ).toUtc();

        final year = parsed.year;

        final aprilEnd = DateTime.utc(year, 5, 0);
        final lastThursdayApril = aprilEnd.subtract(
          Duration(
            days: (aprilEnd.weekday - DateTime.thursday + 7) % 7,
          ),
        );
        final dstStart = DateTime.utc(
          year,
          4,
          lastThursdayApril.day,
          22,
        );

        final octoberEnd = DateTime.utc(year, 11, 0);
        final lastThursdayOctober = octoberEnd.subtract(
          Duration(
            days: (octoberEnd.weekday - DateTime.thursday + 7) % 7,
          ),
        );
        final dstEnd = DateTime.utc(
          year,
          10,
          lastThursdayOctober.day,
          21,
        );

        final isDaylightSaving =
            !parsed.isBefore(dstStart) && parsed.isBefore(dstEnd);

        final date = parsed.add(
          Duration(hours: isDaylightSaving ? 3 : 2),
        );

        String two(int number) => number.toString().padLeft(2, '0');

        return '${two(date.day)}/${two(date.month)}/${date.year}  '
            '${two(date.hour)}:${two(date.minute)}';
      } catch (_) {
        return value.replaceFirst('T', ' ').split('.').first;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return ValueListenableBuilder<Box>(
            valueListenable: Hive.box('notifications_box').listenable(),
            builder: (context, box, _) {
              final latestItems = NotificationsService.instance
                  .getNotifications(companyCode: widget.companyCode)
                  .take(10)
                  .toList();

              return AlertDialog(
                backgroundColor: AppTheme.dialogBackground(context),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'آخر الإشعارات',
                        style: TextStyle(
                          color: AppTheme.textMainFor(context),
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'تحديث',
                      onPressed: () async {
                        await NotificationsService.instance
                            .refreshUnreadFromServer(
                          companyCode: widget.companyCode,
                        );
                        if (dialogContext.mounted) setDialogState(() {});
                      },
                      icon: Icon(
                        Icons.refresh,
                        color: AppTheme.textMainFor(context),
                      ),
                    ),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppTheme.dangerFor(context),
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 420,
                  child: latestItems.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Center(
                            child: Text(
                              'لا توجد إشعارات حتى الآن',
                              style: TextStyle(
                                color: AppTheme.textMutedFor(context),
                                fontFamily: 'Cairo',
                              ),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: latestItems.length,
                          separatorBuilder: (_, __) => Divider(
                            color: GlassStyle.line10For(context),
                            height: 1,
                          ),
                          itemBuilder: (context, index) {
                            final item = latestItems[index];
                            final isRead = item['read'] == true;
                            final branchCode =
                                (item['branch_code'] ?? '')
                                    .toString()
                                    .trim();

                            final branch = _branches
                                    .where(
                                      (b) =>
                                          (b['code'] ?? '').toString() ==
                                          branchCode,
                                    )
                                    .map((b) =>
                                        (b['name'] ?? '').toString())
                                    .where((name) => name.isNotEmpty)
                                    .firstOrNull ??
                                branchCode;

                            final createdAt = formatNotificationDate(
                              (item['created_at'] ?? '').toString(),
                            );

                            final actorName =
                                (item['actor_name'] ?? '')
                                    .toString()
                                    .trim();
                            final body =
                                (item['body'] ?? '').toString().trim();

                            return Material(
                              color: Colors.transparent,
                              child: ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                leading: Icon(
                                  isRead
                                      ? Icons.notifications_none_rounded
                                      : Icons
                                          .notifications_active_rounded,
                                  color: isRead
                                      ? AppTheme.textMutedFor(context)
                                      : AppTheme.accentFor(context),
                                ),
                                title: Text(
                                  (item['title'] ?? 'تغيير').toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        AppTheme.textMainFor(context),
                                    fontFamily: 'Cairo',
                                    fontSize: 13,
                                    fontWeight: isRead
                                        ? FontWeight.normal
                                        : FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  [
                                    if (actorName.isNotEmpty)
                                      'بواسطة: $actorName',
                                    if (body.isNotEmpty) body,
                                    if (branch.isNotEmpty)
                                      'الفرع: $branch',
                                    if (createdAt.isNotEmpty)
                                      createdAt,
                                  ].join('\n'),
                                  maxLines: 6,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                        AppTheme.textMutedFor(context),
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    height: 1.4,
                                  ),
                                ),
                                onTap: () async {
                                  if (item['read'] != true) {
                                    await NotificationsService.instance
                                        .markRead(
                                      item['id'].toString(),
                                    );
                                  }

                                  if (dialogContext.mounted) {
                                    setDialogState(() {});
                                  }
                                  if (mounted) setState(() {});
                                },
                              ),
                            );
                          },
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      await NotificationsService.instance
                          .markAllRead(
                        companyCode: widget.companyCode,
                      );
                      if (dialogContext.mounted) setDialogState(() {});
                      if (mounted) setState(() {});
                    },
                    child: Text(
                      'تحديد الكل كمقروء',
                      style: TextStyle(
                        color: AppTheme.accentFor(context),
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NotificationsPage(
                            companyCode: widget.companyCode,
                          ),
                        ),
                      );
                    },
                    child: Text(
                      'عرض كل الإشعارات',
                      style: TextStyle(
                        color: AppTheme.accentFor(context),
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: AppTheme.dashGradientDeep(context),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            child: Column(
              children: [
                const Text(
                  "IslamApp V1.0",
                  style: TextStyle(
                    color: AppTheme.brandVersionText,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                _buildHeader(),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.timer, color: AppTheme.dangerFor(context), size: 16),
                    const SizedBox(width: 5),
                    Text("وقت النشاط: ", style: TextStyle(color: AppTheme.textSoftFor(context), fontSize: 13, fontFamily: 'Cairo')),
                    Text(_formatDuration(_secondsElapsed), style: TextStyle(color: AppTheme.dangerFor(context), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 15),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    _buildSmallInfo("الوقت", _currentTime, Icons.access_time, AppTheme.warningFor(context)),
                    _buildSmallInfo("التاريخ", _currentDate, Icons.calendar_today, AppTheme.infoSoftFor(context)),
                    _buildSmallInfo("الفرع النشط", _selectedBranchName, Icons.storefront, AppTheme.successFor(context)),
                  ],
                ),
                const SizedBox(height: 20),
                _buildMenuGrid(),
                const SizedBox(height: 20),
                _buildBottomActions(),
                const SizedBox(height: 20),

                if (_permissionsLoaded && PermissionsService().canShowOnlineUsers)
                  OnlineUsersList(
                    companyCode: widget.companyCode,
                    selectedBranchCode: _selectedBranchCode,
                    myAllowedBranches: PermissionsService().allowedBranches,
                  ),

                const SizedBox(height: 15),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.business, color: AppTheme.warningFor(context), size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.companyName, style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
                Text("مرحبا: ${widget.userName}", style: TextStyle(color: AppTheme.textMutedFor(context), fontSize: 12, fontFamily: 'Cairo')),
              ],
            ),
          ),
          if (PermissionsService().canShowNotifications)
            ValueListenableBuilder<Box>(
              valueListenable: Hive.box('notifications_box').listenable(),
              builder: (context, box, _) {
                final unread = NotificationsService.instance.unreadCount(companyCode: widget.companyCode);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      tooltip: 'الإشعارات',
                      icon: Icon(Icons.notifications_none_rounded, color: AppTheme.textMainFor(context), size: 26),
                      onPressed: _showNotificationsPreview,
                    ),
                    if (unread > 0)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
                          decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                          child: Text(unread > 99 ? '99+' : '$unread', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (!_isLoadingBranches && PermissionsService().canChangeBranch && !PermissionsService().hasSingleBranch())
            InkWell(
              onTap: _showBranchSelectionDialog,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: GlassStyle.warningFill15For(context),
                  border: Border.all(color: GlassStyle.warningBorder50For(context)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, color: AppTheme.warningFor(context), size: 16),
                    const SizedBox(width: 4),
                    Text("تغيير الفرع", style: TextStyle(color: AppTheme.warningFor(context), fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSmallInfo(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: GlassStyle.fill05For(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: GlassStyle.line10For(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text("$label: ", style: TextStyle(color: AppTheme.textSoftFor(context), fontSize: 11, fontFamily: 'Cairo')),
          Text(value, style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
        ],
      ),
    );
  }

  Widget _buildMenuGrid() {
    List<Widget> menuItems = [];

    if (_permissionsLoaded && PermissionsService().canShowTreasury) {
      menuItems.add(
        _menuItem("حركة الخزينة", Icons.account_balance_wallet_rounded, AppTheme.successFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => DailyPage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
                userName: widget.userName,
              ),
            ),
          );
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowCoding) {
      menuItems.add(
        _menuItem("التكويد", Icons.code_rounded, AppTheme.warningFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (c) => CodingPage(companyCode: widget.companyCode)),
          ).then((_) {
            _loadBranchesAndCheck(showDialog: false);
          });
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowSuppliers) {
      menuItems.add(
        _menuItem(
          "المشتريات والموردين",
          Icons.shopping_cart_rounded,
          AppTheme.infoSoftFor(context),
          () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => SuppliersDashboardPage(
                  companyCode: widget.companyCode,
                  selectedBranchCode: _selectedBranchCode,
                  userName: widget.userName,
                ),
              ),
            );
          },
        ),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowInventory) {
      menuItems.add(
        _menuItem("حركة الجرد", Icons.inventory_2_rounded, AppTheme.warningOrangeSoftFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => InventoryPage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
              ),
            ),
          );
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowInventory) {
      menuItems.add(
        _menuItem("رصيد المخزون", Icons.storage_rounded, AppTheme.extraTealFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => StockBalancePage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
              ),
            ),
          );
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowReports) {
      menuItems.add(
        _menuItem("التقارير", Icons.analytics_rounded, AppTheme.extraPurpleFor(context), () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (c) => ReportsDashboardPage(
                companyCode: widget.companyCode,
                selectedBranchCode: _selectedBranchCode,
              ),
            ),
          );
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowProductLookup) {
      menuItems.add(
        _menuItem("البحث عن المنتجات", Icons.qr_code_scanner_rounded, AppTheme.extraTealFor(context), () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => const ProductLookupPage()));
        }),
      );
    }

    if (_permissionsLoaded && PermissionsService().canShowNotifications) {
      menuItems.add(
        _menuItem("الإشعارات", Icons.notifications_active_rounded, AppTheme.infoSoftFor(context), () {
          Navigator.push(context, MaterialPageRoute(builder: (c) => NotificationsPage(companyCode: widget.companyCode)));
        }),
      );
    }

    menuItems.add(
      _menuItem("الاعدادات", Icons.settings_rounded, AppTheme.extraBlueGreyFor(context), () async {
        await Navigator.push(context, MaterialPageRoute(builder: (c) => const SettingsPage()));
      }),
    );

    if (menuItems.isEmpty) {
      return Center(
        child: Text(
          "لا توجد صلاحيات متاحة لك",
          style: TextStyle(color: AppTheme.textSoftFor(context), fontFamily: 'Cairo', fontSize: 14),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        double screenWidth = constraints.maxWidth;
        int crossAxisCount;
        double childAspectRatio;

        if (screenWidth > 800) {
          crossAxisCount = 4;
          childAspectRatio = 1.3;
        } else if (screenWidth > 500) {
          crossAxisCount = 3;
          childAspectRatio = 1.2;
        } else {
          crossAxisCount = 2;
          childAspectRatio = 1.1;
        }

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 15,
          crossAxisSpacing: 15,
          childAspectRatio: childAspectRatio,
          children: menuItems,
        );
      },
    );
  }

  Widget _menuItem(String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: GlassCard(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMainFor(context), fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActions() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _bottomBtn("الدعم الفني", Icons.headset_mic_rounded, AppTheme.textMutedFor(context), () {})),
            const SizedBox(width: 12),
            Expanded(child: _bottomBtn("تسجيل الخروج", Icons.logout_rounded, AppTheme.dangerFor(context), _handleLogout)),
          ],
        ),
        const SizedBox(height: 15),
      ],
    );
  }

  Widget _bottomBtn(String label, IconData icon, Color color, VoidCallback action) {
    return InkWell(
      onTap: action,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: GlassStyle.fill03For(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: GlassStyle.line10For(context)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // ✅ _handleLogout — الترتيب الصح:
  // 1) أوقف الحضور (RTDB write)
  // 2) انتظر شوية عشان الـ write يوصل للسيرفر
  // 3) امسح prefs
  // 4) signOut
  // 5) navigate
  // ============================================================
  Future<void> _handleLogout() async {
    // ✅ 1) أوقف الحضور أولاً — قبل أي حاجة
    try {
      await PresenceService.instance.stop();
    } catch (e) {
      print('⚠️ Presence stop error: $e');
    }

    // ✅ 2) انتظر 500ms عشان الـ RTDB write يتأكد من السيرفر
    // (important: signOut قد يقطع الاتصال قبل ما الـ write يوصل)
    await Future.delayed(const Duration(milliseconds: 500));

    // 3) امسح prefs
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('remember_me');
    await prefs.remove('saved_email');
    await prefs.remove('saved_password');
    await prefs.remove('user_name');
    await prefs.remove('company_name');
    await prefs.remove('company_code');
    await prefs.remove('job_code');
    await prefs.remove('job_title');
    await prefs.remove('user_email');

    // 4) signOut
    await FirebaseAuth.instance.signOut();

    disposeGlobalListener();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PermissionsService().removeListener(_onPermissionsChanged);
    _permissionsDebounce?.cancel();

    // ⚠️ مفيش PresenceService.stop() هنا — بيتنادى في _handleLogout بس
    // عشان لو المستخدم عمل logout، already handled
    // لو التطبيق بيتقفل، RTDB onDisconnect بيتولى الأمر تلقائيًا

    _timer.cancel();
    _mainController.dispose();
    super.dispose();
  }
}