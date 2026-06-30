import 'dart:async'; // ✅ إضافة هذا الاستيراد لحل خطأ StreamSubscription
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Box _dailyBox = Hive.box('daily_transactions_box'); 
  
  // ✅ إضافة صندوق التكويد
  final Box _codingBox = Hive.box('coding_box');

  // ✅ إضافة اشتراك خاص بالتكويد (مع الحفاظ على الاشتراك العام لليوميات)
  StreamSubscription<QuerySnapshot>? _codingSubscription;

  // ================== القسم القديم (اليوميات) ==================
  // 1. فتح مجرى الاستماع المركزي (خاص باليوميات)
  Future<Stream<QuerySnapshot>> startGlobalListener(String companyCode) async {
    final prefs = await SharedPreferences.getInstance();
    
    // جلب آخر وقت تم التحديث فيه
    final int? lastSyncMillis = prefs.getInt('last_sync_$companyCode');
    
    print("📡 بدء رادار المزامنة اللحظية لشركة: $companyCode");
    
    // 🌟 توجيه الرادار لمسار الأرشيف الأساسي مباشرة لتوفير الكتابة في الباك إند
    Query query = _firestore
        .collection('transactions')
        .doc(companyCode)
        .collection('daily_records');

    if (lastSyncMillis != null) {
      Timestamp lastSyncTimestamp = Timestamp.fromMillisecondsSinceEpoch(lastSyncMillis);
      query = query.where('updated_at', isGreaterThan: lastSyncTimestamp);
      print("⏱️ استرجاع التحديثات فقط ما بعد: ${lastSyncTimestamp.toDate()}");
    } else {
      print("📥 أول تشغيل: سيتم تحميل بيانات الرادار.");
    }

    // 🌟 الحل الجذري: حفظ الوقت الحالي حتى لا يقرأ الداتا القديمة في الفتحة القادمة للتطبيق
    await prefs.setInt('last_sync_$companyCode', DateTime.now().millisecondsSinceEpoch);

    return query.snapshots();
  }

  // 2. معالجة الإضافة والتعديل (اليوميات)
  Future<void> processIncomingUpdate(String companyCode, String docId, Map<String, dynamic> updateData) async {
    if (updateData.isEmpty) return;

    Map<String, dynamic> tx = {
      'serial': int.tryParse(updateData['serial']?.toString() ?? '0') ?? 0,
      'amount': double.tryParse(updateData['amount']?.toString() ?? '0') ?? 0.0,
      'type': updateData['type'] ?? "وارد",
      'category': updateData['category'] ?? "غير محدد",
      'date': updateData['date'] ?? DateTime.now().toString(),
      'treasury': updateData['treasury'] ?? "الرئيسية",
      
      // 👈 تم التعديل: قراءة وتخزين كود الفرع بدلاً من اسمه (تم وضع 1 ككود افتراضي بدلاً من الفرع الرئيسي)
      'branch_code': updateData['branch_code']?.toString() ?? "1", 
      
      'employee': updateData['employee'] ?? "غير محدد",
      'statement': updateData['statement'] ?? "",
      'company_code': updateData['company_code']?.toString() ?? companyCode,
    };

    // الحفظ المباشر في Hive
    await _dailyBox.put(docId, tx);

    // تحديث الأرصدة الكلية فوراً لتسمع في كل الشاشات لحظياً
    await DailyService().getDailySummaryLocal(companyCode);
    
    print("🔄 الرادار: تم دمج/تحديث الإذن [$docId] بنجاح في الـ Hive.");
  }

  // 3. دالة الحذف الموضعي (اليوميات)
  Future<void> processIncomingDelete(String companyCode, String docId) async {
    if (_dailyBox.containsKey(docId)) {
      await _dailyBox.delete(docId);
      await DailyService().getDailySummaryLocal(companyCode);
      print("🗑️ الرادار: تم حذف الإذن [$docId] من الأجهزة المتصلة بنجاح.");
    }
  }

  // ================== إضافة دعم التكويد (بنفس النمط) ==================
  // 4. فتح مجرى الاستماع للتكويد
  Future<Stream<QuerySnapshot>> startCodingListener(String companyCode) async {
  final prefs = await SharedPreferences.getInstance();
  final int? lastCodingSync = prefs.getInt('last_coding_sync_$companyCode');
  
  print("📡 بدء رادار التكويد لشركة: $companyCode");
  
  Query query = _firestore
      .collectionGroup('coding')
      .where('company_code', isEqualTo: companyCode);

  if (lastCodingSync != null) {
    // جلب التحديثات الجديدة فقط!
    Timestamp lastSyncTimestamp = Timestamp.fromMillisecondsSinceEpoch(lastCodingSync);
    query = query.where('updated_at', isGreaterThan: lastSyncTimestamp);
  }

  // تحديث وقت آخر مزامنة
  await prefs.setInt('last_coding_sync_$companyCode', DateTime.now().millisecondsSinceEpoch);

  return query.snapshots();
}

  // 5. معالجة إضافة/تعديل التكويد
  Future<void> processCodingUpdate(String companyCode, String docId, Map<String, dynamic> data) async {
    if (data.isEmpty) return;

    final String category = data['category'] ?? '';
    if (category.isEmpty) {
      print("⚠️ تحديث تكويد بدون category، تم تجاهله.");
      return;
    }

    final String key = "${companyCode}_$category";
    List<Map<String, dynamic>> list = [];

    if (_codingBox.containsKey(key)) {
      list = List<Map<String, dynamic>>.from(_codingBox.get(key) as List);
    }

    // البحث عن العنصر حسب الكود (docId)
    final int index = list.indexWhere((item) => item['code'] == docId);
    if (index != -1) {
      list[index] = Map<String, dynamic>.from(data);
    } else {
      list.add(Map<String, dynamic>.from(data));
    }

    // ترتيب تصاعدي حسب الكود (كرقم)
    list.sort((a, b) {
      int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
      int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
      return aCode.compareTo(bCode);
    });

    await _codingBox.put(key, list);
    print("🔄 الرادار (التكويد): تم تحديث القسم [$category]، العنصر [$docId].");
  }

  // 6. معالجة حذف التكويد (من أي قسم)
  Future<void> _deleteCodingItemFromAllCategories(String companyCode, String docId) async {
    bool deleted = false;
    for (var key in _codingBox.keys) {
      if (key.toString().startsWith("${companyCode}_")) {
        final List<Map<String, dynamic>> list = List<Map<String, dynamic>>.from(_codingBox.get(key) as List);
        final int index = list.indexWhere((item) => item['code'] == docId);
        if (index != -1) {
          list.removeAt(index);
          await _codingBox.put(key, list);
          deleted = true;
          print("🗑️ الرادار (التكويد): تم حذف العنصر [$docId] من المفتاح [$key].");
          break;
        }
      }
    }
    if (!deleted) {
      print("⚠️ الرادار (التكويد): لم يتم العثور على العنصر [$docId] في أي قسم محلي.");
    }
  }

  // 7. دالة مساعدة للحذف من قسم معين (إذا عُرف)
  Future<void> processCodingDelete(String companyCode, String docId, String category) async {
    if (category.isEmpty) {
      await _deleteCodingItemFromAllCategories(companyCode, docId);
      return;
    }

    final String key = "${companyCode}_$category";
    if (!_codingBox.containsKey(key)) return;

    List<Map<String, dynamic>> list = List<Map<String, dynamic>>.from(_codingBox.get(key) as List);
    list.removeWhere((item) => item['code'] == docId);
    await _codingBox.put(key, list);
    print("🗑️ الرادار (التكويد): تم حذف العنصر [$docId] من القسم [$category].");
  }

  // 8. إلغاء جميع الاشتراكات (تم إضافتها للمساعدة)
  void disposeAll() {
    _codingSubscription?.cancel();
    _codingSubscription = null;
    // ملاحظة: الاشتراك العام (globalSyncSubscription) يُدار من main.dart، لذلك لا نلغيه هنا.
  }
}