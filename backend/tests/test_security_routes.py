from policy_fixtures import legacy_delivery_policy, payload_only_manager
"""بوابات المسارات: رفض بدون صلاحية، قفل افتراضي للفئات غير المعروفة،
تقليل البيانات حسب الصلاحية، وفلترة الفروع مع الحفاظ على منح كل الفروع."""
import asyncio
import datetime
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.core.auth_middleware import allowed_branches_for_profile
from app.routes import coding, employees, hr

EMP = {"role": "employee", "job_code": "1", "email": "e@x.com", "uid": "u1"}


def _emp(perms, branches=None, **extra):
    p = {**EMP, "permissions": perms, **extra}
    if branches is not None:
        p["allowed_branches"] = branches
    return p


# ---------------------------------------------------------------- coding

def test_coding_known_categories_map():
    assert coding._add_permission_key("branches") == "اضافة فرع"
    assert coding._add_permission_key("customers") == "اضافة عملاء"


def test_coding_category_allowlist_and_generic_right():
    # فئات صالحة بلا مفتاح خاص = الحق العام؛ فئة غير صالحة = رفض مغلق
    assert coding._add_permission_key("items") == "اضافة صنف"
    assert coding._add_permission_key("types") == "اضافة صنف"
    with pytest.raises(HTTPException) as exc:
        coding._add_permission_key("secret_new_category")
    assert exc.value.status_code == 403


def test_coding_cost_fields_stripped_without_permission():
    doc = SimpleNamespace(
        id=1, company_code="01", category="branches", branch_code="B1",
        code="1", name="فرع", type=None, barcode=None,
        wholesale_price=100, selling_price=150,
        profit_margin=50, profit_percent=0.5,
        updated_at=None, is_deleted=False,
    )
    data = coding.serialize_coding(doc, include_costs=False)
    assert data["wholesale_price"] is None
    assert data["profit_margin"] is None
    assert data["profit_percent"] is None
    assert data["selling_price"] == 150
    full = coding.serialize_coding(doc, include_costs=True)
    assert full["wholesale_price"] == 100


def test_coding_may_view_costs():
    assert coding._may_view_costs(_emp({"التكويد": {"سعر الشراء": True}}))
    assert coding._may_view_costs(_emp({"المبيعات": {"عرض سعر الجملة": True}}))
    assert not coding._may_view_costs(_emp({"المبيعات": {"إضافة": True}}))
    assert coding._may_view_costs({"role": "admin"})


