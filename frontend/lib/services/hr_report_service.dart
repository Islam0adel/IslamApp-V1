// frontend/lib/services/hr_report_service.dart
import 'cache_partitions.dart';
import 'permissions_service.dart';
import 'salary_visibility.dart';
import 'read_authorization_snapshot.dart';

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import '../models/hr_models.dart';
import '../models/hr_salary_report_model.dart';
import 'auth_http.dart';
import 'employee_service.dart';
import 'hr_service.dart';
import 'hr_salary_calculator.dart';

// خدمة تقارير الرواتب
/// خدمة تقارير الرواتب
///
/// النمط (3 مستويات):
///   1. Cache في Hive (30 دقيقة TTL) — ~10ms
///   2. Local calculation من Hive (مع دمج pending) — ~50-200ms
///   3. Backend fallback (Hugging Face) — ~400-800ms warm / 30s cold
///
/// القرار:
/// - لو مفيش pending + cache valid → من الـ cache
/// - لو فيه pending → احسب محليًا (بدمج pending)
/// - لو فشل الحساب المحلي → ارجع للباك
///
/// ⚠️ important:
/// - الكاش بيتخزن فقط للتقارير "الرسمية" (بدون pending)
/// - الإبطال (invalidate) بيتنادى من الصفحات بعد أي تعديل
class HRReportService {
  final String baseUrl = ApiConstants.baseUrl;

  // يعيد صندوق الترميز المحلي
  Box get _codingBox => CachePartitions.box('coding_box');
  final HRService _hrService = HRService();

  /// مدة صلاحية الكاش
  static const Duration _cacheTTL = Duration(minutes: 30);

  // ============================================================
  // Cache key
  //
  // نستخدم `__` كفاصل عشان ما يتعارضش مع `_` في الأسماء.
  // ============================================================

  // يبني مفتاح تخزين التقرير
  String _cacheKey(
    String companyCode,
    String employeeCode,
    String month,
  ) =>
      'salary_report_${companyCode}__${employeeCode}__$month';

  // يحدد هل الشركة هي نفسها شركة المستخدم
  bool _sameCompany(String company) {
    final ps = PermissionsService();
    return ps.isLoaded &&
        (ps.isSuperAdmin || ps.isCurrentIdentityForCompany(company));
  }

  // يحدد هل التقرير يخص المستخدم نفسه
  bool _ownReport(String company, String employee) {
    final ps = PermissionsService();
    return ps.isCurrentIdentityForCompany(company) &&
        ps.canViewOwnHRData &&
        ps.isCurrentEmployee(employee);
  }

  // يحدد هل الهدف موظف عادي ضمن الفرع
  bool _ordinaryTarget(String employee, String branch) {
    final ps = PermissionsService();
    if (ps.canBypassPermissions)
      return true; // Existing legacy role policy, until reviewed activation.
    final branches = ps.allowedBranches;
    final employees = ps.hrViewableEmployees;
    return (branch.isEmpty ||
            branches == null ||
            branches.isEmpty ||
            branches.contains('all') ||
            branches.contains(branch)) &&
        (employees == null ||
            employees.isEmpty ||
            employees.contains(employee));
  }

  // يحدد هل يحق للمستخدم قراءة التقرير
  bool _readReport(String company, String employee, String branch) {
    final ps = PermissionsService();
    if (!_sameCompany(company)) return false;
    if (_ownReport(company, employee)) return true;
    return (ps.canBypassPermissions ||
            ps.canOpenReportPage ||
            ps.canViewSalaryAmounts ||
            ps.canViewBranchSalaryReport ||
            ps.canManageEmployees) &&
        _ordinaryTarget(employee, branch);
  }

  // يحدد هل تُحفظ المبالغ في التقرير
  bool _keepAmounts(String company, String employee, String branch) =>
      _readReport(company, employee, branch) &&
      (PermissionsService().canBypassPermissions ||
          _ownReport(company, employee) ||
          PermissionsService().canViewSalaryAmounts);

