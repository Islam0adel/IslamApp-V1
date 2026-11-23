"""Account lifecycle actions use current source authority, not cached roles."""
import asyncio
from fastapi import HTTPException
from google.cloud import firestore
from app.core import permission_editor as authority
from app.core.account_editor import allowed
from app.core.account_management import ACTIONS
from app.core.permission_directory import verified_actor


def valid_id(value):
    if not isinstance(value, str) or not value or value != value.strip() or '/' in value or '\\' in value:
        raise HTTPException(status_code=400, detail='معرف غير صالح')
    return value


def current_actor(source, actor, resolver, configuration, company, action, transaction):
    email = str(actor.get('email', '')).strip().lower()
    uid = str(actor.get('uid', ''))
    valid_id(email)
    ref = source.collection('users').document(email)
    document = ref.get(transaction=transaction)
    profile = document.to_dict() if document.exists else None
    if not uid or not isinstance(profile, dict) or profile.get('uid') != uid or not authority._active(profile):
        raise HTTPException(status_code=403, detail='تغير حساب المسؤول. أعد تسجيل الدخول')
    role = resolver({**profile, 'email': email})
    if role != 'super_admin' and (company is None or not company.is_active or str(profile.get('company_code', '')) != company.code):
        raise HTTPException(status_code=403, detail='تغير نطاق الحساب')
    if not allowed(profile, role, configuration, ACTIONS[action]):
        raise HTTPException(status_code=403, detail='لا توجد صلاحية لتنفيذ هذا الإجراء')
    return profile, role, email, uid


async def reject_request(session, source, actor, request_id, resolver):
    """Reject only a still-pending request, with actor/request CAS together.

    A root rejection creates no access, so it also works for unbound requests
    and companies awaiting their initial permission review.
    """
    valid_id(request_id)
    _, initial, initial_role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    if initial_role == 'super_admin':
        company, configuration = None, None
    else:
        company, configuration, _ = await authority._locked_policy(session, str(initial.get('company_code', '')))
        if not allowed(initial, initial_role, configuration, ACTIONS['reject']):
            raise HTTPException(status_code=403, detail='لا توجد صلاحية لرفض الطلبات')

    def mutate(transaction):
        _, role, email, uid = current_actor(source, actor, resolver, configuration, company, 'reject', transaction)
        ref = source.collection('registration_requests').document(request_id)
        snapshot = ref.get(transaction=transaction)
        value = snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value, dict):
            raise HTTPException(status_code=404, detail='الطلب غير موجود')
        if role != 'super_admin' and str(value.get('company_code', '')) != company.code:
            raise HTTPException(status_code=403, detail='غير مسموح برفض طلب شركة أخرى')
        if value.get('status') == 'rejected':
            return {'changed': False}
        if value.get('status') != 'pending':
            raise HTTPException(status_code=409, detail='تمت مراجعة الطلب بالفعل. أعد تحميل القائمة')
        transaction.update(ref, {'status': 'rejected', 'reviewed_at': firestore.SERVER_TIMESTAMP,
                                 'reviewed_by': email, 'reviewed_by_uid': uid})
        return {'changed': True}
    return await asyncio.to_thread(authority.run_source_transaction, source, mutate)


