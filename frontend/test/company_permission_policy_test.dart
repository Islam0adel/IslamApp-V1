// Pure policy groundwork. No assertion here means route/UI integration is complete.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/permission_hierarchy.dart';
import 'package:islam_app/services/company_permission_policy.dart';

void main() {
  test('frontend matches shared hierarchy contract', () {
    final contract = jsonDecode(
            File('../contracts/permission_hierarchy.json').readAsStringSync())
        as Map;
    expect(contract['schema_version'], 1);
    expect(PermissionHierarchy.addToEdit, contract['edit_includes_add']);
  });
  for (final section in PermissionHierarchy.addToEdit.entries) {
    for (final pair in section.value.entries) {
      for (final ca in [false, true]) {
        for (final ce in [false, true]) {
          for (final ua in [false, true]) {
            for (final ue in [false, true]) {
              test('${section.key}/${pair.key}: C=$ca,$ce U=$ua,$ue', () {
                final company = {
                  section.key: {pair.key: ca, pair.value: ce}
                };
                final user = {
                  section.key: {pair.key: ua, pair.value: ue}
                };
                final result = CompanyPermissionPolicy.grants(
                    CompanyPermissionPolicy.effectivePermissions(
                        company, user));
                expect(result.contains((category: section.key, key: pair.key)),
                    (ca || ce) && (ua || ue));
                expect(
                    result.contains((category: section.key, key: pair.value)),
                    ce && ue);
                expect(
                    result
                        .every((r) => r.key == pair.key || r.key == pair.value),
                    true);
              });
            }
          }
        }
      }
    }
  }
  final ceiling = {
    'المبيعات': {'تعديل': true}
  };
  AssignmentCheck check(dynamic before, dynamic after,
          {dynamic company, dynamic delegable, bool skip = false}) =>
      CompanyPermissionPolicy.checkAssignment(
          companyCeiling: company ?? ceiling,
          delegablePermissions: delegable ?? {},
          previousPermissions: before,
          proposedPermissions: after,
          checkDelegation: !skip);
  test('delegation does not supply operating rights', () {
    expect(CompanyPermissionPolicy.effectivePermissions(ceiling, {}), isEmpty);
    expect(check({}, ceiling, delegable: ceiling).allowed, true);
    expect(check({}, ceiling).allowed, false);
  });
  test('add-only delegation cannot grant edit', () {
    final result = check({}, ceiling,
        delegable: {
          'المبيعات': {'إضافة': true}
        });
    expect(result.outsideDelegation, {(category: 'المبيعات', key: 'تعديل')});
    expect(result.allowed, false);
  });
  test('unchanged nondelegable rights stay, changing them is reported', () {
    expect(check(ceiling, ceiling).allowed, true);
    expect(
        check(ceiling, {
          'المبيعات': {'تعديل': true, 'إضافة': false}
        }).allowed,
        true);
    expect(
        check(ceiling, {
          'المبيعات': {'إضافة': true}
        }).outsideDelegation,
        {(category: 'المبيعات', key: 'تعديل')});
  });
  test('skipping delegation cannot bypass the company ceiling', () {
    final result = check({}, ceiling,
        company: {
          'المبيعات': {'إضافة': true}
        },
        skip: true);
    expect(result.outsideCompany, {(category: 'المبيعات', key: 'تعديل')});
    expect(result.allowed, false);
  });
  for (final value in <dynamic>[
    null,
    [],
    true,
    {'المبيعات': []},
    {
      'المبيعات': {'إضافة': 1}
    },
    {
      'المبيعات': {'إضافة': 'true'}
    },
    {
      'المبيعات': {'إضافة': null}
    },
    {'': {}},
    {
      'المبيعات': {'': true}
    }
  ]) {
    test('malformed proposal ${value.toString()} is rejected', () {
      expect(() => CompanyPermissionPolicy.validateMap(value),
          throwsArgumentError);
      expect(() => check({}, value), throwsArgumentError);
    });
  }
  test('malformed runtime values do not become grants', () {
    expect(
        CompanyPermissionPolicy.grants({
          'المبيعات': {'إضافة': 1, 'تعديل': 'true'}
        }),
        isEmpty);
    expect(
        CompanyPermissionPolicy.effectivePermissions(null, ceiling), isEmpty);
    expect(
        CompanyPermissionPolicy.effectivePermissions(ceiling, null), isEmpty);
  });
  test('no extra view delete cost export or adjustment grants are inferred',
      () {
    expect(
        CompanyPermissionPolicy.grants({
          'المبيعات': {'تعديل': true},
          'الموارد البشرية': {'canEditAdjustment': true}
        }),
        {
          (category: 'المبيعات', key: 'إضافة'),
          (category: 'المبيعات', key: 'تعديل'),
          (category: 'الموارد البشرية', key: 'canEditAdjustment')
        });
  });
}
