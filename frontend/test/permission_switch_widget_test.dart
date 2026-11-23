import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/views/widgets/permission_action_switch.dart';

void main(){
  setUpAll(()async{
    final loader=FontLoader('Cairo')..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    await loader.load();
    final icons=FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  Widget app(Widget child)=>MaterialApp(theme:ThemeData(fontFamily:'Cairo'),home:Directionality(textDirection:TextDirection.rtl,child:Scaffold(body:SafeArea(child:child))));
  testWidgets('edit includes add, switching edit off restores the separately stored add choice',(tester)async{
    var edit=true;var add=false;
    await tester.pumpWidget(app(StatefulBuilder(builder:(context,setState)=>Column(children:[
      PermissionActionSwitch(label:'تعديل',value:edit,included:false,onChanged:(v)=>setState(()=>edit=v)),
      PermissionActionSwitch(label:'إضافة',value:add,included:edit,onChanged:(v)=>setState(()=>add=v)),
    ]))));
    SwitchListTile addition()=>tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).last;
    expect(addition().value,isTrue);expect(addition().onChanged,isNull);expect(add,isFalse);
    await tester.tap(find.text('تعديل'));await tester.pumpAndSettle();
    expect(edit,isFalse);expect(addition().value,isFalse);expect(addition().onChanged,isNotNull);
    await tester.tap(find.text('إضافة'));await tester.pumpAndSettle();
    expect(add,isTrue);expect(edit,isFalse);
  });
  testWidgets('permission hierarchy switch narrow pixels',(tester)async{
    tester.view.physicalSize=const Size(320,420);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Padding(padding:EdgeInsets.all(20),child:Text('صلاحيات تحويلات الخزائن',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),
      PermissionActionSwitch(label:'تعديل',value:true,included:false,onChanged:(_){}),
      PermissionActionSwitch(label:'إضافة',value:false,included:true,onChanged:(_){}),
      PermissionActionSwitch(label:'حذف',value:false,included:false,onChanged:(_){}),
    ])));
    await tester.pump();
    await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/permission_hierarchy_narrow.png'));
    await tester.pumpWidget(const SizedBox());
  });
}
