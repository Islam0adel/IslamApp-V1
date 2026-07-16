import 'dart:async'; // ✅ إضافة هذا الاستيراد لحل خطأ StreamSubscription
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';   
import 'daily_service.dart';    

class GlobalSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ✅ استبدال الحقول بـ getters لتأخير الوصول إلى Hive حتى بعد فتح الصناديق
  Box get _dailyBox => Hive.box('daily_transactions_box');
  Box get _codingBox => Hive.box('coding_box');

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
  // 4. فتح مجرى الاستماع للتكويد (بالمسار المسطح النظيف)
  Future<Stream<QuerySnapshot>> startCodingListener(String companyCode) async {
    final prefs = await SharedPreferences.getInstance();
    final int? lastCodingSync = prefs.getInt('last_coding_sync_$companyCode');
    
    print("📡 بدء رادار التكويد لشركة: $companyCode");
    
    // 🌟 استخدام المسار المباشر الجديد 
    Query query = _firestore
        .collection('coding_records')
        .where('company_code', isEqualTo: companyCode);

    if (lastCodingSync != null) {
      // جلب التحديثات الجديدة فقط باستخدام حقل الوقت
      Timestamp lastSyncTimestamp = Timestamp.fromMillisecondsSinceEpoch(lastCodingSync);
      query = query.where('updated_at', isGreaterThan: lastSyncTimestamp);
    }

    // تحديث وقت آخر مزامنة
    await prefs.setInt('last_coding_sync_$companyCode', DateTime.now().millisecondsSinceEpoch);

    return query.snapshots();
  }

  Future<void> processCodingUpdate(String companyCode, String docId, Map<String, dynamic> data) async {
  if (data.isEmpty) return;

  // تنظيف البيانات (لحل مشكلة Timestamp)
  Map<String, dynamic> sanitizedData = Map<String, dynamic>.from(data);
  sanitizedData.forEach((key, value) {
    if (value is Timestamp) {
      sanitizedData[key] = value.toDate().toIso8601String();
    }
  });

  final String category = sanitizedData['category'] ?? '';
  if (category.isEmpty) return;

  final String key = "${companyCode}_$category";
  List<Map<String, dynamic>> list = [];

  // قراءة القائمة الحالية من Hive
  if (_codingBox.containsKey(key)) {
    final rawData = _codingBox.get(key);
    if (rawData is List) {
      list = rawData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    }
  }

  // 🔥 التعديل المهم: استخدام `data['code']` للمقارنة بدلاً من `docId`
  final String itemCode = sanitizedData['code']?.toString() ?? '';
  if (itemCode.isEmpty) {
    print("⚠️ تحديث تكويد بدون code، تم تجاهله.");
    return;
  }

  // البحث عن العنصر باستخدام code
  int index = list.indexWhere((item) => item['code']?.toString() == itemCode);
  if (index != -1) {
    // تحديث العنصر الموجود
    list[index] = sanitizedData;
  } else {
    // إضافة عنصر جديد
    list.add(sanitizedData);
  }

  // تنظيف إضافي: إزالة أي تكرار قديم (احتياطي)
  final Map<String, Map<String, dynamic>> uniqueItems = {};
  for (var item in list) {
    String code = item['code']?.toString() ?? '';
    if (code.isNotEmpty) {
      uniqueItems[code] = item;
    }
  }
  list = uniqueItems.values.toList();

  // ترتيب تصاعدي
  list.sort((a, b) {
    int aCode = int.tryParse(a['code']?.toString() ?? '0') ?? 0;
    int bCode = int.tryParse(b['code']?.toString() ?? '0') ?? 0;
    return aCode.compareTo(bCode);
  });

  await _codingBox.put(key, list);
  print("🔄 الرادار: تم تحديث القسم [$category]، العنصر [$itemCode].");
}

  // 6. معالجة حذف التكويد (من أي قسم) - نسخة ويب آمنة 100%
  Future<void> _deleteCodingItemFromAllCategories(String docId) async {
    // 1. أخذ نسخة ثابتة من المفاتيح لتجنب أخطاء التعديل المتزامن أثناء الحذف
    final List<dynamic> keys = _codingBox.keys.toList();

    // 2. المرور على كل الأقسام المحفوظة في الـ Hive
    for (var key in keys) {
      final dynamic rawData = _codingBox.get(key);
      
      // التأكد أن البيانات عبارة عن قائمة
      if (rawData is List) {
        
        // 🌟 الحل الجذري: إنشاء قائمة جديدة تماماً بدون استخدام List.from
        final List<Map<String, dynamic>> safeList = [];
        
        // 3. تفريغ العناصر يدوياً (عنصر بعنصر) لتجنب أخطاء تحويل الأنواع في الويب
        for (var item in rawData) {
          if (item is Map) {
            final Map<String, dynamic> safeMap = {};
            
            // نقل المفاتيح والقيم يدوياً وتحويل المفتاح لنص صريح
            for (var k in item.keys) {
              safeMap[k.toString()] = item[k];
            }
            
            // إضافة العنصر السليم للقائمة الآمنة
            safeList.add(safeMap);
          }
        }

        // حفظ طول القائمة قبل محاولة الحذف لمعرفة هل تم حذف شيء أم لا
        int initialLength = safeList.length;

        // 4. حذف العنصر المطلوب بناءً على الكود
        safeList.removeWhere((item) {
          String itemCode = item['code']?.toString() ?? '';
          return itemCode == docId || docId.endsWith("_$itemCode");
        });

        // 5. إذا تم حذف العنصر (طول القائمة قل)، نقوم بتحديث الـ Hive
        if (safeList.length < initialLength) {
          await _codingBox.put(key, safeList);
          print("🗑️ الرادار: تم حذف العنصر من الذاكرة المحلية بأمان من القسم [$key].");
        }
      }
    }
  }
  // ================== دعم الجرد ==================

