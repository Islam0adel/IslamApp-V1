import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/services/permission_bulk_edit.dart';
import 'package:islam_app/services/permission_hierarchy.dart';
void main() {
  test('select all never changes denied controls or unrelated groups',(){
    final source={'المبيعات':{'إضافة':false,'تعديل':false,'حذف':false},'صلاحيات عامة':{'x':false}};
    final next=bulkPermissionEdit(source,{'المبيعات':['إضافة','تعديل','حذف']},true,(c,k,n,current)=>k!='حذف');
    expect(next['المبيعات'],{'إضافة':true,'تعديل':true,'حذف':false});
    expect(next['صلاحيات عامة'],{'x':false});expect(source['المبيعات']!['إضافة'],false);
  });
  test('clear edit before included add, but cannot change add while edit is denied',(){
    final source={'المبيعات':{'إضافة':true,'تعديل':true}};
    final cleared=bulkPermissionEdit(source,{'المبيعات':['إضافة','تعديل']},false,(c,k,n,current)=>true);
    expect(PermissionHierarchy.allows(cleared,'المبيعات','إضافة'),false);
    final denied=bulkPermissionEdit(source,{'المبيعات':['إضافة','تعديل']},false,(c,k,n,current)=>k!='تعديل');
    expect(denied,source);
  });
  test('operating action does not touch delegation map or branch selections',(){
    final operating={'المبيعات':{'إضافة':false}};
    final delegation={'المبيعات':{'إضافة':true}};
    final branches=['B2'];
    bulkPermissionEdit(operating,{'المبيعات':['إضافة']},true,(c,k,n,current)=>true);
    expect(delegation['المبيعات']!['إضافة'],true);expect(branches,['B2']);
  });
}
