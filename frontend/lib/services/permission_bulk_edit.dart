import 'permission_hierarchy.dart';

/// Replays only allowed individual toggles. Included-add rows are not editable
/// until their parent edit permission has been cleared by the same operation.
Map<String, Map<String, bool>> bulkPermissionEdit(
    Map<String, Map<String, bool>> original,
    Map<String, Iterable<String>> groups, bool next,
    bool Function(String category, String key, bool next,
        Map<String, Map<String, bool>> current) canToggle) {
  final copy = original.map((category, values) => MapEntry(category, Map<String,bool>.from(values)));
  for (final category in groups.keys) {
    final keys = groups[category]!.toList();
    if (!next) keys.sort((a,b) {
      final parents = PermissionHierarchy.addToEdit[category]?.values.toSet() ?? <String>{};
      return (parents.contains(a) ? 0 : 1).compareTo(parents.contains(b) ? 0 : 1);
    });
    for (final key in keys) {
      final section = copy[category] ?? <String,bool>{};
      final higher = PermissionHierarchy.addToEdit[category]?[key];
      if (higher != null && section[higher] == true) continue;
      if ((section[key] == true) == next) continue;
      if (canToggle(category,key,next,copy)) (copy[category] ??= {})[key] = next;
    }
  }
  return copy;
}
