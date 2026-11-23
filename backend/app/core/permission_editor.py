"""Current-source permission editor and transactional account-scope writes.

SQL company/policy locks are held across the source transaction. Only that
transaction writes account scope. This is not company-policy activation.
"""
from app.core.branch_catalog import company_branch_catalog
import asyncio
import anyio
from copy import deepcopy
from fastapi import HTTPException
from google.cloud import firestore
from sqlalchemy import select
from app.core.models import Company, CompanyPermissionPolicy, Employee
from app.core.company_policy_store import validate_configuration, policy_profile
from app.core.permission_policy import validate_permission_map, grants, check_assignment, effective_permissions
from app.core.branch_scope import active_operating_branches, check_branch_assignment


async def finish_mutation(awaitable):
    """Keep authority locks until an in-flight source write and refresh settle.

    Cancelling an asyncio await does not stop a worker thread. Shield both
    ASGI cancel scopes and direct task cancellation; propagate direct cancel
    only after the protected operation has completed.
    """
    interrupted = False
    with anyio.CancelScope(shield=True):
        work = asyncio.create_task(awaitable)
        while True:
            try:
                return await asyncio.shield(work), interrupted
            except asyncio.CancelledError:
                if work.cancelled():
                    raise
                interrupted = True


def run_source_transaction(source, callback):
    @firestore.transactional
    def operation(transaction):
        return callback(transaction)
    return operation(source.transaction())


def _version(snapshot):
    value = getattr(snapshot, 'update_time', None)
    return value.isoformat() if value is not None else None


def _active(profile):
    return profile.get('is_active') is not False and str(profile.get('status', 'active')).lower() not in ('pending', 'suspended')


def _hr_scope(value):
    if value is None or value == []:
        return None
    if (not isinstance(value, list) or any(not isinstance(code, str) or not code
            or code != code.strip() for code in value) or len(set(value)) != len(value)):
        raise HTTPException(status_code=409, detail='راجع نطاق موظفي الموارد البشرية أولاً')
    return frozenset(value)


def _scoped_rights(rights):
    # Explicit own-HR is independent of the broader branch/employee filter.
    return {right for right in rights if right[0] != 'صلاحيات عامة'
            and right != ('الموارد البشرية', 'canViewOwnHRData')}


def _inside(branches, delegation):
    return 'all' in delegation or ('all' not in branches and set(branches) <= set(delegation))


async def _locked_policy(session, company_code, *, allow_initial_review=False):
    company = await session.scalar(select(Company).where(Company.code == company_code).with_for_update())
    if company is None:
        raise HTTPException(status_code=404, detail='الشركة غير موجودة')
    if company.requires_permission_review and not allow_initial_review:
        raise HTTPException(status_code=403, detail='تحتاج الشركة مراجعة صلاحياتها قبل الاستخدام')
    row = await session.scalar(select(CompanyPermissionPolicy).where(
        CompanyPermissionPolicy.company_code == company_code).with_for_update())
    configuration = deepcopy(row.active) if row is not None else None
    if configuration is not None:
        if type(row.active_revision) is not int or row.active_revision < 1:
            raise HTTPException(status_code=503, detail='تعذر التحقق من إصدار سياسة الشركة')
        try:
            validate_configuration(configuration)
        except ValueError:
            raise HTTPException(status_code=503, detail='تعذر التحقق من سياسة الشركة')
    return company, configuration, row.active_revision if row is not None else None


