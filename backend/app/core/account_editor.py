# backend/app/core/account_editor.py
"""Current-source metadata editor. Operating edit and status are separate actions.

Invitation binding and destructive operations have independent lifecycle routes.
"""
from app.core.branch_catalog import company_branch_catalog
import asyncio
from copy import deepcopy
from fastapi import HTTPException
from google.cloud import firestore
from sqlalchemy import select
from app.core import permission_editor as authority
from app.core.company_policy_store import policy_profile
from app.core.permission_policy import grants
from app.core.branch_scope import active_operating_branches
from app.core.permission_directory import verified_actor

# تصنيف صلاحيات شاشة إدارة المستخدمين المستخدم في فحص الإجراءات
CATEGORY = 'إدارة المستخدمين'
EDIT = 'تعديل'
STATUS = 'تغيير حالة الحساب'


# يرجّع معرّف المستخدم (uid) من بروفايل الحساب
def target_uid(profile):
    value = profile.get('uid')
    if value is None:
        return ''
    if not isinstance(value, str) or value != value.strip():
        raise HTTPException(status_code=409, detail='راجع ارتباط هوية الحساب أولاً')
    return value


# يتحقق هل الدور والإعدادات تسمح بالإجراء المطلوب على صفحة تعديل الحساب
def allowed(profile, role, configuration, key):
    if role == 'super_admin':
        return True
    if configuration is None:
        return role == 'admin'
    return (CATEGORY, key) in grants(policy_profile(profile, configuration, role=role).get('permissions'))


# يجيب بيانات المنفذ والحساب المستهدف ودوريهما ويتحقق من صلاحية المنفذ داخل المعاملة
def accounts(source, actor, target_id, company_code, configuration, company_active, resolver, transaction=None):
    email = str(actor.get('email', '')).strip().lower()
    uid = str(actor.get('uid', ''))
    if not email or not uid:
        raise HTTPException(status_code=401, detail='يجب إعادة تسجيل الدخول')
    actor_ref = source.collection('users').document(email)
    doc = actor_ref.get(transaction=transaction) if transaction is not None else actor_ref.get()
    current = doc.to_dict() if doc.exists else None
    if not isinstance(current, dict) or str(current.get('uid', '')) != uid or not authority._active(current):
        raise HTTPException(status_code=403, detail='حساب المسؤول غير متاح')
    current = {**current, 'email':email}
    role = resolver(current)
    if role != 'super_admin' and (not company_active or str(current.get('company_code', '')) != company_code):
        raise HTTPException(status_code=403, detail='تغير نطاق الحساب')
    if not any(allowed(current, role, configuration, key) for key in (EDIT, STATUS)):
        raise HTTPException(status_code=403, detail='غير مصرح بإدارة بيانات الحساب')
    ref = source.collection('users').document(target_id)
    snapshot = ref.get(transaction=transaction) if transaction is not None else ref.get()
    target = snapshot.to_dict() if snapshot.exists else None
    if not isinstance(target, dict) or str(target.get('company_code', '')) != company_code:
        raise HTTPException(status_code=404, detail='الحساب غير متاح')
    if target.get('account_lifecycle') is not None:
        raise HTTPException(status_code=409, detail='إجراء حذف أو إعادة تهيئة غير مكتمل. أكمل نفس الإجراء أولاً')
    target_role = resolver({**target, 'email':target_id})
    if role != 'super_admin' and target_role == 'super_admin':
        raise HTTPException(status_code=403, detail='غير مسموح بتعديل مدير')
    return doc, current, role, ref, snapshot, target, target_role


