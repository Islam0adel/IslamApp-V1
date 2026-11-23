from app.core.auth_middleware import can_bypass_permissions
# backend/app/core/sync.py

from typing import Dict, Set
import asyncio
from app.core.firebase_setup import db as firebase_db
from app.core.company_policy_store import active_policy_configuration, effective_policy_profile

from fastapi import WebSocket
from app.core.notification_events import (
    prepare_and_persist_event,
    _branch_allowed,
    _can_view_section,
    _SECTION_MAP,
    company_recipient_epoch,
    invalidate_company_recipients,
)

from app.core.hr_audience import HR_EVENTS, HRTarget, message_target, target_allowed, targets_for_codes, own_access, amounts_allowed
from app.core.permissions import has_section_permission

# حقول التكلفة/الراتب التي لا تصل لمن لا يملك حقها عبر البث
_COST_FIELDS = ("wholesale_price", "profit_margin", "profit_percent")
_EMPLOYEE_PRIVATE_FIELDS = (
    "phone", "email", "national_id", "address", "gender", "birth_date",
    "salary", "contract_type", "hire_date", "end_date", "manager_uid",
    "user_uid", "user_email", "emergency_contact", "bank_account",
    "bank_name", "notes",
)
_HR_EVENT_TYPES = {
    "hr_attendance", "hr_vacation", "hr_adjustment", "hr_employee_settings",
}
_HR_VIEW_KEYS = (
    "canViewEmployees", "canManageEmployees", "canOpenAttendancePage",
    "canOpenVacationsPage", "canViewAdjustments", "canViewBranchSalaryReport",
)


def _profile_role(profile: dict) -> str:
    from app.core.auth_middleware import _effective_role
    return _effective_role(profile)


def _ws_can_view_costs(profile: dict) -> bool:
    if can_bypass_permissions(profile):
        return True
    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    for category, key in (
        ("التكويد", "سعر الشراء"),
        ("المبيعات", "عرض سعر الجملة"),
        ("رصيد المخزون", "عرض سعر الجملة"),
    ):
        section = permissions.get(category)
        if isinstance(section, dict) and section.get(key) is True:
            return True
    return False


def _ws_can_view_hr(profile: dict) -> bool:
    if can_bypass_permissions(profile):
        return True
    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    section = permissions.get("الموارد البشرية")
    if not isinstance(section, dict):
        return False
    return any(section.get(key) is True for key in _HR_VIEW_KEYS)


def _ws_can_view_salary(profile: dict) -> bool:
    if can_bypass_permissions(profile):
        return True
    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    section = permissions.get("الموارد البشرية")
    return bool(
        isinstance(section, dict)
        and section.get("canViewSalaryAmounts") is True
    )


def _ws_is_own_only(profile: dict) -> bool:
    if can_bypass_permissions(profile):
        return False
    permissions = profile.get("permissions")
    if not isinstance(permissions, dict):
        return False
    section = permissions.get("الموارد البشرية")
    if not isinstance(section, dict):
        return False
    return (
        section.get("canViewOwnHRData") is True
        and not any(section.get(key) is True for key in _HR_VIEW_KEYS)
    )


