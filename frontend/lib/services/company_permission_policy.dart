import 'page_visibility.dart';
// Company-ceiling operations shared by effective authorization and review.
// This creates no grants and does not select a legacy activation policy.
import 'permission_hierarchy.dart';

typedef PermissionRight = ({String category, String key});

class AssignmentCheck {
  const AssignmentCheck(this.outsideCompany, this.outsideDelegation);
  final Set<PermissionRight> outsideCompany;
  final Set<PermissionRight> outsideDelegation;
  bool get allowed => outsideCompany.isEmpty && outsideDelegation.isEmpty;
}

class CompanyPermissionPolicy {
  static void validateMap(dynamic value) {
    if (value is! Map) throw ArgumentError('permissions must be an object');
    for (final section in value.entries) {
      if (section.key is! String ||
          (section.key as String).isEmpty ||
          section.value is! Map) {
        throw ArgumentError('permission sections must be named objects');
      }
      for (final entry in (section.value as Map).entries) {
        if (entry.key is! String ||
            (entry.key as String).isEmpty ||
            entry.value is! bool) {
          throw ArgumentError('permission values must be named booleans');
        }
      }
    }
  }

  static Set<PermissionRight> grants(dynamic value) {
    final result = <PermissionRight>{};
    if (value is! Map) return result;
    for (final section in value.entries) {
      if (section.key is! String || section.value is! Map) continue;
      final category = section.key as String;
      final entries = section.value as Map;
      for (final entry in entries.entries) {
        if (entry.key is String &&
            (entry.key as String).isNotEmpty &&
            entry.value == true) {
          result.add((category: category, key: entry.key as String));
        }
      }
      for (final pair
          in (PermissionHierarchy.addToEdit[category] ?? <String, String>{})
              .entries) {
        if (entries[pair.value] == true)
          result.add((category: category, key: pair.key));
      }
    }
    return result;
  }

  static Map<String, Map<String, bool>> materialize(
      Set<PermissionRight> rights) {
    final result = <String, Map<String, bool>>{};
    for (final right in rights) {
      (result[right.category] ??= {})[right.key] = true;
    }
    return result;
  }

  static Map<String, Map<String, bool>> effectivePermissions(
          dynamic ceiling, dynamic operating) {
    final result = materialize(grants(ceiling).intersection(grants(operating)));
    final general = operating is Map ? operating['صلاحيات عامة'] : null;
    for (final key in PageVisibility.keys) {
      if (general is Map && general[key] == false) {
        (result['صلاحيات عامة'] ??= {})[key] = false;
      }
    }
    return result;
  }

  static AssignmentCheck checkAssignment(
      {required dynamic companyCeiling,
      required dynamic delegablePermissions,
      required dynamic previousPermissions,
      required dynamic proposedPermissions,
      bool checkDelegation = true}) {
    validateMap(proposedPermissions);
    final previous = grants(previousPermissions);
    final proposed = grants(proposedPermissions);
    final changes =
        previous.difference(proposed).union(proposed.difference(previous));
    for (final key in PageVisibility.keys) {
      final before = previousPermissions is Map ? previousPermissions['صلاحيات عامة'] : null;
      final after = proposedPermissions['صلاحيات عامة'];
      if ((before is Map ? before[key] : null) != (after is Map ? after[key] : null)) {
        changes.add((category: 'صلاحيات عامة', key: key));
      }
    }
    return AssignmentCheck(
        proposed.difference(grants(companyCeiling)),
        checkDelegation
            ? changes.difference(grants(delegablePermissions))
            : <PermissionRight>{});
  }
}
