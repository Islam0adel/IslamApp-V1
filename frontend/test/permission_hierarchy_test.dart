import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/permission_hierarchy.dart';
import 'package:islam_app/services/permissions_service.dart';

void main() {
  for (final section in PermissionHierarchy.addToEdit.entries) {
    for (final pair in section.value.entries) {
      test('${section.key}/${pair.key}: edit includes add only', () {
        final editOnly = <String, dynamic>{section.key: {pair.value: true, pair.key: false}};
        final addOnly = <String, dynamic>{section.key: {pair.key: true}};
        expect(PermissionHierarchy.allows(editOnly, section.key, pair.key), isTrue);
        expect(PermissionHierarchy.allows(editOnly, section.key, pair.value), isTrue);
        expect(PermissionHierarchy.allows(addOnly, section.key, pair.value), isFalse);
        for (final other in ['معاينة', 'حذف', 'تصدير', 'سعر الشراء', 'canViewAttendance', 'canDeleteAttendance']) {
          expect(PermissionHierarchy.allows(editOnly, section.key, other), isFalse);
        }
        final service = PermissionsService();
        service.debugSetPermissionsForTest(editOnly, role: 'employee', branches: ['B1']);
        expect(service.hasPermission(section.key, pair.key), isTrue);
        expect(service.hasPermission(section.key, pair.value), isTrue);
        if (pair.key == 'canAddAttendance') expect(service.canAddAttendance, isTrue);
        if (pair.key == 'canAddVacation') expect(service.canAddVacation, isTrue);
        service.debugSetPermissionsForTest(addOnly, role: 'employee', branches: ['B1']);
        expect(service.hasPermission(section.key, pair.value), isFalse);
        if (pair.key == 'canAddAttendance') expect(service.canEditAttendance, isFalse);
        if (pair.key == 'canAddVacation') expect(service.canEditVacation, isFalse);
      });
    }
  }
  test('specialized financial adjustment mapping is not invented', () {
    final p = <String, dynamic>{'الموارد البشرية': {'canEditAdjustment': true}};
    for (final key in ['canAddBonus', 'canAddLoan', 'canAddDirectDiscount']) {
      expect(PermissionHierarchy.allows(p, 'الموارد البشرية', key), isFalse);
    }
  });
}