  // يحدد هل يحق للمستخدم قراءة تقرير الفرع
  bool _readBranchReport(String company, String? branch) {
    final ps = PermissionsService();
    if (!_sameCompany(company) ||
        (!ps.canBypassPermissions && !ps.canViewBranchSalaryReport))
      return false;
    final branches = ps.allowedBranches;
    return ps.canBypassPermissions ||
        branch == null ||
        branch.isEmpty ||
        branches == null ||
        branches.isEmpty ||
        branches.contains('all') ||
        branches.contains(branch);
  }

  // يحدد هل تُحفظ مبالغ تقرير الفرع
  bool get _keepBranchAmounts =>
      PermissionsService().canBypassPermissions ||
      PermissionsService().canViewSalaryAmounts;

  // ============================================================
  // 1. الدالة الرئيسية: جلب تقرير راتب
  //
  // [includePending] = null  → auto-detect (يعتمد على pending)
  // [includePending] = true  → دمج pending دائمًا
  // [includePending] = false → بيانات السيرفر فقط
  //
  // [useCache] = true → يفضل من الكاش لو مفيش pending
  // ============================================================

  // يجلب تقرير الراتب (من التخزين أو الحساب المحلي أو الخادم)
  Future<HRSalaryReportModel?> getSalaryReport({
    required String companyCode,
    required String employeeCode,
    required String month,
    bool useCache = true,
    bool? includePending,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      // -------- auto-detect pending --------
      final effectiveIncludePending =
          includePending ?? _hasPendingFor(companyCode, employeeCode, month);

      // -------- 1) Cache (فقط لو مفيش pending) --------
      if (useCache && !effectiveIncludePending) {
        final cached = await _getCached(companyCode, employeeCode, month);
        readScope.check();
        if (cached != null) {
          print('⚡ [salary-report] من الـ cache');
          return cached;
        }
      }

      // -------- 2) Local calculation --------
      try {
        final local = await _calculateLocally(
          companyCode: companyCode,
          employeeCode: employeeCode,
          month: month,
          includePending: effectiveIncludePending,
        );
        readScope.check();
        if (local != null) {
          // نخزن في الـ cache فقط للتقارير الرسمية (بدون pending)
          if (!effectiveIncludePending) {
            await _saveToCache(
              companyCode,
              employeeCode,
              month,
              local,
            );
            readScope.check();
          }
          print('🧮 [salary-report] حساب محلي');
          return local;
        }
      } catch (e) {
        print('⚠️ [salary-report] local calc failed: $e');
      }

      // -------- 3) Backend fallback --------
      readScope.check();
      final backend = await _fetchFromBackend(
        companyCode: companyCode,
        employeeCode: employeeCode,
        month: month,
      );
      readScope.check();
      return backend;
    });
  }

  // ============================================================
  // 2. جلب التقرير من السيرفر مباشرة (بدون cache/local)
  //
  // يُستخدم عند الحاجة للنسخة "الرسمية" (مثل PDF).
  // ============================================================

  // يجلب تقرير الراتب من الخادم
  Future<HRSalaryReportModel?> getSalaryReportFromBackend({
    required String companyCode,
    required String employeeCode,
    required String month,
  }) async {
    return CachePartitions.run(() async {
      return _fetchFromBackend(
        companyCode: companyCode,
        employeeCode: employeeCode,
        month: month,
      );
    });
  }

  // ============================================================
  // 3. الحساب المحلي
  // ============================================================

  // يحسب تقرير الراتب محليًا
  Future<HRSalaryReportModel?> _calculateLocally({
    required String companyCode,
    required String employeeCode,
    required String month,
    required bool includePending,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      if (!_readReport(companyCode, employeeCode, '')) return null;
      // -------- بيانات الموظف --------
      final employeeData = await _getEmployeeData(
        companyCode: companyCode,
        employeeCode: employeeCode,
      );
      readScope.check();
      if (employeeData == null) {
        throw Exception('الموظف غير موجود محليًا أو على السيرفر');
      }

      if (!_readReport(companyCode, employeeCode,
          (employeeData['branch_code'] ?? '').toString())) return null;
      final employeeName = employeeData['name']?.toString() ?? '';
      final baseSalary = _toDouble(employeeData['salary']);
      final branchCode = employeeData['branch_code']?.toString() ?? '1';

      // -------- إعدادات الموظف --------
      final settings = await _hrService.getEmployeeSettings(
        companyCode: companyCode,
        employeeCode: employeeCode,
      );
      readScope.check();

      // -------- الحضور (مع أو بدون pending) --------
      final attendanceMap = includePending
          ? await _getAttendanceWithPending(
              companyCode: companyCode,
              employeeCode: employeeCode,
              month: month,
            )
          : await _hrService.getEmployeeMonthAttendance(
              companyCode: companyCode,
              employeeCode: employeeCode,
              month: month,
            );
      readScope.check();

      // -------- الإجازات --------
      final vacations = await _hrService.getVacations(
        companyCode: companyCode,
        fromDate: '$month-01',
        toDate: '$month-31',
        branchCode: branchCode,
        employeeCode: employeeCode,
      );
      readScope.check();

      // -------- التسويات --------
      final adjustments = await _hrService.getEmployeeAdjustments(
        companyCode: companyCode,
        employeeCode: employeeCode,
        month: month,
      );
      readScope.check();

      // -------- الحساب --------
      final reportMap = HRSalaryCalculator.calculate(
        companyCode: companyCode,
        employeeCode: employeeCode,
        employeeName: employeeName,
        month: month,
        baseSalary: baseSalary,
        branchCode: branchCode,
        employeeSettings: settings,
        attendanceByDate: attendanceMap,
        vacations: vacations,
        adjustments: adjustments,
      );

      return HRSalaryReportModel.fromMap(
          _keepAmounts(companyCode, employeeCode, branchCode)
              ? reportMap
              : SalaryVisibility.report(reportMap));
    });
  }

  // ============================================================
  // 4. Backend fallback
  // ============================================================

  // يجلب تقرير الراتب من الخادم ويحلله
  Future<HRSalaryReportModel?> _fetchFromBackend({
    required String companyCode,
    required String employeeCode,
    required String month,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      if (!_readReport(companyCode, employeeCode, '')) return null;
      try {
        final url = Uri.parse(
          "$baseUrl/hr/reports/salary/$companyCode/$employeeCode",
        ).replace(queryParameters: {'month': month});

        readScope.check();
        final response = await AuthHttp.get(url);
        readScope.check();

        if (response.statusCode < 200 || response.statusCode >= 300) {
          print("❌ [salary-report backend] HTTP ${response.statusCode}");
          return null;
        }

        final Map<String, dynamic> data = jsonDecode(response.body);
        if (data['company_code'] != companyCode ||
            data['employee_code'] != employeeCode ||
            !_readReport(companyCode, employeeCode,
                (data['branch_code'] ?? '').toString())) return null;
        final visible = _keepAmounts(companyCode, employeeCode,
                (data['branch_code'] ?? '').toString())
            ? data
            : SalaryVisibility.report(data);
        final report = HRSalaryReportModel.fromMap(visible);

        // نخزن في الـ cache عشان النداء الجاي يكون فوري
        await _saveToCache(companyCode, employeeCode, month, report);
        readScope.check();

        print('🌐 [salary-report] من السيرفر');
        return report;
      } catch (e) {
        print("❌ [salary-report backend] $e");
        return null;
      }
    });
  }

  // ============================================================
  // 5. إدارة الـ Cache
  // ============================================================

  // يقرأ التقرير من الذاكرة المؤقتة
  Future<HRSalaryReportModel?> _getCached(
    String companyCode,
    String employeeCode,
    String month,
  ) async {
    return CachePartitions.run(() async {
      final key = _cacheKey(companyCode, employeeCode, month);
      final raw = _codingBox.get(key);
      if (raw is! Map) return null;

      final map = Map<String, dynamic>.from(raw);

      if (map['company_code'] != companyCode ||
          map['employee_code'] != employeeCode ||
          map['month'] != month ||
          !_keepAmounts(companyCode, employeeCode,
              (map['branch_code'] ?? '').toString())) {
        await _codingBox.delete(key);
        await _codingBox.compact();
        return null;
      }

      // فحص TTL
      final cachedAtStr = map['_cached_at']?.toString();
      if (cachedAtStr != null) {
        final cachedAt = DateTime.tryParse(cachedAtStr);
        if (cachedAt != null &&
            DateTime.now().difference(cachedAt) > _cacheTTL) {
          // منتهي → امسحه
          _codingBox.delete(key);
          return null;
        }
      }

      map.remove('_cached_at');
      return HRSalaryReportModel.fromMap(map);
    });
  }

  // يحفظ التقرير في الذاكرة المؤقتة
  Future<void> _saveToCache(
    String companyCode,
    String employeeCode,
    String month,
    HRSalaryReportModel report,
  ) async {
    return CachePartitions.run(() async {
      if (!_keepAmounts(companyCode, employeeCode, report.branchCode)) return;
      final key = _cacheKey(companyCode, employeeCode, month);

      final data = <String, dynamic>{
        '_cached_at': DateTime.now().toUtc().toIso8601String(),

        'company_code': report.companyCode,
        'branch_code': report.branchCode,
        'employee_code': report.employeeCode,
        'employee_name': report.employeeName,
        'month': report.month,

        // ⭐ الأيام والإعدادات
        'elapsed_days': report.elapsedDays,
        'future_days': report.futureDays,
        'use_fixed_month_days': report.useFixedMonthDays,

        // الأساسيات
        'base_salary': report.baseSalary,
        'work_days': report.workDays,
        'present_days': report.presentDays,
        'absent_days': report.absentDays,
        'vacation_days': report.vacationDays,

        // الدقائق
        'late_minutes_total': report.lateMinutesTotal,
        'overtime_minutes_total': report.overtimeMinutesTotal,
        'early_leave_minutes_total': report.earlyLeaveMinutesTotal,

        // البنود المالية
        'base_pay': report.basePay,
        'absence_deduction': report.absenceDeduction,
        'late_deduction': report.lateDeduction,
        'early_leave_deduction': report.earlyLeaveDeduction,
        'overtime_bonus': report.overtimeBonus,

        'bonuses_total': report.bonusesTotal,
        'deductions_total': report.deductionsTotal,
        'loans_total': report.loansTotal,

        'net_salary': report.netSalary,
        'debt_remaining': report.debtRemaining, // ⭐ إضافة

        // التفاصيل
        'adjustment_lines': report.adjustmentLines
            .map((a) => {
                  'type': a.type,
                  'label': a.label,
                  'amount': a.amount,
                })
            .toList(),

        'attendance_details': report.attendanceDetails
            .map((d) => {
                  'date': d.date,
                  'status': d.status,
                  'note': d.note,
                  'check_in': d.checkIn,
                  'check_out': d.checkOut,
                  'late_minutes': d.lateMinutes,
                  'overtime_minutes': d.overtimeMinutes,
                })
            .toList(),
      };

      await _codingBox.put(key, data);
    });
  }

  // يبطل ذاكرة التقرير لموظف أو شهر محدد
  /// إبطال الكاش لموظف/شهر محدد
  ///
  /// ⚠️ الصفحات لازم تناديها بعد أي تعديل في:
  /// - الحضور
  /// - الإجازات
  /// - التسويات
  /// - إعدادات الموظف
  Future<void> invalidateCache({
    String? companyCode,
    String? employeeCode,
    String? month,
  }) async {
    return CachePartitions.run(() async {
      final toDelete = <dynamic>[];

      for (final key in _codingBox.keys) {
        final keyStr = key.toString();
        final isReport = keyStr.startsWith('salary_report_');
        final isBranchTotals = keyStr.startsWith('branch_salaries_');
        if (!isReport && !isBranchTotals) continue;

        if (companyCode != null &&
            !keyStr.contains('salary_report_${companyCode}__') &&
            !keyStr.contains('branch_salaries_${companyCode}__')) {
          continue;
        }
        if (employeeCode != null && !keyStr.contains('__${employeeCode}__')) {
          continue;
        }
        if (month != null && !keyStr.endsWith('__$month')) {
          continue;
        }

        toDelete.add(key);
      }

      for (final key in toDelete) {
        await _codingBox.delete(key);
      }

      if (toDelete.isNotEmpty) {
        print('🗑️ [salary-report cache] مسح ${toDelete.length} تقرير');
      }
    });
  }

  // يمسح كل ذاكرة التقارير المؤقتة
  /// مسح كل الكاش (يُستدعى عند logout أو reset)
  Future<void> clearAllCache() async {
    return CachePartitions.run(() async {
      await invalidateCache();
      print('🗑️ [salary-report cache] تم مسح كل التقارير');
    });
  }

  // ============================================================
  // 6. Helpers
  // ============================================================

  // يحدد هل توجد عمليات معلقة للموظف والشهر
  /// هل فيه pending لهذا الموظف/الشهر؟
  bool _hasPendingFor(
    String companyCode,
    String employeeCode,
    String month,
  ) {
    final allPending = _hrService.getAllPendingForCompany(companyCode);

    for (final p in allPending) {
      final keyStr = p['_key']?.toString() ?? '';
      if (keyStr.length < 11) continue;

      // key = "{company}_{employee}_{YYYY-MM-DD}"
      final date = keyStr.substring(keyStr.length - 10);
      if (!date.startsWith('$month-')) continue;

      final withoutDate = keyStr.substring(0, keyStr.length - 11);
      final prefix = '${companyCode}_';
      if (!withoutDate.startsWith(prefix)) continue;
      final pEmployee = withoutDate.substring(prefix.length);

      if (pEmployee == employeeCode) return true;
    }

    return false;
  }

  // يدمج الحضور المحلي مع العمليات المعلقة
  /// دمج الحضور المحفوظ مع pending
  Future<Map<String, HRAttendanceModel>> _getAttendanceWithPending({
    required String companyCode,
    required String employeeCode,
    required String month,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      final committed = await _hrService.getEmployeeMonthAttendance(
        companyCode: companyCode,
        employeeCode: employeeCode,
        month: month,
      );
      readScope.check();

      final merged = Map<String, HRAttendanceModel>.from(committed);

      final allPending = _hrService.getAllPendingForCompany(companyCode);

      for (final p in allPending) {
        final keyStr = p['_key']?.toString() ?? '';
        if (keyStr.length < 11) continue;

        final date = keyStr.substring(keyStr.length - 10);
        if (!date.startsWith('$month-')) continue;

        final withoutDate = keyStr.substring(0, keyStr.length - 11);
        final prefix = '${companyCode}_';
        if (!withoutDate.startsWith(prefix)) continue;
        final pEmployee = withoutDate.substring(prefix.length);

        if (pEmployee != employeeCode) continue;

        final action = p['action']?.toString() ?? 'save';

        if (action == 'delete') {
          merged.remove(date);
        } else if (action == 'save') {
          final data = p['data'];
          if (data is Map) {
            merged[date] = HRAttendanceModel.fromMap(
              Map<String, dynamic>.from(data),
            );
          }
        }
      }

      return merged;
    });
  }

  // يجلب بيانات الموظف من التخزين المحلي أو الخادم
  /// جلب بيانات الموظف (Hive أولاً، ثم السيرفر)
  Future<Map<String, dynamic>?> _getEmployeeData({
    required String companyCode,
    required String employeeCode,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      // 1) Hive
      final localKey = '${companyCode}_employees';
      final raw = _codingBox.get(localKey);

      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          if (map['code']?.toString() == employeeCode &&
              map['is_deleted'] != true) {
            return map;
          }
        }
      }

      // 2) السيرفر
      try {
        final emp = await EmployeeService().getEmployee(
          companyCode: companyCode,
          code: employeeCode,
        );
        readScope.check();
        if (emp != null) return emp.toMap();
      } catch (e) {
        print('⚠️ [salary-report] employee fetch: $e');
      }

      return null;
    });
  }

  // يحوّل قيمة ديناميكية إلى عدد عشري بأمان
  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  // ============================================================
  // ⭐ إجمالي رواتب الفروع/الشركة
  //
  // الترتيب:
  //   1. Cache (30 دقيقة)
  //   2. حساب محلي من Hive (لو !forceRefresh)
  //   3. Backend (لو forceRefresh أو الحساب المحلي فشل)
  // ============================================================

  // يجلب إجماليات رواتب الفرع
  Future<Map<String, dynamic>?> getBranchSalariesTotals({
    required String companyCode,
    required String month,
    String? branchCode,
    bool forceRefresh = false,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      if (!_readBranchReport(companyCode, branchCode)) return null;
      final cacheKey =
          'branch_salaries_${companyCode}__${month}__${branchCode ?? "all"}';

      // ---------- 1) Cache (لو !forceRefresh) ----------
      if (!forceRefresh) {
        final cached = _codingBox.get(cacheKey);
        if (cached is Map) {
          final map = Map<String, dynamic>.from(cached);
          final cachedAt = DateTime.tryParse(
            map['_cached_at']?.toString() ?? '',
          );
          if (cachedAt != null &&
              DateTime.now().difference(cachedAt) <= _cacheTTL) {
            final employees = map['employees'];
            final rowsAllowed = employees is List &&
                employees.whereType<Map>().length == employees.length &&
                employees.every((row) => _ordinaryTarget(
                    (row['employee_code'] ?? '').toString(),
                    (row['branch_code'] ?? '').toString()));
            if (_keepBranchAmounts &&
                rowsAllowed &&
                map['company_code'] == companyCode) {
              map.remove('_cached_at');
              print('⚡ [branch-salaries] من الـ cache');
              return map;
            }
            await _codingBox.delete(cacheKey);
            readScope.check();
            await _codingBox.compact();
            readScope.check();
          }
        }
      }

      // ---------- 2) حساب محلي من Hive (لو !forceRefresh) ----------
      if (!forceRefresh) {
        try {
          final local = await _calculateBranchTotalsLocally(
            companyCode: companyCode,
            month: month,
            branchCode: branchCode,
          );
          readScope.check();
          if (local != null) {
            readScope.check();
            if (_keepBranchAmounts) {
              await _codingBox.put(cacheKey, {
                '_cached_at': DateTime.now().toUtc().toIso8601String(),
                ...local,
              });
              readScope.check();
            }
            print('🧮 [branch-salaries] حساب محلي');
            return _keepBranchAmounts ? local : SalaryVisibility.branch(local);
          }
        } catch (e) {
          print('⚠️ [branch-salaries] local calc failed: $e');
        }
      }

      // ---------- 3) Backend ----------
      try {
        final url = Uri.parse(
          '$baseUrl/hr/reports/branches/salaries',
        ).replace(queryParameters: {
          'company_code': companyCode,
          'month': month,
          if (branchCode != null && branchCode.isNotEmpty)
            'branch_code': branchCode,
        });

        readScope.check();
        final response = await AuthHttp.get(url);
        readScope.check();

        if (response.statusCode < 200 || response.statusCode >= 300) {
          print('❌ [branch-salaries] HTTP ${response.statusCode}');
          return null;
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;

        readScope.check();
        if (data['company_code'] != companyCode ||
            !_readBranchReport(companyCode, branchCode)) return null;
        final rows = data['employees'];
        if (rows is! List ||
            rows.whereType<Map>().length != rows.length ||
            rows.any((row) => !_ordinaryTarget(
                (row['employee_code'] ?? '').toString(),
                (row['branch_code'] ?? '').toString()))) return null;
        if (_keepBranchAmounts) {
          await _codingBox.put(cacheKey, {
            '_cached_at': DateTime.now().toUtc().toIso8601String(),
            ...data,
          });
          readScope.check();
        }
        print('🌐 [branch-salaries] من السيرفر');
        return _keepBranchAmounts ? data : SalaryVisibility.branch(data);
      } catch (e) {
        print('❌ [branch-salaries] $e');
        return null;
      }
    });
  }

  // ============================================================
  // ⭐ حساب الإجماليات محلياً من Hive
  // ============================================================

  // يحسب إجماليات رواتب الفرع محليًا
  Future<Map<String, dynamic>?> _calculateBranchTotalsLocally({
    required String companyCode,
    required String month,
    String? branchCode,
  }) async {
    return CachePartitions.run(() async {
      final readScope = await ReadAuthorizationSnapshot.capture();
      // 1) الموظفين من Hive
      final localKey = '${companyCode}_employees';
      final raw = _codingBox.get(localKey);
      if (raw is! List || raw.isEmpty) return null;

      final employees = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['is_deleted'] == true) continue;
        if (!_ordinaryTarget((map['code'] ?? '').toString(),
            (map['branch_code'] ?? '').toString())) continue;
        if (branchCode != null && branchCode.isNotEmpty) {
          if (map['branch_code']?.toString() != branchCode) continue;
        }
        employees.add(map);
      }

      if (employees.isEmpty) return null;

      // 2) حساب كل موظف
      final employeesData = <Map<String, dynamic>>[];
      double totalBasePay = 0.0;
      double totalAbsence = 0.0;
      double totalDelay = 0.0;
      double totalOvertime = 0.0;
      double totalBonuses = 0.0;
      double totalDeductions = 0.0;
      double totalLoans = 0.0;
      double totalNet = 0.0;
      int count = 0;

      for (final emp in employees) {
        readScope.check();
        try {
          final report = await _calculateLocally(
            companyCode: companyCode,
            employeeCode: emp['code'].toString(),
            month: month,
            includePending: false,
          );
          readScope.check();
          if (report == null) continue;

          count++;
          totalBasePay += report.basePay;
          totalAbsence += report.absenceDeduction;
          totalDelay += report.lateDeduction;
          totalOvertime += report.overtimeBonus;
          totalBonuses += report.bonusesTotal;
          totalDeductions += report.deductionsTotal;
          totalLoans += report.loansTotal;
          totalNet += report.netSalary;

          employeesData.add({
            'employee_code': report.employeeCode,
            'employee_name': report.employeeName,
            'branch_code': report.branchCode,
            'base_pay': report.basePay,
            'absence_deduction': report.absenceDeduction,
            'delay_deduction': report.lateDeduction,
            'overtime_bonus': report.overtimeBonus,
            'bonuses_total': report.bonusesTotal,
            'deductions_total': report.deductionsTotal,
            'loans_total': report.loansTotal,
            'net_salary': report.netSalary,
            'present_days': report.presentDays,
            'absent_days': report.absentDays,
            'vacation_days': report.vacationDays,
          });
        } catch (e) {
          print('⚠️ [branch-totals-local] ${emp['code']}: $e');
        }
      }

      if (employeesData.isEmpty) return null;

      // 3) ترتيب حسب الكود
      employeesData.sort((a, b) {
        final aCode = int.tryParse(a['employee_code']?.toString() ?? '0') ?? 0;
        final bCode = int.tryParse(b['employee_code']?.toString() ?? '0') ?? 0;
        return aCode.compareTo(bCode);
      });

      return {
        'company_code': companyCode,
        'month': month,
        'branch_code': branchCode ?? 'all',
        'totals': {
          'employees_count': count,
          'total_base_pay': _round2(totalBasePay),
          'total_absence_deduction': _round2(totalAbsence),
          'total_delay_deduction': _round2(totalDelay),
          'total_overtime_bonus': _round2(totalOvertime),
          'total_bonuses': _round2(totalBonuses),
          'total_deductions': _round2(totalDeductions),
          'total_loans': _round2(totalLoans),
          'total_net_salary': _round2(totalNet),
        },
        'employees': employeesData,
      };
    });
  }

  // ⭐ helper للتقريب
  // يقرّب الرقم إلى خانتين عشريتين
  static double _round2(double v) => (v * 100).round() / 100;
}