def test_coding_save_requires_permission(make_request):
    data = SimpleNamespace(category="branches", branch_code="B1")
    req = make_request(_emp({"التكويد": {"اضافة فرع": False}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(coding.save_code(data=data, request=req, db=None))
    assert exc.value.status_code == 403


def test_coding_save_allowed_passes_gate(make_request):
    data = SimpleNamespace(
        category="branches", branch_code="B1", company_code="01",
        code="1", name="x",
    )
    req = make_request(_emp(
        {"التكويد": {"اضافة فرع": True}}, branches=["B1"]
    ))
    # يتجاوز البوابة ثم يفشل عند قاعدة البيانات الوهمية - المهم عدم رفض 403
    with pytest.raises(Exception) as exc:
        asyncio.run(coding.save_code(data=data, request=req, db=None))
    assert not isinstance(exc.value, HTTPException) or exc.value.status_code != 403


def test_coding_branch_check_blocks_other_branch():
    profile = _emp({}, branches=["B1"])
    with pytest.raises(HTTPException) as exc:
        coding._check_branch(profile, "B2")
    assert exc.value.status_code == 403
    coding._check_branch(profile, "B1")  # لا يرمي


# ------------------------------------------------------------ الفروع

def test_all_branches_employee_has_no_filter():
    # منح "كل الفروع" تمثيله الدقيق: لا قائمة مسموحة ⇒ لا فلتر إطلاقاً
    assert allowed_branches_for_profile(_emp({}, branches=["all"])) is None
    assert allowed_branches_for_profile(_emp({}, branches=["B1"])) == ["B1"]


def test_all_branches_employee_passes_branch_check():
    profile = _emp({}, branches=["all"])
    coding._check_branch(profile, "ANY_BRANCH")  # لا يرمي
    hr._check_hr_branch(profile, "ANY_BRANCH")   # لا يرمي


def test_hr_doc_visible_branch_logic():
    profile = _emp({}, branches=["B1"])
    allowed = allowed_branches_for_profile(profile)
    visible_codes = {"E1", "E2"}
    doc_b1 = SimpleNamespace(branch_code="B1", employee_code="E9")
    doc_b2 = SimpleNamespace(branch_code="B2", employee_code="E1")
    doc_null_known = SimpleNamespace(branch_code=None, employee_code="E1")
    doc_null_unknown = SimpleNamespace(branch_code=None, employee_code="E9")
    assert hr._doc_visible(doc_b1, allowed, visible_codes)
    assert not hr._doc_visible(doc_b2, allowed, visible_codes)
    assert hr._doc_visible(doc_null_known, allowed, visible_codes)
    assert not hr._doc_visible(doc_null_unknown, allowed, visible_codes)
    # موظف كل الفروع يرى كل شيء
    assert hr._doc_visible(doc_b2, None, None)


# ------------------------------------------------------------ الموظفون

def _employee_doc():
    return SimpleNamespace(
        id=1, company_code="01", code="E1", name="أحمد",
        phone="0100", email="a@x.com", national_id="123", address="ق",
        gender=None, birth_date=None, job_title="محاسب",
        department="ح", branch_code="B1", hire_date=None, end_date=None,
        salary=5000, contract_type=None, status="active",
        manager_uid=None, user_uid="u9", user_email="a@x.com",
        emergency_contact=None, bank_account="IBAN", bank_name="ب",
        notes="سري", meta={}, updated_at=None, is_deleted=False,
    )


def test_employee_reference_contract_strips_pii():
    data = employees._employee_payload(_employee_doc(), viewer_can_hr=False)
    assert data["code"] == "E1" and data["name"] == "أحمد"
    assert data["branch_code"] == "B1"
    for field in ("phone", "national_id", "salary", "bank_account", "notes", "address"):
        assert field not in data


def test_employee_hr_viewer_gets_full_record():
    data = employees._employee_payload(_employee_doc(), viewer_can_hr=True)
    assert data["salary"] == 5000
    assert data["national_id"] == "123"


def test_employee_salary_hidden_without_amounts_permission():
    data = employees._employee_payload(
        _employee_doc(), viewer_can_hr=True, viewer_can_salary=False
    )
    assert data["salary"] is None
    assert data["phone"] == "0100"


def test_own_only_viewer_detection():
    own_only = _emp({"الموارد البشرية": {"canViewOwnHRData": True}})
    broad = _emp({"الموارد البشرية": {
        "canViewOwnHRData": True, "canViewEmployees": True}})
    assert employees._is_own_only_viewer(own_only)
    assert not employees._is_own_only_viewer(broad)
    assert not employees._is_own_only_viewer(_emp({}))


def test_employees_view_checks_include_consuming_sections():
    checks = employees._EMPLOYEES_VIEW_CHECKS
    assert ("حسابات العملاء", "إضافة تحصيل") in checks
    assert ("الموارد البشرية", "canViewEmployees") in checks
    assert ("الموارد البشرية", "canViewOwnHRData") in checks


def test_employees_list_denied_without_any_view(make_request):
    req = make_request(_emp({}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(employees.list_employees(company_code="01", request=req, db=None))
    assert exc.value.status_code == 403


# ---------------------------------------------------------------- HR

def test_hr_require_denies_without_keys(make_request):
    req = make_request(_emp({}))
    with pytest.raises(HTTPException) as exc:
        hr._require_hr(req, "canOpenAttendancePage")
    assert exc.value.status_code == 403


def test_hr_require_allows_with_key(make_request):
    profile = _emp({"الموارد البشرية": {"canOpenAttendancePage": True}})
    req = make_request(profile)
    assert hr._require_hr(req, "canOpenAttendancePage") is profile


def test_hr_save_attendance_gate(make_request):
    data = SimpleNamespace(branch_code="B1")
    req = make_request(_emp({}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr.save_attendance(request=req, data=data, db=None))
    assert exc.value.status_code == 403


def test_hr_save_attendance_all_branches_employee(make_request):
    # موظف بكل الفروع + صلاحية إضافة: يتجاوز البوابة وفحص الفرع لأي فرع
    data = SimpleNamespace(branch_code="B7", company_code="01",
                           employee_code="E1", date=None)
    req = make_request(_emp(
        {"الموارد البشرية": {"canAddAttendance": True}}, branches=["all"],
        company_code="01"
    ))
    with pytest.raises(Exception) as exc:
        asyncio.run(hr.save_attendance(request=req, data=data, db=None))
    assert not isinstance(exc.value, HTTPException) or exc.value.status_code != 403


def test_adjustment_add_only_mapping(make_request):
    data = SimpleNamespace(type="mystery", branch_code=None)
    req = make_request(_emp({"الموارد البشرية": {"canAddBonus": True}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr.save_adjustment(request=req, data=data, db=None))
    assert exc.value.status_code == 403


def test_adjustment_bonus_requires_bonus_key(make_request):
    data = SimpleNamespace(type="bonus", branch_code="B1")
    req = make_request(_emp({"الموارد البشرية": {"canAddLoan": True}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr.save_adjustment(request=req, data=data, db=None))
    assert exc.value.status_code == 403


def test_adjustment_delete_requires_delete_key(make_request):
    req = make_request(_emp({"الموارد البشرية": {"canViewAdjustments": True}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr.delete_adjustment(request=req, company_code="01", adjustment_id=5, db=None))
    assert exc.value.status_code == 403


def test_branch_salary_report_requires_key(make_request):
    req = make_request(_emp({"الموارد البشرية": {"canViewAdjustments": True}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr.get_branch_salaries_totals(request=req, company_code="01", month="2026-11", db=None))
    assert exc.value.status_code == 403


# ------------------------------------------------------------ settings

def test_settings_unknown_category_uses_generic_right(make_request):
    from app.routes import settings
    # مخزن-only employee لا يملك "اضافة صنف" → 403
    item = SimpleNamespace(category="vault_secrets")
    req = make_request(_emp({"التكويد": {"اضافة مخزن": True}}))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(settings.add_coding_item(item=item, request=req, db=None))
    assert exc.value.status_code == 403


def test_settings_get_codes_requires_tenant_and_view(make_request):
    from app.routes import settings
    # شركة أخرى → 403 حتى مع صلاحية
    req = make_request(_emp(
        {"التكويد": {"معاينة": True}}, company_code="01"
    ))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(settings.get_coding_items(
            company_code="02", category="items", request=req, db=None
        ))
    assert exc.value.status_code == 403
    # نفس الشركة بدون أي حق عرض → 403
    req2 = make_request(_emp({}, company_code="01"))
    with pytest.raises(HTTPException) as exc2:
        asyncio.run(settings.get_coding_items(
            company_code="01", category="items", request=req2, db=None
        ))
    assert exc2.value.status_code == 403


# ---------------------------------------------------------------- auth

def test_register_legacy_gated(make_request):
    from app.routes import auth
    with pytest.raises(HTTPException) as exc:
        asyncio.run(auth.register(SimpleNamespace(), session=None))
    assert exc.value.status_code == 403


# ------------------------------------------------------------ WebSocket

def test_send_to_user_targets_only_owner():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws_a, ws_b = FakeWS(), FakeWS()
        m.active_connections["01"] = {ws_a, ws_b}
        m.connection_profiles[ws_a] = {"email": "a@x.com"}
        m.connection_profiles[ws_b] = {"email": "b@x.com"}
        await m.send_to_user("01", "A@X.com", {"type": "permissions_changed"})
        assert len(ws_a.sent) == 1
        assert ws_b.sent == []
    asyncio.run(run())


def test_ws_profile_signature_tracks_changes():
    from app.routes.sync import _profile_signature
    base = {"role": "employee", "permissions": {"المبيعات": {"إضافة": True}},
            "allowed_branches": ["all"], "is_active": True, "status": "active"}
    changed = {**base, "permissions": {"المبيعات": {"إضافة": False}}}
    blocked = {**base, "is_active": False}
    assert _profile_signature(base) == _profile_signature(dict(base))
    assert _profile_signature(base) != _profile_signature(changed)
    assert _profile_signature(base) != _profile_signature(blocked)


def test_profile_cache_invalidation():
    from app.core import auth_middleware as mw
    mw._PROFILE_CACHE["x@x.com"] = (0.0, {"uid": "u"})
    mw.invalidate_profile_cache("X@X.com")
    assert "x@x.com" not in mw._PROFILE_CACHE


# ------------------------------------------------------------ جولة التحقق المستقل

class FakeScalars:
    def __init__(self, rows):
        self._rows = rows
    def all(self):
        return list(self._rows)


class FakeResult:
    def __init__(self, rows):
        self._rows = list(rows)
    def scalars(self):
        return FakeScalars(self._rows)
    def scalar_one_or_none(self):
        return self._rows[0] if self._rows else None
    def one_or_none(self):
        return self._rows[0] if self._rows else None


class FakeDB:
    """قاعدة وهمية: ترجع صفوفاً معدّة سلفاً بالترتيب لكل execute."""
    def __init__(self, results):
        self._results = list(results)
    async def execute(self, stmt):
        return self._results.pop(0) if self._results else FakeResult([])
    async def commit(self):
        pass
    async def refresh(self, x):
        pass


def test_reference_contract_hides_uid_and_email():
    data = employees._employee_payload(_employee_doc(), viewer_can_hr=False)
    assert "user_uid" not in data
    assert "user_email" not in data


def test_employees_get_cross_company_denied(make_request):
    req = make_request(_emp(
        {"الموارد البشرية": {"canViewEmployees": True}}, company_code="01"
    ))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(employees.get_employee(
            company_code="02", code="E1", request=req, db=None
        ))
    assert exc.value.status_code == 403


def test_hr_own_data_cannot_read_other_employee(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canViewOwnHRData": True}},
        company_code="01", uid="u1", email="e@x.com",
    )
    req = make_request(profile)
    # الموظف المرتبط بالحساب كوده E9، والهدف E1 → 403
    db = FakeDB([FakeResult(["E9"])])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr_mod._authorize_employee_target(
            req, db, "01", "E1"
        ))
    assert exc.value.status_code == 403


def test_hr_own_data_reads_own_record(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canViewOwnHRData": True}},
        company_code="01", uid="u1", email="e@x.com",
    )
    req = make_request(profile)
    db = FakeDB([FakeResult([SimpleNamespace(code='E1',user_uid='u1',user_email='e@x.com',branch_code='B1',is_deleted=False)])])
    out = asyncio.run(hr_mod._authorize_employee_target(req, db, "01", "E1"))
    assert out is profile


def test_hr_broad_viewer_blocked_by_viewable_list(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canOpenAttendancePage": True}},
        company_code="01", branches=["all"],
        hr_viewable_employees=["E5"],
    )
    req = make_request(profile)
    db = FakeDB([])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr_mod._authorize_employee_target(req, db, "01", "E1"))
    assert exc.value.status_code == 403


def test_hr_broad_viewer_other_branch_target_denied(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canOpenAttendancePage": True}},
        company_code="01", branches=["B1"],
    )
    req = make_request(profile)
    # فرع الموظف المستهدف B2
    db = FakeDB([FakeResult([SimpleNamespace(code='E1',user_uid='other',user_email='other@x.com',branch_code='B2',is_deleted=False)])])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr_mod._authorize_employee_target(req, db, "01", "E1"))
    assert exc.value.status_code == 403


def test_hr_salary_needs_amounts_key_for_others(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canViewAdjustments": True}},
        company_code="01", branches=["all"],
    )
    req = make_request(profile)
    db = FakeDB([FakeResult([None])])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(hr_mod._authorize_employee_target(
            req, db, "01", "E1", salary=True
        ))
    assert exc.value.status_code == 403


def test_ws_unknown_event_admins_only():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws_admin, ws_emp = FakeWS(), FakeWS()
        m.active_connections["01"] = {ws_admin, ws_emp}
        m.connection_profiles[ws_admin] = {"role": "admin"}
        m.connection_profiles[ws_emp] = {
            "role": "employee",
            "permissions": {"المبيعات": {"معاينة": True}},
        }
        await m.broadcast(
            "01",
            {"type": "mystery_event", "data": {"branch_code": "B1"},
             "suppress_notification": True},
        )
        assert len(ws_admin.sent) == 1
        assert ws_emp.sent == []
    asyncio.run(run())


def test_ws_cost_fields_stripped_per_recipient():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws_cost, ws_plain = FakeWS(), FakeWS()
        m.active_connections["01"] = {ws_cost, ws_plain}
        m.connection_profiles[ws_cost] = {
            "role": "employee",
            "permissions": {
                "التكويد": {"معاينة": True, "سعر الشراء": True},
            },
        }
        m.connection_profiles[ws_plain] = {
            "role": "employee",
            "permissions": {"التكويد": {"معاينة": True}},
        }
        await m.broadcast(
            "01",
            {"type": "coding",
             "data": {"branch_code": "B1", "code": "1",
                      "wholesale_price": 100, "profit_margin": 20,
                      "selling_price": 150},
             "suppress_notification": True},
        )
        assert ws_cost.sent[0]["data"]["wholesale_price"] == 100
        assert "wholesale_price" not in ws_plain.sent[0]["data"]
        assert "profit_margin" not in ws_plain.sent[0]["data"]
        assert ws_plain.sent[0]["data"]["selling_price"] == 150
    asyncio.run(run())


def test_ws_employee_pii_stripped_for_non_hr():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws_hr, ws_plain = FakeWS(), FakeWS()
        m.active_connections["01"] = {ws_hr, ws_plain}
        m.connection_profiles[ws_hr] = {
            "role": "employee",
            "permissions": {"الموارد البشرية": {"canViewEmployees": True}},
        }
        m.connection_profiles[ws_plain] = {
            "role": "employee",
            "permissions": {"الموارد البشرية": {"canViewOwnHRData": True}},
        }
        payload = {"code": "E1", "name": "أحمد", "branch_code": "B1",
                   "salary": 5000, "national_id": "123", "phone": "010"}
        await m.broadcast(
            "01",
            {"type": "employee", "data": payload,
             "suppress_notification": True},
        )
        # HR يرى الراتب، غير HR لا يصله الحدث أصلاً (قسم hr مفلتر)
        # أو تصله نسخة مخفاة حسب _can_view_section - هنا نتحقق من التجريد
        if ws_plain.sent:
            assert "salary" not in ws_plain.sent[0]["data"]
            assert "national_id" not in ws_plain.sent[0]["data"]
        assert ws_hr.sent == [] or ws_hr.sent[0]["data"].get("salary") in (5000, None)
    asyncio.run(run())


def test_visible_employee_codes_include_null_branch():
    from app.routes import hr as hr_mod
    # سياسة العميل: الموظف بفرع فارغ يظهر لأي عارض له حق القسم
    profile = _emp({}, branches=["B1"], company_code="01")
    captured = {}
    class CapDB:
        async def execute(self, stmt):
            captured["stmt"] = str(stmt)
            return FakeResult(["E1", "E2"])
    codes = asyncio.run(
        hr_mod._visible_employee_codes(CapDB(), "01", profile)
    )
    assert codes == {"E1", "E2"}
    # الاستعلام يتضمن IS NULL أو مساواة الفرع الفارغ
    assert "IS NULL" in captured["stmt"] or "''" in captured["stmt"]


def test_all_branches_viewer_no_employee_filter():
    from app.routes import hr as hr_mod
    profile = _emp({}, branches=["all"], company_code="01")
    out = asyncio.run(hr_mod._visible_employee_codes(None, "01", profile))
    assert out is None


def test_coding_save_preserves_stored_cost_without_right(make_request, monkeypatch):
    # مسار حفظ كامل: مستخدم بلا حق تكلفة يعدّل سجلاً موجوداً،
    # فلا تتغير حقول التكلفة المخزنة رغم إرسال الواجهة أصفاراً.
    from app.core.sync import manager

    async def _noop_broadcast(*a, **k):
        return None
    monkeypatch.setattr(manager, "broadcast", _noop_broadcast)

    existing = SimpleNamespace(
        id=1, company_code="01", category="items", code="5",
        name="قديم", branch_code="B1", type="وارد", barcode="",
        wholesale_price=100.0, selling_price=150.0,
        profit_margin=50.0, profit_percent=0.5,
        updated_at=None, is_deleted=False,
    )
    db = FakeDB([FakeResult([existing])])
    data = SimpleNamespace(
        company_code="01", category="items", code="5", name="جديد",
        branch_code="B1", type="وارد", barcode="",
        wholesale_price=0.0, selling_price=160.0,
        profit_margin=0.0, profit_percent=0.0,
    )
    req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True}},
        branches=["all"], company_code="01",
    ))
    asyncio.run(coding.save_code(data=data, request=req, db=db))
    assert existing.wholesale_price == 100.0
    assert existing.profit_margin == 50.0
    assert existing.profit_percent == 0.5
    assert existing.selling_price == 160.0
    assert existing.name == "جديد"


def test_coding_save_with_cost_right_updates_cost(make_request, monkeypatch):
    from app.core.sync import manager

    async def _noop_broadcast(*a, **k):
        return None
    monkeypatch.setattr(manager, "broadcast", _noop_broadcast)

    existing = SimpleNamespace(
        id=1, company_code="01", category="items", code="5",
        name="قديم", branch_code="B1", type="وارد", barcode="",
        wholesale_price=100.0, selling_price=150.0,
        cost_pending=False,
        profit_margin=50.0, profit_percent=0.5,
        updated_at=None, is_deleted=False,
    )
    db = FakeDB([FakeResult([existing])])
    data = SimpleNamespace(
        company_code="01", category="items", code="5", name="جديد",
        branch_code="B1", type="وارد", barcode="",
        wholesale_price=120.0, selling_price=170.0,
        profit_margin=50.0, profit_percent=0.42,
    )
    req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True, "سعر الشراء": True}},
        branches=["all"], company_code="01",
    ))
    asyncio.run(coding.save_code(data=data, request=req, db=db))
    assert existing.wholesale_price == 120.0


def test_coding_save_invalid_category_rejected(make_request):
    data = SimpleNamespace(category="vault_secrets", branch_code="B1")
    req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True}}, company_code="01"
    ))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(coding.save_code(data=data, request=req, db=None))
    assert exc.value.status_code == 403


