"""Explicit company-local branch scopes, without legacy wildcard defaults."""
from dataclasses import dataclass


def validate_branch_scope(value, *, allow_empty=True):
    if not isinstance(value, list) or (not allow_empty and not value):
        raise ValueError('branch scope must be an explicit list')
    if any(not isinstance(code, str) or not code or code != code.strip() for code in value):
        raise ValueError('branch codes must be exact nonempty strings')
    if len(set(value)) != len(value) or ('all' in value and value != ['all']):
        raise ValueError('branch scope cannot repeat codes or mix all with named branches')
    if any(code.lower() == 'all' and code != 'all' for code in value):
        raise ValueError('all-branch scope must use the exact all marker')


class InvalidOperatingBranchScope(ValueError):
    pass


def active_operating_branches(value):
    # The historical explicit string marker remains compatible. Missing/empty
    # scope must never be converted into company-wide operating authority.
    if value == 'all':
        value = ['all']
    try:
        validate_branch_scope(value, allow_empty=False)
    except ValueError as exc:
        raise InvalidOperatingBranchScope(str(exc)) from exc
    return list(value)


@dataclass(frozen=True)
class BranchAssignmentCheck:
    outside_company: frozenset[str]
    outside_delegation: frozenset[str]

    @property
    def allowed(self):
        return not self.outside_company and not self.outside_delegation


def check_branch_assignment(*, previous_branches, proposed_branches,
                            delegable_branches, company_branches,
                            check_delegation=True):
    """Replacement check, not account authentication or a write operation.

    The all marker retains future-branch reach. A limited delegation cannot
    grant or revoke that wildcard just because today's branch list is small.
    Unchanged branches outside delegation are preserved; changing them fails.
    """
    validate_branch_scope(previous_branches, allow_empty=False)
    validate_branch_scope(proposed_branches, allow_empty=False)
    validate_branch_scope(delegable_branches)
    validate_branch_scope(company_branches)
    if 'all' in company_branches:
        raise ValueError('company_branches requires actual branch codes')
    previous, proposed = set(previous_branches), set(proposed_branches)
    outside_company = proposed - set(company_branches) - {'all'}
    changes = previous ^ proposed
    outside_delegation = (changes - set(delegable_branches)
        if check_delegation and 'all' not in delegable_branches else set())
    return BranchAssignmentCheck(frozenset(outside_company), frozenset(outside_delegation))
