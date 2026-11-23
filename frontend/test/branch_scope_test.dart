import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/branch_scope.dart';
import 'package:islam_app/services/effective_profile_snapshot.dart';

Map<String, dynamic> profile() => {
      'uid': 'u',
      'email': 'fixture@example.invalid',
      'company_code': 'C1',
      'role': 'admin',
      'company_policy_active': true,
      'company_policy_revision': 1,
      'allowed_branches': ['B1'],
      'permissions': <String, dynamic>{},
      'company_permissions': <String, dynamic>{},
      'assigned_permissions': <String, dynamic>{},
      'delegable_permissions': <String, dynamic>{},
    };
EffectiveProfileSnapshot parse(dynamic data) =>
    EffectiveProfileSnapshot.parse(data,
        uid: 'u', email: 'fixture@example.invalid', company: 'C1');

void main() {
  final cases = <List<dynamic>>[
    [
      ['B1'],
      ['B1', 'B2'],
      ['B2'],
      true
    ],
    [
      ['B1', 'B2'],
      ['B1'],
      ['B2'],
      true
    ],
    [
      ['B1', 'B2'],
      ['B2'],
      ['B2'],
      false
    ],
    [
      ['B1'],
      ['B1'],
      [],
      true
    ],
    [
      ['B1'],
      ['all'],
      ['B1', 'B2'],
      false
    ],
    [
      ['all'],
      ['B1', 'B2'],
      ['B1', 'B2'],
      false
    ],
    [
      ['B1'],
      ['all'],
      ['all'],
      true
    ],
    [
      ['all'],
      ['B1'],
      ['all'],
      true
    ],
    [
      ['B1'],
      ['foreign'],
      ['all'],
      false
    ],
  ];
  for (var i = 0; i < cases.length; i++) {
    test('branch replacement preserves unchanged nondelegable scope $i', () {
      final c = cases[i];
      final result = BranchScope.checkAssignment(
          previousBranches: List<String>.from(c[0]),
          proposedBranches: List<String>.from(c[1]),
          delegableBranches: List<String>.from(c[2]),
          companyBranches: ['B1', 'B2']);
      expect(result.allowed, c[3]);
    });
  }
  test('missing delegation never comes from operating branches', () {
    expect(parse(profile()).data['delegable_branches'], isEmpty);
    final data = profile()..['delegable_branches'] = ['B2'];
    final parsed = parse(data);
    expect(parsed.data['allowed_branches'], ['B1']);
    expect(parsed.data['delegable_branches'], ['B2']);
    (data['delegable_branches'] as List).clear();
    expect(parsed.data['delegable_branches'], ['B2']);
  });
  final invalid = <dynamic>[
    null,
    'all',
    true,
    {},
    [1],
    [''],
    [' B1'],
    ['B1 '],
    ['B1', 'B1'],
    ['all', 'B1'],
    ['ALL']
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('invalid branch delegation is rejected $i', () {
      expect(() => parse(profile()..['delegable_branches'] = invalid[i]),
          throwsA(anything));
    });
  }
  test('employee does not acquire delegation from an unexpected profile field',
      () {
    final data = profile()
      ..['role'] = 'employee'
      ..['delegable_branches'] = ['B2'];
    expect(() => parse(data), throwsA(anything));
  });
  test('legacy source fields are not branch delegation authority', () {
    final data = profile()
      ..['company_policy_active'] = false
      ..['delegable_branches'] = ['all'];
    expect(parse(data).data.containsKey('delegable_branches'), false);
  });
  for (final invalidScope in [
    <String>[],
    ['B1', 'B1'],
    ['all', 'B1'],
    [' B1'],
    ['ALL']
  ]) {
    test('invalid active operating scope stays held: $invalidScope', () {
      expect(() => parse(profile()..['allowed_branches'] = invalidScope),
          throwsA(anything));
    });
  }
}
