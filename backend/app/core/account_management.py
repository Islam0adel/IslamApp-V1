# backend/app/core/account_management.py
"""Current, company-clamped management directory and action capabilities.

An edit/status action supplies a minimal target picker, not general view rights.
Lifecycle mutations must independently enforce the corresponding action.
"""
import asyncio
from fastapi import HTTPException
from app.core.account_editor import allowed, CATEGORY
from app.core.permission_directory import verified_actor
from app.core.permission_editor import _locked_policy, _version

# أسماء الإجراءات (معاينة/إضافة/تعديل/حذف) وربطها بأسماء صلاحياتها
ACTIONS = {'view':'معاينة', 'add':'إضافة', 'edit':'تعديل', 'delete':'حذف',
    'status':'تغيير حالة الحساب', 'reset':'إعادة تهيئة حساب',
    'approve':'الموافقة على طلب', 'reject':'رفض طلب'}
TARGET_ACTIONS = {'view', 'edit', 'delete', 'status', 'reset'}


# يحسب الإجراءات المسموحة للمستخدم على صفحة إدارة الحسابات
def capabilities(profile, role, configuration):
    return {key:allowed(profile, role, configuration, action) for key, action in ACTIONS.items()}


# يتأكد إن المستخدم له وصول للصفحة وإن الشركة نشطة وإلا يرفض
def require_access(profile, role, configuration, code, company_active):
    if role != 'super_admin' and (not company_active or str(profile.get('company_code', '')) != code):
        raise HTTPException(status_code=403, detail='غير مسموح بإدارة هذه الشركة')
    actions = capabilities(profile, role, configuration)
    if not any(actions.values()):
        raise HTTPException(status_code=403, detail='لا توجد صلاحية لإدارة المستخدمين')
    return actions


# يبني سجل حساب واحد للعرض مع إخفاء الحقول الحساسة لو مش مسموح
def record(document, value, role, full):
    result = {'email':document.id, 'uid':str(value.get('uid') or ''), 'name':str(value.get('name') or ''),
        'company_code':str(value.get('company_code') or ''), 'company_name':str(value.get('company_name') or ''),
        'role':role, 'job_code':str(value.get('job_code') or '1'), 'job_title':str(value.get('job_title') or ''),
        'status':str(value.get('status') or 'active'), 'is_active':value.get('is_active') is not False,
        'has_account':bool(value.get('uid'))}
    if not full:
        result['directory_summary_only'] = True
    if full:
        created = value.get('created_at')
        result.update(phone_number=value.get('phone_number', ''), username=value.get('username', ''),
            startup_branch_code=value.get('branch_code', ''), branch_code=value.get('branch_code', ''),
            allowed_branches=value.get('allowed_branches'), email_verified=bool(value.get('email_verified', False)),
            requires_email_verification=bool(value.get('requires_email_verification', False)),
            created_at=created.isoformat() if hasattr(created, 'isoformat') else None)
    return result


# يقرأ قائمة المستخدمين لصفحة الإدارة بعد التحقق من المنفذ
async def read_management_directory(session, source, actor, requested_company, resolver):
    _, initial, role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    code = str(requested_company or '').strip() if role == 'super_admin' else str(initial.get('company_code', ''))
    if not code and role != 'super_admin':
        raise HTTPException(status_code=403, detail='الحساب غير مرتبط بشركة')
    if code:
        company, configuration, revision = await _locked_policy(session, code, allow_initial_review=role == 'super_admin')
    else:
        company, configuration, revision = None, None, None

    # دالة داخلية تتحقق من المنفذ وتجمع بيانات القائمة
    def inspect():
        before, current, role = verified_actor(source, actor, resolver)
        actions = require_access(current, role, configuration, code, company.is_active if company is not None else False)
        rows = []
        if any(actions[key] for key in TARGET_ACTIONS):
            query = source.collection('users')
            if code:
                query = query.where('company_code', '==', code)
            for document in query.stream():
                value = document.to_dict()
                if not isinstance(value, dict):
                    continue
                if code and str(value.get('company_code', '')) != code:
                    continue
                target_role = resolver({**value, 'email':document.id})
                if role != 'super_admin' and target_role == 'super_admin':
                    continue
                rows.append(record(document, value, target_role, actions['view']))
        after, latest, latest_role = verified_actor(source, actor, resolver)
        latest_actions = require_access(latest, latest_role, configuration, code, company.is_active if company is not None else False)
        if _version(before) != _version(after) or actions != latest_actions:
            raise HTTPException(status_code=409, detail='تغير نطاق الحساب. أعد تحميل المستخدمين')
        rows.sort(key=lambda value:({'pending':0, 'active':1, 'suspended':2}.get(value['status'], 3), value['name']))
        return {'company_code':code, 'company_policy_active':configuration is not None,
            'company_policy_revision':revision, 'actions':actions, 'users':rows}
    return await asyncio.to_thread(inspect)


# يقرأ طلبات التسجيل حسب حالتها (معلّق/موافق/مرفوض/الكل)
async def read_requests(session, source, actor, status, resolver):
    if status not in ('pending', 'approved', 'rejected', 'all'):
        raise HTTPException(status_code=400, detail='حالة طلب غير صالحة')
    _, initial, role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    code = '' if role == 'super_admin' else str(initial.get('company_code', ''))
    if not code and role != 'super_admin':
        raise HTTPException(status_code=403, detail='الحساب غير مرتبط بشركة')
    if code:
        company, configuration, _ = await _locked_policy(session, code, allow_initial_review=role == 'super_admin')
    else:
        company, configuration = None, None

    # يحدد الإجراءات المسموحة للمنفذ على الطلبات
    def authorized(profile, role):
        actions = require_access(profile, role, configuration, code, company.is_active if company is not None else False)
        if not (actions['approve'] or actions['reject']):
            raise HTTPException(status_code=403, detail='غير مصرح بمراجعة طلبات الانضمام')
        return actions

    # دالة داخلية تتحقق من المنفذ وتقرأ الطلبات
    def inspect():
        before, current, role = verified_actor(source, actor, resolver)
        actions = authorized(current, role)
        query = source.collection('registration_requests')
        if code:
            query = query.where('company_code', '==', code)
        if status != 'all':
            query = query.where('status', '==', status)
        rows = []
        for document in query.stream():
            value = document.to_dict()
            if not isinstance(value, dict):
                continue
            if code and str(value.get('company_code', '')) != code:
                continue
            if status != 'all' and value.get('status') != status:
                continue
            created = value.get('created_at')
            rows.append({'id':document.id, **{key:value.get(key, '') for key in (
                'name', 'phone_number', 'email', 'company_code', 'company_name', 'branch_code', 'note')},
                'status':value.get('status', 'pending'), 'created_at':created.isoformat() if hasattr(created, 'isoformat') else None})
        after, latest, latest_role = verified_actor(source, actor, resolver)
        if authorized(latest, latest_role) != actions or _version(before) != _version(after):
            raise HTTPException(status_code=409, detail='تغير نطاق الحساب. أعد تحميل الطلبات')
        rows.sort(key=lambda value:value['created_at'] or '', reverse=True)
        return rows
    return await asyncio.to_thread(inspect)