def test_coding_save_items_uses_generic_right(make_request, monkeypatch):
    from app.core.sync import manager

    async def _noop_broadcast(*a, **k):
        return None
    monkeypatch.setattr(manager, "broadcast", _noop_broadcast)

    # صاحب "اضافة مخزن" فقط لا يضيف items (العام "اضافة صنف" مطلوب)
    data = SimpleNamespace(category="items", branch_code="B1",
                           company_code="01", code="1", name="x")
    req = make_request(_emp(
        {"التكويد": {"اضافة مخزن": True}}, company_code="01"
    ))
    with pytest.raises(HTTPException) as exc:
        asyncio.run(coding.save_code(data=data, request=req, db=None))
    assert exc.value.status_code == 403


def test_own_row_keeps_identity_fields():
    doc = _employee_doc()
    viewer = _emp({}, uid="u9", email="viewer@x.com")
    data = employees._employee_payload(
        doc, viewer_can_hr=False, viewer_profile=viewer
    )
    # user_uid يطابق العارض: تبقى الهوية في سجله فقط
    assert data.get("user_uid") == "u9"
    other = employees._employee_payload(
        doc, viewer_can_hr=False,
        viewer_profile=_emp({}, uid="someone_else", email="o@x.com"),
    )
    assert "user_uid" not in other
    assert "user_email" not in other


def test_salary_report_redaction_shape():
    """قائمة سماح: كل حقل مالي من عقد calculate_salary يُسقط، بما فيه
    المتداخل، مع بقاء الحقول غير المالية."""
    from app.routes.hr import _redact_salary_amounts
    report = {
        "employee_code": "E1",
        "employee_name": "احمد",
        "month": "2026-11",
        "base_salary": 5000.0,
        "base_pay": 4800.0,
        "net_salary": 4300.0,
        "permission_deduction": 10.0,
        "early_leave_deduction": 5.0,
        "overtime_bonus": 100.0,
        "bonuses_total": 100.0,
        "deductions_total": 200.0,
        "loans_total": 50.0,
        "debt_remaining": 300.0,
        "absence_deduction": 100.0,
        "late_deduction": 50.0,
        "late_minutes": 15,
        "delay_rules": {"per_minute": 2.0},
        "adjustment_lines": [
            {"label": "خصم", "amount": 30.0, "date": "2026-11-02"}
        ],
    }
    out = _redact_salary_amounts(report)
    assert out["employee_code"] == "E1"
    assert out["employee_name"] == "احمد"
    assert out["month"] == "2026-11"
    assert out["late_minutes"] == 15
    for money in (
        "base_salary", "base_pay", "net_salary", "permission_deduction",
        "early_leave_deduction", "overtime_bonus", "bonuses_total",
        "deductions_total", "loans_total", "debt_remaining",
        "absence_deduction", "late_deduction", "delay_rules",
    ):
        assert money not in out, money
    assert out["adjustment_lines"] == [
        {"label": "خصم", "date": "2026-11-02"}
    ]


