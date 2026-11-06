import 'dart:async';                              // ← NEW: للـ StreamSubscription
import 'package:flutter/material.dart';
import '../../views/widgets/glass_card.dart';
import '../../core/theme.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../services/permissions_service.dart';
import '../../services/presence_service.dart';   // ← NEW

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

    // ✅ NEW: حالة is_active للمستخدم المختار (افتراضي = نشط)
  bool _selectedUserIsActive = true;

  // ⭐ HR: فلترة الموظفين
  List<String>? _hrViewableEmployees; // null/empty = كل الموظفين
  bool _allowAllEmployees = true;
  List<Map<String, String>> _allEmployees = [];

  Map<String, Map<String, bool>> userPermissions = {};

  List<QueryDocumentSnapshot> usersList = [];
  List<Map<String, String>> _allBranches = [];
  bool _allowAllBranches = true;
  List<String> _selectedBranchCodes = [];

  // ✅ NEW: Stream محفوظ — عشان ما نعملش stream جديد كل rebuild
  Stream<QuerySnapshot>? _usersStream;

  // ✅ NEW: request ID — الاستدعاء الأخير بس هو اللي بيفوز
  int _loadUserRequestId = 0;

  // ✅ NEW: اشتراك لحظي في مستند المستخدم المختار
  StreamSubscription<DocumentSnapshot>? _selectedUserSub;

    @override
  void initState() {
    super.initState();
    _loadCompanyCode().then((_) {
      _loadBranches();
      _loadEmployeesForFilter();  // ⭐ جديد
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

    // ⭐ جديد: تحميل الموظفين من Hive (لفلترة HR)
  Future<void> _loadEmployeesForFilter() async {
    if (currentCompanyCode.isEmpty) return;

    final box = Hive.box('coding_box');
    final key = '${currentCompanyCode}_employees';
    final raw = box.get(key);

    if (raw is! List) {
      if (mounted) setState(() => _allEmployees = []);
      return;
    }

    final list = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      if (item['is_deleted'] == true) continue;

      final code = item['code']?.toString() ?? '';
      final name = item['name']?.toString() ?? '';
      if (code.isEmpty) continue;

      list.add({'code': code, 'name': name});
    }

    // ترتيب حسب الكود
    list.sort((a, b) {
      final aCode = int.tryParse(a['code'] ?? '0') ?? 0;
      final bCode = int.tryParse(b['code'] ?? '0') ?? 0;
      return aCode.compareTo(bCode);
    });

    if (mounted) {
      setState(() => _allEmployees = list);
    }
  }

  Future<void> _loadCompanyCode() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('company_code') ?? '';

    if (mounted) {
      setState(() {
        currentCompanyCode = code;
        _isLoading = false;

        // ✅ NEW: بناء الـ stream مرة واحدة فقط — جوه setState
        if (code.isNotEmpty) {
          _usersStream = FirebaseFirestore.instance
              .collection('users')
              .where('company_code', isEqualTo: code)
              .snapshots();
        }
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

        // ⭐ HR: تحضير قائمة الموظفين المرئيين
    // ⚠️ نستخدم [] بدل null (Firestore بيتعامل مع null بشكل غير متوقع)
    final List<String> viewableToSave;
    final bool clearViewable;

    if (_allowAllEmployees) {
      viewableToSave = [];   // ⭐ [] = كل الموظفين
      clearViewable = false; // ⭐ مش هنستخدم clear
    } else {
      final selected = _hrViewableEmployees ?? [];
      if (selected.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'يرجى اختيار موظف واحد على الأقل أو "كل الموظفين"',
            ),
            backgroundColor: AppTheme.warningOrangeFor(context),
          ),
        );
        return;
      }
      viewableToSave = selected;
      clearViewable = false;
    }

    try {
      await PermissionsService().savePermissions(
        userPermissions,
        targetEmail: selectedUserId,
        allowedBranches: allowedBranches,
        hrViewableEmployees: viewableToSave,
        clearHrViewableEmployees: clearViewable,
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
        'إظهار المستخدمين المتصلين': false,
        'إظهار الموارد البشرية': false, 
        
      },
              'الموارد البشرية': {
        // ─── A. فتح الصفحات (3) ───
        'canOpenAttendancePage': false,
        'canOpenVacationsPage': false,
        'canOpenReportPage': false,

        // ─── B. عمليات الحضور (3) ───
        'canAddAttendance': false,
        'canEditAttendance': false,
        'canDeleteAttendance': false,

        // ─── C. عمليات الإجازات (3) ───
        'canAddVacation': false,
        'canEditVacation': false,
        'canDeleteVacation': false,

        // ─── D. التسويات (5) ───
        'canViewAdjustments': false,
        'canAddBonus': false,
        'canAddLoan': false,
        'canEditAdjustment': false,
        'canDeleteAdjustment': false,

        // ─── E. الإعدادات (3) ───
        'canEditWeeklyDay': false,
        'canEditWorkSchedule': false,
        'canEditDelayRules': false,

        // ─── F. الخصم والراتب (3) ───
        'canAddDirectDiscount': false,
        'canViewSalaryAmounts': false,
        'canExportReport': false,
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
    // ✅ request ID: كل استدعاء بياخد رقم، والاستدعاء الأخير بس هو اللي بيفوز
    final requestId = ++_loadUserRequestId;

    try {
      // ============================================================
      // default: كل القيم false (مش يعتمد على jobCode)
      // عشان نبدأ من حالة "نضيفة" والقيم الحقيقية تيجي من Hive/Firestore
      // ============================================================
      final defaultPerms = _createDefaultPermissions('1');

      final Map<String, Map<String, bool>> newPermissions =
          Map<String, Map<String, bool>>.from(
        defaultPerms.map(
          (k, v) => MapEntry(k, Map<String, bool>.from(v)),
        ),
      );

      bool allowAll = true;
      List<String> selectedBranches = [];
      bool isActive = true;

      final localKey = 'permissions_$userId';
      final branchesKey = 'allowed_branches_$userId';
      final box = Hive.box('coding_box');

      // ============================================================
      // 1) Hive — الصلاحيات
      // ============================================================
      if (box.containsKey(localKey)) {
        final data = box.get(localKey);
        if (data != null && data is Map) {
          data.forEach((category, perms) {
            if (perms is! Map) return;
            if (!newPermissions.containsKey(category)) {
              newPermissions[category] = {};
            }
            perms.forEach((key, value) {
              newPermissions[category]![key.toString()] = value is bool
                  ? value
                  : value.toString().toLowerCase() == 'true';
            });
          });
        }
      }

      // ============================================================
      // 2) Hive — الفروع
      // ============================================================
      final savedBranches = box.get(branchesKey);
      if (savedBranches is List) {
        final list = savedBranches.map((e) => e.toString()).toList();
        if (list.contains('all')) {
          allowAll = true;
          selectedBranches = [];
        } else {
          allowAll = false;
          selectedBranches = list;
        }
      }

      // ============================================================
      // 3) Firestore — الصلاحيات + الفروع + is_active
      // ============================================================
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .get();

        if (doc.exists) {
          final data = doc.data();

          if (data != null) {
            // ─────────── is_active ───────────
            isActive = data['is_active'] != false;

            // ─────────── الصلاحيات ───────────
            if (data.containsKey('permissions')) {
              final firestorePerms = data['permissions'];
              await box.put(localKey, firestorePerms);

              if (firestorePerms is Map) {
                firestorePerms.forEach((category, perms) {
                  if (perms is! Map) return;
                  if (!newPermissions.containsKey(category)) {
                    newPermissions[category] = {};
                  }
                  perms.forEach((key, value) {
                    newPermissions[category]![key.toString()] = value is bool
                        ? value
                        : value.toString().toLowerCase() == 'true';
                  });
                });
              }
            }

            // ─────────── الفروع ───────────
            List<String>? branches;
            final rawBranches = data['allowed_branches'];

            if (rawBranches is List) {
              branches = rawBranches.map((e) => e.toString()).toList();
            } else if (rawBranches is String &&
                rawBranches.toLowerCase() == 'all') {
              branches = ['all'];
            }

            if (branches != null && branches.isNotEmpty) {
              await box.put(branchesKey, branches);
              if (branches.contains('all')) {
                allowAll = true;
                selectedBranches = [];
              } else {
                allowAll = false;
                selectedBranches = branches;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Offline mode: Using Hive permissions data.');
      }

      // ============================================================
      // ✅ تحقق: هل ده لسه الاستدعاء الأخير؟
      //    (المستخدم ممكن يكون اختار مستخدم تاني أثناء الـ await)
      // ============================================================
      if (!mounted) return;
      if (requestId != _loadUserRequestId) return;  // ← استدعاء أحدث، تجاهل ده
      if (selectedUserId != userId) return;          // ← المستخدم اتغير

      // ============================================================
      // ✅ setState واحد
      // ============================================================
            // ⭐ HR: تحميل الموظفين المرئيين
      final hrViewableKey = 'hr_viewable_employees_$userId';
      final savedViewable = box.get(hrViewableKey);
      List<String>? loadedViewable;
      if (savedViewable is List) {
        loadedViewable = savedViewable.map((e) => e.toString()).toList();
        if (loadedViewable.isEmpty) loadedViewable = null;
      }

      setState(() {
        userPermissions = newPermissions;
        _allowAllBranches = allowAll;
        _selectedBranchCodes = selectedBranches;
        _selectedUserIsActive = isActive;

        // ⭐ HR
        _hrViewableEmployees = loadedViewable;
        _allowAllEmployees = loadedViewable == null;
      });

      // ✅ NEW: ابدأ الاستماع اللحظي للمستخدم المختار
      _listenToUser(userId);
    } catch (e) {
      debugPrint('_loadUserPermissions error: $e');
    }
  }

  // ============================================================
  // ✅ NEW: الاستماع اللحظي لمستند المستخدم المختار
  //
  // - كل تغيير في users/{userId} → snapshot
  // - تحديث Hive + UI تلقائيًا
  // ============================================================
    void _listenToUser(String userId) {
    _selectedUserSub?.cancel();
    _selectedUserSub = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen(
      (snap) async {
        if (!snap.exists) return;
        final data = snap.data();
        if (data == null) return;

        // تحقق: هل المستخدم لسه مختار؟
        if (!mounted) return;
        if (selectedUserId != userId) return;

        final box = Hive.box('coding_box');
        final localKey = 'permissions_$userId';
        final branchesKey = 'allowed_branches_$userId';

        // ✅ تحديث Hive
        if (data['permissions'] is Map) {
          await box.put(localKey, data['permissions']);
        }
        if (data['allowed_branches'] != null) {
          await box.put(branchesKey, data['allowed_branches']);
        }

        // ⭐ HR: متابعة الموظفين المرئيين (Hive)
        if (data.containsKey('hr_viewable_employees')) {
          final rawViewable = data['hr_viewable_employees'];
          if (rawViewable == null) {
            await box.delete('hr_viewable_employees_$userId');
          } else if (rawViewable is List) {
            await box.put(
              'hr_viewable_employees_$userId',
              rawViewable.map((e) => e.toString()).toList(),
            );
          }
        }

        // ✅ تحديث UI
        if (!mounted) return;
        if (selectedUserId != userId) return;

        setState(() {
          // ─────────────────────────────────────────
          // 1) الصلاحيات
          // ─────────────────────────────────────────
          if (data['permissions'] is Map) {
            final perms = data['permissions'] as Map;
            perms.forEach((category, subPerms) {
              if (subPerms is! Map) return;
              if (!userPermissions.containsKey(category)) {
                userPermissions[category] = {};
              }
              subPerms.forEach((key, value) {
                userPermissions[category]![key.toString()] = value is bool
                    ? value
                    : value.toString().toLowerCase() == 'true';
              });
            });
          }

          // ─────────────────────────────────────────
          // 2) الفروع
          // ─────────────────────────────────────────
          final rawBranches = data['allowed_branches'];
          if (rawBranches is List) {
            final list = rawBranches.map((e) => e.toString()).toList();
            if (list.contains('all')) {
              _allowAllBranches = true;
              _selectedBranchCodes = [];
            } else {
              _allowAllBranches = false;
              _selectedBranchCodes = list;
            }
          } else if (rawBranches is String &&
              rawBranches.toLowerCase() == 'all') {
            _allowAllBranches = true;
            _selectedBranchCodes = [];
          }

          // ─────────────────────────────────────────
          // 3) is_active
          // ─────────────────────────────────────────
          _selectedUserIsActive = data['is_active'] != false;

          // ─────────────────────────────────────────
          // 4) ⭐ HR: الموظفين المرئيين (UI)
          // ─────────────────────────────────────────
          if (data.containsKey('hr_viewable_employees')) {
            final rawViewable = data['hr_viewable_employees'];
            if (rawViewable == null) {
              _hrViewableEmployees = null;
              _allowAllEmployees = true;
            } else if (rawViewable is List) {
              final list = rawViewable.map((e) => e.toString()).toList();
              _hrViewableEmployees = list.isEmpty ? null : list;
              _allowAllEmployees = list.isEmpty;
            }
          }
        });
      },
      onError: (e) => debugPrint('⚠️ _listenToUser error: $e'),
    );
  }

  // ============================================================
  // ✅ NEW: حذف المستخدم من RTDB (قائمة الحضور)
  // ============================================================
  Future<void> _handleRemoveFromPresence() async {
    if (selectedUserId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15)),
        title: Text(
          '⚠️ حذف من قائمة الحضور',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'سيتم إخفاء "$selectedUserId" من قائمة المستخدمين المتصلين.\n\n'
          'لن يتم حذف حسابه من النظام. لو سجل دخول تاني، هيرجع للقائمة.',
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء',
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                )),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('حذف',
                style: TextStyle(
                  color: AppTheme.dangerFor(context),
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                )),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final ok = await PresenceService.instance
        .removeUserByEmail(selectedUserId!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'تم الحذف من قائمة الحضور'
              : 'المستخدم مش موجود في القائمة',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        backgroundColor: ok
            ? AppTheme.successStrongFor(context)
            : AppTheme.warningOrangeFor(context),
      ),
    );
  }

  // ============================================================
  // ✅ NEW: حظر / إلغاء حظر المستخدم (is_active في Firestore)
  // ============================================================
  Future<void> _handleToggleBlock(bool newValue) async {
    if (selectedUserId == null) return;

    // newValue = true  → عايز يخليه نشط (يلغي الحظر)
    // newValue = false → عايز يحظره
    final willBlock = !newValue;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.dialogBackground(context),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15)),
        title: Text(
          willBlock ? '🚫 حظر المستخدم' : '✅ إلغاء الحظر',
          style: TextStyle(
            color: AppTheme.textMainFor(context),
            fontFamily: 'Cairo',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          willBlock
              ? 'سيتم منع "$selectedUserId" من تسجيل الدخول،\n'
                'ولو كان داخل حاليًا، هيتم تسجيل خروجه تلقائيًا.'
              : 'سيتم السماح لـ "$selectedUserId" بتسجيل الدخول مرة أخرى.',
          style: TextStyle(
            color: AppTheme.textMutedFor(context),
            fontFamily: 'Cairo',
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء',
                style: TextStyle(
                  color: AppTheme.textMutedFor(context),
                  fontFamily: 'Cairo',
                )),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              willBlock ? 'حظر' : 'إلغاء الحظر',
              style: TextStyle(
                color: willBlock
                    ? AppTheme.dangerFor(context)
                    : Colors.green,
                fontFamily: 'Cairo',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    // لو المستخدم لغى → الـ switch بيرجع لحالته الأصلية تلقائيًا (مفيش setState)
    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(selectedUserId!)
          .update({'is_active': newValue});

      if (!mounted) return;

      setState(() {
        _selectedUserIsActive = newValue;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            willBlock ? 'تم حظر المستخدم' : 'تم إلغاء الحظر',
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: willBlock
              ? AppTheme.warningOrangeFor(context)
              : AppTheme.successStrongFor(context),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل: $e',
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppTheme.dangerStrongFor(context),
        ),
      );
      // ملاحظة: مش بنعمل setState → الـ switch هيرجع لحالته الأصلية تلقائيًا
    }
  }

  @override
  void dispose() {
    _selectedUserSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // final isDark =
    //     Theme.of(context).brightness ==
    //         Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        // ✅ عدد التبويبات الفعلي = 9
        length: 9,
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
                                    _usersStream,
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
                                          // ✅ NEW: اقرأ is_active فورًا
                                          _selectedUserIsActive =
                                              data?['is_active'] != false;
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

                          // ============================================================
                          // ✅ Switch + زر الحذف اتنقلوا لتبويب "صلاحيات عامة"
                          //    (جوه buildPermissionsTab)
                          // ============================================================

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
                                                            Tab(
                                text: 'الموارد البشرية',
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
                                buildPermissionsTab(
                                  'الموارد البشرية',
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

          // ============================================================
          // ✅ Switch: حالة الحساب (نشط / محظور)
          // + زر: حذف من قائمة الحضور
          // ============================================================
          if (selectedUserId != null) ...[
            // ✅ Switch: الحساب نشط / محظور
            Material(
              color: GlassStyle.fill05For(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: BorderSide(
                  color: _selectedUserIsActive
                      ? Colors.green.withValues(alpha: 0.3)
                      : AppTheme.dangerFor(context).withValues(alpha: 0.3),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                activeThumbColor: Colors.green,
                inactiveThumbColor: AppTheme.dangerFor(context),
                secondary: Icon(
                  _selectedUserIsActive
                      ? Icons.check_circle_rounded
                      : Icons.block_rounded,
                  color: _selectedUserIsActive
                      ? Colors.green
                      : AppTheme.dangerFor(context),
                  size: 22,
                ),
                title: Text(
                  _selectedUserIsActive ? 'الحساب نشط' : 'الحساب محظور',
                  style: TextStyle(
                    color: _selectedUserIsActive
                        ? Colors.green
                        : AppTheme.dangerFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  _selectedUserIsActive
                      ? 'المستخدم يقدر يسجل دخول'
                      : 'المستخدم ممنوع من الدخول',
                  style: TextStyle(
                    color: AppTheme.textMutedFor(context),
                    fontFamily: 'Cairo',
                    fontSize: 10,
                  ),
                ),
                value: _selectedUserIsActive,
                onChanged: _handleToggleBlock,
              ),
            ),

            const SizedBox(height: 12),

            // ✅ زر: حذف من قائمة الحضور
            OutlinedButton.icon(
              onPressed: _handleRemoveFromPresence,
              icon: Icon(
                Icons.delete_sweep_rounded,
                color: AppTheme.dangerFor(context),
                size: 18,
              ),
              label: Text(
                'حذف من قائمة الحضور',
                style: TextStyle(
                  color: AppTheme.dangerFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.dangerFor(context)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                minimumSize: const Size(double.infinity, 0),
              ),
            ),
          ],
          // ============================================================

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
            if (tabName == 'الموارد البشرية') {
      return _buildHrPermissionsTab();
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


  // ============================================================
  // ⭐ HR: تبويب الموارد البشرية (6 مجموعات + فلترة)
  // ============================================================

  Widget _buildHrPermissionsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ─── A. فتح الصفحات ───
        _buildHrSection(
          title: 'فتح الصفحات',
          icon: Icons.lock_open_rounded,
          color: AppTheme.infoFor(context),
          keys: [
            'canOpenAttendancePage',
            'canOpenVacationsPage',
            'canOpenReportPage',
          ],
        ),

        // ─── B. عمليات الحضور ───
        _buildHrSection(
          title: 'عمليات الحضور',
          icon: Icons.fingerprint_rounded,
          color: AppTheme.successFor(context),
          keys: [
            'canAddAttendance',
            'canEditAttendance',
            'canDeleteAttendance',
          ],
        ),

        // ─── C. عمليات الإجازات ───
        _buildHrSection(
          title: 'عمليات الإجازات',
          icon: Icons.beach_access_rounded,
          color: AppTheme.extraTealFor(context),
          keys: [
            'canAddVacation',
            'canEditVacation',
            'canDeleteVacation',
          ],
        ),

        // ─── D. التسويات (مكافأة/سلفة) ───
        _buildHrSection(
          title: 'التسويات (مكافأة / سلفة)',
          icon: Icons.attach_money_rounded,
          color: AppTheme.warningFor(context),
          keys: [
            'canViewAdjustments',
            'canAddBonus',
            'canAddLoan',
            'canEditAdjustment',
            'canDeleteAdjustment',
          ],
        ),

        // ─── E. الإعدادات ───
        _buildHrSection(
          title: 'الإعدادات',
          icon: Icons.settings_rounded,
          color: AppTheme.warningOrangeSoftFor(context),
          keys: [
            'canEditWeeklyDay',
            'canEditWorkSchedule',
            'canEditDelayRules',
          ],
        ),

                // ─── F. الخصم المباشر والراتب ───
        _buildHrSection(
          title: 'الخصم المباشر والراتب',
          icon: Icons.money_off_rounded,
          color: AppTheme.dangerFor(context),
          keys: [
            'canAddDirectDiscount',
            'canViewSalaryAmounts',
            'canExportReport',
          ],
        ),

                      // ─── G. إدارة الموظفين ───
        _buildHrSection(
          title: 'إدارة الموظفين',
          icon: Icons.badge_rounded,
          color: AppTheme.extraBlueGreyFor(context),
          keys: [
            'canViewEmployees',
            'canManageEmployees',
          ],
        ),

                // ─── H. الموظف يشوف بياناته ───
        _buildHrSection(
          title: 'بيانات الموظف الشخصية',
          icon: Icons.person_pin_rounded,
          color: AppTheme.infoFor(context),
          keys: [
            'canViewOwnHRData',
          ],
        ),

        // ─── I. التقارير المجمعة ⭐ جديد ───
        _buildHrSection(
          title: 'التقارير المجمعة',
          icon: Icons.summarize_rounded,
          color: AppTheme.extraPurpleFor(context),
          keys: [
            'canViewBranchSalaryReport',
          ],
        ),

        // ─── J. فلترة الموظفين ───
        _buildHrEmployeesFilterSection(),
      ],
    );
  }


  // ──────────────────────────────────────────────────────────
  // قسم HR واحد (Header + Switch لكل صلاحية)
  // ──────────────────────────────────────────────────────────

  Widget _buildHrSection({
    required String title,
    required IconData icon,
    required Color color,
    required List<String> keys,
  }) {
    final hrPerms = userPermissions['الموارد البشرية'] ?? {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),

        // Switch لكل صلاحية
        ...keys.map((key) {
          final value = hrPerms[key] == true;
          final label = _hrPermissionLabel(key);

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
              child: SwitchListTile(
                activeThumbColor: color,
                inactiveTrackColor: GlassStyle.switchTrackOffFor(context),
                title: Text(
                  label,
                  style: TextStyle(
                    color: AppTheme.textMainFor(context),
                    fontSize: 14,
                    fontFamily: 'Cairo',
                  ),
                ),
                value: value,
                onChanged: selectedUserId == null
                    ? null
                    : (newValue) {
                        setState(() {
                          userPermissions['الموارد البشرية'] ??= {};
                          userPermissions['الموارد البشرية']![key] = newValue;
                        });
                      },
              ),
            ),
          );
        }),

        const SizedBox(height: 15),
      ],
    );
  }


  // ──────────────────────────────────────────────────────────
  // تسمية الصلاحية بالعربي
  // ──────────────────────────────────────────────────────────

  String _hrPermissionLabel(String key) {
    const labels = {
      // A
      'canOpenAttendancePage': 'فتح صفحة الحضور',
      'canOpenVacationsPage': 'فتح صفحة الإجازات',
      'canOpenReportPage': 'فتح صفحة التقارير',
      // B
      'canAddAttendance': 'تسجيل حضور',
      'canEditAttendance': 'تعديل حضور',
      'canDeleteAttendance': 'حذف حضور',
      // C
      'canAddVacation': 'إضافة إجازة',
      'canEditVacation': 'تعديل إجازة',
      'canDeleteVacation': 'حذف إجازة',
      // D
      'canViewAdjustments': 'عرض التسويات',
      'canAddBonus': 'إضافة مكافأة',
      'canAddLoan': 'إضافة سلفة',
      'canEditAdjustment': 'تعديل تسوية',
      'canDeleteAdjustment': 'حذف تسوية',
      // E
      'canEditWeeklyDay': 'تعديل يوم الإجازة الأسبوعي',
      'canEditWorkSchedule': 'تعديل مواعيد العمل',
      'canEditDelayRules': 'تعديل إعدادات التأخير',
      // F
            'canAddDirectDiscount': 'إضافة خصم مباشر',
      'canViewSalaryAmounts': 'إظهار المبالغ المالية',
      'canExportReport': 'تصدير تقرير الراتب',
                  // G
      'canViewEmployees': 'عرض الموظفين',
      'canManageEmployees': 'إدارة الموظفين (إضافة/تعديل/حذف)',
            // H
      'canViewOwnHRData': 'إظهار بيانات الموظف لنفسه (بروفايله + راتبه)',
      // I
      'canViewBranchSalaryReport': 'عرض تقرير إجمالي الرواتب لكل فرع',
    };
    return labels[key] ?? key;
  }


  // ──────────────────────────────────────────────────────────
  // قسم فلترة الموظفين
  // ──────────────────────────────────────────────────────────

  Widget _buildHrEmployeesFilterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppTheme.accentFor(context).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.filter_alt_rounded,
                  color: AppTheme.accentFor(context),
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'فلترة الموظفين المرئيين',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),

        // Checkbox: كل الموظفين
        Container(
          margin: const EdgeInsets.only(bottom: 12),
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
                'كل الموظفين (في الفروع المسموحة)',
                style: TextStyle(
                  color: AppTheme.textMainFor(context),
                  fontSize: 14,
                  fontFamily: 'Cairo',
                ),
              ),
              value: _allowAllEmployees,
              onChanged: selectedUserId == null
                  ? null
                  : (val) {
                      setState(() {
                        _allowAllEmployees = val ?? false;
                        if (_allowAllEmployees) {
                          _hrViewableEmployees = null;
                        } else {
                          _hrViewableEmployees ??= [];
                        }
                      });
                    },
            ),
          ),
        ),

        // قائمة الموظفين (لو "كل الموظفين" = false)
        if (!_allowAllEmployees) ...[
          if (_allEmployees.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '⚠️ لا يوجد موظفون مسجلون في النظام',
                style: TextStyle(
                  color: AppTheme.warningOrangeSoftFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                ),
              ),
            )
          else
            ..._allEmployees.map((emp) {
              final code = emp['code'] ?? '';
              final name = emp['name'] ?? '';
              final isSelected =
                  _hrViewableEmployees?.contains(code) ?? false;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: GlassStyle.fill05For(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: GlassStyle.line10For(context)),
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: CheckboxListTile(
                    activeColor: AppTheme.accentFor(context),
                    checkColor: AppTheme.onAccentFor(context),
                    title: Text(
                      '$name ($code)',
                      style: TextStyle(
                        color: AppTheme.textMainFor(context),
                        fontSize: 13,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    value: isSelected,
                    onChanged: selectedUserId == null
                        ? null
                        : (val) {
                            setState(() {
                              _hrViewableEmployees ??= [];
                              if (val == true) {
                                if (!_hrViewableEmployees!.contains(code)) {
                                  _hrViewableEmployees!.add(code);
                                }
                              } else {
                                _hrViewableEmployees!.remove(code);
                              }
                            });
                          },
                  ),
                ),
              );
            }),

          // تحذير لو مفيش اختيار
          if (_hrViewableEmployees?.isEmpty ?? true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '⚠️ يجب اختيار موظف واحد على الأقل',
                style: TextStyle(
                  color: AppTheme.warningOrangeSoftFor(context),
                  fontFamily: 'Cairo',
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ],
    );
  }

}