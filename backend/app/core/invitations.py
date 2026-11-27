# backend/app/core/invitations.py
"""Create an invitation or approve an application as one source transaction.

Current SQL policy/company/branch locks cover the source commit. Identifier
queries are in that transaction, so failures never become a false absence.
"""
from app.core.branch_catalog import company_branch_catalog
import asyncio
from fastapi import HTTPException
from google.cloud import firestore
from app.core import permission_editor as authority
from app.core.account_lifecycle import valid_id, current_actor
from app.core.permission_directory import verified_actor
from app.core.account_editor import allowed
from app.core.account_management import ACTIONS
from app.core.company_policy_store import policy_profile


# ينشئ دعوة مستخدم جديد بالدور والفروع بعد التحقق من صلاحيات المنفذ
async def create_invitation(session, source, actor, data, resolver, role_codes, role_titles,
                            legacy_defaults, validate_username, request_id=None):
    _, initial, role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    request_value = None
    if request_id is not None:
        valid_id(request_id)
        snapshot = await asyncio.to_thread(source.collection('registration_requests').document(request_id).get)
        if not snapshot.exists:
            raise HTTPException(status_code=404, detail='الطلب غير موجود')
        request_value = snapshot.to_dict() or {}
    requested_company = str((request_value or {}).get('company_code') or data.company_code or '').strip()
    code = requested_company if role == 'super_admin' else str(initial.get('company_code', ''))
    if not code:
        raise HTTPException(status_code=400, detail='اختر الشركة')
    action = 'approve' if request_id else 'add'
    company, configuration, _ = await authority._locked_policy(session, code, allow_initial_review=role == 'super_admin')
    if not allowed(initial, role, configuration, ACTIONS[action]):
        raise HTTPException(status_code=403, detail='لا توجد صلاحية لتنفيذ الإجراء')
    branches = set(await company_branch_catalog(session, code, lock=True))

    # دالة داخلية تنفّذ إنشاء الدعوة داخل معاملة
    def mutate(transaction):
        current, role, actor_email, actor_uid = current_actor(source, actor, resolver, configuration, company, action, transaction)
        if not company.is_active:
            raise HTTPException(status_code=403, detail='الشركة موقوفة')
        application_ref, application = None, None
        if request_id:
            application_ref = source.collection('registration_requests').document(request_id)
            snapshot = application_ref.get(transaction=transaction)
            application = snapshot.to_dict() if snapshot.exists else None
            if not isinstance(application, dict):
                raise HTTPException(status_code=404, detail='الطلب غير موجود')
            if application.get('status') != 'pending':
                raise HTTPException(status_code=409, detail='تمت مراجعة الطلب بالفعل')
            application_company = str(application.get('company_code') or '').strip()
            if (application_company and application_company != code) or (role != 'super_admin' and application_company != code):
                raise HTTPException(status_code=403, detail='الطلب غير مرتبط بهذه الشركة')
        if data.role not in ('admin', 'employee'):
            raise HTTPException(status_code=400, detail='دور غير صالح')
        if role != 'super_admin' and data.role != 'employee':
            raise HTTPException(status_code=403, detail='غير مسموح بتعيين مدير')
        inputs = application if application is not None else data.model_dump()
        email = str(inputs.get('email') or '').strip().lower()
        phone = str(inputs.get('phone_number') or '').strip()
        name = str(inputs.get('name') or '').strip()
        import re
        if not re.fullmatch(r'[\w.\-+]+@[\w.\-]+\.[a-zA-Z]{2,}', email):
            raise HTTPException(status_code=400, detail='بريد الدعوة مطلوب ويجب أن يكون صحيحاً')
        if phone and not re.fullmatch(r'[0-9]{8,15}', phone):
            raise HTTPException(status_code=400, detail='رقم الموبايل غير صحيح')
        username = '' if application is not None else str(data.username or '').strip().lower()
        if username:
            username = validate_username(username)
        branch = str(data.branch_code or '').strip()
        if branch in ('all', '', 'الكل', 'كل الفروع'):
            branch = ''
        if branch and branch not in branches:
            raise HTTPException(status_code=400, detail='الفرع غير موجود في الشركة')
        assigned = [branch] if branch else ['all']
        if configuration is not None and role != 'super_admin':
            delegated = policy_profile(current, configuration, role=role).get('delegable_branches', [])
            if 'all' not in delegated and not set(assigned) <= set(delegated):
                raise HTTPException(status_code=403, detail='الفروع المطلوبة خارج نطاق تفويضك')
        users = source.collection('users')
        # Read exact legacy keys and all matching identifiers before any write.
        ids = {email, 'email_' + email.replace('@', '_at_').replace('/', '_')}
        if phone:
            ids.add('phone_' + phone)
        for key in ids:
            if users.document(key).get(transaction=transaction).exists:
                raise HTTPException(status_code=409, detail='يوجد حساب بنفس بيانات الدعوة')
        for field, value in (('email', email), ('phone_number', phone), ('username', username)):
            if value and any(users.where(field, '==', value).limit(1).stream(transaction=transaction)):
                raise HTTPException(status_code=409, detail='بيانات الدعوة مستخدمة في حساب آخر')
        value = {'name': name, 'phone_number': phone, 'email': email, 'invitation_email': email,
            'company_code': code, 'company_name': company.name, 'branch_code': branch,
            'allowed_branches': assigned, 'role': data.role, 'job_code': role_codes[data.role],
            'job_title': role_titles[data.role], 'uid': '', 'status': 'pending', 'is_active': True,
            'permissions': legacy_defaults() if configuration is None and data.role == 'employee' else {},
            'email_verified': False, 'requires_email_verification': True,
            'invitation_version': 1,
            'created_by_admin': actor_email, 'created_by_uid': actor_uid, 'created_at': firestore.SERVER_TIMESTAMP}
        if username:
            value['username'] = username
        if request_id:
            value['from_registration_request'] = request_id
        ref = users.document(email)
        transaction.set(ref, value)
        if application_ref is not None:
            transaction.update(application_ref, {'status': 'approved', 'company_code': code,
                'company_name': company.name, 'reviewed_at': firestore.SERVER_TIMESTAMP,
                'reviewed_by': actor_email, 'reviewed_by_uid': actor_uid, 'user_doc_id': email})
        return {'company_code': code, 'temp_doc_id': email, 'user_doc_id': email, 'role': data.role}
    return await asyncio.to_thread(authority.run_source_transaction, source, mutate)
