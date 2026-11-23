"""Bind an invited email to its actual Firebase UID without minting grants."""
import asyncio
from fastapi import HTTPException
from google.cloud import firestore
from app.core import permission_editor as authority


async def bind_invitation(session, source, document_id, email, uid, username, resolver):
    ref = source.collection('users').document(document_id)
    initial = await asyncio.to_thread(ref.get)
    if not initial.exists: raise HTTPException(status_code=404, detail='الدعوة غير موجودة')
    code = str((initial.to_dict() or {}).get('company_code', ''))
    company, configuration, _ = await authority._locked_policy(session, code, allow_initial_review=True)
    if not company.is_active: raise HTTPException(status_code=403, detail='الشركة موقوفة')
    def mutate(transaction):
        snapshot = ref.get(transaction=transaction)
        value = snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value, dict) or str(value.get('company_code', '')) != code:
            raise HTTPException(status_code=409, detail='تغيرت الدعوة. أعد المحاولة بعد مراجعة الإدارة')
        if value.get('account_lifecycle') is not None:
            raise HTTPException(status_code=409, detail='إجراء إداري غير مكتمل على الحساب')
        invited_email = str(value.get('invitation_email') or value.get('email') or '').strip().lower()
        if not invited_email:
            raise HTTPException(status_code=409, detail='الدعوة القديمة تحتاج إضافة بريدها بواسطة الإدارة قبل استكمال التسجيل')
        if invited_email != email:
            raise HTTPException(status_code=403, detail='يجب التسجيل بنفس بريد الدعوة')
        previous_uid = value.get('uid') or ''
        if previous_uid and previous_uid != uid:
            raise HTTPException(status_code=409, detail='الدعوة مرتبطة بحساب آخر')
        if value.get('is_active') is False or str(value.get('status', 'pending')).lower() not in ('pending', 'active'):
            raise HTTPException(status_code=403, detail='الدعوة موقوفة. راجع الإدارة')
        destination = source.collection('users').document(email)
        existing = snapshot if document_id == email else destination.get(transaction=transaction)
        if existing.exists and document_id != email:
            raise HTTPException(status_code=409, detail='البريد مرتبط بحساب آخر')
        if username:
            for match in source.collection('users').where('username', '==', username).limit(2).stream(transaction=transaction):
                if match.id != document_id:
                    raise HTTPException(status_code=409, detail='اسم المستخدم مستخدم بالفعل')
        if previous_uid == uid and value.get('status') == 'active' and value.get('email_verified') is True:
            return value
        # Preserve exactly the reviewed source grants/branch scope. An admin's
        # UID is not inserted into SQL policy here; no assignment is inferred.
        value.update(uid=uid, email=email, invitation_email=invited_email, status='pending',
            email_verified=False, requires_email_verification=True,
            registered_at=firestore.SERVER_TIMESTAMP, updated_at=firestore.SERVER_TIMESTAMP)
        if username: value['username'] = username
        transaction.set(destination, value)
        if document_id != email: transaction.delete(ref)
        return value
    return await asyncio.to_thread(authority.run_source_transaction, source, mutate)


async def verify_invited_account(session, source, email, uid):
    ref=source.collection('users').document(email)
    snapshot=await asyncio.to_thread(ref.get)
    value=snapshot.to_dict() if snapshot.exists else None
    if not isinstance(value,dict):raise HTTPException(status_code=404,detail='الحساب غير موجود')
    code=str(value.get('company_code',''))
    company,configuration,_=await authority._locked_policy(session,code)
    if not company.is_active:raise HTTPException(status_code=403,detail='الشركة موقوفة')
    def mutate(transaction):
        snapshot=ref.get(transaction=transaction)
        value=snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value,dict) or value.get('uid')!=uid or str(value.get('company_code',''))!=code:
            raise HTTPException(status_code=403,detail='تغيرت هوية الحساب')
        if value.get('account_lifecycle') is not None or value.get('is_active') is False:
            raise HTTPException(status_code=403,detail='الحساب موقوف')
        if str(value.get('status','active')).lower() not in ('pending','active'):
            raise HTTPException(status_code=403,detail='الحساب غير متاح')
        if str(value.get('invitation_email') or value.get('email') or '').strip().lower()!=email:
            raise HTTPException(status_code=403,detail='بريد الدعوة غير مطابق')
        if value.get('status') == 'active' and value.get('email_verified') is True:
            return value
        transaction.update(ref,{'status':'active','email_verified':True,'updated_at':firestore.SERVER_TIMESTAMP})
        return {**value,'status':'active','email_verified':True}
    return await asyncio.to_thread(authority.run_source_transaction,source,mutate)