def _current_accounts(source, actor, email, company_code, role_resolver, *, transaction=None,
                      configuration=None, company_active=True):
    actor_email = str(actor.get('email', '')).strip().lower()
    actor_uid = str(actor.get('uid', ''))
    if not actor_email or not actor_uid:
        raise HTTPException(status_code=401, detail='يجب إعادة تسجيل الدخول')
    actor_ref = source.collection('users').document(actor_email)
    actor_doc = actor_ref.get(transaction=transaction) if transaction is not None else actor_ref.get()
    current = actor_doc.to_dict() if actor_doc.exists else None
    if not isinstance(current, dict) or str(current.get('uid', '')) != actor_uid:
        raise HTTPException(status_code=401, detail='تغير حساب المسؤول. أعد تحميل الجلسة')
    current = {**current, 'email': actor_email}
    role = role_resolver(current)
    if not _active(current):
        raise HTTPException(status_code=403, detail='حساب المسؤول غير متاح')
    legacy_general = current.get('permissions', {}).get('صلاحيات عامة', {}) if isinstance(current.get('permissions'), dict) else {}
    legacy_editor = isinstance(legacy_general, dict) and legacy_general.get('صفحة الصلاحيات(الاعدادات)') is True
    if role not in ('admin', 'super_admin') and (configuration is not None or not legacy_editor):
        raise HTTPException(status_code=403, detail='غير مصرح بتعديل الصلاحيات')
    if role != 'super_admin':
        if not company_active or str(current.get('company_code', '')) != company_code:
            raise HTTPException(status_code=403, detail='غير مسموح بإدارة هذه الشركة')
    if configuration is not None and role == 'admin':
        delegated = policy_profile(current, configuration, role=role)
        if not grants(delegated.get('delegable_permissions')) and not delegated.get('delegable_branches'):
            raise HTTPException(status_code=403, detail='لا يوجد نطاق مفوض لإدارة الصلاحيات')
    target_ref = source.collection('users').document(email)
    target_doc = actor_doc if actor_email == email else (target_ref.get(transaction=transaction) if transaction is not None else target_ref.get())
    if not target_doc.exists:
        raise HTTPException(status_code=404, detail='المستخدم غير موجود')
    target = target_doc.to_dict() or {}
    if str(target.get('company_code', '')) != company_code:
        if role != 'super_admin':
            raise HTTPException(status_code=404, detail='المستخدم غير موجود')
        raise HTTPException(status_code=409, detail='تغيرت شركة الحساب. أعد تحميل المستخدم')
    if target.get('account_lifecycle') is not None:
        raise HTTPException(status_code=409, detail='إجراء حذف أو إعادة تهيئة غير مكتمل. أكمل نفس الإجراء أولاً')
    target_role = role_resolver({**target, 'email': email})
    if target_role == 'super_admin' and role != 'super_admin':
        raise HTTPException(status_code=403, detail='غير مسموح بتعديل السوبر أدمن')
    if target_role == 'admin' and role not in ('admin', 'super_admin'):
        raise HTTPException(status_code=403, detail='غير مسموح بتعديل مدير')
    return current, role, target_ref, target_doc, target


async def _editor_company(source, actor, email, role_resolver):
    if not email or '/' in email or '\\' in email or email in ('.', '..'):
        raise HTTPException(status_code=400, detail='معرّف الحساب غير صالح')
    def inspect():
        actor_email = str(actor.get('email', '')).strip().lower()
        actor_uid = str(actor.get('uid', ''))
        if not actor_email or not actor_uid:
            raise HTTPException(status_code=401, detail='يجب إعادة تسجيل الدخول')
        snapshot = source.collection('users').document(actor_email).get()
        current = snapshot.to_dict() if snapshot.exists else None
        if not isinstance(current, dict) or str(current.get('uid', '')) != actor_uid or not _active(current):
            raise HTTPException(status_code=403, detail='حساب المسؤول غير متاح')
        role = role_resolver({**current, 'email': actor_email})
        general = current.get('permissions', {}).get('صلاحيات عامة', {}) if isinstance(current.get('permissions'), dict) else {}
        if role not in ('admin', 'super_admin') and not (isinstance(general, dict) and general.get('صفحة الصلاحيات(الاعدادات)') is True):
            raise HTTPException(status_code=403, detail='غير مصرح بإدارة الصلاحيات')
        if role != 'super_admin':
            company = str(current.get('company_code', ''))
            if not company: raise HTTPException(status_code=403, detail='الحساب غير مرتبط بشركة')
            return company
        target = source.collection('users').document(email).get()
        if not target.exists: raise HTTPException(status_code=404, detail='المستخدم غير موجود')
        company = str((target.to_dict() or {}).get('company_code', ''))
        if not company: raise HTTPException(status_code=409, detail='المستخدم غير مرتبط بشركة')
        return company
    return await asyncio.to_thread(inspect)


