# backend/app/core/company_policy_store.py
"""Store company-policy drafts and project the active policy for consumers.

Reviewed activation is owned by company_policy_review. Draft storage never
changes the active policy or clears the initial company review gate.
"""
from app.core.branch_catalog import company_branch_catalog
from copy import deepcopy

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from app.core.models import Company, CompanyPermissionPolicy
from app.core.branch_scope import validate_branch_scope, active_operating_branches
from app.core.permission_policy import effective_permissions, grants, validate_permission_map


# خطأ تعارض نسخة السياسة (حد غيّرها قبل الحفظ)
class PolicyConflict(Exception):
    pass


# خطأ بيتبعت لما الشركة غير معروفة للسياسة
class UnknownPolicyCompany(Exception):
    pass


# خطأ بيتبعت لما الشركة محتاجة مراجعة سياسة قبل المتابعة
class CompanyReviewRequired(Exception):
    """New-company business access is held until its explicit review finishes."""
    pass


# يتحقق من صحة إعدادات السياسة ويرجّعها منظّمة
def validate_configuration(value):
    if not isinstance(value, dict) or set(value) != {'company_permissions', 'admin_profiles'}:
        raise ValueError('policy requires company_permissions and admin_profiles')
    validate_permission_map(value['company_permissions'])
    admins = value['admin_profiles']
    if not isinstance(admins, dict):
        raise ValueError('admin_profiles must be a UID-keyed object')
    ceiling = grants(value['company_permissions'])
    for uid, profile in admins.items():
        if not isinstance(uid, str) or not uid.strip() or uid != uid.strip():
            raise ValueError('admin profile requires an exact nonempty UID')
        required = {'operating_permissions', 'delegable_permissions'}
        if (not isinstance(profile, dict) or not required <= set(profile)
                or set(profile) - required - {'delegable_branches'}):
            raise ValueError('admin profile requires separate operating and delegation maps')
        # Older drafts have no branch-delegation grant. Never infer it from
        # operating branches or from the admin role.
        validate_branch_scope(profile.get('delegable_branches', []))
        for key in ('operating_permissions', 'delegable_permissions'):
            validate_permission_map(profile[key])
            if not grants(profile[key]) <= ceiling:
                raise ValueError('admin rights cannot exceed the company ceiling')


# يطبّق إعدادات السياسة على بروفايل مستخدم ويرجّع البروفايل الناتج
def policy_profile(profile, configuration, *, role):
    """Pure projector. Callers must supply current source-verified active state.

    A missing active configuration preserves legacy behavior. It does not turn
    an empty legacy admin map into a new grant. Active admins require an exact
    UID entry; delegation never supplies an operating right.
    """
    result = deepcopy(profile)
    result['company_policy_active'] = configuration is not None
    result.pop('delegable_permissions', None)
    result.pop('delegable_branches', None)
    if configuration is None:
        return result
    validate_configuration(configuration)
    if role == 'super_admin':
        return result
    result['allowed_branches'] = active_operating_branches(profile.get('allowed_branches'))
    ceiling = configuration['company_permissions']
    if role == 'admin':
        assignment = configuration['admin_profiles'].get(str(profile.get('uid', '')), {})
        operating = assignment.get('operating_permissions', {})
        delegation = assignment.get('delegable_permissions', {})
        branch_delegation = assignment.get('delegable_branches', [])
    else:
        operating = profile.get('permissions', {})
        delegation = {}
        branch_delegation = []
    result['delegable_branches'] = deepcopy(branch_delegation)
    result['permissions'] = effective_permissions(ceiling, operating)
    result['delegable_permissions'] = effective_permissions(ceiling, delegation)
    return result


# يقرأ سياسة الشركة (المسوّدة والمفعّلة) من قاعدة البيانات
async def read_policy(session, company_code):
    company = await session.scalar(select(Company).where(Company.code == company_code))
    if company is None:
        raise UnknownPolicyCompany()
    row = await session.get(CompanyPermissionPolicy, company_code, populate_existing=True)
    return {
        'company_code': company_code,
        'revision': row.revision if row else 0,
        'status': ('initial_review_required' if company.requires_permission_review else
                   'active' if row and row.active is not None else 'legacy_review_required'),
        'requires_permission_review': company.requires_permission_review,
        'draft': deepcopy(row.draft) if row else None,
        'draft_base_active_revision': row.draft_base_active_revision if row else None,
        'draft_requires_reconciliation': bool(row and row.active_revision is not None and row.draft is not None and row.draft_base_active_revision != row.active_revision),
        'active': deepcopy(row.active) if row else None,
        'active_revision': row.active_revision if row else None,
        'reviewed_by_uid': row.reviewed_by_uid if row else None,
        'reviewed_at': row.reviewed_at.isoformat() if row and row.reviewed_at else None,
    }