def test_salary_broad_keys_include_report_page(make_request):
    from app.routes import hr as hr_mod
    # canOpenReportPage يفتح التقرير (مع إخفاء المبالغ لاحقاً)
    profile = _emp(
        {"الموارد البشرية": {"canOpenReportPage": True}},
        company_code="01", branches=["all"],
    )
    req = make_request(profile)
    db = FakeDB([FakeResult([None])])
    out = asyncio.run(hr_mod._authorize_employee_target(
        req, db, "01", "E1", salary=True
    ))
    assert out is profile


def test_settings_edit_keys_are_settings_consumers(make_request):
    from app.routes import hr as hr_mod
    profile = _emp(
        {"الموارد البشرية": {"canEditWeeklyDay": True}},
        company_code="01", branches=["all"],
    )
    req = make_request(profile)
    db = FakeDB([FakeResult([None])])
    out = asyncio.run(hr_mod._authorize_employee_target(
        req, db, "01", "E1"
    ))
    assert out is profile


def test_filter_docs_applies_viewable_list():
    from app.routes import hr as hr_mod
    docs = [
        SimpleNamespace(branch_code="B1", employee_code="E1"),
        SimpleNamespace(branch_code="B1", employee_code="E9"),
    ]
    profile = _emp({}, branches=["all"], company_code="01",
                   hr_viewable_employees=["E1"])
    out = asyncio.run(hr_mod._filter_docs(None, docs, "01", profile))
    assert [d.employee_code for d in out] == ["E1"]


def test_ws_own_only_skips_others_employee_events():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws = FakeWS()
        m.active_connections["01"] = {ws}
        m.connection_profiles[ws] = {
            "role": "employee",
            "permissions": {"الموارد البشرية": {"canViewOwnHRData": True}},
        }
        await m.broadcast(
            "01",
            {"type": "employee",
             "data": {"code": "E2", "name": "آخر", "branch_code": "B1",
                      "user_email": "other@x.com"},
             "suppress_notification": True},
        )
        # لا نسخة بث (own-only)، والنسخة الموجهة لغيره لا تصله
        assert ws.sent == []
    asyncio.run(run())


def test_ws_salary_stripped_without_amounts_right():
    from app.core.sync import ConnectionManager

    class FakeWS:
        def __init__(self):
            self.sent = []
        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        m = payload_only_manager()
        ws = FakeWS()
        m.active_connections["01"] = {ws}
        m.connection_profiles[ws] = {
            "role": "employee",
            "permissions": {"الموارد البشرية": {"canViewEmployees": True}},
        }
        await m.broadcast(
            "01",
            {"type": "employee",
             "data": {"code": "E2", "branch_code": "B1", "salary": 5000},
             "suppress_notification": True},
        )
        assert ws.sent[0]["data"].get("salary") is None or "salary" not in ws.sent[0]["data"]
    asyncio.run(run())


def test_ws_section_fail_closed_missing_category():
    from app.core.notification_events import _can_view_section
    # قسم غير موجود في صلاحيات الموظف = لا إشعار (كان fail-open)
    p = {"role": "employee",
         "permissions": {"المبيعات": {"معاينة": True}}}
    assert _can_view_section(p, "coding") is False
    assert _can_view_section(p, "sales") is True
    # مفتاح غائب كلياً = رفض
    p2 = {"role": "employee", "permissions": {"التكويد": {}}}
    assert _can_view_section(p2, "coding") is False


def test_coding_all_nine_categories(make_request):
    """الفئات التسع الفعلية في العميل كلها مقبولة ولا يسقط منها شيء."""
    from app.routes.coding import _add_permission_key
    expected = {
        "safes": "اضافة خزينة",
        "types": "اضافة صنف",
        "branches": "اضافة فرع",
        "stores": "اضافة مخزن",
        "suppliers": "اضافة مورد",
        "customers": "اضافة عملاء",
        "payment_methods": "اضافة طرق دفع",
        "items": "اضافة صنف",
        "banks": "اضافة بنك",
    }
    for category, key in expected.items():
        assert _add_permission_key(category) == key, category
    import pytest as _pt
    with _pt.raises(Exception):
        _add_permission_key("unknown_thing")


def test_inventory_serializer_cost_strip():
    """من لا يملك حق التكلفة لا تصله أسعار/قيم الجملة في المسلسل."""
    from app.routes.inventory import serialize_inventory

    class _Doc:
        id = 1
        company_code = "01"
        branch_code = "1"
        store_code = "S1"
        date = "2026-11-21"
        inventory_type = "وارد"
        items = [
            {
                "code": "I1",
                "name": "صنف",
                "quantity": 2,
                "wholesalePrice": 10.0,
                "wholesaleValue": 20.0,
                "retailPrice": 15.0,
            }
        ]
        total_wholesale = 20.0
        total_retail = 30.0
        serial = 7
        employee = "احمد"
        updated_at = None
        is_deleted = False

    full = serialize_inventory(_Doc(), include_costs=True)
    assert full["total_wholesale"] == 20.0
    assert full["items"][0]["wholesalePrice"] == 10.0

    stripped = serialize_inventory(_Doc(), include_costs=False)
    assert "total_wholesale" not in stripped
    assert "wholesalePrice" not in stripped["items"][0]
    assert "wholesaleValue" not in stripped["items"][0]
    assert stripped["items"][0]["retailPrice"] == 15.0
    assert stripped["items"][0]["quantity"] == 2


def test_ws_strip_inventory_cost_payload():
    """تقليل حمولة الجرد في البث: بلا حق تكلفة لا تصل أسعار الجملة."""
    from app.core.sync import _strip_payload_for_profile

    profile = {
        "role": "employee",
        "permissions": {"حركة الجرد": {"اذن اضافة مخزون": True}},
    }
    payload = {
        "doc_id": "1",
        "total_wholesale": 100.0,
        "total_retail": 150.0,
        "items": [
            {"code": "I1", "wholesalePrice": 10.0, "wholesaleValue": 100.0,
             "retailPrice": 15.0}
        ],
    }
    out = _strip_payload_for_profile(profile, "inventory", payload)
    assert "total_wholesale" not in out
    assert "wholesalePrice" not in out["items"][0]
    assert out["items"][0]["retailPrice"] == 15.0
    assert out["total_retail"] == 150.0

    privileged = {
        "role": "employee",
        "permissions": {"التكويد": {"سعر الشراء": True}},
    }
    out2 = _strip_payload_for_profile(privileged, "inventory", payload)
    assert out2.get("total_wholesale") == 100.0


def test_own_copy_skips_broadcast_recipients():
    """A connected, authorized owner receives one copy, not a duplicate."""
    import asyncio as _aio
    from app.core.sync import ConnectionManager
    from app.core.hr_audience import HRTarget

    class Socket:
        def __init__(self): self.sent = []
        async def send_json(self, message): self.sent.append(message)

    async def run():
        manager = payload_only_manager()
        socket = Socket()
        await manager.connect('01', socket, accept_connection=False, profile={
            'uid': 'owner', 'email': 'owner@x.com', 'company_code': '01', 'role': 'employee',
            'permissions': {'الموارد البشرية': {'canViewOwnHRData': True}},
        })
        message = {'type': 'employee', 'action': 'update',
                   'data': {'code': 'E1', 'user_email': 'owner@x.com'}}
        target = HRTarget(code='E1', uid='owner', email='owner@x.com')
        await manager._deliver_own_copy('01', message, skip_emails={'owner@x.com'}, hr_target=target)
        assert socket.sent == []
        await manager._deliver_own_copy('01', message, skip_emails=set(), hr_target=target)
        assert len(socket.sent) == 1
        assert socket.sent[0]['notification_scope'] == {'employee_code': 'E1', 'is_self': True}
    _aio.run(run())


# ------------------------------------------------------ سياسة أسعار الكتالوج

class _FakeCodingResult:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows


class _FakeScalars2:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows


class _FakeSaveResult:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows

    def scalars(self):
        return _FakeScalars2(self._rows)

    def scalar_one_or_none(self):
        return self._rows[0] if self._rows else None