# يجهّز سياق التعديل: الشركة والإعدادات والمراجعة والفروع للحساب المستهدف
async def context(session, source, actor, target_id, resolver):
    if not target_id or '/' in target_id or '\\' in target_id:
        raise HTTPException(status_code=400, detail='معرف الحساب غير صالح')
    _, current, role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    code = str(current.get('company_code', ''))
    if role == 'super_admin':
        # يقرأ شركة الحساب المستهدف من مصدر البيانات
        def target_company():
            doc = source.collection('users').document(target_id).get()
            if not doc.exists:
                raise HTTPException(status_code=404, detail='الحساب غير متاح')
            return str((doc.to_dict() or {}).get('company_code', ''))
        code = await asyncio.to_thread(target_company)
    company, configuration, revision = await authority._locked_policy(session, code)
    if role != 'super_admin' and (not company.is_active or str(current.get('company_code', '')) != code):
        raise HTTPException(status_code=403, detail='الحساب غير متاح')
    if not any(allowed(current, role, configuration, key) for key in (EDIT, STATUS)):
        raise HTTPException(status_code=403, detail='غير مصرح بإدارة بيانات الحساب')
    # Locks also protect the available startup choices throughout a source write.
    branches = await company_branch_catalog(session, code, lock=True)
    return company, configuration, revision, branches


# يستخرج الفروع المسموحة للحساب المستهدف ويطابقها مع الفروع النشطة
def branch_scope(target, active):
    raw = target.get('allowed_branches')
    if active:
        try:
            return active_operating_branches(raw)
        except ValueError:
            raise HTTPException(status_code=409, detail='راجع الفروع المسموحة للحساب أولاً')
    if raw is None or raw == []:
        return ['all']
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list) or any(not isinstance(code, str) for code in raw):
        raise HTTPException(status_code=409, detail='راجع الفروع المسموحة للحساب أولاً')
    return ['all'] if any(code.lower() == 'all' for code in raw) else list(raw)


# يتحقق من فرع بداية التشغيل ويتأكد إنه من الفروع المسموحة للحساب
def startup(value, target, configuration, branches):
    branch = value.strip()
    permitted = branch_scope(target, configuration is not None)
    if branch in ('', 'all', 'الكل', 'كل الفروع'):
        return ''
    if not any(code.lower() == 'all' for code in permitted) and branch not in permitted:
        raise HTTPException(status_code=400, detail='فرع البداية يجب أن يكون ضمن الفروع المسموحة للمستخدم')
    if branch not in branches:
        raise HTTPException(status_code=400, detail='فرع البداية غير موجود في هذه الشركة')
    return branch


# يقرأ بيانات شاشة تعديل الحساب للعرض بعد التحقق من الصلاحيات
async def read_account_editor(session, source, actor, target_id, resolver):
    company, configuration, revision, branches = await context(session, source, actor, target_id, resolver)

    # دالة داخلية تقرأ الحساب المستهدف وتبني الرد
    def read():
        before, current, role, _, snapshot, target, target_role = accounts(source, actor, target_id, company.code, configuration, company.is_active, resolver)
        can_edit = allowed(current, role, configuration, EDIT)
        can_status = allowed(current, role, configuration, STATUS)
        scope = branch_scope(target, configuration is not None) if can_edit else []
        value = {'document_id':target_id, 'uid':target_uid(target), 'company_code':company.code,
            'profile_version':authority._version(snapshot), 'company_policy_revision':revision,
            'company_policy_active':configuration is not None, 'name':str(target.get('name') or ''),
            'role':target_role, 'status':str(target.get('status', 'active')), 'is_active':target.get('is_active') is not False,
            'can_edit':can_edit, 'can_change_status':can_status, 'can_change_role':role == 'super_admin' and (configuration is None or bool(target_uid(target))),
            'branch_choices':[{'code':code, 'name':str(name)} for code, name in branches.items()
                if can_edit and ('all' in scope or code in scope)]}
        if can_edit:value.update(invitation_email=str(target.get('invitation_email') or target.get('email') or '') if not target_uid(target) else '', can_set_invitation_email=not bool(target_uid(target)), phone_number=str(target.get('phone_number') or ''), username=str(target.get('username') or ''),
            startup_branch_code=str(target.get('branch_code') or ''), allowed_branches=scope)
        after, latest, latest_role, _, latest_snapshot, _, _ = accounts(source, actor, target_id, company.code, configuration, company.is_active, resolver)
        if authority._version(snapshot) != authority._version(latest_snapshot):
            raise HTTPException(status_code=409, detail='تغيرت بيانات الحساب. أعد التحميل')
        if authority._version(before) != authority._version(after):
            raise HTTPException(status_code=409, detail='تغير نطاق المسؤول. أعد التحميل')
        if not any(allowed(latest, latest_role, configuration, key) for key in (EDIT, STATUS)):
            raise HTTPException(status_code=403, detail='غير مصرح')
        return value
    return await asyncio.to_thread(read)


