# backend/app/core/company_policy_review.py
"""Source-grounded program-admin company policy review and activation."""
from app.core.branch_catalog import company_branch_catalog
import asyncio
import hashlib
import json
from copy import deepcopy
from datetime import datetime
from fastapi import HTTPException
from sqlalchemy import select
from app.core.models import Company, CompanyPermissionPolicy
from app.core.company_policy_store import read_policy, validate_configuration
from app.core.permission_directory import verified_actor
from app.core.permission_editor import _version


# يتأكد إن المنفذ هو الـroot المسموح له بمراجعة سياسة الشركة
def require_root(source, actor, resolver):
    snapshot, current, role = verified_actor(source, actor, resolver)
    if role != 'super_admin':
        raise HTTPException(status_code=403, detail='هذه المراجعة خاصة بصاحب البرنامج')
    return snapshot, current


# يقرأ سياسة الشركة من المصدر للمراجعة
def source_review(source, actor, code, resolver):
    before, _ = require_root(source, actor, resolver)
    accounts = []
    for snapshot in source.collection('users').where('company_code', '==', code).stream():
        value = snapshot.to_dict()
        if not isinstance(value, dict) or str(value.get('company_code', '')) != code:
            continue
        role = resolver({**value, 'email':snapshot.id})
        if role == 'super_admin':
            continue
        accounts.append({'document_id':snapshot.id, 'uid':str(value.get('uid') or ''),
            'email':str(value.get('email') or ''), 'name':str(value.get('name') or ''), 'role':role,
            'status':str(value.get('status') or 'active'), 'is_active':value.get('is_active') is not False,
            'allowed_branches':deepcopy(value.get('allowed_branches')),
            'permissions':deepcopy(value.get('permissions') or {}),
            'lifecycle_pending':value.get('account_lifecycle') is not None, 'profile_version':_version(snapshot)})
    after, _ = require_root(source, actor, resolver)
    if _version(before) != _version(after):
        raise HTTPException(status_code=409, detail='تغير حساب المسؤول. أعد المراجعة')
    accounts.sort(key=lambda row:row['document_id'])
    token = hashlib.sha256(json.dumps(accounts, ensure_ascii=False, sort_keys=True, default=str).encode()).hexdigest()
    return accounts, token


# يجهّز سياق شاشة المراجعة: السياسة المسوّدة والمفعّلة والمصدر
async def review_context(session, source, actor, code, resolver):
    _, current = await asyncio.to_thread(require_root, source, actor, resolver)
    # Account mutations lock their target company. Lock actor and reviewed
    # company in stable order so root authority cannot change mid-commit.
    codes = sorted({code, str(current.get('company_code', ''))}- {''})
    for locked_code in codes:
        await session.scalar(select(Company).where(Company.code == locked_code).with_for_update())
    _, latest = await asyncio.to_thread(require_root, source, actor, resolver)
    if str(latest.get('company_code', '')) != str(current.get('company_code', '')):
        raise HTTPException(status_code=409, detail='تغير نطاق المسؤول. أعد تحميل المراجعة')
    company = await session.scalar(select(Company).where(Company.code == code).with_for_update())
    if company is None:
        raise HTTPException(status_code=404, detail='الشركة غير موجودة')
    await session.scalar(select(CompanyPermissionPolicy).where(CompanyPermissionPolicy.company_code == code).with_for_update())
    branches = [{'code':branch_code, 'name':name} for branch_code, name in
        (await company_branch_catalog(session, code, lock=True)).items()]
    accounts, token = await asyncio.to_thread(source_review, source, actor, code, resolver)
    value = await read_policy(session, code)
    return {**value, 'company_name':company.name, 'company_active':company.is_active,
            'accounts':accounts, 'source_review_token':token, 'branches':branches}


# يفعّل سياسة الشركة بعد مراجعتها مع فحص رقم النسخة وتوكن المصدر
async def activate_review(session, source, actor, code, resolver, expected_revision, expected_source_token):
    review = await review_context(session, source, actor, code, resolver)
    if review['revision'] != expected_revision or review['source_review_token'] != expected_source_token:
        raise HTTPException(status_code=409, detail='تغيرت المسودة أو حسابات الشركة. أعد تحميل المراجعة')
    configuration = review['draft']
    if review['draft_requires_reconciliation']:
        raise HTTPException(status_code=409, detail='تغيرت صلاحيات المديرين المفعلة. قارنها بالمسودة المحفوظة وأكد المراجعة قبل إعادة حفظها وتفعيلها')
    if configuration is None:
        raise HTTPException(status_code=400, detail='احفظ مسودة الصلاحيات قبل التفعيل')
    try:
        validate_configuration(configuration)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    admins = {row['uid']:row for row in review['accounts'] if row['role'] == 'admin' and row['uid']
            and row['is_active'] and not row['lifecycle_pending']}
    assigned_ids = [row['uid'] for row in review['accounts'] if row['role'] == 'admin' and row['uid']]
    if len(set(assigned_ids)) != len(assigned_ids):
        raise HTTPException(status_code=409, detail='أكثر من حساب مدير مرتبط بنفس الهوية. أصلح الربط أولاً')
    if set(configuration['admin_profiles'])-set(admins):
        raise HTTPException(status_code=409, detail='المسودة تشمل هوية مدير غير متاحة. أعد مراجعة المديرين')
    if not configuration['admin_profiles']:
        raise HTTPException(status_code=400, detail='اختر مديراً مرتبطاً بهويته وراجع نطاقه قبل التفعيل')
    branch_codes = {row['code'] for row in review['branches']}
    for profile in configuration['admin_profiles'].values():
        if not set(profile.get('delegable_branches', [])) <= branch_codes|{'all'}:
            raise HTTPException(status_code=400, detail='نطاق التفويض يشمل فرعاً غير موجود')
    # All current accounts must have explicit valid operating branches before
    # switching the company together. No missing scope becomes an all grant.
    from app.core.branch_scope import active_operating_branches
    for row in review['accounts']:
        if not row['is_active'] or row['lifecycle_pending']:
            continue
        try:
            scope = active_operating_branches(row['allowed_branches'])
        except ValueError:
            raise HTTPException(status_code=409, detail='راجع الفروع المسموحة لكل حساب قبل التفعيل')
        if not set(scope) <= branch_codes|{'all'}:
            raise HTTPException(status_code=409, detail='أحد الحسابات مرتبط بفرع غير موجود')
    # Recheck the source immediately before SQL activation. SQL authority stays
    # locked throughout. This is not a distributed source/SQL transaction.
    _, token = await asyncio.to_thread(source_review, source, actor, code, resolver)
    if token != expected_source_token:
        raise HTTPException(status_code=409, detail='تغيرت حسابات الشركة أثناء المراجعة')
    row = await session.get(CompanyPermissionPolicy, code)
    company = await session.get(Company, code)
    row.active = deepcopy(configuration)
    row.active_revision = row.revision+1
    row.draft_base_active_revision = row.active_revision
    row.revision += 1
    row.reviewed_by_uid = str(actor['uid'])
    row.reviewed_at = datetime.utcnow()
    company.requires_permission_review = False
    await session.commit()
    return {'company_code':code, 'active_revision':row.active_revision, 'authorization_changed':True,
            'refresh_accounts':[value['document_id'] for value in review['accounts']]}
