import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Box _dailyBox = Hive.box('daily_transactions_box'); 

  // 1. فتح مجرى الاستماع المركزي (المعدل ذكياً)
  Future<Stream<QuerySnapshot>> startGlobalListener(String companyCode) async {
    final prefs = await SharedPreferences.getInstance();
    
    // جلب آخر وقت تم التحديث فيه
    final int? lastSyncMillis = prefs.getInt('last_sync_$companyCode');
    
    print("📡 بدء رادار المزامنة اللحظية لشركة: $companyCode");
    
    Query query = _firestore
        .collection('companies')
        .doc(companyCode)
        .collection('live_updates');

    // 🔥 لو التطبيق اتفتح قبل كدة، فلتر البيانات بناءً على الوقت فقط!
    if (lastSyncMillis != null) {
      Timestamp lastSyncTimestamp = Timestamp.fromMillisecondsSinceEpoch(lastSyncMillis);
      query = query.where('updated_at', isGreaterThan: lastSyncTimestamp);
      print("⏱️ استرجاع التحديثات فقط ما بعد: ${lastSyncTimestamp.toDate()}");
    } else {
      print("📥 أول تشغيل: سيتم تحميل كافة بيانات الرادار وتخزينها.");
    }

    return query.snapshots();
  }

  // 2. معالجة الإضافة والتعديل والحذف الوهمي
  // 2. معالجة الإضافة والتعديل والحذف الموضعي بدقة متناهية
  Future<void> processIncomingUpdate(String companyCode, String docId, Map<String, dynamic> updateData) async {
    if (updateData.isEmpty) return;

    // 🔥 1. الفحص السحري: إذا لقط الرادار أن الحقل "is_deleted" قيمته true
    // فهذا يعني أن الباك إند أرسل إشارة حذف وهمي (Soft Delete) من الرادار
    if (updateData['is_deleted'] == true) {
      print("🗑️ الرادار: تم التقاط إشارة حذف للإذن [$docId]. جاري مسحه من قاعدة بيانات الموبايل...");
      
      // مسح الحركة فوراً من صندوق الـ Hive المحلي لكي تختفي من الواجهة
      await _dailyBox.delete(docId);
      
      // إعادة حساب وتحديث الأرصدة الكلية فوراً لتسمع في كل الشاشات لحظياً
      await DailyService().getDailySummaryLocal(companyCode);
      
      print("✅ الرادار: تم مسح الإذن [$docId] محلياً بنجاح.");
      return; // إنهاء الدالة هنا لأن الإذن تم حذفه ولا نريد إعادة حفظه بالأسفل
    }

    // 2. تنظيف وتجهيز البيانات (في حالة الإضافة أو التعديل الطبيعي)
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

    // 🌟 3. الحفظ المباشر والوحيد في الـ Hive باستخدام docId لضمان عدم التكرار
    await _dailyBox.put(docId, tx);

    // 🌟 4. تحديث الأرصدة الكلية فوراً لتسمع في كل الشاشات لحظياً
    await DailyService().getDailySummaryLocal(companyCode);
    
    print("🔄 الرادار: تم دمج/تحديث الإذن [$docId] بنجاح في الـ Hive.");
  }

  // 3. دالة الحذف الموضعي
  Future<void> processIncomingDelete(String companyCode, String docId) async {
    if (_dailyBox.containsKey(docId)) {
      await _dailyBox.delete(docId);
      await DailyService().getDailySummaryLocal(companyCode);
      print("🗑️ الرادار: تم حذف الإذن [$docId] من الأجهزة المتصلة بنجاح.");
    }
  }
}