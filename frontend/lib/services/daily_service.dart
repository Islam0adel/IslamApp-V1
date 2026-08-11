import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;
  
  // فتح صندوق الحركات المالي الخاص باليومية لـ Hive
  final Box _transactionBox = Hive.box('daily_transactions_box');

  // 1. جلب الأرصدة التراكمية من الخزائن المتكودة محلياً في الـ Hive
  Future<Map<String, dynamic>> getDailySummaryLocal(String companyCode, {String? branchCode}) async {
    try {
      final Box codingBox = Hive.box('coding_box');
      final String localKey = "${companyCode}_safes";
      
      List<String> activeTreasuries = [];
      if (codingBox.containsKey(localKey)) {
        final dynamic rawData = codingBox.get(localKey);
        if (rawData is List) {
          activeTreasuries = rawData
              .map((item) => item['name']?.toString() ?? "")
              .where((name) => name.isNotEmpty)
              .toList();
        }
      }

      Map<String, double> treasuryBalances = {};
      for (var name in activeTreasuries) {
        treasuryBalances[name] = 0.0;
      }

      List<dynamic> allTx = _transactionBox.values.toList();
      
      // 🌟 التعديل السحري: ترتيب آمن جداً يمنع الـ Crash لو السيريال مش رقم صريح
      allTx.sort((a, b) => 
        (int.tryParse(a['serial']?.toString() ?? '0') ?? 0)
        .compareTo(int.tryParse(b['serial']?.toString() ?? '0') ?? 0)
      );

      for (var tx in allTx) {
        if (tx['company_code'] == companyCode) {
          
          // 👈 تم التعديل: الفلترة باستخدام branch_code وتجاهل كلمات التحديد العام
          if (branchCode != null && !['الكل', 'كل الفروع', 'all', ''].contains(branchCode) && tx['branch_code'] != branchCode) {
            continue; 
          }

          String tName = tx['treasury'] ?? "";
          double amt = double.tryParse(tx['amount']?.toString() ?? '0.0') ?? 0.0;
          String type = tx['type'] ?? "وارد";

          if (treasuryBalances.containsKey(tName)) {
            if (type == "وارد") {
              treasuryBalances[tName] = treasuryBalances[tName]! + amt;
            } else if (type == "صادر") {
              treasuryBalances[tName] = treasuryBalances[tName]! - amt;
            }
          }
        }
      }

      // 🌟 تحديث الـ Hive اللحظي من قلب الدالة عشان الشاشة تقرأ الرصيد فوراً وميصفرش
      await Hive.box('daily_transactions_box').put("${companyCode}_balances", treasuryBalances);

      return {
        "status": "success",
        "balances": treasuryBalances,
      };
    } catch (e) {
      print("خطأ في حساب الأرصدة: $e");
      return {"status": "error", "balances": {}};
    }
  }

  // جلب جميع اليوميات من السيرفر (بدون تحديد نطاق تاريخ)
  Future<List<dynamic>> fetchAllTransactions(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=2020-01-01&end_date=2100-12-31'),
      );
      if (response.statusCode == 200) {
        List<dynamic> serverData = jsonDecode(response.body);
        // تخزين في Hive بنفس المفاتيح المستخدمة (branch_code + serial)
        for (var item in serverData) {
          String bCode = item['branch_code']?.toString() ?? '1';
          await _transactionBox.put("branch_${bCode}_${item['serial']}", item);
        }
        // تحديث الأرصدة
        await getDailySummaryLocal(companyCode);
        print("✅ تم جلب ${serverData.length} يومية من السيرفر وتخزينها محلياً");
        return serverData;
      } else {
        throw 'فشل جلب اليوميات من السيرفر';
      }
    } catch (e) {
      print("❌ فشل جلب جميع اليوميات: $e");
      rethrow;
    }
  }

  // ✅ المزامنة التزايدية لليوميات (تجلب فقط التغييرات منذ آخر مزامنة)
  // ✅ المزامنة التزايدية لليوميات