async def cancel_invited_account(session, source, email, uid, auth, notify):
    """Cancel only this unverified pending identity, with honest Auth failures."""
    from uuid import uuid4
    ref=source.collection('users').document(email)
    snapshot=await asyncio.to_thread(ref.get)
    value=snapshot.to_dict() if snapshot.exists else None
    if not isinstance(value,dict):raise HTTPException(status_code=404,detail='الحساب غير موجود')
    code=str(value.get('company_code',''))
    await authority._locked_policy(session,code)
    operation_id=uuid4().hex
    def prepare(transaction):
        snapshot=ref.get(transaction=transaction)
        value=snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value,dict) or value.get('uid')!=uid or str(value.get('company_code',''))!=code:
            raise HTTPException(status_code=403,detail='الحساب غير مطابق')
        if value.get('email_verified') is True or value.get('status')!='pending':
            raise HTTPException(status_code=403,detail='لا يمكن إلغاء حساب مكتمل من شاشة التسجيل')
        marker=value.get('account_lifecycle')
        if marker is not None:
            if not isinstance(marker,dict) or marker.get('action')!='cancel' or marker.get('uid')!=uid:
                raise HTTPException(status_code=409,detail='هناك إجراء إداري غير مكتمل')
            return marker
        marker={'id':operation_id,'action':'cancel','uid':uid,'restore_active':value.get('is_active') is not False}
        transaction.update(ref,{'account_lifecycle':marker,'is_active':False,'updated_at':firestore.SERVER_TIMESTAMP})
        return marker
    marker=await asyncio.to_thread(authority.run_source_transaction,source,prepare)
    await notify(code,email)
    def remove():
        try:identity=auth.get_user(uid)
        except auth.UserNotFoundError:return
        if identity.uid!=uid or str(identity.email or '').strip().lower()!=email:
            raise HTTPException(status_code=409,detail='تعارض هوية الحساب. راجع الإدارة')
        try:auth.delete_user(uid)
        except auth.UserNotFoundError:pass
    try:await asyncio.to_thread(remove)
    except HTTPException:raise
    except Exception:raise HTTPException(status_code=503,detail='لم يتأكد إلغاء هوية التسجيل. أعد نفس الإجراء لإكماله')
    from sqlalchemy import select
    from app.core.models import Employee
    for employee in (await session.scalars(select(Employee).where(
            Employee.company_code==code,Employee.user_uid==uid).with_for_update())).all():
        employee.user_uid=''
        employee.user_email=email
    await session.commit()
    await authority._locked_policy(session,code)
    def finalize(transaction):
        snapshot=ref.get(transaction=transaction)
        value=snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value,dict) or value.get('uid')!=uid or value.get('account_lifecycle')!=marker:
            raise HTTPException(status_code=409,detail='تغير الحساب أثناء الإلغاء. راجع الإدارة')
        transaction.update(ref,{'uid':'','status':'pending','email_verified':False,
            'is_active':marker['restore_active'],'account_lifecycle':firestore.DELETE_FIELD,
            'registered_at':None,'updated_at':firestore.SERVER_TIMESTAMP})
    await asyncio.to_thread(authority.run_source_transaction,source,finalize)
    return code
