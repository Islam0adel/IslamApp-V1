import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/permission_editor_snapshot.dart';

Map<String, dynamic> editorJson() => {
      'email': 'target@example.invalid',
      'uid': 'target',
      'company_code': 'C1',
      'profile_version': 'v1',
      'company_policy_active': true,
      'company_policy_revision': 2,
      'platform_admin': false,
      'is_active': true,
      'source_role': 'employee',
      'source_job_code': '1',
      'permissions': <String, dynamic>{},
      'allowed_branches': ['B2'],
      'startup_branch_code': 'B2',
      'hr_viewable_employees': null,
      'company_permissions': {
        'المبيعات': {'تعديل': true, 'حذف': true, 'عرض سعر التكلفة': true},
        'الموارد البشرية': {'canViewOwnHRData': true}
      },
      'delegable_permissions': {
        'المبيعات': {'تعديل': true}
      },
      'delegable_branches': ['B2'],
      'branch_choices': [
        {'code': 'B2', 'name': 'الثاني'}
      ],
      'employee_choices': [],
    };
void main() {
  test('delegation does not require own operating branches or data rights', () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    expect(e.canToggle('المبيعات', 'تعديل', true, {}, ['B2']), true);
    expect(e.canToggle('المبيعات', 'حذف', true, {}, ['B2']), false);
    expect(e.canToggle('المبيعات', 'عرض سعر التكلفة', true, {}, ['B2']), false);
    expect(e.canToggle('المبيعات', 'تصدير', true, {}, ['B2']), false);
  });
  test('edit includes add for the same type but never supplies delete', () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    expect(e.canToggle('المبيعات', 'إضافة', true, {}, ['B2']), true);
    expect(e.canToggle('المبيعات', 'حذف', true, {}, ['B2']), false);
  });
  test('scoped toggles require before and after branches inside delegation',
      () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    expect(e.canToggle('المبيعات', 'تعديل', true, {}, ['B3']), false);
    expect(e.canToggle('المبيعات', 'تعديل', true, {}, ['all']), false);
  });
  test('branch changes cannot carry undelegated existing delete rights', () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    expect(
        e.canEditBranch('B2', {
          'المبيعات': {'حذف': true}
        }),
        false);
    expect(e.canEditBranch('B2', {}), true);
    expect(e.canEditBranch('B3', {}), false);
    expect(e.canEditBranch('all', {}), false);
  });
  test('own HR does not turn into broad HR or branch authority', () {
    final json = editorJson();
    json['delegable_permissions'] = {
      'الموارد البشرية': {'canViewOwnHRData': true}
    };
    final e = PermissionEditorSnapshot.fromJson(json);
    expect(e.canToggle('الموارد البشرية', 'canViewOwnHRData', true, {}, ['B3']),
        true);
    expect(e.canToggle('الموارد البشرية', 'canViewEmployees', true, {}, ['B2']),
        false);
    expect(
        e.canEditBranch('B2', {
          'الموارد البشرية': {'canViewOwnHRData': true}
        }),
        true);
  });
  test(
      'root can explicitly remove dormant rights but cannot add outside ceiling',
      () {
    final json = editorJson();
    json['platform_admin'] = true;
    final e = PermissionEditorSnapshot.fromJson(json);
    expect(
        e.canToggle('المبيعات', 'صلاحية قديمة', false, {
          'المبيعات': {'صلاحية قديمة': true}
        }, [
          'B2'
        ]),
        true);
    expect(e.canToggle('المبيعات', 'صلاحية قديمة', true, {}, ['B2']), false);
  });
  for (final field in [
    'profile_version',
    'uid',
    'company_policy_revision',
    'delegable_permissions'
  ]) {
    test('active snapshot rejects missing $field', () {
      final v = editorJson()..remove(field);
      expect(() => PermissionEditorSnapshot.fromJson(v), throwsA(anything));
    });
  }
  test('returned maps and branch lists are detached from editable drafts', () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    e.permissions['المبيعات'] = {'حذف': true};
    e.branches.add('all');
    expect(e.permissions, isEmpty);
    expect(e.branches, ['B2']);
  });
  test(
      'source changes invalidate the editor without changing its expected version',
      () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    final source = {
      'uid': 'target',
      'company_code': 'C1',
      'role': 'employee',
      'job_code': '1',
      'permissions': {},
      'allowed_branches': ['B2'],
      'branch_code': 'B2',
      'is_active': true
    };
    expect(e.matchesSource(source), true);
    for (final change in [
      {'uid': 'other'},
      {'role': 'admin'},
      {'is_active': false},
      {
        'allowed_branches': ['B3']
      },
      {
        'permissions': {
          'المبيعات': {'حذف': true}
        }
      },
      {
        'hr_viewable_employees': ['E1']
      },
      {'branch_code': 'B3'}
    ]) {
      expect(e.matchesSource({...source, ...change}), false);
    }
    expect(e.version, 'v1');
  });
  test('malformed source flags are never accepted as unchanged metadata', () {
    final e = PermissionEditorSnapshot.fromJson(editorJson());
    expect(
        e.matchesSource({
          'uid': 'target',
          'permissions': {
            'X': {'Y': 'true'}
          }
        }),
        false);
  });
  test(
      'legacy null branch scope keeps its old all meaning, active null does not',
      () {
    final raw = jsonDecode(jsonEncode(editorJson())) as Map<String, dynamic>;
    raw['allowed_branches'] = null;
    expect(PermissionEditorSnapshot.fromJson(raw).branches, isEmpty);
    raw['company_policy_active'] = false;
    expect(PermissionEditorSnapshot.fromJson(raw).branches, ['all']);
  });
}
