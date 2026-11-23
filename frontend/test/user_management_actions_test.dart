import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/permissions_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final role in ['admin', 'employee']) {
    for (final action in PermissionsService.userManagementActions) {
      test('$role active operating action stays independent: $action', () {
        final service = PermissionsService();
        service.debugSetPermissionsForTest(
            {
              'إدارة المستخدمين': {action: true}
            },
            role: role,
            loaded: true,
            companyPolicyActive: true,
            branches: ['B1']);
        expect(service.canOpenUserManagement, true);
        for (final other in PermissionsService.userManagementActions) {
          expect(service.canUserManagementAction(other),
              other == action || (action == 'تعديل' && other == 'إضافة'));
        }
        expect(service.canManageUsers, role == 'admin',
            reason: 'Unrelated pending ownership gate must not be widened');
        expect(service.canReviewUserRequests,
            action == 'الموافقة على طلب' || action == 'رفض طلب');
      });
    }
  }
  test('active empty admin is not a management action bypass', () {
    final service = PermissionsService();
    service.debugSetPermissionsForTest({},
        role: 'admin',
        loaded: true,
        companyPolicyActive: true,
        branches: ['B1']);
    expect(service.canOpenUserManagement, false);
    expect(service.canReviewUserRequests, false);
  });
  for (final role in ['admin', 'super_admin']) {
    test('legacy $role keeps existing management access', () {
      final service = PermissionsService();
      service.debugSetPermissionsForTest({},
          role: role, loaded: true, branches: ['B1']);
      expect(service.canOpenUserManagement, true);
      expect(
          PermissionsService.userManagementActions
              .every(service.canUserManagementAction),
          true);
      expect(service.canUserManagementAction('unknown'), false);
    });
  }
}
