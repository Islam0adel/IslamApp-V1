import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DailyService {
  final String baseUrl = ApiConstants.baseUrl;

  // 1. جلب الأرصدة (نقدي وفيزا) مضافاً إليها الفرع النشط
  Future<Map<String, dynamic>> getDailySummary(String companyCode, String? treasury, String branch) async {
    try {
      String url = '$baseUrl/transactions/summary/$companyCode?branch=${Uri.encodeComponent(branch)}';
      if (treasury != null && treasury.isNotEmpty) {
        url += '&treasury=${Uri.encodeComponent(treasury)}';
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) return jsonDecode(response.body);
      throw 'فشل جلب ملخص الأرصدة';
    } catch (e) {
      throw 'خطأ في الاتصال بالسيرفر: $e';
    }
  }

  // 2. حفظ حركة جديدة وتحديث الكاش المباشر للمستخدم الحالي (متوافق مع التزامن وبدون قراءات مكررة)
  Future<void> saveTransaction({
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

      // 1. حفظ الإذن في قاعدة البيانات عن طريق الباك إند
      final response = await http.post(
        Uri.parse('$baseUrl/transactions/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(transactionData),
      );

      if (response.statusCode != 200) {
        throw 'حدث خطأ أثناء الحفظ: ${response.body}';
      }

      // 2. تحديث سريع ومحلي جداً لكاش جهاز هذا المستخدم فوراً للحفاظ على استجابة الشاشة السريعة
      try {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys();
        
        for (String key in keys) {
          if (key.startsWith('cached_history_${companyCode}_')) {
            final cachedString = prefs.getString(key);
            if (cachedString != null && cachedString.isNotEmpty) {
              List<dynamic> localList = jsonDecode(cachedString) as List<dynamic>;
              
              int existingIndex = localList.indexWhere((item) => item['serial'] == serial);
              
              if (existingIndex != -1) {
                localList[existingIndex] = transactionData;
              } else {
                if (key.contains(date) || key.endsWith(date)) {
                  localList.add(transactionData);
                }
              }
              
              // إعادة الترتيب التنازلي التلقائي وحفظ الكاش المحلى لنفس الجهاز
              localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
              await prefs.setString(key, jsonEncode(localList));
            }
          }
        }
      } catch (cacheError) {
        print('خطأ جانبي في تحديث كاش الحفظ السريع: $cacheError');
      }

    } catch (e) {
      throw 'فشل عملية الحفظ: $e';
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

  // 4. جلب سجل الحركات (النسخة النهائية الفائقة: تزامن لـ 3 مستخدمين + معالجة المحذوفات تلقائياً + كشف التصفير الشامل)
  Future<List<dynamic>> getTransactionsHistory(String companyCode, String startDate, String endDate) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String cacheKey = 'cached_history_${companyCode}_${startDate}_$endDate';

      List<dynamic> localList = [];
      int lastSyncSerial = 0;

      // 1. قراءة الكاش المحلي ومعرفة أعلى سيريال واصلين له
      if (prefs.containsKey(cacheKey)) {
        final cachedString = prefs.getString(cacheKey);
        if (cachedString != null && cachedString.isNotEmpty) {
          localList = jsonDecode(cachedString) as List<dynamic>;
          if (localList.isNotEmpty) {
            lastSyncSerial = localList.map((item) => int.parse(item['serial'].toString())).reduce((a, b) => a > b ? a : b);
          }
        }
      }

      // 2. جلب الحركات الجديدة والتعديلات فقط من السيرفر
      final response = await http.get(
        Uri.parse('$baseUrl/transactions/list/$companyCode?start_date=$startDate&end_date=$endDate&last_sync_serial=$lastSyncSerial'),
      );

      if (response.statusCode == 200) {
        final List<dynamic> newIncomingData = jsonDecode(response.body) as List<dynamic>;

        // دمج الحركات الجديدة أو المعدلة بداخل الكاش
        if (newIncomingData.isNotEmpty) {
          for (var newItem in newIncomingData) {
            int existingIndex = localList.indexWhere((localItem) => localItem['serial'] == newItem['serial']);
            if (existingIndex != -1) {
              localList[existingIndex] = newItem;
            } else {
              localList.add(newItem);
            }
          }
        }

        // 3. 🟢 تنظيف المحذوفات (IDs Checker): فحص المطابقة السريع
        final serialsResponse = await http.get(
          Uri.parse('$baseUrl/transactions/active_serials/$companyCode?start_date=$startDate&end_date=$endDate'),
        );
        
        if (serialsResponse.statusCode == 200) {
          final Map<String, dynamic> serialsData = jsonDecode(serialsResponse.body);
          final List<dynamic> serverActiveSerials = serialsData['active_serials'] ?? [];
          
          // مسح أي إذن موجود في الكاش المحلي ولكنه غير موجود في قائمة السيرفر الحالية (لأنه حُذف من مستخدم آخر)
          localList.removeWhere((localItem) {
            int localSerial = int.parse(localItem['serial'].toString());
            return !serverActiveSerials.contains(localSerial);
          });
        }

        // 🔥 4. الخاصية الجديدة الذكية (كشف التصفير الشامل):
        // إذا أعاد السيرفر مصفوفة فارغة، وكانت قائمة السيريالات النشطة على السيرفر فارغة تماماً أيضاً،
        // والكاش المحلي لا يزال يحتوي على أذون قديمة، فهذا يعني برمجياً أن البيانات تم تصفيرها من السيرفر.
        // نقوم فوراً بتطهير الكاش المحلي ليتطابق مع السيرفر.
        if (response.body == "[]" && localList.isNotEmpty) {
          // نقوم بعمل فحص إضافي للتأكد أن السيرفر صفر تماماً وليس مجرد عدم وجود حركات جديدة
          final lastSerialResponse = await http.get(Uri.parse('$baseUrl/transactions/last_serial/$companyCode'));
          if (lastSerialResponse.statusCode == 200) {
            final int serverLastSerial = jsonDecode(lastSerialResponse.body)['last_serial'] ?? 0;
            if (serverLastSerial == 0) {
              print('🚨 ذكاء التطبيق: تم كشف عملية تصفير كاملة على السيرفر! جاري تفريغ الكاش المحلي...');
              localList = []; 
            }
          }
        }

        // ترتيب تنازلي وحفظ الكاش المحدث والنظيف تماماً
        localList.sort((a, b) => int.parse(b['serial'].toString()).compareTo(int.parse(a['serial'].toString())));
        await prefs.setString(cacheKey, jsonEncode(localList));

        return localList;
      } else {
        if (localList.isNotEmpty) return localList;
        throw 'خطأ من السيرفر: ${response.statusCode}';
      }
    } catch (e) {
      print('تحذير في جلب الحركات والمطابقة: $e');
      throw 'فشل جلب سجل الحركات: $e';
    }
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