# يحفظ تعديلات الحساب (بيانات وأدوار وفروع) بعد التحقق من الصلاحيات والتعارضات
async def write_account_editor(session, source, actor, target_id, data, resolver, role_codes, role_titles,
                               validate_username):
    company, configuration, revision, branches = await context(session, source, actor, target_id, resolver)
    active = configuration is not None
    if active and (data.expected_profile_version is None or data.expected_target_uid is None or data.expected_policy_revision != revision):
        raise HTTPException(status_code=409, detail='حمّل بيانات الحساب الحالية قبل الحفظ')
    if data.expected_policy_revision is not None and data.expected_policy_revision != revision:
        raise HTTPException(status_code=409, detail='تغيرت سياسة الشركة. أعد التحميل')
    # Existing identifier checks are preserved. A cross-entry-point unique
    # reservation contract for registration/invitations is still separate work.
    phone = (data.phone_number or '').strip() if data.phone_number is not None else None
    username = (data.username or '').strip().lower() if data.username is not None else None

    # يجمع المعرّفات (بريد وهاتف مثلًا) اللي لازم تكون غير مكررة
    def identifiers():
        _, current, role, _, snapshot, target, target_role = accounts(source, actor, target_id, company.code, configuration, company.is_active, resolver)
        metadata = any(getattr(data, key) is not None for key in ('name', 'phone_number', 'branch_code', 'username', 'invitation_email'))
        if metadata and not allowed(current, role, configuration, EDIT):
            raise HTTPException(status_code=403, detail='غير مصرح بتعديل بيانات الحساب')
        if (data.status is not None or data.is_active is not None) and not allowed(current, role, configuration, STATUS):
            raise HTTPException(status_code=403, detail='غير مصرح بتغيير حالة الحساب')
        if data.role is not None and data.role != target_role and role != 'super_admin':
            raise HTTPException(status_code=403, detail='غير مسموح بتعيين هذا الدور')
        if username:
            validate_username(username)

        # يفحص هل القيمة مستخدمة بالفعل عند حساب تاني
        def taken(field, value):
            return any(doc.id != target_id for doc in source.collection('users').where(field, '==', value).limit(2).stream())
        duplicate_phone = taken('phone_number', phone) if phone and phone != target.get('phone_number') else False
        duplicate_username = taken('username', username) if username and username != target.get('username') else False
        return authority._version(snapshot), duplicate_phone, duplicate_username
    preflight_version, duplicate_phone, duplicate_username = await asyncio.to_thread(identifiers)

    # ينفّذ التعديل داخل معاملة واحدة بعد إعادة التحقق من المنفذ والهدف
    def apply(transaction):
        _, current, role, ref, snapshot, target, target_role = accounts(source, actor, target_id, company.code, configuration, company.is_active, resolver, transaction)
        if authority._version(snapshot) != preflight_version:
            raise HTTPException(status_code=409, detail='تغيرت بيانات الحساب. أعد التحميل قبل الحفظ')
        if data.expected_target_uid is not None and target_uid(target) != data.expected_target_uid:
            raise HTTPException(status_code=409, detail='تغير ارتباط الحساب. أعد التحميل')
        if data.expected_profile_version is not None and authority._version(snapshot) != data.expected_profile_version:
            raise HTTPException(status_code=409, detail='تغيرت بيانات الحساب. أعد التحميل قبل الحفظ')
        metadata = any(getattr(data, key) is not None for key in ('name', 'phone_number', 'branch_code', 'username', 'invitation_email'))
        if metadata and not allowed(current, role, configuration, EDIT):
            raise HTTPException(status_code=403, detail='غير مصرح بتعديل بيانات الحساب')
        if (data.status is not None or data.is_active is not None) and not allowed(current, role, configuration, STATUS):
            raise HTTPException(status_code=403, detail='غير مصرح بتغيير حالة الحساب')
        is_self = str(current.get('email', '')) == target_id
        updates = {}
        if data.name is not None:
            updates['name'] = data.name.strip()
        if data.invitation_email is not None:
            import re
            invitation_email = data.invitation_email.strip().lower()
            existing_email = str(target.get('invitation_email') or target.get('email') or '').strip().lower()
            if target_uid(target):
                raise HTTPException(status_code=409, detail='لا يمكن تغيير بريد حساب مسجل')
            if not re.fullmatch(r'[\w.\-+]+@[\w.\-]+\.[a-zA-Z]{2,}', invitation_email):
                raise HTTPException(status_code=400, detail='بريد الدعوة غير صحيح')
            if existing_email and existing_email != invitation_email:
                raise HTTPException(status_code=409, detail='بريد الدعوة مسجل بالفعل. ألغ الدعوة وأعد إنشاءها لتغييره')
            for field in ('email', 'invitation_email'):
                for match in source.collection('users').where(field, '==', invitation_email).limit(2).stream(transaction=transaction):
                    if match.id != target_id:
                        raise HTTPException(status_code=409, detail='بريد الدعوة مستخدم في حساب آخر')
            destination = source.collection('users').document(invitation_email).get(transaction=transaction)
            if destination.exists and destination.id != target_id:
                raise HTTPException(status_code=409, detail='بريد الدعوة مستخدم في حساب آخر')
            updates.update(email=invitation_email, invitation_email=invitation_email)

        if phone and phone != target.get('phone_number'):
            if duplicate_phone:
                raise HTTPException(status_code=400, detail='رقم الموبايل مسجل بمستخدم آخر')
            updates['phone_number'] = phone
        if username is not None:
            if username and duplicate_username:
                raise HTTPException(status_code=400, detail='اسم المستخدم مستخدم بالفعل')
            updates['username'] = username
        if data.branch_code is not None:
            if configuration is None and role != 'super_admin' and data.branch_code:
                own = branch_scope(current, False)
                if own and not any(code.lower() == 'all' for code in own) and data.branch_code not in own:
                    raise HTTPException(status_code=403, detail='غير مسموح بالوصول إلى هذا الفرع')
            updates['branch_code'] = startup(data.branch_code, target, configuration, branches)
        if data.role is not None and data.role != target_role:
            if data.role not in role_codes:
                raise HTTPException(status_code=400, detail='دور غير صالح')
            if role != 'super_admin':
                raise HTTPException(status_code=403, detail='غير مسموح بتعيين هذا الدور')
            if target_role == 'super_admin' and is_self and data.role != 'super_admin':
                raise HTTPException(status_code=403, detail='لا يمكن تغيير دور السوبر أدمن')
            if active and not target_uid(target):
                raise HTTPException(status_code=409, detail='أكمل ربط الحساب قبل تغيير دوره')
            updates.update(role=data.role, job_code=role_codes[data.role], job_title=role_titles[data.role])
            if data.role == 'admin':
                updates['permissions'] = {}
        if data.status is not None:
            if data.status not in ('active', 'pending', 'suspended'):
                raise HTTPException(status_code=400, detail='حالة غير صالحة')
            if target_role == 'super_admin' and is_self and data.status != 'active':
                raise HTTPException(status_code=403, detail='لا يمكن إيقاف السوبر أدمن')
            if active and data.status == 'active' and not target_uid(target):
                raise HTTPException(status_code=409, detail='أكمل ربط الحساب قبل تفعيله')
            if active and data.status == 'pending' and target.get('status', 'active') != 'pending':
                raise HTTPException(status_code=400, detail='استخدم إعادة تهيئة الحساب بدلاً من تغيير حالته إلى معلق')
            updates['status'] = data.status
        if data.is_active is not None:
            if target_role == 'super_admin' and is_self and data.is_active is False:
                raise HTTPException(status_code=403, detail='لا يمكن حظر السوبر أدمن')
            updates['is_active'] = data.is_active
        visible = deepcopy(updates)
        if updates:
            transaction.update(ref, {**updates, 'updated_at':firestore.SERVER_TIMESTAMP})
        return {'company_code':company.code, 'updates':visible}
    return await asyncio.to_thread(authority.run_source_transaction, source, apply)
