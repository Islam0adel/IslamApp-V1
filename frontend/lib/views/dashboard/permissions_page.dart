import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../core/theme.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart';

class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  String? selectedUserId;
  String? selectedUserJobCode;
  String currentCompanyCode = '';
  bool _isLoading = true;

  Map<String, Map<String, bool>> userPermissions = {};

  List<QueryDocumentSnapshot> usersList = [];
  List<Map<String, String>> _allBranches = [];
  bool _allowAllBranches = true;
  List<String> _selectedBranchCodes = [];

  @override
  void initState() {
    super.initState();
    _loadCompanyCode().then((_) {
      _loadBranches();
    });
  }

  Future<void> _loadBranches() async {
    if (currentCompanyCode.isEmpty) return;

    final box = Hive.box('coding_box');
    final branchesKey = '${currentCompanyCode}_branches';
    var branches = box.get(branchesKey) as List? ?? [];

    if (!mounted) return;

    setState(() {
      _allBranches = branches.map((e) {
        return {
          'code': e['code'].toString(),
          'name': e['name'].toString(),
        };
      }).toList();

      if (_allBranches.isEmpty) {
        _allBranches = [
          {
            'code': 'none',
            'name': 'لا توجد فروع مسجلة',
          }
        ];
      }
    });
  }

  Future<void> _loadCompanyCode() async {
    final prefs = await SharedPreferences.getInstance();

    if (mounted) {
      setState(() {
        currentCompanyCode =
            prefs.getString('company_code') ?? '';
        _isLoading = false;
      });
    }

    await _loadCurrentUserPermissions();
  }

  Future<void> _loadCurrentUserPermissions() async {
    final prefs = await SharedPreferences.getInstance();

    final userEmail =
        prefs.getString('user_email') ?? '';

    final jobCode =
        prefs.getString('job_code') ?? '1';

    if (userEmail.isNotEmpty) {
      if (mounted) {
        setState(() {
          selectedUserId = userEmail;
          selectedUserJobCode = jobCode;
        });
      }

      await _loadUserPermissions(
        userEmail,
        jobCode,
      );
    }
  }

  Stream<QuerySnapshot> getCompanyUsers() {
    return FirebaseFirestore.instance
        .collection('users')
        .where(
          'company_code',
          isEqualTo: currentCompanyCode,
        )
        .snapshots();
  }

  void _applyPermissionsData(dynamic data) {
    if (data == null || data is! Map) return;

    if (!mounted) return;

    setState(() {
      data.forEach((category, perms) {
        if (perms is! Map) return;

        if (!userPermissions.containsKey(category)) {
          userPermissions[category] = {};
        }

        perms.forEach((key, value) {
          userPermissions[category]![key.toString()] =
              value is bool
                  ? value
                  : value.toString().toLowerCase() ==
                      'true';
        });
      });
    });
  }

  Map<String, Map<String, bool>> _createDefaultPermissions(
    String jobCode,
  ) {
    var allPermissions = {
      'حركة الخزينة': {
        'شاشات الارصدة': false,
        'ادخال اذون': false,
        'المعاينة': false,
        'التعديل': false,
        'الحذف': false,
        'استيراد من اكسل': false,
        'تصدير': false,
        'فلترة': false,
      },
      'التكويد': {
        'معاينة': false,
        'اضافة صنف': false,
        'سعر الشراء': false,
        'اضافة فرع': false,
        'اضافة خزينة': false,
        'اضافة مورد': false,
        'اضافة مخزن': false,
        'اضافة عملاء': false,
        'اضافة طرق دفع': false,
        'اضافة بنك': false,
        'اضافة موظف': false,
      },
      'حسابات الموردين': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },
      'تسويات الموردين': {
        'إضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'تصدير': false,
      },
      'حركة الجرد': {
        'اضافة': false,
        'تعديل': false,
        'حذف': false,
        'معاينة': false,
        'استيراد': false,
        'تصدير': false,
      },
      'التقارير': {
        'تقرير المبيعات': false,
        'تقرير فترة': false,
        'مشاركة': false,
        'تقرير التدفق النقدي': false,
        'تحليل المصروفات بالنسبة للمبيعات': false, 
  'تحليل هيكل المصروفات': false,
  'الربحية الصافية لكل فرع': false,
  'تحليل حجم الفاتورة': false,
  'تحليل الخزائن النقدية': false,
  'الأصناف بطيئة الحركة': false,
  'تحليل دقة الجرد': false,
  'تقييم المخزون و ABC': false,
  'تحليل أداء الموردين': false,
  'تحليل العوائد والخصومات': false,
  'تحليل الاتجاهات الموسمية': false,
  'تحليل هامش الربح الفعلي': false,
  'تحليل تجميع المنتجات': false,
  'التقرير الموسع (صافي الجرد)': false,
      },
      'رصيد المخزون': {
        'معاينة': false,
        'عرض سعر الجملة': false,
        'تصدير': false,
      },
      'صلاحيات عامة': {
        'تغيير الفرع(صفحة الهوم)': false,
        'صفحة الصلاحيات(الاعدادات)': false,
        'إظهار حركة الخزينة': false,
        'إظهار التكويد': false,
        'إظهار التقارير': false,
        'إظهار حركة الموردين': false,
        'إظهار حركة الجرد': false,
        'إظهار الإشعارات': true, 
        'إظهار البحث عن المنتجات': false,
      },
    };

    if (jobCode == '99' || jobCode == '200') {
      allPermissions.forEach((category, perms) {
        perms.forEach((key, _) {
          allPermissions[category]![key] = true;
        });
      });
    }

    return allPermissions;
  }

  Future<void> _loadUserPermissions(
  String userId,
  String jobCode,
) async {
  final defaultPerms = _createDefaultPermissions(jobCode);

  if (mounted) {
    setState(() {
      userPermissions = defaultPerms;
    });
  }

  final localKey = 'permissions_$userId';
  final branchesKey = 'allowed_branches_$userId';

  final box = Hive.box('coding_box');

  // ============================================================
  // 1) قراءة الفروع من Hive (لو موجودة)
  // ============================================================
  final savedBranches = box.get(branchesKey);

  if (savedBranches is List) {
    final list = savedBranches.map((e) => e.toString()).toList();

    if (mounted) {
      setState(() {
        if (list.contains('all')) {
          _allowAllBranches = true;
          _selectedBranchCodes = [];
        } else {
          _allowAllBranches = false;
          _selectedBranchCodes = list;
        }
      });
    }
  } else {
    if (mounted) {
      setState(() {
        _allowAllBranches = true;
        _selectedBranchCodes = [];
      });
    }
  }

  // ============================================================
  // 2) قراءة الصلاحيات من Hive (لو موجودة)
  // ============================================================
  if (box.containsKey(localKey)) {
    final data = box.get(localKey);

    if (data != null) {
      _applyPermissionsData(data);
    }
  }

  // ============================================================
  // 3) مزامنة من Firestore
  //    - الصلاحيات
  //    - ✅ الفروع (الإضافة الجديدة)
  // ============================================================
  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .get();

    if (doc.exists) {
      final data = doc.data();

      if (data != null) {

        // ─────────── الصلاحيات ───────────
        if (data.containsKey('permissions')) {
          final firestorePerms = data['permissions'];

          await box.put(localKey, firestorePerms);

          _applyPermissionsData(firestorePerms);
        }

        // ─────────── ✅ الفروع المسموح بها ───────────
        List<String>? branches;
        final rawBranches = data['allowed_branches'];

        if (rawBranches is List) {
          branches = rawBranches.map((e) => e.toString()).toList();
        } else if (rawBranches is String &&
            rawBranches.toLowerCase() == 'all') {
          branches = ['all'];
        }

        if (branches != null && branches.isNotEmpty) {
          // حدّث Hive عشان المرة الجاية القراءة تكون فورية
          await box.put(branchesKey, branches);

          // حدّث الواجهة (بشرط المستخدم لسه مختار)
          if (mounted && selectedUserId == userId) {
            setState(() {
              if (branches!.contains('all')) {
                _allowAllBranches = true;
                _selectedBranchCodes = [];
              } else {
                _allowAllBranches = false;
                _selectedBranchCodes = branches;
              }
            });
          }
        }
      }
    }
  } catch (e) {
    debugPrint(
      'Offline mode: Using Hive permissions data.',
    );
  }
}

  Future<void> savePermissions() async {
    if (selectedUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('برجاء اختيار الموظف أولاً'),
          backgroundColor: AppTheme.warningOrangeFor(context),
        ),
      );
      return;
    }

    List<String> allowedBranches;

    if (_allowAllBranches) {
      allowedBranches = ['all'];
    } else {
      allowedBranches =
          List<String>.from(_selectedBranchCodes);

      if (allowedBranches.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'يرجى اختيار فرع واحد على الأقل أو "كل الفروع"',
            ),
            backgroundColor: AppTheme.warningOrangeFor(context),
          ),
        );
        return;
      }
    }

    try {
      await PermissionsService().savePermissions(
        userPermissions,
        targetEmail: selectedUserId,
        allowedBranches: allowedBranches,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('تم حفظ الصلاحيات بنجاح!'),
            backgroundColor: AppTheme.successStrongFor(context),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم الحفظ محلياً (وضع عدم الاتصال)',
            ),
            backgroundColor:
                AppTheme.warningOrangeSoftFor(context),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // final isDark =
    //     Theme.of(context).brightness ==
    //         Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        // ✅ عدد التبويبات الفعلي = 8
        length: 8,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: AppTheme.permissionsGradient(context),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: _isLoading
                    ? Center(
                        child:
                            CircularProgressIndicator(
                          color:
                              AppTheme.accentFor(context),
                        ),
                      )
                    : Column(
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.all(
                              16.0,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  icon:
                                      Icon(
                                    Icons
                                        .arrow_back_ios_new_rounded,
                                    color:
                                        AppTheme.textMainFor(context),
                                  ),
                                  onPressed: () =>
                                      Navigator.pop(
                                    context,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    'إدارة الصلاحيات',
                                    style:
                                        TextStyle(
                                      color:
                                          AppTheme.textMainFor(context),
                                      fontSize:
                                          22,
                                      fontWeight:
                                          FontWeight.bold,
                                      fontFamily:
                                          'Cairo',
                                    ),
                                    textAlign:
                                        TextAlign
                                            .center,
                                  ),
                                ),
                                Container(
                                  decoration:
                                      BoxDecoration(
                                    color: GlassStyle.fill10For(context),
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      10,
                                    ),
                                  ),
                                  child:
                                      IconButton(
                                    icon:
                                        Icon(
                                      Icons
                                          .save_rounded,
                                      color:
                                          AppTheme.accentFor(context),
                                    ),
                                    onPressed:
                                        savePermissions,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal: 20.0,
                              vertical: 8.0,
                            ),
                            child: Container(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                horizontal: 16,
                              ),
                              decoration:
                                  BoxDecoration(
                                color: GlassStyle.fill05For(context),
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  15,
                                ),
                                border: Border.all(
                                  color: GlassStyle.line10For(context),
                                ),
                              ),
                              child:
                                  StreamBuilder<
                                      QuerySnapshot>(
                                stream:
                                    getCompanyUsers(),
                                builder:
                                    (
                                  context,
                                  snapshot,
                                ) {
                                  if (snapshot
                                          .connectionState ==
                                      ConnectionState
                                          .waiting) {
                                    return Padding(
                                      padding:
                                          EdgeInsets.all(
                                        12.0,
                                      ),
                                      child: Text(
                                        'جاري تحميل الموظفين...',
                                        style:
                                            TextStyle(
                                          color:
                                              AppTheme.textSoftFor(context),
                                          fontFamily:
                                              'Cairo',
                                        ),
                                      ),
                                    );
                                  }

                                  if (!snapshot
                                          .hasData ||
                                      snapshot.data!
                                          .docs.isEmpty) {
                                    return Padding(
                                      padding:
                                          EdgeInsets.all(
                                        12.0,
                                      ),
                                      child: Text(
                                        'لا يوجد موظفين مسجلين',
                                        style:
                                            TextStyle(
                                          color:
                                              AppTheme.textSoftFor(context),
                                          fontFamily:
                                              'Cairo',
                                        ),
                                      ),
                                    );
                                  }

                                  usersList =
                                      snapshot
                                          .data!
                                          .docs;

                                  return DropdownButtonHideUnderline(
                                    child:
                                        DropdownButton<
                                            String>(
                                      dropdownColor:
                                          AppTheme.dropdownBackground(context),
                                      isExpanded:
                                          true,
                                      hint:
                                          Text(
                                        'اختر الموظف',
                                        style:
                                            TextStyle(
                                          color:
                                              AppTheme.textSoftFor(context),
                                          fontFamily:
                                              'Cairo',
                                        ),
                                      ),
                                      value:
                                          selectedUserId,
                                      icon:
                                          Icon(
                                        Icons
                                            .keyboard_arrow_down_rounded,
                                        color:
                                            AppTheme.accentFor(context),
                                      ),
                                      style:
                                          TextStyle(
                                        color:
                                            AppTheme.textMainFor(context),
                                        fontSize:
                                            16,
                                        fontFamily:
                                            'Cairo',
                                      ),
                                      items:
                                          usersList
                                              .map(
                                        (user) {
                                          final data =
                                              user.data()
                                                  as Map<String,
                                                      dynamic>?;

                                          final empName =
                                              data?['name']
                                                      ?.toString() ??
                                                  'بدون اسم';

                                          final empJob =
                                              data?['job_title'] !=
                                                      null
                                                  ? ' - ${data!['job_title']}'
                                                  : '';

                                          return DropdownMenuItem<
                                              String>(
                                            value:
                                                user.id,
                                            child:
                                                Text(
                                              '$empName$empJob',
                                            ),
                                          );
                                        },
                                      ).toList(),
                                      onChanged:
                                          (value) {
                                        if (value ==
                                            null) {
                                          return;
                                        }

                                        final selectedUser =
                                            usersList
                                                .firstWhere(
                                          (u) =>
                                              u.id ==
                                              value,
                                        );

                                        final data =
                                            selectedUser
                                                    .data()
                                                as Map<String,
                                                    dynamic>?;

                                        final jobCode =
                                            data?['job_code']
                                                    ?.toString() ??
                                                '1';

                                        setState(() {
                                          selectedUserId =
                                              value;
                                          selectedUserJobCode =
                                              jobCode;
                                        });

                                        _loadUserPermissions(
                                          value,
                                          jobCode,
                                        );
                                      },
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          TabBar(
                            isScrollable:
                                true,
                            indicatorColor:
                                AppTheme.accentFor(context),
                            labelColor:
                                AppTheme.accentFor(context),
                            unselectedLabelColor:
                                AppTheme.textHintFor(context),
                            labelStyle:
                                TextStyle(
                              fontFamily:
                                  'Cairo',
                              fontWeight:
                                  FontWeight.bold,
                            ),
                            tabs: [
                              Tab(
                                text:
                                    'حركة الخزينة',
                              ),
                              Tab(
                                text:
                                    'التكويد',
                              ),
                              Tab(
                                text:
                                    'حسابات الموردين',
                              ),
                              Tab(
                                text:
                                    'تسويات الموردين',
                              ),
                              Tab(
                                text:
                                    'حركة الجرد',
                              ),
                              Tab(
                                text:
                                    'التقارير',
                              ),
                              Tab(
                                text:
                                    'رصيد المخزون',
                              ),
                              Tab(
                                text:
                                    'صلاحيات عامة',
                              ),
                            ],
                          ),
                          Expanded(
                            child:
                                TabBarView(
                              children: [
                                buildPermissionsTab(
                                  'حركة الخزينة',
                                ),
                                buildPermissionsTab(
                                  'التكويد',
                                ),
                                buildPermissionsTab(
                                  'حسابات الموردين',
                                ),
                                buildPermissionsTab(
                                  'تسويات الموردين',
                                ),
                                buildPermissionsTab(
                                  'حركة الجرد',
                                ),
                                buildPermissionsTab(
                                  'التقارير',
                                ),
                                buildPermissionsTab(
                                  'رصيد المخزون',
                                ),
                                buildPermissionsTab(
                                  'صلاحيات عامة',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  
Widget buildPermissionsTab(String tabName) {
  var permissionsMap = userPermissions[tabName] ?? {};

  if (tabName == 'رصيد المخزون') {
    permissionsMap.remove('عرض قيمة الجملة');
  }

  if (tabName == 'صلاحيات عامة') {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ...permissionsMap.entries.map((entry) {
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: GlassStyle.fill05For(context),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: GlassStyle.line10For(context)),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              child: SwitchListTile(
                activeThumbColor: AppTheme.accentFor(context),
                inactiveTrackColor: GlassStyle.switchTrackOffFor(context),
                title: Text(
                  entry.key,
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 16,
                    fontFamily: 'Cairo',
                  ),
                ),
                value: entry.value,
                onChanged: selectedUserId == null
                    ? null
                    : (newValue) {
                        setState(() {
                          userPermissions[tabName]![entry.key] = newValue;
                        });
                      },
              ),
            ),
          );
        }).toList(),
        Divider(color: GlassStyle.line24For(context)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'الفروع المسموح بها',
            style: TextStyle(
              color: AppTheme.textMainFor(context),
              fontSize: 18,
              fontWeight: FontWeight.bold,
              fontFamily: 'Cairo',
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: GlassStyle.fill05For(context),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: GlassStyle.line10For(context)),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            child: CheckboxListTile(
              activeColor: AppTheme.accentFor(context),
              checkColor: AppTheme.onAccentFor(context),
              title: Text(
                'كل الفروع',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 16,
                  fontFamily: 'Cairo',
                ),
              ),
              value: _allowAllBranches,
              onChanged: selectedUserId == null
                  ? null
                  : (val) {
                      setState(() {
                        _allowAllBranches = val ?? false;
                        if (_allowAllBranches) {
                          _selectedBranchCodes = [];
                        }
                      });
                    },
            ),
          ),
        ),
        if (!_allowAllBranches)
          ..._allBranches.map((branch) {
            final isSelected =
                _selectedBranchCodes.contains(branch['code']);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: GlassStyle.fill05For(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: GlassStyle.line10For(context)),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: CheckboxListTile(
                  activeColor: AppTheme.accentFor(context),
                  checkColor: AppTheme.onAccentFor(context),
                  title: Text(
                    branch['name'] ?? '',
                    style: TextStyle(
                      color: AppTheme.textMainFor(context),
                      fontSize: 14,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  value: isSelected,
                  onChanged: selectedUserId == null
                      ? null
                      : (val) {
                          setState(() {
                            if (val == true) {
                              _selectedBranchCodes.add(branch['code']!);
                            } else {
                              _selectedBranchCodes.remove(branch['code']);
                            }
                          });
                        },
                ),
              ),
            );
          }).toList(),
        if (!_allowAllBranches && _selectedBranchCodes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '⚠️ يجب اختيار فرع واحد على الأقل',
              style: TextStyle(
                color: AppTheme.warningOrangeSoftFor(context),
                fontFamily: 'Cairo',
              ),
            ),
          ),
      ],
    );
  }

  return ListView.builder(
    padding: const EdgeInsets.all(20),
    itemCount: permissionsMap.length,
    itemBuilder: (context, index) {
      final key = permissionsMap.keys.elementAt(index);
      final value = permissionsMap[key] ?? false;

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: GlassStyle.fill05For(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: GlassStyle.line10For(context)),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          child: SwitchListTile(
            activeThumbColor: AppTheme.accentFor(context),
            inactiveTrackColor: GlassStyle.switchTrackOffFor(context),
            title: Text(
              key,
              style: TextStyle(
                color: AppTheme.textMainFor(context),
                fontSize: 16,
                fontFamily: 'Cairo',
              ),
            ),
            value: value,
            onChanged: selectedUserId == null
                ? null
                : (newValue) {
                    setState(() {
                      userPermissions[tabName]![key] = newValue;
                    });
                  },
          ),
        ),
      );
    },
  );
}

}