"""Minimal account choices for a permission editor, not an account directory.

No business-data access, phone numbers, usernames, passwords or policy profiles
are returned. SQL policy stays fixed while the source scan is authorized.
"""
import asyncio
from fastapi import HTTPException
from app.core.permission_editor import _locked_policy, _active, _version
from app.core.company_policy_store import policy_profile
from app.core.permission_policy import grants


def verified_actor(source, actor, role_resolver):
    email=str(actor.get('email','')).strip().lower(); uid=str(actor.get('uid',''))
    if not uid or not email or '/' in email or '\\' in email:
        raise HTTPException(status_code=401,detail='يجب إعادة تسجيل الدخول')
    document=source.collection('users').document(email).get()
    current=document.to_dict() if document.exists else None
    if not isinstance(current,dict) or str(current.get('uid',''))!=uid or not _active(current):
        raise HTTPException(status_code=403,detail='حساب المسؤول غير متاح')
    current={**current,'email':email}
    return document,current,role_resolver(current)


def require_editor(current, role, configuration, company_code, company_active):
    if role=='super_admin': return
    if not company_active or str(current.get('company_code',''))!=company_code:
        raise HTTPException(status_code=403,detail='غير مسموح بإدارة هذه الشركة')
    if configuration is not None:
        projected=policy_profile(current,configuration,role=role)
        if role!='admin' or (not grants(projected.get('delegable_permissions')) and not projected.get('delegable_branches')):
            raise HTTPException(status_code=403,detail='لا يوجد نطاق مفوض لإدارة الصلاحيات')
    elif role!='admin':
        general=current.get('permissions',{}).get('صلاحيات عامة',{}) if isinstance(current.get('permissions'),dict) else {}
        if not isinstance(general,dict) or general.get('صفحة الصلاحيات(الاعدادات)') is not True:
            raise HTTPException(status_code=403,detail='غير مصرح بإدارة الصلاحيات')


async def read_permission_targets(session, source, actor, requested_company, role_resolver):
    _,initial,role=await asyncio.to_thread(verified_actor,source,actor,role_resolver)
    code=str(requested_company or '').strip() if role=='super_admin' else str(initial.get('company_code',''))
    if not code and role!='super_admin':
        raise HTTPException(status_code=400,detail='اختر الشركة أولاً')
    if code:
        company,configuration,revision=await _locked_policy(session,code,allow_initial_review=role=='super_admin')
    else:
        company,configuration,revision=None,None,None
    def inspect():
        before,current,current_role=verified_actor(source,actor,role_resolver)
        require_editor(current,current_role,configuration,code,company.is_active if company is not None else False)
        if company is None and current_role!='super_admin':
            raise HTTPException(status_code=403,detail='غير مصرح')
        users=[]
        query=source.collection('users')
        if code: query=query.where('company_code','==',code)
        for document in query.stream():
            value=document.to_dict() or {}
            if code and str(value.get('company_code',''))!=code: continue
            target_role=role_resolver({**value,'email':document.id})
            if current_role!='super_admin' and target_role=='super_admin':
                continue
            users.append({'email':document.id,'uid':str(value.get('uid','')),
                'name':str(value.get('name','')),'company_code':str(value.get('company_code','')),
                'company_name':str(value.get('company_name','')),'job_code':str(value.get('job_code','1')),
                'job_title':str(value.get('job_title','')),'role':target_role,
                'status':str(value.get('status','active')),'is_active':value.get('is_active') is not False})
        after,latest,latest_role=verified_actor(source,actor,role_resolver)
        require_editor(latest,latest_role,configuration,code,company.is_active if company is not None else False)
        if company is None and latest_role!='super_admin':
            raise HTTPException(status_code=403,detail='غير مصرح')
        if _version(before)!=_version(after):
            raise HTTPException(status_code=409,detail='تغير حساب المسؤول. أعد تحميل قائمة المستخدمين')
        return {'company_code':code,'company_policy_active':configuration is not None,
            'company_policy_revision':revision if configuration is not None else None,
            'users':sorted(users,key=lambda user:(user['name'],user['email']))}
    return await asyncio.to_thread(inspect)
