import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;
  
  // فتح صندوق الحركات المالي الخاص باليومية لـ Hive
  final Box _transactionBox = Hive.box('daily_transactions_box');

  // 1. جلب الأرصدة التراكمية من الخزائن المتكودة محلياً في الـ Hive
  Future<Map<String, dynamic>> getDailySummaryLocal(String companyCode, {String? branch}) async {
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
          
          if (branch != null && branch != "كل الفروع" && tx['branch'] != branch) {
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
    required String branch,
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
          'branch': branch,
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
            'branch': branch,
          };

          // استبدل هذا السطر: await _transactionBox.put(assignedSerial, transactionData);
          // بهذا الكود:
          String safeBranch = branch.replaceAll(" ", "_").replaceAll("/", "-");
          String uniqueId = "${safeBranch}_$assignedSerial";
          await _transactionBox.put(uniqueId, transactionData);

          // تشغيل المزامنة التلقائية التراكمية
          await syncCacheFromServer(companyCode, assignedSerial);

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
            // استبدل سطر الحفظ بهذا:
            String b = item['branch'] ?? "الفرع الرئيسي";
            String safeBranch = b.replaceAll(" ", "_").replaceAll("/", "-");
            await _transactionBox.put("${safeBranch}_${item['serial']}", Map<String, dynamic>.from(item));
          }
        }
      }
    } catch (e) {
      print("خطأ في المزامنة الخلفية: $e");
    }
  }

  // 4. جلب سجل الأذون التاريخي (ذكياً من Hive أولاً ثم فلترة بالتاريخ)
  // 4. جلب سجل الأذون التاريخي (ذكياً من Hive أولاً ثم فلترة بالتاريخ)
  // 4. جلب سجل الأذون التاريخي (ذكياً من Hive أولاً ثم فلترة بالتاريخ والفرع)
  Future<List<dynamic>> getTransactionsHistory(String companyCode, String startDate, String endDate, {String? branch}) async {
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
            // استبدل سطر الحفظ (داخل الـ for loop الخاص بـ serverData) بهذا:
            String b = item['branch'] ?? "الفرع الرئيسي";
            String safeBranch = b.replaceAll(" ", "_").replaceAll("/", "-");
            await _transactionBox.put("${safeBranch}_${item['serial']}", item);
          }
          resultData = serverData;
        } else {
          throw 'خطأ من السيرفر: ${response.statusCode}';
        }
      }

      // 🌟 السحر هنا: فلترة الهيستوري بناءً على الفرع المختار قبل إرجاع القائمة
      if (branch != null && branch != "كل الفروع") {
        resultData = resultData.where((tx) => tx['branch'] == branch).toList();
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

      if (branch != null && branch != "كل الفروع") {
        fallbackData = fallbackData.where((tx) => tx['branch'] == branch).toList();
      }
      return fallbackData;
    }
  }

  Future<void> deleteTransaction(String companyCode, int serial, String branch) async {
    try {
      String encodedBranch = Uri.encodeComponent(branch);
      final response = await http.delete(
        Uri.parse('$baseUrl/transactions/delete/$companyCode/$encodedBranch/$serial'),
      );

      if (response.statusCode == 200) {
        String safeBranch = branch.replaceAll(" ", "_").replaceAll("/", "-");
        await _transactionBox.delete("${safeBranch}_$serial");
        await syncCacheFromServer(companyCode, serial);
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
}