# يحفظ مسوّدة السياسة مع فحص رقم النسخة المتوقع
async def save_policy_draft(session, company_code, configuration, *, expected_revision, reconciled_active_revision=None):
    """Caller authenticates the program admin. This only commits a draft.

    Compare-and-swap prevents a stale editor overwriting a newer draft. The
    first-insert race is checked by the primary key, not a select-then-upsert.
    Active configuration and review metadata are never changed here.
    """
    validate_configuration(configuration)
    if type(expected_revision) is not int or expected_revision < 0:
        raise ValueError('expected_revision must be a nonnegative integer')
    company = await session.scalar(select(Company.code).where(
        Company.code == company_code).with_for_update())
    if company is None:
        raise UnknownPolicyCompany()
    existing = await session.get(CompanyPermissionPolicy, company_code, populate_existing=True)
    active_revision = existing.active_revision if existing else None
    if (existing and existing.draft is not None and active_revision is not None
            and existing.draft_base_active_revision != active_revision
            and reconciled_active_revision != active_revision):
        raise PolicyConflict('review the current active policy alongside the retained draft')
    named_branches = {code for admin in configuration['admin_profiles'].values()
                      for code in admin.get('delegable_branches', []) if code != 'all'}
    if named_branches:
        current_branches = set(await company_branch_catalog(session, company_code, lock=True))
        if not named_branches <= current_branches:
            raise ValueError('delegation includes unknown company branches')
    if expected_revision == 0:
        session.add(CompanyPermissionPolicy(company_code=company_code, revision=1,
                                            draft=deepcopy(configuration), draft_base_active_revision=active_revision))
        try:
            await session.commit()
        except IntegrityError as exc:
            await session.rollback()
            raise PolicyConflict() from exc
    else:
        changed = await session.execute(
            update(CompanyPermissionPolicy)
            .where(CompanyPermissionPolicy.company_code == company_code,
                   CompanyPermissionPolicy.revision == expected_revision)
            .values(revision=expected_revision + 1, draft=deepcopy(configuration), draft_base_active_revision=active_revision)
            .execution_options(synchronize_session=False)
        )
        if changed.rowcount != 1:
            await session.rollback()
            raise PolicyConflict()
        await session.commit()
    return await read_policy(session, company_code)


# يرجّع إعدادات السياسة المفعّلة للشركة
async def active_policy_configuration(session, company_code):
    """One current SQL read, with a new-company gate and no negative cache.

    A missing policy on an existing company keeps its legacy semantics. A new
    company is never converted into legacy simply because it has no policy yet.
    The gate must be cleared atomically by the explicit reviewed activation workflow,
    never by saving a draft or writing an account profile.
    """
    result = await session.execute(select(
        Company.requires_permission_review,
        CompanyPermissionPolicy.active, CompanyPermissionPolicy.active_revision,
    ).select_from(Company).outerjoin(CompanyPermissionPolicy,
        CompanyPermissionPolicy.company_code == Company.code
    ).where(Company.code == company_code))
    row = result.first()
    if row is None:
        return None, None
    if row[0] is True:
        raise CompanyReviewRequired()
    return deepcopy(row[1]), row[2]


# يحسب البروفايل الفعلي للمستخدم حسب السياسة ورقم نسختها
def effective_policy_profile(profile, configuration, revision, *, role):
    result = policy_profile(profile, configuration, role=role)
    result.pop('company_permissions', None)
    result.pop('assigned_permissions', None)
    result['company_policy_revision'] = revision if configuration is not None else None
    if configuration is not None and role != 'super_admin':
        result['company_permissions'] = deepcopy(configuration['company_permissions'])
        if role == 'admin':
            assignment = configuration['admin_profiles'].get(str(profile.get('uid', '')), {})
            result['assigned_permissions'] = deepcopy(assignment.get('operating_permissions', {}))
        else:
            result['assigned_permissions'] = deepcopy(profile.get('permissions', {}))
    return result


# يحمّل السياسة المفعّلة ويطبّقها على البروفايل
async def load_effective_policy_profile(session, profile, *, role):
    """Project current SQL policy onto a caller-verified fresh source profile.

    This does not authenticate an account or read Firestore. The caller owns
    UID, email, company, status and source freshness checks.
    """
    configuration, revision = None, None
    if role != 'super_admin':
        configuration, revision = await active_policy_configuration(
            session, str(profile.get('company_code', '')),
        )
    result = effective_policy_profile(profile, configuration, revision, role=role)
    result['role'] = role
    return result