Future<void> syncChangesFromServer(String companyCode, [String? lastSync]) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncKey = '${ApiConstants.LAST_SYNC_DAILY}$companyCode';
    
    // إذا لم يُمرر lastSync، نقرأه من SharedPreferences
    final lastSyncValue = lastSync ?? prefs.getString(lastSyncKey);

    // إذا لم يكن هناك وقت سابق، نستدعي التحميل الكامل
    if (lastSyncValue == null) {
      await syncAllTransactions(companyCode);
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
      return;
    }

    final response = await http.get(
      Uri.parse('$baseUrl/transactions/changes/$companyCode?since=$lastSyncValue'),
    );
    if (response.statusCode == 200) {
      List<dynamic> changes = jsonDecode(response.body);
      for (var item in changes) {
        String bCode = item['branch_code']?.toString() ?? '1';
        await _transactionBox.put("branch_${bCode}_${item['serial']}", item);
      }
      // تحديث الأرصدة
      await getDailySummaryLocal(companyCode);
      await prefs.setString(lastSyncKey, DateTime.now().toIso8601String());
      print("✅ تم مزامنة ${changes.length} تحديث لليوميات");
    } else {
      print("⚠️ فشل المزامنة التزايدية لليوميات، كود: ${response.statusCode}");
    }
  } catch (e) {
    print("❌ خطأ في المزامنة التزايدية لليوميات: $e");
  }
}

  // 2. دالة حفظ أو تعديل حركة (ترسل للسيرفر وتحدث الـ Hive ذكياً)
  Future<Map<String, dynamic>> saveTransaction({
    required String companyCode,
    required int serial,
    required String treasury,
    required double amount,
    required String statement,
    required String category,
    required String date,
    required String type,
    String? employee,
    required String branchCode, // 👈 تم التعديل هنا
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/transactions/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'company_code': companyCode,
          'serial': serial, 
          'treasury': treasury,
          'amount': amount,
          'statement': statement,
          'category': category,
          'date': date,
          'type': type,
          'employee': employee ?? "غير محدد",
          'branch_code': branchCode, // 👈 تم التعديل هنا
        }),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> result = jsonDecode(response.body);
        if (result['status'] == 'success') {
          int assignedSerial = result['serial'];

          Map<String, dynamic> transactionData = {
            'company_code': companyCode,
            'serial': assignedSerial,
            'treasury': treasury,
            'amount': amount,
            'statement': statement,
            'category': category,
            'date': date,
            'type': type,
            'employee': employee ?? "غير محدد",
            'branch_code': branchCode, // 👈 تم التعديل هنا
          };
          
          // 👈 تم التعديل: توحيد الآي دي ليتطابق مع ما تم إنشاؤه في الباك إند
          String uniqueId = "branch_${branchCode}_$assignedSerial";
          print("🚀 Sending to server: company_code=$companyCode, branch_code=$branchCode");
          // تحديث الإذن محلياً في الـ Hive
          await _transactionBox.put(uniqueId, transactionData);

          // 🌟 هنمنع الدالة دي تشتغل لو بنعدل إذن قديم عشان متسحبش كل الأذون اللي بعده من الفايربيز
          if (serial == 0) {
            // تشغيل المزامنة التلقائية التراكمية في حالة الإضافة الجديدة فقط
            // await syncCacheFromServer(companyCode, assignedSerial);
          }

          return {"success": true, "serial": assignedSerial};
        }
      }
      throw 'حدث خطأ أثناء الحفظ بالسيرفر';
    } catch (e) {
      throw 'فشل عملية الحفظ: $e';
    }
  }

  // 3. المزامنة الذكية التراكمية بناءً على رقم إذن معين لتحديث باقي المستخدمين
  Future<void> syncCacheFromServer(String companyCode, int fromSerial) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/updates/$companyCode/$fromSerial'),
      );

      if (response.statusCode == 200) {
        List<dynamic> updates = jsonDecode(response.body);
        for (var item in updates) {
          if (item is Map && item.containsKey('serial')) {
            // 👈 تم التعديل: إنشاء الآي دي بناءً على كود الفرع القادم من السيرفر
            String bCode = item['branch_code']?.toString() ?? "1";
            await _transactionBox.put("branch_${bCode}_${item['serial']}", Map<String, dynamic>.from(item));
          }
        }
      }
    } catch (e) {
      print("خطأ في المزامنة الخلفية: $e");
    }
  }

  // 4. جلب سجل الأذون التاريخي (ذكياً من Hive أولاً ثم فلترة بالتاريخ والفرع)
  Future<List<dynamic>> getTransactionsHistory(String companyCode, String startDate, String endDate, {String? branchCode}) async {
    try {
      List<dynamic> resultData = [];

      if (_transactionBox.isNotEmpty) {
        List<dynamic> localData = _transactionBox.values
            .where((tx) =>
                tx['company_code'] == companyCode &&
                tx['date'].toString().compareTo(startDate) >= 0 &&
                tx['date'].toString().compareTo(endDate) <= 0)
            .toList();
        
        if (localData.isNotEmpty) {
          resultData = localData;
        }
      }

      if (resultData.isEmpty) {
        final response = await http.get(
          Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=$startDate&end_date=$endDate'),
        );

        if (response.statusCode == 200) {
          List<dynamic> serverData = jsonDecode(response.body);
          for (var item in serverData) {
            // 👈 تم التعديل: إنشاء الآي دي بناءً على كود الفرع 
            String bCode = item['branch_code']?.toString() ?? "1";
            await _transactionBox.put("branch_${bCode}_${item['serial']}", item);
          }
          resultData = serverData;
        } else {
          throw 'خطأ من السيرفر: ${response.statusCode}';
        }
      }

      // 🌟 السحر هنا: فلترة الهيستوري بناءً على كود الفرع
      if (branchCode != null && !['الكل', 'كل الفروع', 'all', ''].contains(branchCode)) {
        resultData = resultData.where((tx) => tx['branch_code'] == branchCode).toList();
      }

      return resultData;

    } catch (e) {
      // حائط الصد عند انقطاع الإنترنت (مع تطبيق فلترة الفروع أيضاً)
      List<dynamic> fallbackData = _transactionBox.values
          .where((tx) =>
              tx['company_code'] == companyCode &&
              tx['date'].toString().compareTo(startDate) >= 0 &&
              tx['date'].toString().compareTo(endDate) <= 0)
          .toList();

      if (branchCode != null && !['الكل', 'كل الفروع', 'all', ''].contains(branchCode)) {
        fallbackData = fallbackData.where((tx) => tx['branch_code'] == branchCode).toList();
      }
      return fallbackData;
    }
  }

  // 5. عند الحذف
  Future<void> deleteTransaction(String companyCode, int serial, String branchCode) async { // 👈 تم التعديل هنا
    try {
      // 👈 تم التعديل: الرابط بيستقبل الكود بدل الاسم
      final response = await http.delete(
        Uri.parse('$baseUrl/transactions/delete/$companyCode/$branchCode/$serial'),
      );

      if (response.statusCode == 200) {
        // 👈 تم التعديل: التعديل المحلي المباشر بناءً على المعرف المطابق للباك إند
        String docId = "branch_${branchCode}_$serial";
        
        await _transactionBox.delete(docId); // حذف محلي فوراً
        
        // تحديث الأرصدة المحلية فوراً لتسمع في الواجهات بناءً على البيانات الجديدة في الـ Hive
        await getDailySummaryLocal(companyCode); 
      } else {
        throw 'فشل حذف الحركة من السيرفر';
      }
    } catch (e) {
      throw 'خطأ أثناء الحذف: $e';
    }
  }

  // 6. جلب آخر سيريال محلياً
  int getLastLocalSerial(String companyCode) {
    var localTx = _transactionBox.values
        .where((e) => e is Map && e['company_code'] == companyCode)
        .toList();
    if (localTx.isEmpty) return 0;
    localTx.sort((a, b) => (a['serial'] as int).compareTo(b['serial'] as int));
    return localTx.last['serial'] as int;
  }

  // 7. دالة لجلب جميع الحركات من السيرفر (بدون تحديد فترة زمنية) - تستخدم للتحميل الكامل
  Future<void> syncAllTransactions(String companyCode) async {
    try {
      // استخدم نطاق زمني واسع جداً لضمان جلب كل البيانات
      final startDate = '2020-01-01';
      final endDate = '2100-12-31';
      
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=$startDate&end_date=$endDate'),
      );

      if (response.statusCode == 200) {
        List<dynamic> serverData = jsonDecode(response.body);
        for (var item in serverData) {
          // استخدام نفس مفتاح التخزين الموحد (branch_code + serial)
          String bCode = item['branch_code']?.toString() ?? '1';
          await _transactionBox.put("branch_${bCode}_${item['serial']}", item);
        }
        // بعد التخزين، نحدث الأرصدة المحلية فوراً
        await getDailySummaryLocal(companyCode);
        print("✅ تم مزامنة جميع الحركات من السيرفر بنجاح (عدد: ${serverData.length})");
      } else {
        throw 'فشل جلب البيانات من السيرفر';
      }
    } catch (e) {
      print("❌ خطأ في مزامنة جميع الحركات: $e");
      // لا نرمي استثناء حتى لا نوقف التطبيق، فقط نسجل الخطأ
    }
  }
}