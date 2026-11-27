// frontend/lib/services/coding_service.dart
import 'cache_partitions.dart';

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/coding_model.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'staged_changes.dart';
import 'sync_read_access.dart';
import 'permissions_service.dart';
import 'read_authorization_snapshot.dart';

// خدمة الترميز: تجلب بيانات الترميز وتخزنها محليًا وتزامنها مع الخادم
class CodingService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;

  // ============================================================
  // Hive
  // ============================================================

  // يعيد صندوق الترميز المحلي
  Box get _codingBox => CachePartitions.box('coding_box');

  // ============================================================
  // الأقسام
  // ============================================================

  final List<String> categories = const [
    'safes',
    'types',
    'branches',
    'stores',
    'suppliers',
    'customers',
    'payment_methods',
    'items',
    // ✅ employees انتقل لـ EmployeeService
  ];

  // ============================================================
  // 1. جلب قائمة قسم من Hive أو السيرفر
  //
  // مهم:
  // هذه الدالة ليست مسؤولة عن المزامنة المركزية.
  //
  // لو البيانات موجودة في Hive:
  //     لا API
  //
  // لو غير موجودة:
  //     GET /coding/list
  //
  // أما المزامنة العادية عند تشغيل البرنامج فتتم عن طريق:
  // syncChangesFromServer()
  // ============================================================

  // يجلب قائمة الترميز للشركة من التخزين المحلي
  Future<List<CodingModel>> getCodingList({
    required String companyCode,
    required String category,
  }) async {
    return CachePartitions.run(() async {
      final String localKey = "${companyCode}_$category";

      // ----------------------------------------------------------
      // 1) Hive
      // ----------------------------------------------------------

      if (_codingBox.containsKey(localKey)) {
        final dynamic rawData = _codingBox.get(localKey);

        if (rawData is List) {
          print(
            "⚡ التكويد [$category] من Hive",
          );

          final List<CodingModel> result = [];

          for (final item in rawData) {
            if (item is! Map) {
              continue;
            }

            final map = Map<String, dynamic>.from(item);

            // لا نعرض المحذوف
            if (map['is_deleted'] == true) {
              continue;
            }

            try {
              result.add(
                CodingModel.fromMap(map),
              );
            } catch (e) {
              print(
                "⚠️ خطأ في تحويل تكويد [$category]: $e",
              );
            }
          }

          return result;
        }
      }

      // ----------------------------------------------------------
      // 2) السيرفر
      //
      // هذا يحدث فقط إذا لم توجد بيانات محلية.
      // ----------------------------------------------------------

      print(
        "⚠️ لا توجد بيانات محلية للقسم [$category]، "
        "جاري تحميله من السيرفر...",
      );

      try {
        final response = await AuthHttp.get(
          Uri.parse(
            "$baseUrl/coding/list/"
            "$companyCode/$category",
          ),
        );

        if (response.statusCode != 200) {
          print(
            "❌ خطأ من السيرفر [$category]: "
            "${response.statusCode}",
          );

          return [];
        }

        final List<dynamic> decodedData = jsonDecode(response.body);

        final List<Map<String, dynamic>> cleanList = [];

        for (final item in decodedData) {
          if (item is! Map) {
            continue;
          }

          final map = Map<String, dynamic>.from(item);

          if (map['is_deleted'] == true) {
            continue;
          }

          map['is_deleted'] = false;

          cleanList.add(map);
        }

        cleanList.sort(
          (a, b) {
            final int aCode = int.tryParse(
                  a['code']?.toString() ?? '0',
                ) ??
                0;

            final int bCode = int.tryParse(
                  b['code']?.toString() ?? '0',
                ) ??
                0;

            return aCode.compareTo(
              bCode,
            );
          },
        );

        await _codingBox.put(
          localKey,
          cleanList,
        );

        print(
          "✅ تم جلب [$category] من السيرفر "
          "وحفظه في Hive (${cleanList.length})",
        );

        return cleanList
            .map(
              (item) => CodingModel.fromMap(item),
            )
            .toList();
      } catch (e) {
        print(
          "❌ فشل الاتصال بالسيرفر [$category]: $e",
        );

        return [];
      }
    });
  }

  // ============================================================
  // 2. Full Sync للتكويد
  //
  // يستخدم فقط:
  // lastSync == null
  //
  // جهاز جديد = نعم
  // جهاز قديم = لا
  // ============================================================

  // يجلب كل بيانات الترميز من الخادم ويخزنها محليًا
  Future<void> fetchAllCoding(
    String companyCode,
  ) async {
    return CachePartitions.run(() async {
      print(
        "📥 التكويد: بدء FULL SYNC "
        "للشركة $companyCode",
      );

      final v2Candidate = await _captureV2(companyCode);

      try {
        // ✅ 1) جلب كل الأقسام بالتوازي
        final responses = await Future.wait(
          categories.map(
            (category) async {
              try {
                return await AuthHttp.get(
                  Uri.parse(
                    '$baseUrl/coding/list/'
                    '$companyCode/$category',
                  ),
                );
              } catch (_) {
                return null;
              }
            },
          ),
        );

        // ✅ 2) معالجة النتائج بالترتيب (نفس الأصل)
        for (int i = 0; i < categories.length; i++) {
          final category = categories[i];
          final response = responses[i];

          if (response == null) {
            throw Exception(
              'فشل الاتصال بالسيرفر [$category]',
            );
          }

          if (response.statusCode != 200) {
            throw Exception(
              'فشل تحميل التكويد [$category]. '
              'HTTP ${response.statusCode}: '
              '${response.body}',
            );
          }

          final List<dynamic> data = jsonDecode(response.body);

          final List<Map<String, dynamic>> list = [];

          for (final item in data) {
            if (item is! Map) {
              continue;
            }

            final map = Map<String, dynamic>.from(item);

            // المحذوف لا يدخل Hive
            if (map['is_deleted'] == true) {
              continue;
            }

            map['is_deleted'] = false;

            list.add(map);
          }

          // ------------------------------------------------------
          // ترتيب
          // ------------------------------------------------------

          list.sort(
            (a, b) {
              final int aCode = int.tryParse(
                    a['code']?.toString() ?? '0',
                  ) ??
                  0;

              final int bCode = int.tryParse(
                    b['code']?.toString() ?? '0',
                  ) ??
                  0;

              return aCode.compareTo(
                bCode,
              );
            },
          );

          final String localKey = "${companyCode}_$category";

          await _codingBox.put(
            localKey,
            list,
          );

          print(
            "✅ FULL SYNC: [$category] "
            "(${list.length})",
          );
        }

        print(
          "✅ اكتمل FULL SYNC للتكويد "
          "للشركة $companyCode",
        );

        await _commitV2(companyCode, v2Candidate);
      } catch (e) {
        print(
          "❌ فشل FULL SYNC للتكويد: $e",
        );

        rethrow;
      }
    });
  }

  // ============================================================
  // 3. المزامنة التزايدية للتكويد
  //
  // lastSync موجود:
  //     /coding/changes
  //
  // لا يوجد تحميل كامل.
  // ============================================================

  // يزامن تغييرات الترميز من الخادم
  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    return CachePartitions.run(() async {
      final prefs = await CachePartitions.preferences();

      final String lastSyncKey = '${ApiConstants.LAST_SYNC_CODING}$companyCode';

      final String? lastSyncValue = lastSync ??
          prefs.getString(
            lastSyncKey,
          );

      // ==========================================================
      // جهاز جديد
      // ==========================================================

      if (lastSyncValue == null || lastSyncValue.isEmpty) {
        print(
          "📥 التكويد: لا يوجد lastSync "
          "→ FULL SYNC",
        );

        await fetchAllCoding(
          companyCode,
        );

        // حفظ وقت المزامنة بعد النجاح
        await prefs.setString(
          lastSyncKey,
          DateTime.now().toUtc().toIso8601String(),
        );

        return;
      }

      // ==========================================================
      // جهاز قديم
      // ==========================================================

      print(
        "📡 التكويد: INCREMENTAL SYNC "
        "منذ $lastSyncValue",
      );

      try {
        final v2Candidate = await _captureV2(companyCode);

        // The server feed was re-applied since this device last reconciled (rollback + re-apply
        // creates a new epoch; changes made while it was off were never stamped). The stored
        // checkpoint says nothing about that gap, so reconcile with one full sync. This fires only on
        // an epoch change, not periodically.
        final String? storedEpoch = prefs.getString(v2EpochKey(companyCode));
        if (v2Candidate != null &&
            storedEpoch != null &&
            storedEpoch != v2Candidate.epoch) {
          print("📥 التكويد: feed epoch changed → FULL SYNC");
          final startedAt = DateTime.now().toUtc();
          await fetchAllCoding(companyCode);
          await prefs.setString(lastSyncKey, startedAt.toIso8601String());
          return;
        }

        final DateTime syncStartedAt = DateTime.now().toUtc();

        // --------------------------------------------------------
        // نستخدم UTC
        // --------------------------------------------------------

        final DateTime sinceDt = DateTime.parse(
          lastSyncValue,
        ).toUtc();

        final String effectiveSince = sinceDt.toIso8601String();

        // --------------------------------------------------------
        // ✅ 1) جلب كل التغييرات بالتوازي
        // --------------------------------------------------------

        final responses = await Future.wait(
          categories.map(
            (category) async {
              try {
                return await AuthHttp.get(
                  Uri.parse(
                    '$baseUrl/coding/changes/'
                    '$companyCode'
                    '?category=$category'
                    '&since=$effectiveSince',
                  ),
                );
              } catch (_) {
                return null;
              }
            },
          ),
        );

        // --------------------------------------------------------
        // ✅ 2) معالجة كل قسم بالترتيب (نفس الأصل)
        // --------------------------------------------------------

        for (int i = 0; i < categories.length; i++) {
          final category = categories[i];
          final response = responses[i];

          if (response == null) {
            throw Exception(
              'فشل الاتصال بالسيرفر [$category]',
            );
          }

          if (response.statusCode != 200) {
            throw Exception(
              'فشل مزامنة التكويد [$category]. '
              'HTTP ${response.statusCode}: '
              '${response.body}',
            );
          }

          final List<dynamic> changes = jsonDecode(
            response.body,
          );

          // ------------------------------------------------------
          // لا يوجد تغييرات في القسم
          // ------------------------------------------------------

          if (changes.isEmpty) {
            print(
              "⏭️ [$category] لا يوجد تغييرات",
            );

            continue;
          }

          await _applyCategoryChanges(companyCode, category, changes);

          print(
            "✅ تم تحديث [$category] "
            "(${changes.length} تغيير)",
          );
        }

        // ========================================================
        // حفظ lastSync
        //
        // فقط بعد نجاح كل الأقسام
        // ========================================================

        await prefs.setString(
          lastSyncKey,
          syncStartedAt.toIso8601String(),
        );

        print(
          "✅ اكتملت INCREMENTAL SYNC للتكويد",
        );

        await _commitV2(companyCode, v2Candidate);
      } catch (e) {
        // مهم جدًا:
        // لا نحرك lastSync إذا أي قسم فشل.
        print(
          "❌ فشل INCREMENTAL SYNC للتكويد: $e",
        );

        rethrow;
      }
    });
  }

  // يطبق تغييرات فئة واحدة على القائمة المحلية ويحفظها
  /// Applies one category's change list to the local list and saves it. Moved out of
  /// syncChangesFromServer unchanged so the live incremental sync and a staged apply share it.
  Future<void> _applyCategoryChanges(
    String companyCode,
    String category,
    List<dynamic> changes,
  ) async {
    final String localKey = '${companyCode}_$category';

    // ------------------------------------------------------
    // قراءة القائمة المحلية
    // ------------------------------------------------------

    List<Map<String, dynamic>> currentList = [];

    if (_codingBox.containsKey(
      localKey,
    )) {
      final dynamic raw = _codingBox.get(
        localKey,
      );

      if (raw is List) {
        currentList = raw
            .whereType<Map>()
            .map(
              (e) => Map<String, dynamic>.from(e),
            )
            .where(
              (e) => e['is_deleted'] != true,
            )
            .toList();
      }
    }

    // ------------------------------------------------------
    // تطبيق التغييرات
    // ------------------------------------------------------

    for (final item in changes) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic> map = Map<String, dynamic>.from(
        item,
      );

      final String action = map['action']?.toString() ??
          (map['is_deleted'] == true ? 'delete' : 'update');

      final String? code = map['code']?.toString();

      if (code == null || code.isEmpty) {
        print(
          "⚠️ تحديث تكويد بدون code "
          "[$category]",
        );

        continue;
      }

      // ----------------------------------------------------
      // حذف السجل من القائمة المحلية
      // ----------------------------------------------------

      currentList.removeWhere(
        (e) => e['code']?.toString() == code,
      );

      // ----------------------------------------------------
      // DELETE
      // ----------------------------------------------------

      if (action == 'delete' || map['is_deleted'] == true) {
        print(
          "🗑️ حذف تكويد [$category/$code]",
        );

        continue;
      }

      // ----------------------------------------------------
      // INSERT / UPDATE
      // ----------------------------------------------------

      map.remove(
        'action',
      );

      map['is_deleted'] = false;

      currentList.add(
        map,
      );

      print(
        "✅ تحديث تكويد "
        "[$category/$code]",
      );
    }

    // ------------------------------------------------------
    // إزالة أي تكرارات
    // ------------------------------------------------------

    final Map<String, Map<String, dynamic>> uniqueItems = {};

    for (final item in currentList) {
      final code = item['code']?.toString() ?? '';

      if (code.isNotEmpty) {
        uniqueItems[code] = item;
      }
    }

    currentList = uniqueItems.values.toList();

    // ------------------------------------------------------
    // ترتيب
    // ------------------------------------------------------

    currentList.sort(
      (a, b) {
        final int aCode = int.tryParse(
              a['code']?.toString() ?? '0',
            ) ??
            0;

        final int bCode = int.tryParse(
              b['code']?.toString() ?? '0',
            ) ??
            0;

        return aCode.compareTo(
          bCode,
        );
      },
    );

    // ------------------------------------------------------
    // حفظ
    // ------------------------------------------------------

    if (currentList.isEmpty) {
      await _codingBox.delete(
        localKey,
      );
    } else {
      await _codingBox.put(
        localKey,
        currentList,
      );
    }
  }

  // ============================================================
  // Closed-app sync (EXPERIMENT): commit-safe feed /coding/changes-v2.
  //
  // The v2 cursor is a checkpoint kept next to the v1 lastSync. It is captured BEFORE a successful
  // full or incremental v1 sync starts and stored only after that sync succeeded, so every change
  // committed after the capture is delivered by v2 and nothing falls between the two. If the
  // endpoint is not available (older server) nothing is stored and nothing is staged.
  // ============================================================

  /// Set by StagedInbox so the worker learns the new coding checkpoint.
  static void Function(String company)? onCheckpointChanged;

  // يعيد مفتاح مؤشر النسخة الثانية للمزامنة
  static String v2CursorKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}${company}_v2';

  // يعيد مفتاح عهد النسخة الثانية للمزامنة
  static String v2EpochKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}${company}_v2epoch';

  // يعيد مفتاح نطاق النسخة الثانية للمزامنة
  static String v2ScopeKey(String company) =>
      '${ApiConstants.LAST_SYNC_CODING}${company}_v2scope';

  // يلتقط مؤشر المزامنة ونطاقه وعهده قبل الجلب
  Future<({String cursor, String scope, String epoch})?> _captureV2(
      String company) async {
    try {
      final r = await AuthHttp.get(
              Uri.parse('$baseUrl/coding/changes-v2/$company?cursor=latest'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body);
      if (m is! Map ||
          m['invalid'] == true ||
          m['next_cursor'] is! String ||
          m['scope'] is! String ||
          (m['next_cursor'] as String).isEmpty ||
          (m['scope'] as String).isEmpty) return null;
      return (
        cursor: m['next_cursor'] as String,
        scope: m['scope'] as String,
        epoch: (m['epoch'] ?? '').toString()
      );
    } catch (_) {
      return null;
    }
  }

  // يثبّت المؤشر الملتقط بعد نجاح التطبيق
  Future<void> _commitV2(String company,
      ({String cursor, String scope, String epoch})? cand) async {
    if (cand == null) return;
    try {
      final prefs = await CachePartitions.preferences();
      await prefs.setString(v2CursorKey(company), cand.cursor);
      await prefs.setString(v2ScopeKey(company), cand.scope);
      await prefs.setString(v2EpochKey(company), cand.epoch);
      try {
        onCheckpointChanged?.call(company);
      } catch (_) {}
    } catch (_) {}
  }

  // يعيد نقطة تحقق للعمل المرحلي للشركة
  /// Checkpoint the worker continues from; null when none (or coding read access is not held now).
  Future<({String cursor, String scope})?> stagedCheckpoint(
      String company) async {
    try {
      if (!SyncReadAccess.allows('coding')) return null;
      final prefs = await CachePartitions.preferences();
      final c = prefs.getString(v2CursorKey(company));
      final s = prefs.getString(v2ScopeKey(company));
      if (c == null || c.isEmpty || s == null || s.isEmpty) return null;
      return (cursor: c, scope: s);
    } catch (_) {
      return null;
    }
  }

  static const _costFields = [
    'wholesale_price',
    'profit_margin',
    'profit_percent'
  ];

  // يحدد هل يحق للمستخدم عرض التكاليف
  bool _mayViewCosts() {
    final p = PermissionsService();
    return p.canBypassPermissions ||
        p.hasPermission('التكويد', 'سعر الشراء') ||
        p.hasPermission('المبيعات', 'عرض سعر الجملة') ||
        p.hasPermission('رصيد المخزون', 'عرض سعر الجملة');
  }

  // يطبق دفعة مرحلية واحدة من استجابة التغييرات
  /// Applies one /coding/changes-v2 response that the service worker fetched while the app was
  /// closed. It is applied only when it continues exactly from the stored cursor and scope, under
  /// the coding read right held NOW. Items go through the same per-category apply as the live
  /// incremental sync, except that an item older than the row already stored is skipped (the live
  /// sync may have brought a newer one). Returns true when applied and the cursor moved.
  Future<bool> applyStagedBatch(String company, dynamic decoded,
      {required String fromCursor, required String fromScope}) async {
    try {
      return await CachePartitions.run(() async {
        final epoch = ReadAuthorizationEpoch.value;
        if (!SyncReadAccess.allows('coding')) return false;
        final prefs = await CachePartitions.preferences();
        if (prefs.getString(v2CursorKey(company)) != fromCursor ||
            prefs.getString(v2ScopeKey(company)) != fromScope) return false;
        if (decoded is! Map ||
            decoded['invalid'] == true ||
            decoded['scope'] != fromScope ||
            decoded['next_cursor'] is! String ||
            (decoded['next_cursor'] as String).isEmpty ||
            decoded['items'] is! List) return false;
        final byCategory = <String, List<Map<String, dynamic>>>{};
        for (final raw in decoded['items'] as List) {
          if (raw is! Map) return false;
          final m = Map<String, dynamic>.from(raw);
          if (m['company_code'] != company) return false;
          final category = m['category']?.toString();
          if (category == null || !categories.contains(category)) continue;
          // Defense in depth: the server already projects costs by the caller's cost right (and the
          // scope fingerprint carries it), but a staged item must never put a cost field into Hive
          // when this client does not hold a cost right now.
          if (!_mayViewCosts()) {
            for (final f in _costFields) {
              if (m.containsKey(f)) m[f] = null;
            }
          }
          byCategory.putIfAbsent(category, () => []).add(m);
        }
        for (final e in byCategory.entries) {
          final stored = _codingBox.get('${company}_${e.key}');
          final localStamp = <String, DateTime?>{};
          if (stored is List) {
            for (final r in stored) {
              if (r is Map) {
                localStamp[r['code']?.toString() ?? ''] =
                    StagedChanges.stamp(r['updated_at']);
              }
            }
          }
          final fresh = <Map<String, dynamic>>[];
          for (final m in e.value) {
            final l = localStamp[m['code']?.toString() ?? ''];
            final i = StagedChanges.stamp(m['updated_at']);
            if (l != null && i != null && l.isAfter(i)) continue;
            fresh.add(m);
          }
          if (fresh.isEmpty) continue;
          if (!SyncReadAccess.allows('coding') ||
              epoch != ReadAuthorizationEpoch.value) return false;
          await _applyCategoryChanges(company, e.key, fresh);
        }
        if (!SyncReadAccess.allows('coding') ||
            epoch != ReadAuthorizationEpoch.value) return false;
        await prefs.setString(
            v2CursorKey(company), decoded['next_cursor'] as String);
        try {
          onCheckpointChanged?.call(company);
        } catch (_) {}
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // 4. حفظ أو تحديث تكويد
  // ============================================================

  // يحفظ كود ترميز جديد أو معدّل
  Future<Map<String, dynamic>> saveCode({
    required String companyCode,
    required String category,
    required CodingModel model,
  }) async {
    return CachePartitions.run(() async {
      try {
        final Map<String, dynamic> bodyData = Map<String, dynamic>.from(
          model.toMap(),
        );

        bodyData['company_code'] = companyCode;

        bodyData['category'] = category;

        final response = await AuthHttp.post(
          Uri.parse(
            "$baseUrl/coding/save",
          ),
          headers: {
            "Content-Type": "application/json",
          },
          body: json.encode(
            bodyData,
          ),
        );

        if (response.statusCode != 200) {
          return {
            'success': false,
            'error': 'فشل الحفظ من السيرفر. '
                'كود الخطأ: '
                '${response.statusCode}',
          };
        }

        final Map<String, dynamic> result = json.decode(
          response.body,
        );

        final String newCode = result['code']?.toString() ?? model.code;

        final String action = result['action']?.toString() ?? 'update';

        final String localKey = "${companyCode}_$category";

        // --------------------------------------------------------
        // قراءة القائمة الحالية
        // --------------------------------------------------------

        List<Map<String, dynamic>> currentList = [];

        if (_codingBox.containsKey(
          localKey,
        )) {
          final dynamic rawData = _codingBox.get(
            localKey,
          );

          if (rawData is List) {
            currentList = rawData
                .whereType<Map>()
                .map(
                  (item) => Map<String, dynamic>.from(item),
                )
                .where(
                  (item) => item['is_deleted'] != true,
                )
                .toList();
          }
        }

        // --------------------------------------------------------
        // البيانات المحلية
        // --------------------------------------------------------

        final Map<String, dynamic> newItem = Map<String, dynamic>.from(
          model.toMap(),
        );

        newItem['code'] = newCode;

        newItem['company_code'] = companyCode;

        newItem['category'] = category;

        newItem['is_deleted'] = false;

        // --------------------------------------------------------
        // حذف النسخة القديمة
        // --------------------------------------------------------

        currentList.removeWhere(
          (item) => item['code']?.toString() == newCode,
        );

        // --------------------------------------------------------
        // إضافة النسخة الجديدة
        // --------------------------------------------------------

        currentList.add(
          newItem,
        );

        // --------------------------------------------------------
        // منع التكرار
        // --------------------------------------------------------

        final Map<String, Map<String, dynamic>> uniqueItems = {};

        for (final item in currentList) {
          final String code = item['code']?.toString() ?? '';

          if (code.isNotEmpty) {
            uniqueItems[code] = item;
          }
        }

        currentList = uniqueItems.values.toList();

        // --------------------------------------------------------
        // ترتيب
        // --------------------------------------------------------

        currentList.sort(
          (a, b) {
            final int aCode = int.tryParse(
                  a['code']?.toString() ?? '0',
                ) ??
                0;

            final int bCode = int.tryParse(
                  b['code']?.toString() ?? '0',
                ) ??
                0;

            return aCode.compareTo(
              bCode,
            );
          },
        );

        await _codingBox.put(
          localKey,
          currentList,
        );

        print(
          "✅ تم الحفظ المحلي للتكويد "
          "[$category/$newCode]",
        );

        return {
          'success': true,
          'code': newCode,
          'action': action,
        };
      } catch (e) {
        return {
          'success': false,
          'error': e.toString(),
        };
      }
    });
  }

  // ============================================================
  // 5. حذف تكويد
  // ============================================================

  // يحذف كود ترميز
  Future<bool> deleteCode({
    required String companyCode,
    required String category,
    required String code,
  }) async {
    return CachePartitions.run(() async {
      try {
        final response = await AuthHttp.delete(
          Uri.parse(
            "$baseUrl/coding/delete/"
            "$companyCode/"
            "$category/"
            "$code",
          ),
        );

        if (response.statusCode != 200) {
          print(
            "❌ السيرفر رفض حذف التكويد "
            "[$category/$code] "
            "HTTP ${response.statusCode}",
          );

          return false;
        }

        // --------------------------------------------------------
        // حذف محلي فوري
        // --------------------------------------------------------

        final String localKey = "${companyCode}_$category";

        if (_codingBox.containsKey(
          localKey,
        )) {
          final dynamic rawData = _codingBox.get(
            localKey,
          );

          if (rawData is List) {
            final List<Map<String, dynamic>> safeList = [];

            for (final item in rawData) {
              if (item is! Map) {
                continue;
              }

              final Map<String, dynamic> safeMap =
                  Map<String, dynamic>.from(item);

              if (safeMap['code']?.toString() == code.toString()) {
                continue;
              }

              if (safeMap['is_deleted'] == true) {
                continue;
              }

              safeList.add(
                safeMap,
              );
            }

            if (safeList.isEmpty) {
              await _codingBox.delete(
                localKey,
              );
            } else {
              await _codingBox.put(
                localKey,
                safeList,
              );
            }

            print(
              "✅ تم حذف التكويد "
              "[$category/$code] من Hive",
            );
          }
        }

        return true;
      } catch (e) {
        print(
          "❌ خطأ أثناء حذف التكويد: $e",
        );

        return false;
      }
    });
  }
}
