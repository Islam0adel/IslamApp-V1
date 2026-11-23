/// Explicit scopes for reviewed company policies. No role or operating scope
/// supplies a missing branch-delegation grant.
class BranchAssignmentCheck {
  const BranchAssignmentCheck(this.outsideCompany, this.outsideDelegation);
  final Set<String> outsideCompany;
  final Set<String> outsideDelegation;
  bool get allowed => outsideCompany.isEmpty && outsideDelegation.isEmpty;
}

class BranchScope {
  static void validate(dynamic value, {bool allowEmpty = true}) {
    if (value is! List || (!allowEmpty && value.isEmpty)) {
      throw const FormatException('Branch scope must be an explicit list');
    }
    if (value.any(
        (code) => code is! String || code.isEmpty || code != code.trim())) {
      throw const FormatException(
          'Branch codes must be exact nonempty strings');
    }
    if (value.toSet().length != value.length ||
        (value.contains('all') && value.length != 1) ||
        value.any((code) =>
            (code as String).toLowerCase() == 'all' && code != 'all')) {
      throw const FormatException(
          'Invalid all-branch scope or duplicate codes');
    }
  }

  static BranchAssignmentCheck checkAssignment({
    required List<String> previousBranches,
    required List<String> proposedBranches,
    required List<String> delegableBranches,
    required List<String> companyBranches,
    bool checkDelegation = true,
  }) {
    validate(previousBranches, allowEmpty: false);
    validate(proposedBranches, allowEmpty: false);
    validate(delegableBranches);
    validate(companyBranches);
    if (companyBranches.contains('all')) {
      throw const FormatException('Actual company branch codes required');
    }
    final previous = previousBranches.toSet(),
        proposed = proposedBranches.toSet();
    final changes =
        previous.difference(proposed).union(proposed.difference(previous));
    return BranchAssignmentCheck(
      proposed.difference({...companyBranches, 'all'}),
      checkDelegation && !delegableBranches.contains('all')
          ? changes.difference(delegableBranches.toSet())
          : <String>{},
    );
  }
}
