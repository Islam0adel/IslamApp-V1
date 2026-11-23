import json
from pathlib import Path
from app.core.page_visibility import PAGE_VISIBILITY_KEYS
from app.core.permission_policy import effective_permissions, check_assignment
from app.core.permissions import has_section_permission
from app.core.notification_events import _can_view_section

def test_shared_visibility_contract():
 assert PAGE_VISIBILITY_KEYS == set(json.loads((Path(__file__).resolve().parents[2]/'contracts/page_visibility.json').read_text())['keys'])

def test_explicit_hide_survives_projection_without_grant():
 key='إظهار تحويلات الخزائن'
 assert effective_permissions({}, {'صلاحيات عامة':{key:False}})=={'صلاحيات عامة':{key:False}}
 assert effective_permissions({}, {'صلاحيات عامة':{key:True}})=={}
 assert not check_assignment(company_ceiling={},delegable_permissions={},previous_permissions={},proposed_permissions={'صلاحيات عامة':{key:False}}).allowed

def test_every_page_visible_supplies_no_api_or_notification_right():
 p={'role':'employee','company_code':'C1','allowed_branches':['all'],'permissions':{'صلاحيات عامة':{**{k:True for k in PAGE_VISIBILITY_KEYS},'إظهار الإشعارات':True,'إظهار الموارد البشرية':True,'إظهار حركة الخزينة':True,'إظهار التكويد':True,'إظهار حركة الجرد':True}}}
 for c in ['المبيعات','تحويلات الخزائن','التكويد','حركة الجرد','حركة الخزينة']:
  for k in ['معاينة','إضافة','تعديل','حذف','المعاينة','ادخال اذون']:
   assert not has_section_permission(p,c,k)
 for section in ['daily','coding','inventory','purchases','settlements','sales','sales_returns','customer_payments','stock_transfers','treasury_transfers','hr_attendance']:
  assert not _can_view_section(p,section)