class _FakeSaveDB:
    """قاعدة وهمية لمسارات الحفظ: execute متسلسل + commit/add."""

    def __init__(self, results):
        self._results = list(results)
        self.added = []

    async def execute(self, stmt):
        return self._results.pop(0) if self._results else _FakeSaveResult([])

    def add(self, obj):
        self.added.append(obj)

    async def commit(self):
        pass

    async def refresh(self, obj):
        if getattr(obj, "id", None) is None:
            obj.id = 1

    async def rollback(self):
        pass


def _inv_profile(cost_right=False, edit_right=False):
    perms = {"حركة الجرد": {"اضافة": True}}
    if edit_right:
        perms["حركة الجرد"]["تعديل"] = True
    if cost_right:
        perms["التكويد"] = {"سعر الشراء": True}
    return _emp(perms, branches=["all"])


def _inv_model(codes):
    from app.core.schemas import InventoryItemModel, InventoryModel
    return InventoryModel(
        company_code="01", branch_code="1", store_code="S1",
        date="2026-11-21", inventory_type="وارد",
        items=[
            InventoryItemModel(
                code=c, name=f"صنف {c}", quantity=2,
                wholesalePrice=999.0, retailPrice=15.0,
                wholesaleValue=1998.0, retailValue=30.0,
            )
            for c in codes
        ],
        total_wholesale=1998.0 * len(codes),
        total_retail=30.0 * len(codes),
    )


def test_inventory_save_unknown_code_rejected_atomically(
    make_request, monkeypatch
):
    """صنف غير موجود بالكتالوج: رفض 400 قبل أي كتابة، حتى لحامل
    حق التكلفة، ولا commit ولا بث."""
    from app.routes import inventory as inv

    calls = {"broadcast": 0}

    async def fake_broadcast(*a, **k):
        calls["broadcast"] += 1

    monkeypatch.setattr(inv.manager, "broadcast", fake_broadcast)
    req = make_request(_inv_profile(cost_right=True))
    # نتيجة الكتالوج فارغة = الصنف غير معروف
    db = _FakeSaveDB([_FakeSaveResult([])])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(inv.save_inventory(
            request=req, data=_inv_model(["NOPE"]), db=db
        ))
    assert exc.value.status_code == 400
    assert db.added == []
    assert calls["broadcast"] == 0


def test_inventory_save_known_code_catalog_price_wins(
    make_request, monkeypatch
):
    """العقد المصالح: من بلا حق تكلفة يأخذ سعر الكتالوج لسطر
    جديد؛ حامل الحق يحتفظ بسعره المدخل؛ وعند التعديل يُحفظ
    السعر المخزن للجميع (لا إعادة تسعير للتاريخ)."""
    from app.routes import inventory as inv

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(inv.manager, "broadcast", fake_broadcast)

    # 1) غير مخوّل بالتكلفة، سطر جديد: الكتالوج (10) يغلب إدخاله (999)
    req = make_request(_inv_profile(cost_right=False))
    db = _FakeSaveDB([
        _FakeSaveResult([("I1", 10.0, False)]),
        _FakeSaveResult([]),  # لا تعارض
    ])
    out = asyncio.run(inv.save_inventory(
        request=req, data=_inv_model(["I1"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    saved = db.added[0]
    assert saved.items[0]["wholesalePrice"] == 10.0
    assert saved.total_wholesale == 20.0

    # 2) حامل حق التكلفة: سعره المدخل محفوظ (سلوك قائم)
    req2 = make_request(_inv_profile(cost_right=True))
    db2 = _FakeSaveDB([
        _FakeSaveResult([("I1", 10.0, False)]),
        _FakeSaveResult([]),
    ])
    asyncio.run(inv.save_inventory(
        request=req2, data=_inv_model(["I1"]), db=db2
    ))
    saved2 = db2.added[0]
    assert saved2.items[0]["wholesalePrice"] == 999.0

    # 3) تعديل سجل موجود: السعر المخزن (50) محفوظ حتى لغير المخوّل
    from app.core.models import InventoryRecord as _IR
    existing = _IR(
        id=5, company_code="01", branch_code="1", store_code="S1",
        date="2026-11-21", inventory_type="وارد",
        items=[{"code": "I1", "name": "صنف I1", "quantity": 1,
                "wholesalePrice": 50.0, "wholesaleValue": 50.0,
                "retailPrice": 15.0, "retailValue": 15.0}],
        total_wholesale=50.0, total_retail=15.0,
        serial=3, employee="احمد", is_deleted=False,
    )
    req3 = make_request(_inv_profile(cost_right=False, edit_right=True))
    model3 = _inv_model(["I1"])
    model3.doc_id = "5"
    db3 = _FakeSaveDB([
        _FakeSaveResult([[{"code": "I1", "wholesalePrice": 50.0}]]),
        _FakeSaveResult([("I1", 10.0, False)]),
        _FakeSaveResult([existing]),
    ])
    asyncio.run(inv.save_inventory(request=req3, data=model3, db=db3))
    assert existing.items[0]["wholesalePrice"] == 50.0
    assert existing.total_wholesale == 100.0  # 50 × كمية 2 الجديدة


def _supplier_model(codes):
    from app.core.schemas import SupplierItemModel, SupplierTransactionModel
    return SupplierTransactionModel(
        company_code="01", branch_code="1", store_code="S1",
        serial=1, date="2026-11-21",
        supplier_name="مورد", payment_method="نقدي",
        treasury="خ1", is_add_to_store=False,
        employee="احمد",
        items=[
            SupplierItemModel(
                code=c, name=f"صنف {c}", quantity=2, price=999.0,
                type="صنف", discountRate=0.0, discountAmount=0.0,
                total=1998.0,
            )
            for c in codes
        ],
        total_amount=1998.0 * len(codes),
        paid_amount=0.0,
    )


def test_supplier_save_catalog_price_and_unknown_rejected(
    make_request, monkeypatch
):
    """المشتريات: السعر من الكتالوج دائماً؛ صنف غير معروف يرفض
    الفاتورة كاملة قبل أي كتابة."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    profile = _emp(
        {"حسابات الموردين": {"اضافة": True}}, branches=["all"]
    )
    req = make_request(profile)

    # غير مخوّل بالتكلفة، سطر جديد: 10 من الكتالوج تغلب 999 المرسلة
    db = _FakeSaveDB([
        _FakeSaveResult([("I1", 10.0, False)]),
        _FakeSaveResult([]),
    ])
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=_supplier_model(["I1"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    saved = db.added[0]
    assert saved.items[0]["price"] == 10.0
    assert saved.items[0]["total"] == 20.0
    assert saved.total_amount == 20.0

    # حامل حق التكلفة: سعره المدخل محفوظ (لا إعادة تسعير)
    req_cost = make_request(_emp(
        {"حسابات الموردين": {"اضافة": True},
         "التكويد": {"سعر الشراء": True}},
        branches=["all"],
    ))
    db_cost = _FakeSaveDB([
        _FakeSaveResult([("I1",)]),  # الصنف معروف بالكتالوج
        _FakeSaveResult([]),          # لا تعارض
    ])
    asyncio.run(sup.save_supplier_transaction(
        request=req_cost, data=_supplier_model(["I1"]), db=db_cost
    ))
    assert db_cost.added[0].items[0]["price"] == 999.0

    # صنف غير معروف: رفض 400 بلا كتابة
    db2 = _FakeSaveDB([_FakeSaveResult([])])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(sup.save_supplier_transaction(
            request=req, data=_supplier_model(["NOPE"]), db=db2
        ))
    assert exc.value.status_code == 400
    assert db2.added == []


def test_inventory_edit_authorized_price_change_honored(
    make_request, monkeypatch
):
    """حامل حق التكلفة يعدّل سعر سطر قائم: سعره المدخل يُحترم
    (الأساس). التجميد للسعر المخزن يخص من بلا حق تكلفة فقط."""
    from app.core.models import InventoryRecord as _IR
    from app.routes import inventory as inv

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(inv.manager, "broadcast", fake_broadcast)
    existing = _IR(
        id=7, company_code="01", branch_code="1", store_code="S1",
        date="2026-11-21", inventory_type="وارد",
        items=[{"code": "I1", "name": "صنف I1", "quantity": 1,
                "wholesalePrice": 50.0, "wholesaleValue": 50.0,
                "retailPrice": 15.0, "retailValue": 15.0}],
        total_wholesale=50.0, total_retail=15.0,
        serial=3, employee="احمد", is_deleted=False,
    )
    req = make_request(_inv_profile(cost_right=True, edit_right=True))
    model = _inv_model(["I1"])
    model.doc_id = "7"
    db = _FakeSaveDB([
        _FakeSaveResult([[{"code": "I1", "wholesalePrice": 50.0}]]),
        _FakeSaveResult([("I1", 10.0, False)]),
        _FakeSaveResult([existing]),
    ])
    asyncio.run(inv.save_inventory(request=req, data=model, db=db))
    assert existing.items[0]["wholesalePrice"] == 999.0
    assert existing.total_wholesale == 1998.0


def test_supplier_unknown_code_grant_without_cost_right_rejected(
    make_request, monkeypatch
):
    """حق التكويد بلا حق تكلفة: لا يقبل صنفاً جديداً بسعر مدخل —
    حقل السعر مخفي عنه أصلاً فيصبح صفراً مُختلَقاً سعراً للكتالوج.
    يرفض ويطلب التسجيل أولاً من شاشة التكويد."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    profile = _emp(
        {"حسابات الموردين": {"اضافة": True},
         "التكويد": {"اضافة صنف": True}},
        branches=["all"],
    )
    req = make_request(profile)
    db = _FakeSaveDB([_FakeSaveResult([])])  # الكتالوج لا يعرف الصنف
    with pytest.raises(HTTPException) as exc:
        asyncio.run(sup.save_supplier_transaction(
            request=req, data=_supplier_model(["NEW1"]), db=db
        ))
    assert exc.value.status_code == 400
    assert "التكويد" in str(exc.value.detail)


def test_supplier_unknown_code_cost_and_grant_accepted(
    make_request, monkeypatch
):
    """حق التكلفة مع حق التكويد: الصنف الجديد يُقبل بسعره المدخل
    (يصبح سعر الكتالوج عبر تسجيل العميل له)، المسار الأساسي."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    profile = _emp(
        {"حسابات الموردين": {"اضافة": True},
         "التكويد": {"اضافة صنف": True, "سعر الشراء": True}},
        branches=["all"],
    )
    req = make_request(profile)
    db = _FakeSaveDB([_FakeSaveResult([])])
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=_supplier_model(["NEW1"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    saved = db.added[0]
    assert saved.items[0]["price"] == 999.0
    assert saved.total_amount == 1998.0


def _supplier_update_model(codes, doc_id="5"):
    from app.core.schemas import SupplierItemModel, SupplierTransactionModel
    m = _supplier_model(codes)
    return SupplierTransactionModel(**{**m.model_dump(), "doc_id": doc_id})


def _existing_supplier(items):
    from app.core.models import SupplierRecord as _SR
    return _SR(
        id=5, company_code="01", branch_code="1", store_code="S1",
        serial=1, date="2026-11-20", supplier_name="مورد",
        payment_method="نقدي", treasury="خ1", is_add_to_store=False,
        employee="احمد", items=items, total_amount=0.0,
        paid_amount=0.0, is_add_to_coding=False, is_deleted=False,
    )


def test_supplier_restricted_edit_preserves_stored_discount_and_total(
    make_request, monkeypatch
):
    """تعديل مقيد (بلا حق تكلفة) لفاتورة فيها خصم مخزن: السعر
    والخصم المخزنان يُستعادان سطراً بسطر، فلا يُعاد حساب إجمالي
    تاريخي بخصم صفر."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    stored_items = [
        {"code": "A1", "name": "صنف A1", "quantity": 2, "price": 100.0,
         "discountAmount": 30.0, "discountRate": 15.0, "total": 170.0},
    ]
    existing = _existing_supplier(stored_items)
    existing.total_amount = 170.0
    profile = _emp({"حسابات الموردين": {"تعديل": True}}, branches=["all"])
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([stored_items]),      # السطور المخزنة
        _FakeSaveResult([("A1", 100.0, False)]),     # أسعار الكتالوج
        _FakeSaveResult([existing]),          # السجل الموجود
    ])
    model = _supplier_update_model(["A1"])  # العميل المقيد أرسل 0/999؟
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=model, db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    assert existing.items[0]["price"] == 100.0
    assert existing.items[0]["discountAmount"] == 30.0
    assert existing.items[0]["discountRate"] == 15.0
    assert existing.items[0]["total"] == 170.0
    assert existing.total_amount == 170.0


