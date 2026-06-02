import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Box _dailyBox = Hive.box('daily_transactions_box'); 

  // 1. فتح مجرى الاستماع المركزي
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

  // 2. معالجة الإضافة والتعديل
  Future<void> processIncomingUpdate(String companyCode, String docId, Map<String, dynamic> updateData) async {
    if (updateData.isEmpty) return;

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
      'company_code': updateData['company_code']?.toString() ?? companyCode,
    };

    // الحفظ المباشر في Hive
    await _dailyBox.put(docId, tx);

    // تحديث الأرصدة الكلية فوراً لتسمع في كل الشاشات لحظياً
    await DailyService().getDailySummaryLocal(companyCode);
    
    print("🔄 الرادار: تم دمج/تحديث الإذن [$docId] بنجاح في الـ Hive.");
  }

  // 3. دالة الحذف الموضعي (سيتم استدعاؤها تلقائياً عند الحذف من الباك إند)
  Future<void> processIncomingDelete(String companyCode, String docId) async {
    if (_dailyBox.containsKey(docId)) {
      await _dailyBox.delete(docId);
      await DailyService().getDailySummaryLocal(companyCode);
      print("🗑️ الرادار: تم حذف الإذن [$docId] من الأجهزة المتصلة بنجاح.");
    }
  }
}