def _strip_payload_for_profile(
    profile: dict, event_type: str, payload: dict, *, hr_target=None
) -> dict:
    """تقليل الحمولة لكل مستلم: حقول التكلفة لمن لا يملك حق التكلفة،
    وبيانات الموظف الشخصية/الراتب لمن لا يملك صلاحية HR."""
    if not isinstance(payload, dict):
        return payload
    data = payload
    if not _ws_can_view_costs(profile):
        if any(field in data for field in _COST_FIELDS):
            data = dict(data)
            for field in _COST_FIELDS:
                data.pop(field, None)
        # حمولات المشتريات: سعر البند وإجماليه وإجمالي الفاتورة
        # تُحجب عمّن لا يملك حق عرض التكلفة
        if event_type == "supplier":
            if "total_amount" in data:
                data = dict(data)
                data.pop("total_amount", None)
        if event_type == "supplier" and isinstance(
            data.get("items"), list
        ):
            if any(
                isinstance(it, dict)
                and ("price" in it or "total" in it)
                for it in data["items"]
            ):
                data = dict(data)
                data["items"] = [
                    {
                        k: v for k, v in it.items()
                        if k not in (
                            "price", "total",
                            "discountAmount", "discountRate",
                        )
                    }
                    if isinstance(it, dict) else it
                    for it in data["items"]
                ]
        # حمولات الجرد: إجمالي الجملة وحقول الجملة داخل الأصناف
        if "total_wholesale" in data:
            data = dict(data)
            data.pop("total_wholesale", None)
        items = data.get("items")
        if isinstance(items, list) and any(
            isinstance(it, dict)
            and ("wholesalePrice" in it or "wholesaleValue" in it)
            for it in items
        ):
            data = dict(data)
            data["items"] = [
                {
                    k: v for k, v in it.items()
                    if k not in ("wholesalePrice", "wholesaleValue")
                }
                if isinstance(it, dict) else it
                for it in items
            ]
    personal=own_access(profile,hr_target)
    if event_type == "employee":
        if not _ws_can_view_hr(profile) and not personal:
            if any(field in data for field in _EMPLOYEE_PRIVATE_FIELDS):
                data = dict(data)
                for field in _EMPLOYEE_PRIVATE_FIELDS:
                    data.pop(field, None)
        elif not amounts_allowed(profile,hr_target) and "salary" in data:
            data = dict(data)
            data.pop("salary", None)
    if event_type=='hr_adjustment' and not amounts_allowed(profile,hr_target) and 'amount' in data:
        data=dict(data)
        data.pop('amount',None)
    return data


class DeliveryTargetChanged(Exception):
    def __init__(self, target): self.target = target


class DeliveryCompanyUnavailable(Exception):
    def __init__(self, configuration, revision):
        self.configuration, self.revision = configuration, revision


async def current_delivery_policy(company_code, hr_target=None):
    # One current SQL policy read per company event, not per connected device.
    from sqlalchemy import select
    from app.core.database import AsyncSessionLocal
    from app.core.models import Company
    async with AsyncSessionLocal() as session:
        configuration, revision = await active_policy_configuration(session, str(company_code))
        # Company suspension applies to legacy sockets too.
        active = await session.scalar(select(Company.is_active).where(Company.code == str(company_code)))
        if hr_target is not None:
            current = (await targets_for_codes(session, str(company_code), [hr_target.code])).get(hr_target.code)
            if current != hr_target:
                raise DeliveryTargetChanged(current)
        if active is not True:
            raise DeliveryCompanyUnavailable(configuration, revision)
    return configuration, revision