async def read_permission_editor(session, source, actor, email, role_resolver):
    company_code = await _editor_company(source, actor, email, role_resolver)
    company, configuration, revision = await _locked_policy(session, company_code)
    current, role, _, snapshot, target = await asyncio.to_thread(_current_accounts,
        source, actor, email, company_code, role_resolver,
        configuration=configuration, company_active=company.is_active)
    active = configuration is not None
    projected = policy_profile(current, configuration, role=role)
    delegation = (configuration['company_permissions'] if role == 'super_admin' and active
        else projected.get('delegable_permissions', {}))
    branch_delegation = ['all'] if role == 'super_admin' else projected.get('delegable_branches', [])
    raw_branches = target.get('allowed_branches')
    target_branches = set(raw_branches) if isinstance(raw_branches, list) and all(isinstance(v, str) for v in raw_branches) else set()
    if raw_branches == 'all' or (not active and not raw_branches): target_branches = {'all'}
    visible_branches = target_branches | set(branch_delegation)
    catalog=await company_branch_catalog(session,company_code)
    branch_choices = [{'code': code, 'name': name} for code,name in catalog.items()
        if 'all' in visible_branches or code in visible_branches]
    employee_choices = []
    if not active or role == 'super_admin' or any(right[0] == 'الموارد البشرية' for right in grants(delegation)):
        employee_query = select(Employee.code, Employee.name).where(
            Employee.company_code == company_code, Employee.is_deleted.is_(False))
        if 'all' not in visible_branches:
            from sqlalchemy import or_
            employee_query = employee_query.where(or_(Employee.branch_code.in_(visible_branches),
                (Employee.user_uid == str(target.get('uid'))) if target.get('uid') else False))
        employee_choices = [{'code': code, 'name': name} for code, name in (await session.execute(employee_query)).all()]
    updated_at = target.get('updated_at')
    return {'email': email, 'uid': str(target.get('uid', '')), 'company_code': company_code,
        'is_active': target.get('is_active') is not False, 'role': role_resolver({**target, 'email': email}),
        'source_role': target.get('role'), 'source_job_code': target.get('job_code'),
        'source_status': target.get('status'),
        'platform_admin': role == 'super_admin',
        'is_self': current['email'] == email,
        'source_updated_at': updated_at.isoformat() if hasattr(updated_at, 'isoformat') else None,
        'branch_choices': branch_choices, 'employee_choices': employee_choices,
        'profile_version': _version(snapshot), 'company_policy_active': active,
        'company_policy_revision': revision if active else None,
        'source_permissions': deepcopy(target.get('permissions', {})),
        'permissions': deepcopy(configuration['admin_profiles'].get(str(target.get('uid','')), {}).get('operating_permissions', {})) if active and role_resolver({**target,'email':email}) == 'admin' else deepcopy(target.get('permissions', {})),
        'allowed_branches': deepcopy(target.get('allowed_branches')),
        'startup_branch_code': str(target.get('branch_code', '')),
        'hr_viewable_employees': deepcopy(target.get('hr_viewable_employees')),
        'company_permissions': deepcopy(configuration['company_permissions']) if active else None,
        'delegable_permissions': deepcopy(delegation),
        'delegable_branches': deepcopy(branch_delegation)}


async def write_legacy_editor_status(session, source, actor, email, data, role_resolver):
    """Only the legacy permission-editor status control, with source CAS.

    Reviewed policies use account-management status authority instead. Never
    reproduce the old unchecked direct-client update or permit root self-block.
    """
    code = await _editor_company(source, actor, email, role_resolver)
    company, configuration, _ = await _locked_policy(session, code)
    if configuration is not None:
        raise HTTPException(status_code=403, detail='استخدم إدارة المستخدمين لتغيير حالة الحساب')
    def apply(transaction):
        current, role, ref, snapshot, target = _current_accounts(source, actor, email,
            code, role_resolver, transaction=transaction, configuration=None,
            company_active=company.is_active)
        if str(target.get('uid', '')) != data.expected_target_uid or _version(snapshot) != data.expected_profile_version:
            raise HTTPException(status_code=409, detail='تغير الحساب. أعد تحميله قبل تغيير حالته')
        if role_resolver({**target, 'email': email}) == 'super_admin' and current['email'] == email and not data.is_active:
            raise HTTPException(status_code=403, detail='لا يمكن حظر حسابك كصاحب البرنامج')
        if (target.get('is_active') is not False) == data.is_active:
            return {'company_code': code, 'changed': False}
        transaction.update(ref, {'is_active': data.is_active, 'updated_at': firestore.SERVER_TIMESTAMP})
        return {'company_code': code, 'changed': True}
    return await asyncio.to_thread(run_source_transaction, source, apply)


