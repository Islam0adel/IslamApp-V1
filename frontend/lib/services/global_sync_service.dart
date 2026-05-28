import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // 🌟 صندوق الهيف الأساسي المتطابق مع الماين بالملي
  final Box _dailyBox = Hive.box('daily_transactions_box'); 

  // 1. فتح مجرى الاستماع المركزي للحركات المحدثة من الفايربيز
  Stream<QuerySnapshot> startGlobalListener(String companyCode) {
    print("📡 محاولة بدء الاستماع لـ: $companyCode");
    
    return _firestore
        .collection('companies')
        .doc(companyCode)
        .collection('live_updates')
        .snapshots()
        ..listen((data) {
          print("✅ الاستماع يعمل! تم استقبال تحديث.");
        }, onError: (e) {
          print("❌ خطأ في الاستماع: $e");
        });
  }

  // 2. معالجة الإضافة والتعديل الموضعي
  Future<void> processIncomingUpdate(String companyCode, Map<String, dynamic> updateData) async {
  // 1. تنظيف وتجهيز البيانات
  Map<String, dynamic> tx = {
    'serial': int.tryParse(updateData['serial']?.toString() ?? '0') ?? 0,
    'amount': double.tryParse(updateData['amount']?.toString() ?? '0') ?? 0.0,
    'type': updateData['type'] ?? "وارد",
    'category': updateData['category'] ?? "غير محدد",
    'date': updateData['date'] ?? DateTime.now().toString(),
    'treasury': updateData['treasury'] ?? "الرئيسية",
    'branch': updateData['branch'] ?? "الفرع الرئيسي",
    'employee': updateData['employee'] ?? "غير محدد",
    'statement': updateData['statement'] ?? "",
    'company_code': updateData['company_code']?.toString() ?? companyCode.toString(),
  };

  int targetSerial = tx['serial'];

  final String historyKey = "${companyCode}_history_data";
  List<dynamic> localRaw = _dailyBox.get(historyKey, defaultValue: []);
  List<Map<String, dynamic>> localList = localRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

  // 2. تحديث أو إضافة الإذن في القائمة
  int index = localList.indexWhere((e) => int.tryParse(e['serial'].toString()) == targetSerial);
  
  if (index != -1) {
    localList[index] = tx; 
    print("🔄 تم تحديث الإذن رقم $targetSerial في الـ Hive التاريخي");
  } else {
    localList.add(tx);
    print("➕ تم إضافة الإذن رقم $targetSerial في الـ Hive التاريخي");
  }

  // 3. ترتيب القائمة التاريخية للبث
  localList.sort((a, b) => (b['serial'] as int).compareTo(a['serial'] as int));

  // 🌟 4. التعديل الجوهري لتوحيد البيانات: 
  // نحفظ الإذن منفصلاً بمفتاحه الرقمي لكي تراه وتجمعه دالة الأرصدة الشاملة بدقة
  String safeBranch = tx['branch'].toString().replaceAll(" ", "_").replaceAll("/", "-");
  String uniqueId = "${safeBranch}_$targetSerial";
  await _dailyBox.put(uniqueId, tx);

  // 5. الحفظ النهائي لقائمة المعاينة والتاريخ
  await _dailyBox.put(historyKey, localList);
  
  // 🌟 6. السحر هنا: بدلاً من حساب أرصدة مبتورة من قائمة البث فقط، نقوم باستدعاء 
  // الدالة الشاملة والمركزية لتقوم بجمع كل الحركات (القديمة المجلوبة والسحابية والجديدة) معاً
  await DailyService().getDailySummaryLocal(companyCode);
  
  print("✅ تم دمج الإذن وتحديث الأرصدة الكلية والنهائية بنجاح.");
}

  // 3. 🌟 دالة الحذف الموضعي الذكية (تم إدخالها داخل الكلاس وضبط مفتاح الـ Hive الخاص بك)
  Future<void> processIncomingDelete(String companyCode, int targetSerial) async {
    final String historyKey = "${companyCode}_history_data"; // 🌟 تم تعديل المفتاح هنا أيضاً ليتطابق تماماً
    
    List<dynamic> localRaw = _dailyBox.get(historyKey, defaultValue: []);
    List<Map<String, dynamic>> localList = localRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

    // حذف الإذن المستهدف فقط بناءً على السيريال
    localList.removeWhere((e) => int.tryParse(e['serial'].toString()) == targetSerial);

    // إعادة حساب الأرصدة للحركات المتبقية محلياً (الآن ستعمل بدون أي إيرور)
    Map<String, double> updatedBalances = _recalculateBalances(localList);

    // حفظ التحديثات النهائية بعد الحذف في الـ Hive
    await _dailyBox.put(historyKey, localList);
    await _dailyBox.put("${companyCode}_balances", updatedBalances);
    
    print("🗑️ الرادار: تم حذف الإذن رقم $targetSerial محلياً وإعادة ضبط الأرصدة بنجاح.");
  }

  // 4. دالة الحسابات المحلية الذكية للأرصدة دون استهلاك إنترنت
  Map<String, double> _recalculateBalances(List<Map<String, dynamic>> list) {
    Map<String, double> balances = {};
    for (var row in list) {
      String treasury = row['treasury'] ?? "الرئيسية";
      double amount = double.tryParse(row['amount'].toString()) ?? 0.0;
      String type = row['type'] ?? "وارد";

      if (!balances.containsKey(treasury)) balances[treasury] = 0.0;
      if (type == "وارد") {
        balances[treasury] = balances[treasury]! + amount;
      } else if (type == "صادر") {
        balances[treasury] = balances[treasury]! - amount;
      }
    }
    return balances;
  }
} // 🌟 هنا نهاية الكلاس الصحيحة تماماً وبدون أي أقواس عشوائية بالأسفل