Future<Stream<QuerySnapshot>> startInventoryListener(String companyCode) async {
  final prefs = await SharedPreferences.getInstance();
  final int? lastSync = prefs.getInt('last_inventory_sync_$companyCode');

  Query query = _firestore
      .collection('inventory_records')
      .where('company_code', isEqualTo: companyCode);

  if (lastSync != null) {
    Timestamp lastTimestamp = Timestamp.fromMillisecondsSinceEpoch(lastSync);
    query = query.where('updated_at', isGreaterThan: lastTimestamp);
  }

  await prefs.setInt('last_inventory_sync_$companyCode', DateTime.now().millisecondsSinceEpoch);
  return query.snapshots();
}

Future<void> processInventoryUpdate(String companyCode, String docId, Map<String, dynamic> data) async {
  if (data.isEmpty) return;

  // تنظيف Timestamp
  Map<String, dynamic> sanitized = Map.from(data);
  sanitized.forEach((key, value) {
    if (value is Timestamp) {
      sanitized[key] = value.toDate().toIso8601String();
    }
  });

  final box = Hive.box('inventory_box');
  // مفتاح التخزين المحلي: companyCode_branchCode_storeCode_date
  final branchCode = sanitized['branch_code'] ?? '';
  final storeCode = sanitized['store_code'] ?? '';
  final date = sanitized['date'] ?? '';
  final localKey = '${companyCode}_${branchCode}_${storeCode}_$date';

  List<Map<String, dynamic>> list = [];
  if (box.containsKey(localKey)) {
    final raw = box.get(localKey);
    if (raw is List) {
      list = raw.map((e) => Map<String, dynamic>.from(e)).toList();
    }
  }

  // إزالة أي عنصر له نفس doc_id وتحديثه
  list.removeWhere((e) => e['doc_id'] == docId);
  list.add(sanitized);

  await box.put(localKey, list);
  print('🔄 الرادار: تحديث الجرد [$docId]');
}

Future<void> processInventoryDelete(String companyCode, String docId) async {
  final box = Hive.box('inventory_box');
  final keys = box.keys.toList();
  for (var key in keys) {
    final raw = box.get(key);
    if (raw is List) {
      final updated = raw.where((e) => e['doc_id'] != docId).toList();
      if (updated.length != raw.length) {
        await box.put(key, updated);
        break;
      }
    }
  }
  print('🗑️ الرادار: حذف الجرد [$docId]');
}

  // 7. دالة مساعدة للحذف من قسم معين (إذا عُرف) - نسخة ويب آمنة بدون List.from
  Future<void> processCodingDelete(String companyCode, String docId, String category) async {
    if (category.isEmpty) {
      await _deleteCodingItemFromAllCategories(docId);
      return;
    }

    final String key = "${companyCode}_$category";
    if (!_codingBox.containsKey(key)) return;

    final dynamic rawData = _codingBox.get(key);
    
    if (rawData is List) {
      // 🌟 إنشاء قائمة جديدة صريحة لتجنب تحويلات Dart2JS الداخلية
      final List<Map<String, dynamic>> safeList = [];
      
      // تفريغ العناصر يدوياً تماماً
      for (int i = 0; i < rawData.length; i++) {
        final dynamic item = rawData[i];
        if (item is Map) {
          final Map<String, dynamic> safeMap = {};
          item.forEach((k, v) {
            safeMap[k.toString()] = v;
          });
          safeList.add(safeMap);
        }
      }
          
      int initialLength = safeList.length;

      // البحث عن العنصر ومسحه باستخدام الكود
      safeList.removeWhere((item) => item['code']?.toString() == docId.toString());
      
      // حفظ القائمة الجديدة في الذاكرة المحلية
      if (safeList.length < initialLength) {
        await _codingBox.put(key, safeList);
        print("🗑️ الرادار (التكويد): تم حذف العنصر [$docId] من القسم [$category] بنجاح.");
      }
    }
  }

  // 8. إلغاء جميع الاشتراكات (تم إضافتها للمساعدة)
  void disposeAll() {
    _codingSubscription?.cancel();
    _codingSubscription = null;
    // ملاحظة: الاشتراك العام (globalSyncSubscription) يُدار من main.dart، لذلك لا نلغيه هنا.
  }
}