def test_supplier_restricted_edit_repeated_code_matched_in_order(
    make_request, monkeypatch
):
    """الكود المكرر في الفاتورة نفسها: كل سطر يستعيد سعره المخزن
    بترتيب الظهور (قائمة انتظار لكل كود)، لا أول سعر للجميع."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    stored_items = [
        {"code": "R1", "name": "صنف R1", "quantity": 1, "price": 50.0,
         "discountAmount": 0.0, "discountRate": 0.0, "total": 50.0},
        {"code": "R1", "name": "صنف R1", "quantity": 1, "price": 80.0,
         "discountAmount": 0.0, "discountRate": 0.0, "total": 80.0},
    ]
    existing = _existing_supplier(stored_items)
    existing.total_amount = 130.0
    profile = _emp({"حسابات الموردين": {"تعديل": True}}, branches=["all"])
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([stored_items]),
        _FakeSaveResult([("R1", 999.0, False)]),
        _FakeSaveResult([existing]),
    ])
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=_supplier_update_model(["R1", "R1"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    assert existing.items[0]["price"] == 50.0
    assert existing.items[1]["price"] == 80.0
    # الكمية من السطور المرسلة (2 لكل سطر)، والأسعار من المخزن:
    # 2×50 + 2×80
    assert existing.total_amount == 260.0


def test_supplier_delete_broadcast_stripped_for_no_cost_recipient(
    make_request, monkeypatch
):
    """حذف فاتورة: الحمولة المذاعة تمر على طبقة التجريد بنوع
    الحدث الصحيح — مستلم بلا حق تكلفة لا يرى الأسعار ولا الإجمالي،
    والمخوَّل يراها كاملة (شكل الحدث نفسه لكليهما)."""
    from app.core.sync import _strip_payload_for_profile
    from app.routes import supplier as sup

    sent = []

    async def fake_broadcast(company, message):
        sent.append(message)

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    existing = _existing_supplier([
        {"code": "A1", "name": "صنف A1", "quantity": 2, "price": 100.0,
         "discountAmount": 30.0, "discountRate": 15.0, "total": 170.0},
    ])
    existing.total_amount = 170.0
    profile = _emp({"حسابات الموردين": {"حذف": True}}, branches=["all"])
    req = make_request(profile)
    db = _FakeSaveDB([_FakeSaveResult([existing])])
    out = asyncio.run(sup.delete_supplier_transaction(
        request=req, company_code="01", doc_id="5", db=db
    ))
    assert out.get("status") == "success"
    assert existing.is_deleted is True
    assert len(sent) == 1
    message = sent[0]
    assert message["type"] == "supplier" and message["action"] == "delete"
    stripped = _strip_payload_for_profile(
        _emp({"حسابات الموردين": {"اضافة": True}}),
        message["type"], message["data"],
    )
    assert "total_amount" not in stripped
    assert "price" not in stripped["items"][0]
    assert "total" not in stripped["items"][0]
    assert "discountAmount" not in stripped["items"][0]
    # المخوَّل: لا تغيير في الشكل
    full = _strip_payload_for_profile(
        _emp({"حسابات الموردين": {"اضافة": True},
              "التكويد": {"سعر الشراء": True}}),
        message["type"], message["data"],
    )
    assert full["total_amount"] == 170.0
    assert full["items"][0]["price"] == 100.0


def test_supplier_unset_cost_rejected_atomic_no_partial_save(
    make_request, monkeypatch
):
    """صنف علامته cost_pending (سعره غير محدد) ومحرر بلا حق
    تكلفة: رفض ذري قبل أي كتابة — الفاتورة كلها لا تُحفظ
    (لا سطر جزئي)، برسالة تطلب تحديد السعر أولاً."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    profile = _emp(
        {"حسابات الموردين": {"اضافة": True}},
        branches=["all"],
    )
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([
            ("A1", 50.0, False),   # سعر محدد
            ("Z9", 0.0, True),     # سعر غير محدد
        ]),
    ])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(sup.save_supplier_transaction(
            request=req, data=_supplier_model(["A1", "Z9"]), db=db
        ))
    assert exc.value.status_code == 400
    assert "سعر شراء محدد" in str(exc.value.detail)
    assert db.added == [], "رفض ذري: لا حفظ جزئي لأي سطر"


