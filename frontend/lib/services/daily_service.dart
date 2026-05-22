import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;

  // ================= 1. جلب الأرصدة (محلياً بالكامل ومتزامن مع النبضة) =================
  Future<Map<String, dynamic>> getDailySummary(String companyCode, String? treasury, String branch) async {
    final prefs = await SharedPreferences.getInstance();
    final String cacheKey = 'cached_summary_${companyCode}_$branch';

    // إذا لم يتوفر اتصال أو لم يكن هناك تحديث جديد، يعود بالكاش المحلي فوراً (صفر قراءة للفايربيز)
    if (prefs.containsKey(cacheKey)) {
      final cachedString = prefs.getString(cacheKey);
      if (cachedString != null && cachedString.isNotEmpty) {
        return jsonDecode(cachedString) as Map<String, dynamic>;
      }
    }

    try {
      String url = '$baseUrl/transactions/summary/$companyCode?branch=${Uri.encodeComponent(branch)}';
      if (treasury != null && treasury.isNotEmpty) url += '&treasury=${Uri.encodeComponent(treasury)}';
      
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await prefs.setString(cacheKey, response.body); // حفظ الأرصدة محلياً
        return jsonDecode(response.body);
      }
      throw 'فشل جلب ملخص الأرصدة';
    } catch (e) {
      if (prefs.containsKey(cacheKey)) {
        return jsonDecode(prefs.getString(cacheKey)!) as Map<String, dynamic>;
      }
      throw 'خطأ في الاتصال بالسيرفر: $e';
    }
  }

  // ================= حفظ حركة وتحديث كاش السيريال والأرصدة وجلبها فوراً للشاشة =================
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
      final Map<String, dynamic> transactionData = {
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
      };

      final response = await http.post(
        Uri.parse('$baseUrl/transactions/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(transactionData),
      );

      if (response.statusCode != 200) throw 'حدث خطأ أثناء الحفظ: ${response.body}';

      final prefs = await SharedPreferences.getInstance();
      
      // 1. تحديث كاش السيريال المباشر محلياً للحركة القادمة
      await prefs.setInt('cached_serial_${companyCode}_$branch', serial + 1);

      // 2. حقن الحركة في كاش السجل اليومي فوراً
      final String historyKey = 'cached_history_${companyCode}_${date}_$date';
      List<dynamic> localList = [];
      if (prefs.containsKey(historyKey)) {
        localList = jsonDecode(prefs.getString(historyKey) ?? '[]') as List<dynamic>;
      }
      localList.removeWhere((item) => item['serial'] == serial);
      localList.add(transactionData);
      localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
      await prefs.setString(historyKey, jsonEncode(localList));

      // 3. مسح كاش ملخص الأرصدة القديم تماماً لإجبار المنظومة على التحديث
      final keys = prefs.getKeys();
      for (String key in keys) {
        if (key.startsWith('cached_summary_${companyCode}_')) {
          await prefs.remove(key);
        }
      }

      // جلب الأرصدة المحدثة والمنضبطة من السيرفر فوراً وحفظها في الكاش الجديد
      String summaryUrl = '$baseUrl/transactions/summary/$companyCode?branch=${Uri.encodeComponent(branch)}';
      if (treasury.isNotEmpty) summaryUrl += '&treasury=${Uri.encodeComponent(treasury)}';
      
      final summaryResponse = await http.get(Uri.parse(summaryUrl));
      if (summaryResponse.statusCode == 200) {
        final String summaryCacheKey = 'cached_summary_${companyCode}_$branch';
        await prefs.setString(summaryCacheKey, summaryResponse.body);
        return jsonDecode(summaryResponse.body) as Map<String, dynamic>;
      }

      return {"cash_balance": 0.0, "visa_balance": 0.0};
    } catch (e) {
      throw 'فشل عملية الحفظ والتحديث: $e';
    }
  }

  // 5. تعديل إذن قديم وإعادة ضبط الأرصدة التراكمية في الباك إند وتحديث الكاش المحلي فوراً
  Future<void> updateTransaction({
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
      final Map<String, dynamic> transactionData = {
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
      };

      // 1. إرسال طلب التعديل للرابط الجديد المستقل باستخدام PUT
      final response = await http.put(
        Uri.parse('$baseUrl/transactions/update'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(transactionData),
      );

      if (response.statusCode != 200) {
        throw 'حدث خطأ أثناء التعديل: ${response.body}';
      }

      // 2. تحديث كاش الجهاز الحالي فوراً ليعكس التعديل على الشاشة في نفس اللحظة
      try {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys();
        
        for (String key in keys) {
          if (key.startsWith('cached_history_${companyCode}_')) {
            final cachedString = prefs.getString(key);
            if (cachedString != null && cachedString.isNotEmpty) {
              List<dynamic> localList = jsonDecode(cachedString) as List<dynamic>;
              
              // البحث عن مكان الإذن القديم لتحديثه بالبيانات الجديدة
              int existingIndex = localList.indexWhere((item) => item['serial'] == serial);
              
              if (existingIndex != -1) {
                localList[existingIndex] = transactionData;
                
                // ترتيب الكاش وحفظه مجدداً
                localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
                await prefs.setString(key, jsonEncode(localList));
              }
            }
          }
        }
      } catch (cacheError) {
        print('خطأ جانبي في تحديث كاش التعديل السريع: $cacheError');
      }

    } catch (e) {
      throw 'فشل عملية التعديل: $e';
    }
  }

  // 3. جلب آخر سيريال
  Future<int> getLastSerial(String companyCode) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/last_serial/$companyCode'),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['last_serial'] ?? 0;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  // ================= 3. المحرك الذكي الرئيسي: القراءة المحلية وفحص نبض الشبكة اللحظي =================
Future<List<dynamic>> getTransactionsHistory(String companyCode, String startDate, String endDate) async {
  final prefs = await SharedPreferences.getInstance();
  final String historyKey = 'cached_history_${companyCode}_${startDate}_$endDate';
  final String lastSyncKey = 'last_network_sync_time_$companyCode';

  // 1. جلب الكاش الموجود حالياً
  List<dynamic> localList = [];
  if (prefs.containsKey(historyKey)) {
    localList = jsonDecode(prefs.getString(historyKey) ?? '[]') as List<dynamic>;
  }

  try {
    // فحص نبض الشبكة لمعرفة هل حدث أي تغيير
    final syncResponse = await http.get(Uri.parse('$baseUrl/transactions/sync_check/$companyCode')).timeout(const Duration(seconds: 4));
    
    if (syncResponse.statusCode == 200) {
      final Map<String, dynamic> syncData = jsonDecode(syncResponse.body);
      String serverLastUpdate = syncData['last_update_timestamp'] ?? '';
      String localLastSync = prefs.getString(lastSyncKey) ?? '';

      if (serverLastUpdate != localLastSync) {
        String timeParam = localList.isEmpty ? "" : localLastSync;

        // 3. نطلب من السيرفر التحديثات بناءً على الوقت فائق الدقة
        final response = await http.get(Uri.parse('$baseUrl/transactions/delta_sync/$companyCode?last_sync_time=$timeParam'));

        if (response.statusCode == 200) {
          final List<dynamic> newUpdates = jsonDecode(response.body) as List<dynamic>;

          // 4. الدمج الذكي بالتناغم مع التوقيت
          for (var update in newUpdates) {
            int index = localList.indexWhere((item) => item['serial'].toString() == update['serial'].toString());
            if (index != -1) {
              localList[index] = update; // تم تحديث إذن معدل في مكانه
            } else {
              localList.add(update); // تم إضافة إذن جديد
            }
          }

          // 🌟 4.5 [ماكينة الحسابات المحلية المحصنة]: إعادة توازن الأرصدة داخل كاش الموبايل
          // نرتب القائمة تصاعدياً مؤقتاً لتبدأ الحساب التراكمي من أقدم إذن لأحدث إذن
          localList.sort((a, b) => int.parse(a['serial'].toString()).compareTo(int.parse(b['serial'].toString())));
          
          double runningCash = 0.0;
          double runningVisa = 0.0;

          for (int i = 0; i < localList.length; i++) {
            double amt = double.parse(localList[i]['amount'].toString());
            String cat = localList[i]['category'] ?? '';
            String txType = localList[i]['type'] ?? 'cash';

            // تحديد اتجاه الحركة بناءً على الكلمة (نفس منطق الباك إند تماماً)
            String direction = "صادر";
            if (cat == "تحويل من النقدي" || cat == "تحويل من الفيزا") {
              direction = "تحويل";
            } else if (RegExp(r'(وارد|إيراد|ايراد|فيزا|ايداع|إيداع|مبيعات)').hasMatch(cat.toLowerCase())) {
              direction = "وارد";
            }

            if (cat == "تحويل من النقدي") {
              runningCash -= amt;
              runningVisa += amt;
            } else if (cat == "تحويل من الفيزا") {
              runningCash += amt;
              runningVisa -= amt;
            } else {
              if (txType == "cash") {
                runningCash = (direction == "وارد") ? (runningCash + amt) : (runningCash - amt);
              } else if (txType == "visa") {
                runningVisa = (direction == "وارد") ? (runningVisa + amt) : (runningVisa - amt);
              }
            }

            // حقن الأرصدة المتسلسلة والمصححة داخل عنصر الكاش المحلي فوراً
            localList[i]['current_cash_balance'] = runningCash;
            localList[i]['current_visa_balance'] = runningVisa;
          }

          // 5. التنظيف (حذف ما تم حذفه من السيرفر نهائياً)
          final serialsResponse = await http.get(Uri.parse('$baseUrl/transactions/active_serials/$companyCode?start_date=$startDate&end_date=$endDate'));
          if (serialsResponse.statusCode == 200) {
            final Map<String, dynamic> serialsData = jsonDecode(serialsResponse.body);
            final List<dynamic> active = serialsData['active_serials'] ?? [];
            localList.removeWhere((item) => !active.contains(int.parse(item['serial'].toString())));
          }

          // 6. إعادة ترتيب القائمة تنازلياً للعرض المثالي في جدول الهيستوري
          localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
          await prefs.setString(historyKey, jsonEncode(localList));
          await prefs.setString(lastSyncKey, serverLastUpdate);

          // 7. مسح كاش ملخص الأرصدة القديم
          final keys = prefs.getKeys();
          for (String key in keys) {
            if (key.startsWith('cached_summary_${companyCode}_')) {
              await prefs.remove(key);
            }
          }
        }
      }
    }
  } catch (e) {
    print('⚠️ خطأ مزامنة: $e');
  }

  // فرز نهائي تنازلي للتأكد من سلامة المعاينة تحت أي ظرف
  localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
  return localList;
}

  // 5. حذف حركة مالية نهائياً
  Future<void> deleteTransaction(String companyCode, int serial) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/transactions/delete/$companyCode/$serial'),
      );
      if (response.statusCode != 200) {
        throw 'فشل حذف الحركة من السيرفر';
      }
    } catch (e) {
      throw 'خطأ أثناء الحذف: $e';
    }
  }
}