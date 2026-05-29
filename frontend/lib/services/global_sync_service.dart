import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Box _dailyBox = Hive.box('daily_transactions_box'); 

  // 1. فتح مجرى الاستماع المركزي للحركات المحدثة من الفايربيز
  Stream<QuerySnapshot> startGlobalListener(String companyCode) {
    print("📡 بدء رادار المزامنة اللحظية لشركة: $companyCode");
    return _firestore
        .collection('companies')
        .doc(companyCode)
        .collection('live_updates')
        .snapshots();
  }

  // 2. معالجة الإضافة والتعديل الموضعي بدقة متناهية
  Future<void> processIncomingUpdate(String companyCode, String docId, Map<String, dynamic> updateData) async {
    if (updateData.isEmpty) return;

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
      'company_code': updateData['company_code']?.toString() ?? companyCode,
    };

    // 🌟 2. الحفظ المباشر والوحيد في الـ Hive باستخدام docId 
    // هذا يمنع التكرار تماماً ويتوافق 100% مع الباك إند
    await _dailyBox.put(docId, tx);

    // 🌟 3. تحديث الأرصدة الكلية فوراً لتسمع في كل الشاشات لحظياً
    await DailyService().getDailySummaryLocal(companyCode);
    
    print("🔄 الرادار: تم دمج/تحديث الإذن [$docId] بنجاح.");
  }

  // 3. دالة الحذف الموضعي الذكية
  Future<void> processIncomingDelete(String companyCode, String docId) async {
    // 🌟 الحذف المباشر من الـ Hive باستخدام المعرف الموحد (الفرع + السيريال)
    await _dailyBox.delete(docId);

    // إعادة حساب الأرصدة للأجهزة المتصلة لكي يتم خصم/رد رصيد الإذن المحذوف
    await DailyService().getDailySummaryLocal(companyCode);
    
    print("🗑️ الرادار: تم حذف الإذن [$docId] من الأجهزة المتصلة بنجاح.");
  }
}