async def write_permission_editor(session, source, actor, email, data, role_resolver):
    validate_permission_map(data.permissions)
    company_code = await _editor_company(source, actor, email, role_resolver)
    company, configuration, revision = await _locked_policy(session, company_code)
    active = configuration is not None
    if active and (data.expected_policy_revision != revision or not data.expected_profile_version
                   or not data.expected_target_uid):
        raise HTTPException(status_code=409, detail='حمّل نطاق الصلاحيات الحالي قبل الحفظ')
    company_branches = set(await company_branch_catalog(session,company_code,lock=True)) if active or data.startup_branch_code is not None else set()
    requested_hr = None if data.clear_hr_viewable_employees else data.hr_viewable_employees
    unknown_hr = False
    if active and (requested_hr is not None or data.clear_hr_viewable_employees):
        wanted = _hr_scope(requested_hr)
        if wanted:
            known = set((await session.scalars(select(Employee.code).where(
                Employee.company_code == company_code, Employee.is_deleted.is_(False),
                Employee.code.in_(wanted)).with_for_update())).all())
            unknown_hr = not wanted <= known

    def apply(transaction):
        current, role, target_ref, snapshot, target = _current_accounts(source, actor, email,
            company_code, role_resolver, transaction=transaction,
            configuration=configuration, company_active=company.is_active)
        if unknown_hr:
            raise HTTPException(status_code=400, detail='نطاق الموارد البشرية يحتوي على موظف غير متاح في هذه الشركة')
        if data.expected_target_uid is not None and str(target.get('uid', '')) != data.expected_target_uid:
            raise HTTPException(status_code=409, detail='تغير ارتباط الحساب. أعد تحميل المستخدم')
        if data.expected_profile_version is not None and _version(snapshot) != data.expected_profile_version:
            raise HTTPException(status_code=409, detail='تغيرت بيانات المستخدم. أعد تحميلها قبل الحفظ')
        target_role = role_resolver({**target, 'email': email})
        admin_operating = active and target_role == 'admin'
        updates = {'updated_at': firestore.SERVER_TIMESTAMP}
        if not admin_operating: updates['permissions'] = deepcopy(data.permissions)
        if data.allowed_branches is not None:
            updates['allowed_branches'] = list(data.allowed_branches)
        if data.clear_hr_viewable_employees:
            updates['hr_viewable_employees'] = None
        elif data.hr_viewable_employees is not None:
            updates['hr_viewable_employees'] = list(data.hr_viewable_employees)
        if data.startup_branch_code is not None:
            updates['branch_code'] = data.startup_branch_code.strip()
        if active:
            if data.allowed_branches is not None:
                try:
                    active_operating_branches(data.allowed_branches)
                except ValueError:
                    raise HTTPException(status_code=400, detail='اختر نطاق فروع صريحاً وصحيحاً')
            root = role == 'super_admin'
            projected = policy_profile(current, configuration, role=role)
            delegation = projected.get('delegable_permissions', {})
            branch_delegation = projected.get('delegable_branches', [])
            previous = (configuration['admin_profiles'].get(str(target.get('uid','')), {}).get('operating_permissions', {}) if admin_operating else target.get('permissions', {}))
            check = check_assignment(company_ceiling=configuration['company_permissions'],
                delegable_permissions=delegation, previous_permissions=previous,
                proposed_permissions=data.permissions, check_delegation=not root)
            if check.outside_company and target_role != 'super_admin':
                raise HTTPException(status_code=403, detail='الصلاحيات تتجاوز نطاق الشركة')
            if check.outside_delegation:
                raise HTTPException(status_code=403, detail='هذا التغيير خارج الصلاحيات المسموح لك بمنحها أو سحبها')
            try:
                before_branches = active_operating_branches(target.get('allowed_branches'))
            except ValueError:
                if not root or data.allowed_branches is None:
                    raise HTTPException(status_code=409, detail='راجع نطاق فروع المستخدم أولاً')
                before_branches = active_operating_branches(data.allowed_branches)
            after_branches = active_operating_branches(updates.get('allowed_branches', before_branches))
            branch_check = check_branch_assignment(previous_branches=before_branches,
                proposed_branches=after_branches, delegable_branches=branch_delegation,
                company_branches=sorted(company_branches), check_delegation=not root)
            if not branch_check.allowed:
                raise HTTPException(status_code=403, detail='التغيير خارج فروع الشركة أو الفروع المسموح لك بإدارتها')
            changed_rights = grants(previous) ^ grants(data.permissions)
            changed_branches = set(before_branches) != set(after_branches)
            try:
                previous_hr = _hr_scope(target.get('hr_viewable_employees'))
            except HTTPException:
                if not root or ('hr_viewable_employees' not in updates):
                    raise
                previous_hr = object()  # Explicit platform-admin repair.
            hr_changed = previous_hr != _hr_scope(updates.get(
                'hr_viewable_employees', target.get('hr_viewable_employees')))
            if not root:
                if (_scoped_rights(changed_rights) or hr_changed) and not (
                        _inside(before_branches, branch_delegation) and _inside(after_branches, branch_delegation)):
                    raise HTTPException(status_code=403, detail='هذا التغيير يؤثر على بيانات خارج الفروع المسموح لك بإدارتها')
                exposed = _scoped_rights(grants(effective_permissions(configuration['company_permissions'], previous))
                    | grants(data.permissions))
                required = exposed if changed_branches else set()
                if hr_changed:
                    required |= {right for right in exposed if right[0] == 'الموارد البشرية'}
                if not required <= grants(delegation):
                    raise HTTPException(status_code=403, detail='تغيير النطاق يوسّع أو يسحب صلاحيات غير مفوضة لك')
            if data.startup_branch_code is not None or changed_branches:
                startup = str(updates.get('branch_code', target.get('branch_code', ''))).strip()
                if startup == 'all': startup = ''
                if startup and (startup not in company_branches or ('all' not in after_branches and startup not in after_branches)):
                    raise HTTPException(status_code=400, detail='اختر فرع بداية ضمن الفروع المسموحة')
                if data.startup_branch_code is not None: updates['branch_code'] = startup
        if not active and data.startup_branch_code is not None:
            startup = data.startup_branch_code.strip()
            if startup in ('all', 'الكل', 'كل الفروع'): startup = ''
            scope = updates.get('allowed_branches', target.get('allowed_branches'))
            if scope is None or scope == []: scope = ['all']
            if isinstance(scope, str): scope = [scope]
            if startup and (startup not in company_branches or not isinstance(scope, list)
                    or ('all' not in scope and startup not in scope)):
                raise HTTPException(status_code=400, detail='اختر فرع بداية ضمن الفروع المسموحة')
            updates['branch_code'] = startup
        transaction.update(target_ref, updates)
        return {'company_code': company_code, 'company_policy_active': active, '_admin_uid': str(target.get('uid','')) if admin_operating else None}
    result = await asyncio.to_thread(run_source_transaction, source, apply)
    admin_uid = result.pop('_admin_uid', None)
    if admin_uid:
        # Source CAS validates current actor/UID/scope while SQL authority stays
        # locked. SQL owns admin use, source owns branches/HR metadata. These
        # stores do not provide a distributed transaction.
        row = await session.get(CompanyPermissionPolicy, company_code)
        updated = deepcopy(configuration)
        assignment = updated['admin_profiles'].setdefault(admin_uid, {
            'operating_permissions': {}, 'delegable_permissions': {}, 'delegable_branches': []})
        assignment['operating_permissions'] = deepcopy(data.permissions)
        validate_configuration(updated)
        row.active = updated
        row.revision += 1
        row.active_revision = row.revision
        # Retain the saved draft exactly. Its old base now requires explicit
        # reconciliation against current active values before it can activate.
        await session.commit()
    return result
