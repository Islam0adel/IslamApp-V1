// lib/services/notification_router.dart
//
// يفتح الشاشة المناسبة بناءً على إشعار.
// يستخدم في:
//   - NotificationsPage (tap)
//   - HomePage preview dialog (tap)
//   - DeepLinkService (SW push click - بعد المزامنة)
//
// ⭐ يستخدم "History Pages" بدل صفحات الإضافة عشان المستخدم يشوف
//    الحدث في سياقه (بدل ما يفتحله نموذج إضافة جديد).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'permissions_service.dart';

import '../views/dashboard/company_users_page.dart';
import '../core/navigator_key.dart';

// ─── History pages ───
import '../views/dashboard/daily_history_page.dart';
import '../views/dashboard/supplier_history_page.dart';
import '../views/dashboard/supplier_settlement_history_page.dart';
import '../views/dashboard/inventory_history_page.dart';

// ─── Pages without history (fall back to main page) ───
import '../views/dashboard/coding_page.dart';

// ─── HR pages ───
import '../pages/hr/attendance_page.dart';
import '../pages/hr/vacations_page.dart';
import '../pages/hr/employees/employees_list_page.dart';

class NotificationRouter {
  NotificationRouter._();

  static Future<void> openNotification(
    Map<String, dynamic> notification,
  ) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    final context = navigator.context;
    final section = (notification['section'] ?? '').toString();
    if (section.isEmpty) return;

    // ─── فحص الصلاحية ───
    if (!_canAccessSection(section)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'ليس لديك صلاحية الوصول لهذا القسم',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        );
      }
      return;
    }

    // ─── بيانات الشركة/المستخدم ───
    final prefs = await SharedPreferences.getInstance();
    final companyCode = prefs.getString('company_code') ?? '';
    final userName = prefs.getString('user_name') ?? '';

    if (companyCode.isEmpty) return;

    // ⭐ الفرع: من الإشعار أولاً، وإلا الفرع النشط الحالي
    final notifBranch =
        (notification['branch_code'] ?? '').toString().trim();
    final selectedBranchCode = notifBranch.isNotEmpty
        ? notifBranch
        : (prefs.getString('selected_branch_code') ?? 'all');

    // ─── اختيار الصفحة ───
    Widget? page;
    switch (section) {
      case 'daily':
        page = DailyHistoryPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
          userName: userName,
        );
        break;

      case 'purchases':
        page = SupplierHistoryPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
          userName: userName,
        );
        break;

      case 'settlements':
        page = SupplierSettlementHistoryPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
        );
        break;

      case 'coding':
        // مفيش صفحة "history" للتكويد — نفتح صفحة التكويد الرئيسية
        page = CodingPage(companyCode: companyCode);
        break;

      case 'inventory':
        page = InventoryHistoryPage(
          companyCode: companyCode,
          selectedBranchCode: selectedBranchCode,
        );
        break;

      case 'hr_attendance':
        page = const AttendancePage();
        break;

      case 'hr_vacations':
      case 'hr_adjustments':
        // التسويات في تاب داخل صفحة الإجازات
        page = const VacationsPage();
        break;

      case 'hr_employees':
        page = const EmployeesListPage();
        break;

      // ⭐ طلبات الانضمام — super_admin فقط → يفتح CompanyUsersPage
      case 'registration_requests':
        page = const _RegistrationRequestsRedirect();
        break;
    }

    if (page == null) return;

    // مهلة صغيرة عشان أي dialog مفتوح يقفل
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!context.mounted) return;

    await navigator.push(MaterialPageRoute(builder: (_) => page!));
  }
  // (يتم إضافة _RegistrationRequestsRedirect بعد الفئة)
  
  // ⭐ نفس منطق NotificationsService._canAccessSection
  static bool _canAccessSection(String section) {
    final ps = PermissionsService();
    if (!ps.isLoaded) return false;

    switch (section) {
      case 'daily':
        return ps.canShowTreasury;
      case 'purchases':
        return ps.canShowSuppliers;
      case 'settlements':
        return ps.canShowSupplierSettlements;
      case 'coding':
        return ps.canShowCoding;
      case 'inventory':
        return ps.canShowInventory;
      case 'hr_attendance':
        return ps.canOpenAttendancePage || ps.canAddAttendance;
      case 'hr_vacations':
        return ps.canOpenVacationsPage || ps.canAddVacation;
      case 'hr_adjustments':
        return ps.canViewAdjustments;
      case 'hr_employees':
        return ps.canViewEmployees || ps.canViewOwnHRData;
      default:
        return false;
    }
  }
  
}

// ============================================================
// Wrapper بسيط يفتح CompanyUsersPage للسوبر أدمن
// ============================================================
class _RegistrationRequestsRedirect extends StatelessWidget {
  const _RegistrationRequestsRedirect();

  @override
  Widget build(BuildContext context) {
    // نستخدم FutureBuilder عشان نجيب بيانات الشركة
    return FutureBuilder<Map<String, dynamic>>(
      future: _resolveCompanyInfo(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('طلبات الانضمام')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final info = snapshot.data!;
        return CompanyUsersPage(
          companyCode: info['company_code'] as String? ?? '',
          companyName: info['company_name'] as String? ?? 'كل الشركات',
        );
      },
    );
  }

Future<Map<String, dynamic>> _resolveCompanyInfo() {
  return Future.value({
    'company_code': '',
    'company_name': 'كل الشركات',
  });
}
}