def test_supplier_explicit_zero_cost_allowed_for_no_cost_editor(
    make_request, monkeypatch
):
    """صفر مصرَّح به (cost_pending=False، حدّده مخوَّل صراحة)
    قيمة مشروعة: المحرر بلا حق تكلفة يحفظ الفاتورة عليه."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    profile = _emp(
        {"حسابات الموردين": {"اضافة": True}},
        branches=["all"],
    )
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([("Z9", 0.0, False)]),
    ])
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=_supplier_model(["Z9"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    assert db.added[0].items[0]["price"] == 0.0


def test_supplier_zero_catalog_price_stored_line_still_editable(
    make_request, monkeypatch
):
    """سطر مخزن قديم بسعر صفر: التعديل المقيد يحفظه كما هو
    (حفظ تاريخي) — الرفض يطال الأسطر الجديدة فقط."""
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)
    stored_items = [
        {"code": "Z9", "name": "صنف Z9", "quantity": 1, "price": 0.0,
         "discountAmount": 0.0, "discountRate": 0.0, "total": 0.0},
    ]
    existing = _existing_supplier(stored_items)
    existing.total_amount = 0.0
    profile = _emp({"حسابات الموردين": {"تعديل": True}}, branches=["all"])
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([stored_items]),
        _FakeSaveResult([("Z9", 0.0, True)]),
        _FakeSaveResult([existing]),
    ])
    out = asyncio.run(sup.save_supplier_transaction(
        request=req, data=_supplier_update_model(["Z9"]), db=db
    ))
    assert out.get("status") == "success" or "doc_id" in out
    assert existing.items[0]["price"] == 0.0


def test_inventory_zero_catalog_price_rejected_for_no_cost_editor(
    make_request, monkeypatch
):
    """نفس الحماية في الجرد: صنف بلا سعر شراء ومحرر بلا حق
    تكلفة — رفض واضح بدل قيمة صفر صامتة."""
    from app.routes import inventory as inv

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(inv.manager, "broadcast", fake_broadcast)
    from app.core.schemas import InventoryItemModel, InventoryModel
    model = InventoryModel(
        company_code="01", branch_code="1", store_code="S1",
        serial=1, date="2026-11-21", employee="احمد",
        inventory_type="وارد",
        items=[
            InventoryItemModel(
                code="Z9", name="صنف Z9", quantity=2,
                wholesalePrice=0.0, retailPrice=5.0,
                wholesaleValue=0.0, retailValue=10.0,
            )
        ],
        total_wholesale=0.0, total_retail=10.0,
    )
    profile = _emp({"حركة الجرد": {"اضافة": True}},
                   branches=["all"])
    req = make_request(profile)
    db = _FakeSaveDB([
        _FakeSaveResult([("Z9", 0.0, True)]),  # سعر غير محدد
    ])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(inv.save_inventory(
            request=req, data=model, db=db
        ))
    assert exc.value.status_code == 400
    assert "سعر شراء محدد" in str(exc.value.detail)
    assert db.added == [], "رفض ذري: لا حفظ جزئي"


def test_supplier_serializer_strips_total_without_cost_right():
    """بلا حق تكلفة: إجمالي الفاتورة وحقول التكلفة لا تغادر
    الخادم لمن لا يملك حق التكلفة)."""
    from app.core.models import SupplierRecord as _SR
    from app.routes.supplier import serialize_supplier

    doc = _SR(
        id=3, company_code="01", branch_code="1", store_code="S1",
        serial=5, date="2026-11-21", supplier_name="مورد",
        payment_method="نقدي", treasury="خ1", is_add_to_store=False,
        employee="احمد",
        items=[{"code": "I1", "name": "صنف", "quantity": 2,
                "price": 10.0, "total": 20.0, "discountAmount": 0.0,
                "discountRate": 0.0}],
        total_amount=20.0, paid_amount=5.0, is_add_to_coding=False,
        is_deleted=False,
    )
    out = serialize_supplier(doc, include_costs=False)
    assert "total_amount" not in out
    item = out["items"][0]
    assert "price" not in item and "total" not in item
    assert "discountAmount" not in item
    assert item["name"] == "صنف"
    full = serialize_supplier(doc, include_costs=True)
    assert full["total_amount"] == 20.0
    assert full["items"][0]["price"] == 10.0


def test_ws_strip_supplier_cost_payload():
    """بث المشتريات: بلا حق تكلفة لا يصل سعر ولا إجمالي سطر
    ولا إجمالي فاتورة؛ حامل الحق يستلم كاملاً."""
    from app.core.sync import _strip_payload_for_profile

    profile = {
        "role": "employee",
        "permissions": {"حسابات الموردين": {"اضافة": True}},
    }
    payload = {
        "doc_id": "1", "total_amount": 20.0, "paid_amount": 5.0,
        "items": [{"code": "I1", "price": 10.0, "total": 20.0,
                   "discountAmount": 0.0, "discountRate": 0.0,
                   "name": "صنف"}],
    }
    out = _strip_payload_for_profile(profile, "supplier", payload)
    assert "total_amount" not in out
    item = out["items"][0]
    assert "price" not in item and "total" not in item
    assert "discountAmount" not in item
    assert item["name"] == "صنف"

    privileged = {
        "role": "employee",
        "permissions": {"التكويد": {"سعر الشراء": True}},
    }
    out2 = _strip_payload_for_profile(privileged, "supplier", payload)
    assert out2.get("total_amount") == 20.0
    assert out2["items"][0]["price"] == 10.0


# ------------------------------------------------------------ علامة cost_pending

class _ScalarOneResult:
    def __init__(self, value):
        self._value = value

    def scalar_one_or_none(self):
        return self._value


class _FakeCodingDB:
    def __init__(self, existing=None):
        self._existing = existing
        self.added = []

    async def execute(self, stmt):
        return _ScalarOneResult(self._existing)

    def add(self, obj):
        self.added.append(obj)

    async def commit(self):
        pass

    async def refresh(self, obj):
        if getattr(obj, "id", None) is None:
            obj.id = 1

    async def rollback(self):
        pass


def _coding_data(**over):
    base = dict(
        category="items", company_code="01", branch_code="B1",
        code="Z9", name="صنف", type="وارد", barcode="",
        wholesale_price=0.0, selling_price=5.0,
        profit_margin=0.0, profit_percent=0.0,
    )
    base.update(over)
    return SimpleNamespace(**base)


def test_coding_create_by_costless_clerk_marks_cost_pending(
    make_request, monkeypatch
):
    """كاتب التكويد بلا حق تكلفة يسجل الصنف بلا سعر: الصفر
    المخزن موسوم cost_pending=True (غير محدد) لا صفراً مصرَّحاً."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)
    req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True}}, branches=["B1"]
    ))
    db = _FakeCodingDB(existing=None)
    out = asyncio.run(cod.save_code(
        data=_coding_data(wholesale_price=7.5), request=req, db=db
    ))
    assert out["status"] == "success"
    rec = db.added[0]
    assert rec.cost_pending is True
    assert rec.wholesale_price == 0.0, "سعره المدخل لا يُقبل بلا حق"


def test_coding_create_by_cost_holder_is_explicit(make_request, monkeypatch):
    """من يملك حق التكلفة يحفظ سعره (حتى صفراً صريحاً):
    لا علامة cost_pending."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)
    req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True, "سعر الشراء": True}},
        branches=["B1"],
    ))
    db = _FakeCodingDB(existing=None)
    out = asyncio.run(cod.save_code(
        data=_coding_data(wholesale_price=7.5), request=req, db=db
    ))
    assert out["status"] == "success"
    rec = db.added[0]
    assert rec.cost_pending is False
    assert rec.wholesale_price == 7.5


def _pending_item():
    return SimpleNamespace(
        id=1, company_code="01", category="items", code="Z9",
        branch_code="B1", name="قديم", type="وارد", barcode="",
        wholesale_price=0.0, cost_pending=True,
        selling_price=5.0, profit_margin=0.0, profit_percent=0.0,
        is_deleted=False, updated_at=None,
    )


def _holder_request(make_request):
    return make_request(_emp(
        {"التكويد": {"اضافة صنف": True, "سعر الشراء": True}},
        branches=["B1"],
    ))


def test_pending_item_name_only_save_retains_marker_and_price(
    make_request, monkeypatch
):
    """حفظ عادي (إعادة تسمية/باركود) على صنف "غير محدد" لا
    يزيل العلامة ولا يكتب السعر — إعادة إرسال الصفر شكلاً
    ليست موافقة على صفر. العميل القديم غير المدرك للعلامة
    آمن: لا إزالة عرضية."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)
    existing = _pending_item()
    db = _FakeCodingDB(existing=existing)
    asyncio.run(cod.save_code(
        data=_coding_data(name="جديد", wholesale_price=0.0),
        request=_holder_request(make_request), db=db,
    ))
    assert existing.name == "جديد", "الاسم يتحدث"
    assert existing.cost_pending is True, "الحفظ العادي لا يزيل العلامة"
    assert existing.wholesale_price == 0.0


