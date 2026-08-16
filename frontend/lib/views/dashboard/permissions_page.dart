import 'package:flutter/material.dart';
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
  setState(() {
    _allBranches = branches.map((e) => {
      'code': e['code'].toString(),
      'name': e['name'].toString(),
    }).toList();
    // إذا كانت القائمة فارغة، نضيف رسالة توضيحية اختيارية
    if (_allBranches.isEmpty) {
      _allBranches = [{'code': 'none', 'name': 'لا توجد فروع مسجلة'}];
    }
  });
}

  Future<void> _loadCompanyCode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        currentCompanyCode = prefs.getString('company_code') ?? '';
        _isLoading = false;
      });
    }
    await _loadCurrentUserPermissions();
  }

  Future<void> _loadCurrentUserPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    final userEmail = prefs.getString('user_email') ?? '';
    final jobCode = prefs.getString('job_code') ?? '1';
    if (userEmail.isNotEmpty) {
      setState(() {
        selectedUserId = userEmail;
        selectedUserJobCode = jobCode;
      });
      await _loadUserPermissions(userEmail, jobCode);
    }
  }

  Stream<QuerySnapshot> getCompanyUsers() {
    return FirebaseFirestore.instance
        .collection('users')
        .where('company_code', isEqualTo: currentCompanyCode)
        .snapshots();
  }

  // دالة لتحديث البيانات المطبقة (دمج بدلاً من استبدال)
  void _applyPermissionsData(dynamic data) {
    if (data == null) return;
    setState(() {
      data.forEach((category, perms) {
        if (!userPermissions.containsKey(category)) {
          userPermissions[category] = {};
        }
        perms.forEach((key, value) {
          userPermissions[category]![key] = value ?? false;
        });
      });
    });
  }

  Map<String, Map<String, bool>> _createDefaultPermissions(String jobCode) {
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
      },
      'رصيد المخزون': {
  'معاينة': false,
  'عرض سعر الجملة': false,
  // 'عرض قيمة الجملة': false,
  'تصدير': false,
},
      'صلاحيات عامة': {
        'تغيير الفرع(صفحة الهوم)': false,
        'صفحة الصلاحيات(الاعدادات)': false,
        'إظهار حركة الخزينة': false,
      'إظهار التكويد': false,
      'إظهار التقارير': false,
      'إظهار حركة الموردين': false,   // 🔥 جديد
      'إظهار حركة الجرد': false, 
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

  Future<void> _loadUserPermissions(String userId, String jobCode) async {
    // 1. إنشاء الهيكل الافتراضي
    var defaultPerms = _createDefaultPermissions(jobCode);
    setState(() {
      userPermissions = defaultPerms;
    });

   
    final localKey = 'permissions_$userId';
    final box = Hive.box('coding_box');
var savedBranches = box.get('allowed_branches_$userId');
if (savedBranches != null && savedBranches is List) {
  var list = savedBranches.map((e) => e.toString()).toList();
  setState(() {
    if (list.contains('all')) {
      _allowAllBranches = true;
      _selectedBranchCodes = [];
    } else {
      _allowAllBranches = false;
      _selectedBranchCodes = list;
    }
  });
} else {
  setState(() {
    _allowAllBranches = true;
    _selectedBranchCodes = [];
  });
}

    // 2. محاولة قراءة من Hive
    if (box.containsKey(localKey)) {
      var data = box.get(localKey);
      if (data != null) {
        _applyPermissionsData(data);
      }
    }

    // 3. محاولة قراءة من Firestore (لتحديث الأحدث)
    try {
      var doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (doc.exists && doc.data()!.containsKey('permissions')) {
        var firestorePerms = doc.data()!['permissions'];
        await box.put(localKey, firestorePerms);
        // إعادة تطبيق البيانات من Firestore (تغلب على Hive)
        _applyPermissionsData(firestorePerms);
      }
    } catch (e) {
      debugPrint("Offline mode: Using Hive permissions data.");
    }
  }

  Future<void> savePermissions() async {
  if (selectedUserId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('برجاء اختيار الموظف أولاً'), backgroundColor: Colors.orange),
    );
    return;
  }

  List<String> allowedBranches;
  if (_allowAllBranches) {
    allowedBranches = ['all'];
  } else {
    allowedBranches = List.from(_selectedBranchCodes);
    if (allowedBranches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى اختيار فرع واحد على الأقل أو "كل الفروع"'), backgroundColor: Colors.orange),
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
        const SnackBar(content: Text('تم حفظ الصلاحيات بنجاح!'), backgroundColor: Colors.green),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم الحفظ محلياً (وضع عدم الاتصال)'), backgroundColor: Colors.orangeAccent),
      );
    }
  }
}

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        length: 7,
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
                      colors: isDark
                          ? [const Color.fromARGB(255, 33, 31, 147), const Color(0xFF161B22)]
                          : [const Color.fromARGB(255, 33, 44, 159), const Color(0xFF3949AB)],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                const Expanded(
                                  child: Text(
                                    'إدارة الصلاحيات',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'Cairo',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: IconButton(
                                    icon: const Icon(Icons.save_rounded, color: Colors.cyanAccent),
                                    onPressed: savePermissions,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(color: Colors.white.withOpacity(0.1)),
                              ),
                              child: StreamBuilder<QuerySnapshot>(
                                stream: getCompanyUsers(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState == ConnectionState.waiting) {
                                    return const Padding(
                                      padding: EdgeInsets.all(12.0),
                                      child: Text(
                                        'جاري تحميل الموظفين...',
                                        style: TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                      ),
                                    );
                                  }
                                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                                    return const Padding(
                                      padding: EdgeInsets.all(12.0),
                                      child: Text(
                                        'لا يوجد موظفين مسجلين',
                                        style: TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                      ),
                                    );
                                  }

                                  usersList = snapshot.data!.docs;

                                  return DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      dropdownColor: const Color(0xFF2D2D44),
                                      isExpanded: true,
                                      hint: const Text(
                                        'اختر الموظف',
                                        style: TextStyle(color: Colors.white70, fontFamily: 'Cairo'),
                                      ),
                                      value: selectedUserId,
                                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.cyanAccent),
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'Cairo'),
                                      items: usersList.map((user) {
                                        final data = user.data() as Map<String, dynamic>?;
                                        String empName = data?['name']?.toString() ?? 'بدون اسم';
                                        String empJob = data?['job_title'] != null ? ' - ${data!['job_title']}' : '';
                                        return DropdownMenuItem(
                                          value: user.id,
                                          child: Text('$empName$empJob'),
                                        );
                                      }).toList(),
                                      onChanged: (value) {
                                        if (value != null) {
                                          var selectedUser = usersList.firstWhere((u) => u.id == value);
                                          final data = selectedUser.data() as Map<String, dynamic>?;
                                          String jobCode = data?['job_code']?.toString() ?? '1';
                                          setState(() {
                                            selectedUserId = value;
                                            selectedUserJobCode = jobCode;
                                          });
                                          _loadUserPermissions(value, jobCode);
                                        }
                                      },
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const TabBar(
                            isScrollable: true,
                            indicatorColor: Colors.cyanAccent,
                            labelColor: Colors.cyanAccent,
                            unselectedLabelColor: Colors.white54,
                            labelStyle: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold),
                            tabs: [
                              Tab(text: 'حركة الخزينة'),
                              Tab(text: 'التكويد'),
                              Tab(text: 'حسابات الموردين'),
                              Tab(text: 'تسويات الموردين'),
                              Tab(text: 'حركة الجرد'),
                              Tab(text: 'التقارير'),
                              Tab(text: 'رصيد المخزون'),
                              Tab(text: 'صلاحيات عامة'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                buildPermissionsTab('حركة الخزينة'),
                                buildPermissionsTab('التكويد'),
                                buildPermissionsTab('حسابات الموردين'),
                                buildPermissionsTab('تسويات الموردين'),
                                buildPermissionsTab('حركة الجرد'),
                                buildPermissionsTab('التقارير'),
                                buildPermissionsTab('رصيد المخزون'),
                                buildPermissionsTab('صلاحيات عامة'),
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

  // إذا كان التبويب هو "صلاحيات عامة"، نضيف واجهة الفروع
  if (tabName == 'صلاحيات عامة') {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // مفاتيح الصلاحيات الحالية
        ...permissionsMap.entries.map((entry) {
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: SwitchListTile(
              activeColor: Colors.cyanAccent,
              inactiveTrackColor: Colors.white24,
              title: Text(entry.key, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'Cairo')),
              value: entry.value,
              onChanged: selectedUserId == null ? null : (newValue) {
                setState(() {
                  userPermissions[tabName]![entry.key] = newValue;
                });
              },
            ),
          );
        }).toList(),
        const Divider(color: Colors.white24),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'الفروع المسموح بها',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Cairo'),
          ),
        ),
        // خيار "كل الفروع"
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: CheckboxListTile(
            activeColor: Colors.cyanAccent,
            checkColor: Colors.black,
            title: const Text('كل الفروع', style: TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'Cairo')),
            value: _allowAllBranches,
            onChanged: selectedUserId == null ? null : (val) {
              setState(() {
                _allowAllBranches = val!;
                if (_allowAllBranches) {
                  _selectedBranchCodes = [];
                }
              });
            },
          ),
        ),
        // قائمة الفروع الفردية
        if (!_allowAllBranches)
          ..._allBranches.map((branch) {
            bool isSelected = _selectedBranchCodes.contains(branch['code']);
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: CheckboxListTile(
                activeColor: Colors.cyanAccent,
                checkColor: Colors.black,
                title: Text(branch['name']!, style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'Cairo')),
                value: isSelected,
                onChanged: selectedUserId == null ? null : (val) {
                  setState(() {
                    if (val!) {
                      _selectedBranchCodes.add(branch['code']!);
                    } else {
                      _selectedBranchCodes.remove(branch['code']);
                    }
                  });
                },
              ),
            );
          }).toList(),
        if (!_allowAllBranches && _selectedBranchCodes.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('⚠️ يجب اختيار فرع واحد على الأقل', style: TextStyle(color: Colors.orangeAccent, fontFamily: 'Cairo')),
          ),
      ],
    );
  }

  // باقي التبويبات كما هي
  return ListView.builder(
    padding: const EdgeInsets.all(20),
    itemCount: permissionsMap.length,
    itemBuilder: (context, index) {
      String key = permissionsMap.keys.elementAt(index);
      bool value = permissionsMap[key]!;
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: SwitchListTile(
          activeColor: Colors.cyanAccent,
          inactiveTrackColor: Colors.white24,
          title: Text(key, style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'Cairo')),
          value: value,
          onChanged: selectedUserId == null ? null : (newValue) {
            setState(() {
              userPermissions[tabName]![key] = newValue;
            });
          },
        ),
      );
    },
  );
}
}