import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/services/read_authorization_snapshot.dart';
import 'commercial_queue_regression_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  setUp(() {
    SharedPreferences.setMockInitialValues({'company_code': 'C1'});
    f.currentUid = 'uid-A';
  });
  for (final active in [false, true]) {
    for (final role in ['admin', 'super_admin', 'employee']) {
      test('bypass preserves role and depends on reviewed activation $active $role', () {
        final ps = PermissionsService();
        ps.debugSetPermissionsForTest({}, role: role, companyPolicyActive: active);
        final bypass = role == 'super_admin' || (role == 'admin' && !active);
        expect(ps.canBypassPermissions, bypass);
        expect(ps.currentRole, role);
        expect(ps.isAdmin, role != 'employee');
        expect(ps.canManageCompanies, role == 'super_admin');
        expect(ps.canAddTreasuryTransfer, bypass);
        expect(ps.canViewTreasuryTransfers, bypass);
        expect(ps.canEditTreasuryTransfer, bypass);
        expect(ps.canDeleteTreasuryTransfer, bypass);
        expect(ps.canReadTreasuryEffects, bypass);
      });
    }
  }
  test('active admin retains only explicit same-kind action implications', () {
    final ps = PermissionsService();
    ps.debugSetPermissionsForTest({'تحويلات الخزائن': {'تعديل': true}},
      role: 'admin', companyPolicyActive: true);
    expect(ps.canEditTreasuryTransfer, true);
    expect(ps.canAddTreasuryTransfer, true);
    expect(ps.canViewTreasuryTransfers, false);
    expect(ps.canDeleteTreasuryTransfer, false);
    expect(ps.canViewSalaryAmounts, false);
  });
  test('policy transition invalidates outstanding reads', () async {
    final ps = PermissionsService();
    ps.debugSetPermissionsForTest({}, role: 'admin');
    final before = await ReadAuthorizationSnapshot.capture();
    ps.debugSetPermissionsForTest({}, role: 'admin', companyPolicyActive: true);
    expect(before.isCurrent, false);
    expect(ps.canBypassPermissions, false);
  });
}