async def destructive_account(session, source, actor, target_id, action, resolver, auth, notify):
    """Source-held delete/reset, with a durable retry marker and UID pin.

    A provider error never means success. Once prepared, metadata and permission
    editors cannot revive the held source account. A repeated same action can
    finish an Auth deletion whose first response was lost.
    """
    from uuid import uuid4
    from sqlalchemy import select
    from app.core.models import Employee
    valid_id(target_id)
    _, initial, initial_role = await asyncio.to_thread(verified_actor, source, actor, resolver)
    code = str(initial.get('company_code', ''))
    if initial_role == 'super_admin':
        snapshot = await asyncio.to_thread(source.collection('users').document(target_id).get)
        if not snapshot.exists:
            raise HTTPException(status_code=404, detail='الحساب غير موجود')
        code = str((snapshot.to_dict() or {}).get('company_code', ''))
    company, configuration, _ = await authority._locked_policy(session, code)
    operation_id = uuid4().hex

    def prepare(transaction):
        _, role, email, uid = current_actor(source, actor, resolver, configuration, company, action, transaction)
        ref = source.collection('users').document(target_id)
        snapshot = ref.get(transaction=transaction)
        target = snapshot.to_dict() if snapshot.exists else None
        if not isinstance(target, dict) or str(target.get('company_code', '')) != company.code:
            raise HTTPException(status_code=404, detail='الحساب غير موجود')
        target_role = resolver({**target, 'email': target_id})
        target_uid = target.get('uid') or ''
        if not isinstance(target_uid, str) or target_uid != target_uid.strip():
            raise HTTPException(status_code=409, detail='راجع هوية الحساب أولاً')
        if target_id == email or (target_uid and target_uid == uid) or target_role == 'super_admin':
            raise HTTPException(status_code=403, detail='لا يمكن تنفيذ الإجراء على حسابك أو السوبر أدمن')
        if role != 'super_admin' and target_role != 'employee':
            raise HTTPException(status_code=403, detail='غير مسموح بتعديل مدير')
        pending = target.get('account_lifecycle')
        if pending is not None:
            if not isinstance(pending, dict) or pending.get('action') != action or pending.get('uid') != target_uid or not pending.get('id'):
                raise HTTPException(status_code=409, detail='هناك إجراء آخر غير مكتمل على الحساب. راجع الإدارة')
            return target, pending
        marker = {'id': operation_id, 'action': action, 'uid': target_uid,
                  'actor_uid': uid, 'actor_email': email, 'restore_active': target.get('is_active') is not False}
        transaction.update(ref, {'account_lifecycle': marker, 'is_active': False,
                                 'updated_at': firestore.SERVER_TIMESTAMP})
        return target, marker

    target, marker = await asyncio.to_thread(authority.run_source_transaction, source, prepare)
    await notify(code, target_id)
    target_uid = marker['uid']
    if target_uid:
        def remove_identity():
            try:
                identity = auth.get_user(target_uid)
            except auth.UserNotFoundError:
                return
            expected_email = str(target.get('email') or target_id).strip().lower()
            if str(identity.uid) != target_uid or str(identity.email or '').strip().lower() != expected_email:
                raise HTTPException(status_code=409, detail='تعارض هوية Firebase. الحساب موقوف ولم يتم حذف الهوية. راجع الإدارة')
            try:
                auth.delete_user(target_uid)
            except auth.UserNotFoundError:
                pass
        try:
            await asyncio.to_thread(remove_identity)
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(status_code=503, detail='لم يتأكد حذف هوية Firebase. الحساب موقوف مؤقتاً؛ أعد نفس الإجراء لإكماله')

    # Clear only the old exact HR owner, never somebody else's replacement.
    # Keep email for deterministic re-linking on reset; a delete unlinks both.
    if target_uid:
        employees = (await session.scalars(select(Employee).where(
            Employee.company_code == code, Employee.user_uid == target_uid).with_for_update())).all()
        for employee in employees:
            employee.user_uid = ''
            employee.user_email = str(target.get('email') or target_id) if action == 'reset' else ''
        await session.flush()

    def finalize(transaction):
        current_actor(source, actor, resolver, configuration, company, action, transaction)
        ref = source.collection('users').document(target_id)
        snapshot = ref.get(transaction=transaction)
        value = snapshot.to_dict() if snapshot.exists else None
        if not isinstance(value, dict) or value.get('account_lifecycle') != marker or (value.get('uid') or '') != target_uid:
            raise HTTPException(status_code=409, detail='تغير الحساب بعد إيقافه. راجع الإدارة قبل المحاولة مجدداً')
        if action == 'delete':
            transaction.delete(ref)
        else:
            transaction.update(ref, {'uid': '', 'email': str(target.get('email') or target_id),
                'email_verified': False, 'requires_email_verification': True, 'status': 'pending',
                'is_active': marker.get('restore_active', False), 'registered_at': None, 'username': '',
                'account_lifecycle': firestore.DELETE_FIELD, 'updated_at': firestore.SERVER_TIMESTAMP})
    # SQL HR unlink is committed before source finalization, so a lost source
    # response cannot strand an old HR UID after a successful reset.
    await session.commit()
    # Reacquire policy/company locks after that required SQL commit.
    company, configuration, _ = await authority._locked_policy(session, code)
    await asyncio.to_thread(authority.run_source_transaction, source, finalize)
    return {'company_code': code}
