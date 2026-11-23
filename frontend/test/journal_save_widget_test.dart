import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as xlsx;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:islam_app/services/journal_save_intent.dart';
import 'package:islam_app/services/journal_import_batch.dart';
import 'package:islam_app/services/permissions_service.dart';
import 'package:islam_app/views/dashboard/daily_page.dart';
import 'commercial_queue_regression_test.dart' as f;
import 'journal_save_recovery_test.dart' as j;

class WorkbookPicker extends FilePicker {
  final Uint8List bytes;
  WorkbookPicker(this.bytes);
  @override
  Future<FilePickerResult?> pickFiles({String? dialogTitle,String? initialDirectory,
    FileType type=FileType.any,List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,bool allowCompression=true,
    int compressionQuality=30,bool allowMultiple=false,bool withData=false,
    bool withReadStream=false,bool lockParentWindow=false,bool readSequential=false}) async =>
      FilePickerResult([PlatformFile(name:'rows.xlsx',size:bytes.length,bytes:bytes)]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = f.FakeCore();
  FirebaseAuthPlatform.instance = f.FakeAuth();
  late Directory directory;
  late j.JournalServer server;
  JournalIntentStore store() =>
      JournalIntentStore(tabId: '${JournalTabScope.current}:manual');
  JournalSaveIntent pendingIntent() => JournalSaveIntent(
      ownerUid: 'uid-A', companyCode: 'C1', branchCode: 'B1', serial: 0)
    ..capture({
      'company_code': 'C1',
      'branch_code': 'B1',
      'serial': 0,
      'treasury': 'A',
      'amount': 10.0,
      'statement': 'pending test',
      'date': '2026-11-22',
      'category': 'Income',
      'type': 'وارد',
      'employee': 'fixture',
      'link_id': null,
      'supplier_name': null,
      'add_to_settlement': false,
      'unlink_settlement': false,
    });
  setUpAll(() async {
    final font = FontLoader('Cairo')
      ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    await font.load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('journal_widget_');
    Hive.init(directory.path);
    for (final box in [
      'coding_box',
      'daily_transactions_box',
      'supplier_settlement_box',
      JournalIntentStore.boxName,
      JournalImportBatch.boxName
    ]) {
      await Hive.openBox(box);
    }
    SharedPreferences.setMockInitialValues({});
    f.currentUid = 'uid-A';
    PermissionsService().debugSetPermissionsForTest(
        {
          'حركة الخزينة': {
            'ادخال اذون': true,
            'المعاينة': true,
            'التعديل': true,
            'شاشات الارصدة': true
          }
        },
        role: 'employee',
        branches: ['B1']);
    final coding = Hive.box('coding_box');
    await coding.put('C1_safes', [
      {'code': '1', 'name': 'A'}
    ]);
    await coding.put('C1_types', [
      {'code': '1', 'name': 'Income', 'type': 'وارد'}
    ]);
    await coding.put('C1_suppliers', [
      {'name': 'Supplier'}
    ]);
    server = j.JournalServer();
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
  }

  Future<void> open(WidgetTester tester,
      {double width = 390, bool dark = false, Map<String,dynamic>? editItem}) async {
    tester.view.physicalSize = Size(width, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            fontFamily: 'Cairo',
            brightness: dark ? Brightness.dark : Brightness.light),
        home: Directionality(
            textDirection: TextDirection.rtl,
            child: DailyPage(
                companyCode: 'C1',
                selectedBranchCode: 'B1',
                branchName: 'B1',editItem:editItem))));
    await drain(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
    var closed = false;
    Object? failure;
    Hive.close().then((_) {
      closed = true;
    }, onError: (Object error) {
      failure = error;
      closed = true;
    });
    for (var i = 0; i < 30 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(failure, isNull);
    expect(closed, true);
  }

  testWidgets('edit form sends displayed server version and does not silently rebase a conflict',(tester) async {
    await http.runWithClient(() async {
      await open(tester,editItem:{'serial':1,'amount':10,'statement':'old','date':'2026-11-22','treasury':'A','category':'Income','updated_at':'2026-11-22T09:00:00'});
      await tester.ensureVisible(find.text('تعديل الإذن'));
      await tester.tap(find.text('تعديل الإذن'));await drain(tester);
      expect(server.posts.single['base_updated_at'],'2026-11-22T09:00:00');
      expect(find.textContaining('تغيّر السجل'),findsOneWidget);
      await tester.pump(const Duration(milliseconds:300));
      await expectLater(find.byType(Scaffold),matchesGoldenFile('goldens/journal_edit_conflict.png'));
      expect(server.posts.length,1);
      expect(tester.widgetList<TextField>(find.byType(TextField)).first.controller!.text,'10');
      await finish(tester);
    },()=>MockClient((request) async {
      if (request.method=='POST') {server.posts.add(Map<String,dynamic>.from(jsonDecode(request.body)));return j.respond('{}',409);}
      if (request.url.path.contains('/save-status/')) return j.respond('{}',404);
      return server.handle(request);
    }));
  });
  testWidgets('actual workbook picker import resumes lost response without duplicate rows',(tester) async {
    final workbook=xlsx.Excel.createExcel();
    final sheet=workbook[workbook.getDefaultSheet()!];
    sheet.appendRow(['المبلغ','البيان','التصنيف','التاريخ','الخزينة'].map((v)=>xlsx.TextCellValue(v)).toList());
    for (final value in [10,20]) { sheet.appendRow([xlsx.IntCellValue(value),xlsx.TextCellValue('import$value'),xlsx.TextCellValue('Income'),xlsx.TextCellValue('2026-11-22'),xlsx.TextCellValue('A')]); }
    FilePicker.platform=WorkbookPicker(Uint8List.fromList(workbook.encode()!));
    PermissionsService().debugSetPermissionsForTest({'حركة الخزينة':{'ادخال اذون':true,'المعاينة':true,'التعديل':true,'شاشات الارصدة':true,'استيراد من اكسل':true}},role:'employee',branches:['B1']);
    var lose=true;
    await http.runWithClient(() async {
      await open(tester);
      tester.widgetList<TextField>(find.byType(TextField)).last.controller!.text='2026-11-22';
      Future<void> import() async {
        await tester.tap(find.byIcon(Icons.upload_file));await tester.pumpAndSettle();
        await tester.tap(find.text('موافق واختيار الملف'));await drain(tester);await drain(tester);
      }
      await import();
      expect(server.rows.length,1,reason:tester.widgetList<Text>(find.byType(Text)).map((t)=>t.data).join(" | "));
      expect(find.textContaining('لم يكتمل الاستيراد'),findsOneWidget);
      await expectLater(find.byType(DailyPage),matchesGoldenFile('goldens/journal_import_uncertain.png'));
      lose=false;
      await import();
      expect(server.rows.length,2);
      expect(server.posts.length,2);
      expect(Hive.box(JournalImportBatch.boxName).isEmpty,true);
      expect(tester.takeException(),isNull);
      await finish(tester);
    },()=>MockClient((request) async {
      if (request.method=='POST' && request.url.path.endsWith('/transactions/save')) {
        final response=await server.handle(request);
        if (lose) throw const SocketException('lost import reply');
        return response;
      }
      if (request.method=='GET' && request.url.path.contains('/save-status/') && lose) throw const SocketException('status unavailable');
      return server.handle(request);
    }));
  });
  testWidgets(
      'restored manual intention is visible and frozen, with no automatic POST',
      (tester) async {
    final value = pendingIntent();
    await tester.runAsync(() => store().save(value));
    await http.runWithClient(() async {
      await open(tester);
      expect(server.posts, isEmpty);
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.first.controller!.text, '10.0');
      expect(fields.first.enabled, false);
      expect(fields[1].controller!.text, 'pending test');
      expect(find.text('تأكيد الحفظ السابق'), findsOneWidget);
      await expectLater(find.byType(DailyPage),
          matchesGoldenFile('goldens/journal_pending_narrow.png'));
      expect(tester.takeException(), isNull);
      await finish(tester);
    }, () => MockClient(server.handle));
  });
  for (final layout in [(320.0, false), (390.0, true), (1280.0, false)]) {
    testWidgets(
        'pending recovery remains readable at ${layout.$1} dark=${layout.$2}',
        (tester) async {
      await tester.runAsync(() => store().save(pendingIntent()));
      await http.runWithClient(() async {
        await open(tester, width: layout.$1, dark: layout.$2);
        await expectLater(
            find.byType(DailyPage),
            matchesGoldenFile(
                'goldens/journal_pending_${layout.$1.toInt()}_${layout.$2 ? 'dark' : 'light'}.png'));
        expect(tester.takeException(), isNull);
        expect(server.posts, isEmpty);
        await finish(tester);
      }, () => MockClient(server.handle));
    });
  }
  testWidgets(
      'retry button uses original operation, then clears confirmed form for a distinct voucher',
      (tester) async {
    final value = pendingIntent();
    await tester.runAsync(() => store().save(value));
    await http.runWithClient(() async {
      await open(tester);
      await tester.ensureVisible(find.text('تأكيد الحفظ السابق'));
      await tester.tap(find.text('تأكيد الحفظ السابق'));
      await drain(tester);
      expect(server.posts.length, 1);
      expect(server.posts.single['operation_id'], value.operationId);
      expect(server.statusReads, 1);
      expect(server.rows.length, 1);
      expect(
          tester
              .widgetList<TextField>(find.byType(TextField))
              .first
              .controller!
              .text,
          '');
      expect(find.text('حفظ'), findsOneWidget);
      expect(
          await store().load(
              ownerUid: 'uid-A',
              companyCode: 'C1',
              branchCode: 'B1',
              serial: 0),
          isNull);
      expect(tester.takeException(), isNull);
      await finish(tester);
    }, () => MockClient(server.handle));
  });
  testWidgets(
      'unconfirmed save keeps the same frozen form and explicit confirmation button',
      (tester) async {
    final value = pendingIntent();
    await tester.runAsync(() => store().save(value));
    server.mode = '500';
    await http.runWithClient(() async {
      await open(tester);
      await tester.ensureVisible(find.text('تأكيد الحفظ السابق'));
      await tester.tap(find.text('تأكيد الحفظ السابق'));
      await drain(tester);
      expect(find.text('تأكيد الحفظ السابق'), findsOneWidget);
      expect(tester.widgetList<TextField>(find.byType(TextField)).first.enabled,
          false);
      expect(
          (await store().load(
                  ownerUid: 'uid-A',
                  companyCode: 'C1',
                  branchCode: 'B1',
                  serial: 0))!
              .operationId,
          value.operationId);
      expect(server.rows, isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester);
    }, () => MockClient(server.handle));
  });
}