def test_pending_item_nonzero_cost_clears_marker(
    make_request, monkeypatch
):
    """صاحب الحق يدخل سعراً غير صفري: يُحفظ وتُزال العلامة."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)
    existing = _pending_item()
    db = _FakeCodingDB(existing=existing)
    asyncio.run(cod.save_code(
        data=_coding_data(wholesale_price=9.5),
        request=_holder_request(make_request), db=db,
    ))
    assert existing.cost_pending is False
    assert existing.wholesale_price == 9.5


def test_pending_item_explicit_zero_confirm_clears_only_authorized(
    make_request, monkeypatch
):
    """الصفر الصريح: تأكيد confirm_zero_cost من صاحب الحق
    يزيل العلامة عند صفر؛ نفس التأكيد بلا حق = رفض 403."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)

    clerk_req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True}}, branches=["B1"]
    ))
    existing = _pending_item()
    db = _FakeCodingDB(existing=existing)
    with pytest.raises(HTTPException) as exc:
        asyncio.run(cod.save_code(
            data=_coding_data(wholesale_price=0.0,
                              confirm_zero_cost=True),
            request=clerk_req, db=db,
        ))
    assert exc.value.status_code == 403
    assert existing.cost_pending is True, "تأكيد غير مخوَّل لا يزيل"

    existing2 = _pending_item()
    db2 = _FakeCodingDB(existing=existing2)
    asyncio.run(cod.save_code(
        data=_coding_data(wholesale_price=0.0, confirm_zero_cost=True),
        request=_holder_request(make_request), db=db2,
    ))
    assert existing2.cost_pending is False, "تأكيد مخوَّل يزيل عند صفر"
    assert existing2.wholesale_price == 0.0, "الصفر الصريح قيمة مشروعة"


def test_pending_item_clerk_update_never_touches_cost(
    make_request, monkeypatch
):
    """كاتب بلا حق تكلفة يعدّل صنفاً "غير محدداً": لا سعر
    ولا علامة تتغير مهما أرسل."""
    from app.routes import coding as cod

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(cod.manager, "broadcast", fake_broadcast)
    clerk_req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True}}, branches=["B1"]
    ))
    existing = _pending_item()
    db = _FakeCodingDB(existing=existing)
    asyncio.run(cod.save_code(
        data=_coding_data(wholesale_price=9.0), request=clerk_req, db=db
    ))
    assert existing.cost_pending is True, "بلا حق: العلامة تبقى"
    assert existing.wholesale_price == 0.0, "بلا حق: السعر لا يتغير"


def test_settings_add_code_marks_pending_then_invoice_rejected(
    make_request, monkeypatch
):
    """مسار /settings/add-code البديل: صنف جديد بلا مدخل سعر
    يُوسَم "غير محدد" أياً كان المنشئ، وفاتورة مورد عليه
    تترفض ذرياً حتى يُحدَّد سعره."""
    from app.routes import settings as st
    from app.routes import supplier as sup

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(st.manager, "broadcast", fake_broadcast)
    monkeypatch.setattr(sup.manager, "broadcast", fake_broadcast)

    holder_req = make_request(_emp(
        {"التكويد": {
            "اضافة صنف": True, "اضافة فرع": True,
            "سعر الشراء": True,
        }},
        branches=["B1"],
    ))
    item = st.CodingItem(
        category="items", code="Z9", name="صنف", company_code="01",
    )
    db = _FakeCodingDB(existing=None)
    asyncio.run(st.add_coding_item(item=item, request=holder_req, db=db))
    created = db.added[0]
    assert created.cost_pending is True, "لا مدخل سعر = غير محدد"
    assert created.wholesale_price == 0.0

    # ومن نفس المسار: فئة غير سعرية (فروع) لا تُوسَم
    item2 = st.CodingItem(
        category="branches", code="B2", name="فرع", company_code="01",
    )
    db2 = _FakeCodingDB(existing=None)
    asyncio.run(st.add_coding_item(item=item2, request=holder_req, db=db2))
    assert db2.added[0].cost_pending is False

    # الفاتورة على الصنف غير المحدد تترفض قبل أي كتابة
    sup_req = make_request(_emp(
        {"حسابات الموردين": {"اضافة": True}}, branches=["all"]
    ))
    sup_db = _FakeSaveDB([
        _FakeSaveResult([("Z9", 0.0, created.cost_pending)]),
    ])
    with pytest.raises(HTTPException) as exc:
        asyncio.run(sup.save_supplier_transaction(
            request=sup_req, data=_supplier_model(["Z9"]), db=sup_db
        ))
    assert exc.value.status_code == 400
    assert sup_db.added == []


def test_settings_reactivation_zeroes_and_marks_pending(
    make_request, monkeypatch
):
    """إعادة تفعيل صنف محذوف: خط الأساس يصفّر سعره، فيعود
    "غير محدد" حتى يُسعَّر من جديد؛ الفئات غير السعرية لا
    تُوسَم. لا تغيير عن سلوك التصفير القائم."""
    from app.routes import settings as st

    async def fake_broadcast(*a, **k):
        return None

    monkeypatch.setattr(st.manager, "broadcast", fake_broadcast)
    holder_req = make_request(_emp(
        {"التكويد": {"اضافة صنف": True, "سعر الشراء": True}},
        branches=["B1"],
    ))

    priced = SimpleNamespace(
        id=1, company_code="01", category="items", code="P1",
        name="قديم", type="", barcode="", wholesale_price=25.0,
        selling_price=30.0, profit_margin=5.0, profit_percent=0.2,
        cost_pending=False, is_deleted=True, updated_at=None,
    )
    db = _FakeCodingDB(existing=priced)
    item = st.CodingItem(
        category="items", code="P1", name="جديد", company_code="01",
    )
    asyncio.run(st.add_coding_item(item=item, request=holder_req, db=db))
    assert priced.is_deleted is False
    assert priced.wholesale_price == 0.0, "سلوك التصفير القائم محفوظ"
    assert priced.cost_pending is True, "العائد بلا سعر = غير محدد"


def test_migration_source_matches_repo_pattern():
    """عبارة الترقية في database.py نفسها: idempotent بنمط
    IF NOT EXISTS المستخدم في باقي القائمة، وقبل خدمة الطلبات."""
    src = open('app/core/database.py', encoding='utf-8').read()
    assert (
        'ALTER TABLE coding_records ADD COLUMN IF NOT EXISTS'
        ' cost_pending BOOLEAN NOT NULL DEFAULT FALSE'
    ) in src, "عبارة الترقية الفعلية غير موجودة في create_tables"
    assert 'cost_pending' in src.split('create_tables')[1]


def test_coding_records_upgrade_adds_pending_as_explicit(
    tmp_path, monkeypatch
):
    """ترقية قاعدة موجودة: جدول قديم بلا العمود يكتسبه بقيمة
    FALSE — الصفوف التاريخية (بأصفارها) تُقرأ صريحة."""
    import sqlalchemy as sa

    engine = sa.create_engine(f"sqlite:///{tmp_path}/old.db")
    with engine.begin() as conn:
        conn.execute(sa.text(
            "CREATE TABLE coding_records ("
            "id INTEGER PRIMARY KEY, company_code VARCHAR(10),"
            " category VARCHAR(50), code VARCHAR(50),"
            " wholesale_price FLOAT)"
        ))
        conn.execute(sa.text(
            "INSERT INTO coding_records"
            " (company_code, category, code, wholesale_price)"
            " VALUES ('01', 'items', 'Z9', 0.0)"
        ))
        # نفس عبارة الترقية (SQLite لا يدعم IF NOT EXISTS)
        conn.execute(sa.text(
            "ALTER TABLE coding_records ADD COLUMN"
            " cost_pending BOOLEAN NOT NULL DEFAULT FALSE"
        ))
        row = conn.execute(sa.text(
            "SELECT wholesale_price, cost_pending"
            " FROM coding_records WHERE id = 1"
        )).first()
        assert row[0] == 0.0
        assert row[1] in (False, 0), "الصفر التاريخي صريح لا غير محدد"
    engine.dispose()