class ConnectionManager:
    """
    مدير اتصالات WebSocket.

    كل شركة لها مجموعة مستقلة من الأجهزة المتصلة.

    مثال:

    company 01
        ├── device A
        ├── device B
        └── device C

    company 02
        ├── device D
        └── device E
    """

    def __init__(self, *, policy_loader=None):
        self._policy_loader = policy_loader or current_delivery_policy
        self.active_connections: Dict[
            str,
            Set[WebSocket]
        ] = {}
        self.connection_profiles: Dict[WebSocket, dict] = {}

    # ============================================================
    # اتصال جهاز
    # ============================================================

    async def connect(
        self,
        company_code: str,
        websocket: WebSocket,
        accept_connection: bool = True,
        profile: dict | None = None,
    ):
        if accept_connection:
            await websocket.accept()

        if company_code not in self.active_connections:
            self.active_connections[company_code] = set()

        self.active_connections[company_code].add(websocket)
        self.connection_profiles[websocket] = {
            **(profile or {"company_code": company_code}),
            "_permissions_invalidated": False,
            "_permissions_revision": 0,
        }

        print(
            f"🔌 WebSocket connected | "
            f"company={company_code} | "
            f"connections={len(self.active_connections[company_code])}"
        )

    # ============================================================
    # فصل جهاز
    # ============================================================

    def disconnect(
        self,
        company_code: str,
        websocket: WebSocket,
    ):
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return

        connections.discard(websocket)
        self.connection_profiles.pop(websocket, None)

        # لو مفيش أجهزة متصلة للشركة
        # نحذف مجموعة الشركة لتقليل استخدام الذاكرة.
        if not connections:
            self.active_connections.pop(
                company_code,
                None,
            )

        print(
            f"🔌 WebSocket disconnected | "
            f"company={company_code}"
        )

    def replace_user_profile(
        self, company_code: str, email: str, fresh: dict | None,
    ) -> None:
        """Replace local socket authorization, or hold data until it is fresh.

        The control message still reaches a held connection. This only changes
        this process's snapshots; it is not cross-worker invalidation.
        """
        company = str(company_code)
        target = str(email).strip().lower()
        for connection in list(self.active_connections.get(company, set())):
            current = self.connection_profiles.get(connection, {})
            if str(current.get("email", "")).strip().lower() != target:
                continue
            current_revision = current.get("_permissions_revision", 0)
            revision = (current_revision if isinstance(current_revision, int) else 0) + 1
            allowed = (
                fresh is not None
                and str(fresh.get("uid", "")) == str(current.get("uid", ""))
                and str(fresh.get("company_code", "")) == company
                and fresh.get("is_active") is not False
                and str(fresh.get("status", "active")).lower()
                not in ("pending", "suspended")
            )
            self.connection_profiles[connection] = {
                **(fresh if allowed else current),
                "email": target,
                "_permissions_invalidated": not allowed,
                "_permissions_revision": revision,
            }

    async def _fresh_delivery_profiles(self, company_code, hr_target=None, *, emit_controls=True):
        """Verify the batch immediately before data dispatch.

        Legacy raw-profile behavior stays intact until reviewed activation.
        Active companies use fresh account sources, shared across a user's
        devices in this batch. Unknown policy state never means legacy bypass.
        """
        company = str(company_code)
        controls = set()
        company_active = True
        try:
            epoch = company_recipient_epoch(company)
            configuration, revision = await self._policy_loader(company, hr_target)
            if epoch != company_recipient_epoch(company):
                epoch = company_recipient_epoch(company)
                configuration, revision = await self._policy_loader(company, hr_target)
                if epoch != company_recipient_epoch(company):
                    raise RuntimeError('Company scope changed during verification')
        except DeliveryCompanyUnavailable as exc:
            configuration, revision = exc.configuration, exc.revision
            company_active = False
        except DeliveryTargetChanged as exc:
            await self.notify_hr_link_changed(company, [target for target in (hr_target, exc.target) if target is not None])
            return False
        except Exception as exc:
            for connection in list(self.active_connections.get(company, set())):
                profile = self.connection_profiles.get(connection, {})
                email = str(profile.get('email', '')).strip().lower()
                if email and not profile.get('_permissions_invalidated'):
                    controls.add(email)
                self.replace_user_profile(company, email, None)
            if emit_controls:
                for email in controls:
                    await self.send_to_user(company, email, {'type': 'permissions_changed',
                        'data': {'resync': True}, 'suppress_notification': True})
            print(f'⚠️ Live policy unavailable | company={company} | error={exc}')
            return False

        fresh_sources = {}
        for connection in list(self.active_connections.get(company, set())):
            current = self.connection_profiles.get(connection, {})
            # A disappeared active policy is not permission to restore a raw
            # legacy admin bypass. No unreviewed downgrade is supported.
            unexpected_downgrade = configuration is None and current.get('company_policy_active') is True
            email = str(current.get('email', '')).strip().lower()
            uid = str(current.get('uid', ''))
            local_revision = current.get('_permissions_revision', 0)
            try:
                if unexpected_downgrade or not email or not uid or firebase_db is None:
                    raise RuntimeError('Current account policy cannot be verified')
                identity = (uid, email)
                if identity not in fresh_sources:
                    document = firebase_db.collection('users').document(email).get()
                    fresh_sources[identity] = document.to_dict() if document.exists else None
                fresh = fresh_sources[identity]
                if (not isinstance(fresh, dict) or str(fresh.get('uid', '')) != uid
                        or str(fresh.get('company_code', '')) != company
                        or fresh.get('is_active') is False
                        or str(fresh.get('status', 'active')).lower() in ('pending', 'suspended')):
                    raise RuntimeError('Current source account is unavailable')
                fresh = {**fresh, 'email': email}
                role = _profile_role(fresh)
                if not company_active and role != 'super_admin':
                    raise RuntimeError('Company is unavailable')
                projected = effective_policy_profile(fresh,
                    configuration if role != 'super_admin' else None,
                    revision if role != 'super_admin' else None, role=role)
                projected['role'] = role
                if self.connection_profiles.get(connection, {}).get('_permissions_revision', 0) != local_revision:
                    continue
                comparison = {**current, 'role': _profile_role(current), 'company_policy_active': current.get('company_policy_active') is True}
                changed = current.get('_permissions_invalidated') or any(comparison.get(key) != projected.get(key)
                    for key in ('role', 'permissions', 'allowed_branches', 'hr_viewable_employees',
                                'company_policy_active', 'company_policy_revision', 'delegable_permissions', 'delegable_branches'))
                self.connection_profiles[connection] = {**projected, '_permissions_invalidated': False,
                    '_permissions_revision': local_revision + (1 if changed else 0)}
                if changed and email:
                    controls.add(email)
            except Exception as exc:
                if email and not current.get('_permissions_invalidated'):
                    controls.add(email)
                self.replace_user_profile(company, email, None)
                print(f'⚠️ Live account scope unavailable | company={company} | error={exc}')
        if controls and emit_controls:
            for email in controls:
                await self.send_to_user(company, email, {'type': 'permissions_changed',
                    'data': {'resync': True}, 'suppress_notification': True})
            # Control dispatch awaited I/O. Recheck once before business data.
            return await self._fresh_delivery_profiles(company, hr_target, emit_controls=False)
        return True

    # ============================================================
    # إرسال تحديث لكل أجهزة الشركة
    # ============================================================

    async def broadcast(
        self,
        company_code: str,
        message: dict,
    ):
        audience_epoch = company_recipient_epoch(company_code)
        event_type = str(message.get("type", ""))
        payload = message.get("data") if isinstance(message.get("data"), dict) else {}
        hr_target = None
        if event_type in HR_EVENTS:
            try:
                if event_type == "employee":
                    hr_target = await message_target(None, company_code, event_type, payload)
                else:
                    from app.core.database import AsyncSessionLocal
                    async with AsyncSessionLocal() as target_db:
                        hr_target = await message_target(target_db, company_code, event_type, payload)
            except Exception as exc:
                print(f"⚠️ Live HR target lookup failed | company={company_code} | error={exc}")
                hr_target = HRTarget(code=str(payload.get("employee_code", "") or ""))
        # حفظ سجل التدقيق والإشعارات في Neon قبل بث الحدث للأجهزة المتصلة.
        if not message.get("suppress_notification"):
            message = await prepare_and_persist_event(company_code, message, hr_target=hr_target)
        if hr_target is not None and audience_epoch != company_recipient_epoch(company_code):
            try:
                from app.core.database import AsyncSessionLocal
                async with AsyncSessionLocal() as target_db:
                    current_targets = await targets_for_codes(target_db, company_code, [hr_target.code])
                if current_targets.get(hr_target.code) != hr_target:
                    return  # Do not retarget an older payload after a link/delete change.
            except Exception:
                return
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return
        if not await self._fresh_delivery_profiles(company_code, hr_target):
            return

        # --------------------------------------------------------
        # نعمل نسخة من الـset
        #
        # عشان لو حصل disconnect أثناء الإرسال
        # ما يحصلش تعديل على المجموعة أثناء iteration.
        # --------------------------------------------------------

        connections_copy = list(connections)

        dead_connections = []
        # بريدات الأجهزة التي استلمت الحدث فعلاً (لمنع ازدواج النسخة
        # الموجهة لصاحب السجل مع نسخة البث العام)
        delivered_emails = set()
        pending_frames = []

        for connection in connections_copy:
            try:
                profile = self.connection_profiles.get(connection, {})
                if profile.get("_permissions_invalidated"):
                    continue
                event_type = str(message.get("type", ""))
                section = _SECTION_MAP.get(event_type, (None, None))[0]
                payload = message.get("data") if isinstance(message.get("data"), dict) else {}
                branch_code = str(payload.get("branch_code", "") or "")
                branch_visible = _branch_allowed(profile, branch_code)
                if event_type == "stock_transfer":
                    branch_visible = (
                        _branch_allowed(profile, str(payload.get("from_branch_code", "")))
                        or _branch_allowed(profile, str(payload.get("to_branch_code", "")))
                    )
                if section is None:
                    # قفل افتراضي: نوع حدث غير معروف يصل للمديرين فقط
                    if not can_bypass_permissions(profile):
                        continue
                elif not own_access(profile,hr_target) and (not branch_visible or not _can_view_section(profile, section,
                        data_only=True)):
                    continue
                if hr_target is not None and not target_allowed(profile, hr_target):
                    continue
                if (
                    event_type in ("employee", "hr_employee_settings")
                    and _ws_is_own_only(profile)
                ):
                    # نسخة سجله تصله موجهة عبر _deliver_own_copy فقط
                    continue
                stripped = _strip_payload_for_profile(
                    profile, event_type, payload, hr_target=hr_target
                )
                delivery = {**message, "data": stripped}
                if hr_target is not None:
                    delivery["notification_scope"] = hr_target.for_recipient(profile)
                pending_frames.append((connection, delivery, profile))

            except Exception as e:
                print(
                    f"⚠️ فشل إرسال WebSocket | "
                    f"company={company_code} | "
                    f"error={e}"
                )

                dead_connections.append(
                    connection
                )

        async def send_verified(connection, delivery, expected):
            # Dispatch the verified batch together. A slow recipient must not
            # leave later recipients queued behind unrelated network I/O.
            if self.connection_profiles.get(connection) is not expected or expected.get('_permissions_invalidated'):
                return
            try:
                await connection.send_json(delivery)
                email = str(expected.get('email', '')).strip().lower()
                if email: delivered_emails.add(email)
            except Exception:
                dead_connections.append(connection)
        if pending_frames:
            await asyncio.gather(*(send_verified(*frame) for frame in pending_frames))

        # --------------------------------------------------------
        # تنظيف الاتصالات الميتة
        # --------------------------------------------------------

        for connection in dead_connections:
            self.disconnect(
                company_code,
                connection,
            )

        await self._deliver_own_copy(
            company_code, message, skip_emails=delivered_emails, hr_target=hr_target, scope_verified=not pending_frames,
        )

    # ============================================================
    # نسخة موجهة لصاحب السجل نفسه (canViewOwnHRData):
    # أحداث الموظف/الحضور/الإجازات/التسويات تصل لصاحبها كاملة
    # وفي وقتها حتى بدون صلاحية HR واسعة.
    # ============================================================

    async def _deliver_own_copy(
        self,
        company_code: str,
        message: dict,
        skip_emails: set | None = None,
        hr_target: HRTarget | None = None,
        scope_verified: bool = False,
    ) -> None:
        try:
            if hr_target is None:
                return
            candidates = [connection for connection in self.active_connections.get(company_code, set())
                if str(self.connection_profiles.get(connection, {}).get('email', '')).strip().lower() not in (skip_emails or set())
                and has_section_permission(self.connection_profiles.get(connection, {}), 'الموارد البشرية', 'canViewOwnHRData')
                and hr_target.is_self(self.connection_profiles.get(connection, {}))]
            if not candidates:
                return
            if not scope_verified and not await self._fresh_delivery_profiles(company_code, hr_target):
                return
            for connection in list(self.active_connections.get(company_code, set())):
                profile = self.connection_profiles.get(connection, {})
                email = str(profile.get("email", "")).strip().lower()
                if (email in (skip_emails or set())
                        or profile.get("_permissions_invalidated")
                        or not has_section_permission(profile, "الموارد البشرية", "canViewOwnHRData")
                        or not hr_target.is_self(profile)
                        or not target_allowed(profile, hr_target)):
                    continue
                await connection.send_json({
                    **message, "notification_scope": hr_target.for_recipient(profile),
                })
        except Exception as e:
            print(f"⚠️ own-copy delivery failed: {e}")

    async def notify_hr_link_changed(self, company_code: str, targets) -> None:
        """Invalidate old/new linked accounts without disclosing HR content."""
        invalidate_company_recipients(company_code)
        for connection in list(self.active_connections.get(company_code, set())):
            profile = self.connection_profiles.get(connection, {})
            if not any(target.matches_account(profile) for target in targets):
                continue
            try:
                await connection.send_json({
                    "type": "permissions_changed", "data": {"resync": True},
                    "suppress_notification": True,
                })
            except Exception:
                self.disconnect(company_code, connection)

    # ============================================================
    # إرسال حدث لمستخدم معين فقط داخل الشركة
    #
    # يُستخدم لأحداث الحساب (تغيير الصلاحيات/الحظر) حتى لا تصل
    # لباقي أجهزة الشركة. الرسالة ليست بيانات فرعية فلا تُرشَّح
    # بالفرع أو القسم.
    # ============================================================

    async def notify_company_directory_changed(self) -> None:
        for company, connections in list(self.active_connections.items()):
            for connection in list(connections):
                profile = self.connection_profiles.get(connection, {})
                if _profile_role(profile) != 'super_admin':
                    continue
                try:
                    await connection.send_json({'type': 'company_directory_changed',
                        'data': {}, 'suppress_notification': True})
                except Exception:
                    self.disconnect(company, connection)

    async def notify_user_directory_changed(self, company_code: str) -> None:
        """Identity-free hint, including authorized platform admins elsewhere."""
        company = str(company_code)
        for connected_company, connections in list(self.active_connections.items()):
            for connection in list(connections):
                profile = self.connection_profiles.get(connection, {})
                permissions = profile.get('permissions', {})
                general = permissions.get('صلاحيات عامة', {}) if isinstance(permissions, dict) else {}
                role = _profile_role(profile)
                if role != 'super_admin' and (connected_company != company or (
                    role != 'admin' and not (isinstance(general, dict) and general.get('صفحة الصلاحيات(الاعدادات)') is True))):
                    continue
                try:
                    await connection.send_json({'type': 'user_directory_changed',
                        'data': {'company_code': company}, 'suppress_notification': True})
                except Exception:
                    self.disconnect(connected_company, connection)

    async def send_to_user(
        self,
        company_code: str,
        email: str,
        message: dict,
    ) -> None:
        if message.get('type') not in ('permissions_changed', 'notification_settings_changed'):
            return  # This is a control-only channel, never unfiltered business data.
        connections = self.active_connections.get(company_code)
        if not connections:
            return

        target = str(email or "").strip().lower()
        dead_connections = []

        for connection in list(connections):
            try:
                profile = self.connection_profiles.get(connection, {})
                if (
                    str(profile.get("email", "")).strip().lower()
                    != target
                ):
                    continue
                if (profile.get("_permissions_invalidated")
                        and message.get("type") != "permissions_changed"):
                    continue
                await connection.send_json(message)
            except Exception:
                dead_connections.append(connection)

        for connection in dead_connections:
            self.disconnect(company_code, connection)

    # ============================================================
    # عدد الأجهزة المتصلة
    # ============================================================

    def connection_count(
        self,
        company_code: str,
    ) -> int:
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return 0

        return len(connections)

    # ============================================================
    # هل الشركة عندها أجهزة متصلة؟
    # ============================================================

    def has_connections(
        self,
        company_code: str,
    ) -> bool:
        return self.connection_count(
            company_code
        ) > 0


# ============================================================
# Global Connection Manager
# ============================================================

manager = ConnectionManager()
