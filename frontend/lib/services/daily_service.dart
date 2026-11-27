// frontend/lib/services/daily_service.dart
import 'cache_partitions.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'journal_save_client.dart';
import 'journal_save_intent.dart';
import 'permissions_service.dart';
import 'journal_cache.dart';
import 'v2_cursor_bootstrap.dart';
import 'treasury_transfer_service.dart';
import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import 'auth_http.dart';

// خدمة اليومية: تجلب الحركات وتحفظها محليًا وتزامنها مع الخادم
class DailyService {
  // ============================================================
  // API
  // ============================================================

  final String baseUrl = ApiConstants.baseUrl;

  // ============================================================
  // Hive
  // ============================================================

  // يعيد صندوق الحركات المحلي
  Box get _transactionBox => CachePartitions.box('daily_transactions_box');

  // ============================================================
  // 1. حساب الأرصدة محلياً من Hive
  // ============================================================

  // يحسب ملخص اليومية محليًا
  Future<Map<String, dynamic>> getDailySummaryLocal(
    String companyCode, {
    String? branchCode,
  }) async {
    return CachePartitions.run(() async {
      try {
        // --------------------------------------------------------
        // قراءة الخزائن من التكويد المحلي
        // --------------------------------------------------------

        final Box codingBox = CachePartitions.box('coding_box');

        final String localKey = "${companyCode}_safes";

        List<String> activeTreasuries = [];

        if (codingBox.containsKey(localKey)) {
          final dynamic rawData = codingBox.get(localKey);

          if (rawData is List) {
            activeTreasuries = rawData
                .whereType<Map>()
                .map(
                  (item) => item['name']?.toString() ?? "",
                )
                .where(
                  (name) => name.isNotEmpty,
                )
                .toList();
          }
        }

        // --------------------------------------------------------
        // إنشاء الأرصدة
        // --------------------------------------------------------

        Map<String, double> treasuryBalances = {};

        for (final name in activeTreasuries) {
          treasuryBalances[name] = 0.0;
        }

        // --------------------------------------------------------
        // قراءة كل الحركات من Hive
        // --------------------------------------------------------

        final List<dynamic> allTx = _transactionBox.values.toList();

        // --------------------------------------------------------
        // ترتيب آمن بالسيريال
        // --------------------------------------------------------

        allTx.sort(
          (a, b) {
            final int aSerial = int.tryParse(
                  a is Map ? a['serial']?.toString() ?? '0' : '0',
                ) ??
                0;

            final int bSerial = int.tryParse(
                  b is Map ? b['serial']?.toString() ?? '0' : '0',
                ) ??
                0;

            return aSerial.compareTo(
              bSerial,
            );
          },
        );

        // --------------------------------------------------------
        // حساب الأرصدة
        // --------------------------------------------------------

        for (final rawTx in allTx) {
          if (rawTx is! Map) {
            continue;
          }

          final tx = Map<String, dynamic>.from(
            rawTx,
          );

          // ======================================================
          // تجاهل السجلات المحذوفة
          // ======================================================

          if (tx['is_deleted'] == true) {
            continue;
          }

          // ======================================================
          // التأكد من الشركة
          // ======================================================

          if (tx['company_code'] != companyCode) {
            continue;
          }

          // ======================================================
          // فلترة الفرع
          // ======================================================

          if (branchCode != null &&
              ![
                'الكل',
                'كل الفروع',
                'all',
                '',
              ].contains(branchCode) &&
              tx['branch_code']?.toString() != branchCode) {
            continue;
          }

          // ======================================================
          // بيانات الحركة
          // ======================================================

          final String treasury = tx['treasury']?.toString() ?? "";

          final double amount = double.tryParse(
                tx['amount']?.toString() ?? '0.0',
              ) ??
              0.0;

          final String type = tx['type']?.toString() ?? "وارد";

          // ======================================================
          // إضافة / خصم
          // ======================================================

          if (treasuryBalances.containsKey(
            treasury,
          )) {
            if (type == "وارد") {
              treasuryBalances[treasury] = treasuryBalances[treasury]! + amount;
            } else if (type == "صادر") {
              treasuryBalances[treasury] = treasuryBalances[treasury]! - amount;
            }
          }
        }

        // Independent transfers change balances only, never journal turnover.
        final effects = TreasuryTransferService()
            .balanceEffects(companyCode, branchCode: branchCode);
        for (final entry in effects.entries) {
          if (treasuryBalances.containsKey(entry.key)) {
            treasuryBalances[entry.key] =
                treasuryBalances[entry.key]! + entry.value;
          }
        }

        // --------------------------------------------------------
        // حفظ الأرصدة محلياً
        // --------------------------------------------------------

        final String balanceKey = branchCode == null ||
                branchCode.isEmpty ||
                branchCode == 'all' ||
                branchCode == 'الكل' ||
                branchCode == 'كل الفروع'
            ? "${companyCode}_balances_all"
            : "${companyCode}_balances_${branchCode}";

        await _transactionBox.put(
          balanceKey,
          treasuryBalances,
        );

        return {
          "status": "success",
          "balances": treasuryBalances,
        };
      } catch (e) {
        print(
          "❌ خطأ في حساب الأرصدة: $e",
        );

        return {
          "status": "error",
          "balances": {},
        };
      }
    });
  }

  // ============================================================
  // 2. جلب جميع اليوميات من السيرفر
  //    Full Sync - جهاز جديد فقط
  // ============================================================

  // يجلب كل الحركات من الخادم
  Future<List<dynamic>> fetchAllTransactions(
    String companyCode,
  ) async {
    return CachePartitions.run(() async {
      try {
        final response = await AuthHttp.get(
          Uri.parse(
            '$baseUrl/transactions/list/$companyCode'
            '?start_date=2020-01-01'
            '&end_date=2100-12-31',
          ),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'فشل جلب اليوميات '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        final List<dynamic> serverData = jsonDecode(response.body);

        // --------------------------------------------------------
        // حفظ البيانات
        // --------------------------------------------------------

        for (final rawItem in serverData) {
          if (rawItem is! Map) {
            continue;
          }

          final Map<String, dynamic> item = Map<String, dynamic>.from(
            rawItem,
          );

          // ------------------------------------------------------
          // لو المحذوف وصل لأي سبب، لا نحفظه
          // ------------------------------------------------------

          if (item['is_deleted'] == true) {
            continue;
          }

          final String serial = item['serial']?.toString() ?? '';

          if (serial.isEmpty) {
            continue;
          }

          await JournalCache.put(_transactionBox, item,
              expectedCompany: companyCode);
        }

        // --------------------------------------------------------
        // تحديث الأرصدة
        // --------------------------------------------------------

        await getDailySummaryLocal(
          companyCode,
          branchCode: null,
        );

        print(
          "✅ تم جلب ${serverData.length} يومية "
          "من السيرفر وتخزينها محلياً",
        );

        return serverData;
      } catch (e) {
        print(
          "❌ فشل جلب جميع اليوميات: $e",
        );

        rethrow;
      }
    });
  }

  // ============================================================
  // 3. المزامنة التزايدية
  //
  // lastSync موجود
  //      ↓
  // changes فقط
  //
  // delete
  //      ↓
  // حذف من Hive
  //
  // update / insert
  //      ↓
  // تحديث Hive
  // ============================================================

  // يجلب آخر مؤشر مزامنة من الخادم
  Future<String?> _fetchLatestCursor(String companyCode) async {
    try {
      final r = await AuthHttp.get(Uri.parse(
          '${ApiConstants.baseUrl}/transactions/changes-v2/$companyCode?cursor=latest'));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      return '${m['next_cursor']}|${m['scope'] ?? ''}';
    } catch (_) {
      return null;
    }
  }

  // يزامن تغييرات الحركات من الخادم
  Future<void> syncChangesFromServer(
    String companyCode, [
    String? lastSync,
  ]) async {
    return CachePartitions.run(() async {
      final prefs = await CachePartitions.preferences();

      final String lastSyncKey = '${ApiConstants.LAST_SYNC_DAILY}$companyCode';

      final String? lastSyncValue = lastSync ??
          prefs.getString(
            lastSyncKey,
          );

      // ==========================================================
      // لا يوجد lastSync
      // ==========================================================

      if (lastSyncValue == null || lastSyncValue.isEmpty) {
        print(
          '📥 لا يوجد lastSync لليوميات، '
          'جاري التحميل الكامل...',
        );

        final v2store = V2CursorStore(prefs.getString, (k, v) async {
          await prefs.setString(k, v);
        }, (k) async {
          await prefs.remove(k);
        }, lastSyncKey);
        await V2Bootstrap.run(
          store: v2store,
          fetchLatest: () => _fetchLatestCursor(companyCode),
          fullSync: () => syncAllTransactions(companyCode),
        );

        await prefs.setString(
          lastSyncKey,
          DateTime.now().toUtc().toIso8601String(),
        );

        return;
      }

      try {
        // --------------------------------------------------------
        // وقت بداية المزامنة
        //
        // نستخدمه كحد أعلى للتحديثات التي نعتبرها مكتملة.
        // أي تغيير يحصل بعده سيظهر في المرة القادمة.
        // --------------------------------------------------------

        final DateTime syncStartedAt = DateTime.now().toUtc();

        // --------------------------------------------------------
        // آخر وقت مزامنة
        //
        // Backend يستقبل UTC بدون timezone داخل SQL.
        // --------------------------------------------------------

        DateTime sinceDt = DateTime.parse(lastSyncValue).toUtc();

        sinceDt = sinceDt.subtract(
          const Duration(minutes: 1),
        );

        final String effectiveSince = sinceDt.toIso8601String();

        print(
          '📡 اليوميات: جلب التغييرات منذ '
          '$effectiveSince',
        );

        // --------------------------------------------------------
        // Request
        // --------------------------------------------------------

        final String v2Key = '${lastSyncKey}_v2';
        final String? v2Cursor = prefs.getString(v2Key);
        String? v2Next;
        String? v2Bootstrap;
        final List<dynamic> changes = <dynamic>[];

        final Stopwatch swFetch = Stopwatch()..start();
        if (v2Cursor != null) {
          // Commit-safe feed: (transaction id, row id) cursor, paged.
          var cur = v2Cursor;
          var guard = 0;
          while (true) {
            final r = await AuthHttp.get(Uri.parse(
                '$baseUrl/transactions/changes-v2/$companyCode?cursor=$cur&limit=200&scope=${prefs.getString('${lastSyncKey}_v2scope') ?? ''}'));
            if (r.statusCode != 200) {
              throw Exception('فشل مزامنة اليوميات (v2). HTTP ${r.statusCode}');
            }
            final body = jsonDecode(r.body) as Map<String, dynamic>;
            if (body['invalid'] == true) {
              // Cursor no longer valid (server restored/copied, or this user's allowed
              // branches changed). Take a fresh cursor first, then do a full sync in place.
              print(
                  '⚠️ v2 invalid (${body['reason'] ?? 'cursor'}) → full sync');
              final v2store = V2CursorStore(prefs.getString, (k, v) async {
                await prefs.setString(k, v);
              }, (k) async {
                await prefs.remove(k);
              }, lastSyncKey);
              await V2Bootstrap.clear(v2store);
              await V2Bootstrap.run(
                store: v2store,
                fetchLatest: () => _fetchLatestCursor(companyCode),
                fullSync: () => syncAllTransactions(companyCode),
              );
              await prefs.setString(
                  lastSyncKey, DateTime.now().toUtc().toIso8601String());
              return;
            }
            changes.addAll(body['items'] as List);
            cur = body['next_cursor'].toString();
            if (body['has_more'] != true) break;
            if (++guard > 500) throw Exception('v2 paging guard');
          }
          v2Next = cur;
          print('📡 اليوميات v2: ${changes.length} تغيير حتى $cur');
        } else {
          // First run on this device with the new feed: take the cursor before the
          // old time-based fetch, which then covers everything up to now.
          v2Bootstrap = await _fetchLatestCursor(companyCode);
          final response = await AuthHttp.get(
            Uri.parse(
              '$baseUrl/transactions/changes/'
              '$companyCode?since=$effectiveSince',
            ),
          );
          if (response.statusCode != 200) {
            throw Exception(
              'فشل مزامنة اليوميات. '
              'HTTP ${response.statusCode}: '
              '${response.body}',
            );
          }
          changes.addAll(jsonDecode(response.body) as List);
        }

        // --------------------------------------------------------
        // تطبيق التغييرات
        // --------------------------------------------------------

        swFetch.stop();
        final Stopwatch swApply = Stopwatch()..start();
        int legacyApplied = 0, legacySkippedSame = 0, legacySkippedStale = 0;
        for (final rawItem in changes) {
          if (rawItem is! Map) {
            continue;
          }

          final Map<String, dynamic> map = Map<String, dynamic>.from(
            rawItem,
          );

          final String action = map['action']?.toString() ?? 'update';

          final String branchCode = map['branch_code']?.toString() ?? '1';

          final String? serial = map['serial']?.toString();

          if (serial == null || serial.isEmpty) {
            throw Exception(
              'تحديث يومية بدون serial',
            );
          }

          final String key = 'branch_${branchCode}_$serial';

          // ======================================================
          // DELETE
          // ======================================================

          if (action == 'delete' || map['is_deleted'] == true) {
            await JournalCache.delete(_transactionBox,
                company: companyCode, branch: branchCode, serial: serial);

            print(
              '🗑️ تم حذف اليومية [$key] من Hive',
            );

            continue;
          }

          // ======================================================
          // INSERT / UPDATE
          // ======================================================

          map.remove('action');

          // لا نحتاج حفظ is_deleted=false
          // لكن تركه مش مشكلة.
          // نخليه لضمان وضوح حالة السجل محلياً.
          map['is_deleted'] = false;

          // Same version already stored (for example merged from the staged batch a moment ago):
          // do not write it again. Newer or different versions are still written as before.
          final outcome = await JournalCache.putIfNotOlder(_transactionBox, map,
              expectedCompany: companyCode);
          if (outcome == 'same') {
            legacySkippedSame++;
            continue;
          }
          if (outcome == 'stale') {
            legacySkippedStale++;
            continue;
          }
          legacyApplied++;

          print(
            '✅ تم تحديث اليومية [$key] في Hive',
          );
        }

        // --------------------------------------------------------
        // تحديث الأرصدة
        // --------------------------------------------------------

        swApply.stop();
        print(
            '⏱ daily open-sync timing: fetch=${swFetch.elapsedMilliseconds}ms apply=${swApply.elapsedMilliseconds}ms items=${changes.length} v2=${v2Cursor != null} applied=$legacyApplied skippedSame=$legacySkippedSame skippedStale=$legacySkippedStale');
        await getDailySummaryLocal(
          companyCode,
          branchCode: null,
        );

        // --------------------------------------------------------
        // تحديث lastSync فقط بعد نجاح العملية كاملة
        // --------------------------------------------------------

        await prefs.setString(
          lastSyncKey,
          syncStartedAt.toIso8601String(),
        );

        if (v2Next != null) {
          await prefs.setString(v2Key, v2Next);
        } else if (v2Bootstrap != null) {
          final bp = v2Bootstrap.split('|');
          await prefs.setString(v2Key, bp[0]);
          await prefs.setString(
              '${lastSyncKey}_v2scope', bp.length > 1 ? bp[1] : '');
        }

        print(
          '✅ تمت مزامنة '
          '${changes.length} تحديث لليوميات',
        );
      } catch (e) {
        print(
          '❌ فشل مزامنة اليوميات: $e',
        );

        // مهم:
        // لا نغير lastSync عند الفشل.
        rethrow;
      }
    });
  }

  // ============================================================
  // 4. حفظ / تعديل حركة
  // ============================================================

  // يحوّل ختم وقت الخادم إلى تاريخ
  DateTime? _serverStamp(dynamic value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return null;
    final hasZone = RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(text);
    return DateTime.tryParse(hasZone ? text : '${text}Z')?.toUtc();
  }

  // يحدد هل يحق للمستخدم تسجيل قيد في هذا الفرع
  bool _journalOwnerAllowed(JournalSaveIntent intent, String branch) {
    final rights = PermissionsService();
    return FirebaseAuth.instance.currentUser?.uid == intent.ownerUid &&
        (rights.canAddTransaction ||
            rights.canEditTransaction ||
            rights.canViewTransactions) &&
        rights.canAccessBranch(branch);
  }

  // يحدد هل يحق للمستخدم تسجيل تسوية في هذا الفرع
  bool _settlementOwnerAllowed(JournalSaveIntent intent, String branch) {
    final rights = PermissionsService();
    return _journalOwnerAllowed(intent, branch) &&
        (rights.canViewSupplierSettlements ||
            rights.canAddSupplierSettlement ||
            rights.canEditSupplierSettlement);
  }

  // يحفظ حركة ملتقطة سابقًا بإعادة المحاولة
  /// Retry only the captured intention, never rebuild it from an edited form.
  Future<Map<String, dynamic>> saveCapturedTransaction(JournalSaveIntent intent,
      {JournalIntentStore? store}) async {
    return CachePartitions.run(() async {
      var dailyChanged = false;
      var settlementChanged = false;
      final dailyWatch =
          _transactionBox.watch().listen((_) => dailyChanged = true);
      final Box? settlements =
          CachePartitions.isBoxOpen('supplier_settlement_box')
              ? CachePartitions.box('supplier_settlement_box')
              : null;
      final settlementWatch =
          settlements?.watch().listen((_) => settlementChanged = true);
      try {
        return await JournalSaveClient(store: store).submit(intent,
            applySnapshot: (result) async {
          final row = Map<String, dynamic>.from(result['record'] as Map);
          final branch = row['branch_code'].toString();
          if (!_journalOwnerAllowed(intent, branch) ||
              row['is_deleted'] == true) return false;
          final serial = row['serial'].toString();
          final key = JournalCache.key(intent.companyCode, branch, serial);
          final legacy = 'branch_${branch}_$serial';
          final cached =
              _transactionBox.get(key) ?? _transactionBox.get(legacy);
          var refreshed = true;
          final oldStamp =
              cached is Map && cached['company_code'] == intent.companyCode
                  ? _serverStamp(cached['updated_at'])
                  : null;
          final incomingStamp = _serverStamp(row['updated_at']);
          if (cached == null && dailyChanged) {
            // A deletion observed after this request must not be undone by a late ack.
            refreshed = false;
          } else if (oldStamp == null ||
              incomingStamp != null && !incomingStamp.isBefore(oldStamp)) {
            if (!_journalOwnerAllowed(intent, branch)) return false;
            await JournalCache.put(_transactionBox, row,
                expectedCompany: intent.companyCode);
          }
          final linkedRaw = result['linked_settlement'];
          if (linkedRaw is Map) {
            final linked = Map<String, dynamic>.from(linkedRaw);
            final docId = linked['doc_id']?.toString() ?? '';
            final linkedBranch = linked['branch_code']?.toString() ?? '';
            // Journal authority alone must not populate another module's cache.
            if (!_settlementOwnerAllowed(intent, linkedBranch))
              return refreshed;
            if (settlements == null ||
                docId.isEmpty ||
                linked['company_code'] != intent.companyCode ||
                !_settlementOwnerAllowed(intent, linkedBranch)) return false;
            Map? current;
            for (final value in settlements.values.whereType<List>()) {
              for (final record in value.whereType<Map>()) {
                if (record['company_code'] == intent.companyCode &&
                    record['doc_id']?.toString() == docId) current = record;
              }
            }
            final previousStamp = _serverStamp(current?['updated_at']);
            final linkedStamp = _serverStamp(linked['updated_at']);
            if (previousStamp != null &&
                (linkedStamp == null || linkedStamp.isBefore(previousStamp)))
              return refreshed;
            if (current == null && settlementChanged) return false;
            // Remove only this company's previous location for this document.
            for (final oldKey in settlements.keys.toList()) {
              if (!_settlementOwnerAllowed(intent, linkedBranch)) return false;
              final value = settlements.get(oldKey);
              if (value is! List) continue;
              final remaining = value
                  .where((record) =>
                      record is! Map ||
                      record['company_code'] != intent.companyCode ||
                      record['doc_id']?.toString() != docId)
                  .toList();
              if (remaining.length == value.length) continue;
              if (remaining.isEmpty) {
                await settlements.delete(oldKey);
              } else {
                await settlements.put(oldKey, remaining);
              }
            }
            if (linked['is_deleted'] != true) {
              if (!_settlementOwnerAllowed(intent, linkedBranch)) return false;
              final target =
                  '${intent.companyCode}_${linkedBranch}_${linked['date']}';
              final old = settlements.get(target);
              final list = old is List ? List<dynamic>.from(old) : <dynamic>[];
              list.add(linked);
              await settlements.put(target, list);
            }
          }
          return refreshed;
        });
      } finally {
        await dailyWatch.cancel();
        await settlementWatch?.cancel();
      }
    });
  }

  // يحفظ حركة يومية جديدة أو معدّلة
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
    required String branchCode,
    String? linkId,
    String? supplierName,
    bool addToSettlement = false,
    bool unlinkSettlement = false,
    String? baseUpdatedAt,
    JournalSaveIntent? intent,
    JournalIntentStore? intentStore,
  }) async {
    return CachePartitions.run(() async {
      if (intent != null) {
        intent.capture({
          'company_code': companyCode,
          'base_updated_at': baseUpdatedAt,
          'serial': serial,
          'treasury': treasury,
          'amount': amount,
          'statement': statement,
          'category': category,
          'date': date,
          'type': type,
          'employee': employee ?? 'غير محدد',
          'branch_code': branchCode,
          'link_id': linkId,
          'supplier_name': supplierName,
          'add_to_settlement': addToSettlement,
          'unlink_settlement': unlinkSettlement,
        });
        return saveCapturedTransaction(intent, store: intentStore);
      }
      try {
        final response = await AuthHttp.post(
          Uri.parse(
            '$baseUrl/transactions/save',
          ),
          headers: {
            'Content-Type': 'application/json',
          },
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
            'branch_code': branchCode,
            'base_updated_at': baseUpdatedAt,
            'link_id': linkId,
            'supplier_name': supplierName,
            'add_to_settlement': addToSettlement,
            'unlink_settlement': unlinkSettlement,
          }),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        final Map<String, dynamic> result = jsonDecode(
          response.body,
        );

        if (result['status'] != 'success') {
          throw Exception(
            result['message'] ?? 'فشل حفظ الحركة',
          );
        }

        final int assignedSerial =
            (result['serial'] as num?)?.toInt() ?? serial;
        final String? assignedLinkId =
            unlinkSettlement ? null : (result['link_id']?.toString() ?? linkId);

        // --------------------------------------------------------
        // بيانات محلية
        // --------------------------------------------------------

        final Map<String, dynamic> transactionData = {
          'company_code': companyCode,
          'serial': assignedSerial,
          'treasury': treasury,
          'amount': amount,
          'statement': statement,
          'category': category,
          'date': date,
          'type': type,
          'employee': employee ?? "غير محدد",
          'branch_code': branchCode,
          'link_id': assignedLinkId,
          'add_to_settlement': addToSettlement,
          'supplier_name': unlinkSettlement ? null : supplierName,
          'unlink_settlement': unlinkSettlement,
          'is_deleted': false,
        };

        print(
          "🚀 Sending to server: "
          "company_code=$companyCode, "
          "branch_code=$branchCode",
        );

        // --------------------------------------------------------
        // تحديث محلي فوري
        // --------------------------------------------------------

        await JournalCache.put(_transactionBox, transactionData,
            expectedCompany: companyCode);

        final linkedRaw = result['linked_settlement'];
        if (linkedRaw is Map) {
          final linked = Map<String, dynamic>.from(linkedRaw);
          final settlementBox = CachePartitions.box('supplier_settlement_box');
          final settlementKey =
              '${linked['company_code']}_${linked['branch_code']}_${linked['date']}';
          for (final oldKey in settlementBox.keys.toList()) {
            final rawList = settlementBox.get(oldKey);
            if (rawList is! List) continue;
            final list = rawList
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            list.removeWhere(
                (e) => e['doc_id']?.toString() == linked['doc_id']?.toString());
            if (list.isEmpty) {
              await settlementBox.delete(oldKey);
            } else if (list.length != rawList.length) {
              await settlementBox.put(oldKey, list);
            }
          }
          if (linked['is_deleted'] != true) {
            final rawList = settlementBox.get(settlementKey);
            final list = rawList is List
                ? rawList
                    .whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .toList()
                : <Map<String, dynamic>>[];
            list.add(linked);
            await settlementBox.put(settlementKey, list);
          }
        }

        return {
          "success": true,
          "serial": assignedSerial,
          "link_id": assignedLinkId,
        };
      } catch (e) {
        throw Exception(
          'فشل عملية الحفظ: $e',
        );
      }
    });
  }

  // ============================================================
  // 5. مزامنة قديمة حسب Serial
  //
  // للتوافق مع أي كود قديم.
  // ============================================================

  // يزامن الذاكرة المؤقتة من الخادم
  Future<void> syncCacheFromServer(
    String companyCode,
    int fromSerial,
  ) async {
    return CachePartitions.run(() async {
      try {
        final response = await AuthHttp.get(
          Uri.parse(
            '$baseUrl/transactions/updates/'
            '$companyCode/$fromSerial',
          ),
        );

        if (response.statusCode != 200) {
          return;
        }

        final List<dynamic> updates = jsonDecode(
          response.body,
        );

        for (final rawItem in updates) {
          if (rawItem is! Map) {
            continue;
          }

          final Map<String, dynamic> item = Map<String, dynamic>.from(
            rawItem,
          );

          if (!item.containsKey('serial')) {
            continue;
          }

          // ------------------------------------------------------
          // المحذوف
          // ------------------------------------------------------

          if (item['is_deleted'] == true || item['action'] == 'delete') {
            final String bCode = item['branch_code']?.toString() ?? "1";

            final String serial = item['serial'].toString();

            await JournalCache.delete(_transactionBox,
                company: companyCode, branch: bCode, serial: serial);

            continue;
          }

          // ------------------------------------------------------
          // العادي
          // ------------------------------------------------------

          await JournalCache.put(_transactionBox, item,
              expectedCompany: companyCode);
        }
      } catch (e) {
        print(
          "⚠️ خطأ في المزامنة الخلفية: $e",
        );
      }
    });
  }

  // ============================================================
  // 6. جلب التاريخ
  //
  // Hive أولاً
  // ثم السيرفر عند الحاجة
  // ============================================================

  // يجلب سجل الحركات حسب الفرع والفترة
  Future<List<dynamic>> getTransactionsHistory(
    String companyCode,
    String startDate,
    String endDate, {
    String? branchCode,
  }) async {
    return CachePartitions.run(() async {
      try {
        List<dynamic> resultData = [];

        // --------------------------------------------------------
        // قراءة من Hive
        // --------------------------------------------------------

        if (_transactionBox.isNotEmpty) {
          final List<dynamic> localData = _transactionBox.values.where(
            (tx) {
              if (tx is! Map) {
                return false;
              }

              if (tx['company_code'] != companyCode) {
                return false;
              }

              if (tx['is_deleted'] == true) {
                return false;
              }

              final String txDate = tx['date']?.toString() ?? '';

              return txDate.compareTo(
                        startDate,
                      ) >=
                      0 &&
                  txDate.compareTo(
                        endDate,
                      ) <=
                      0;
            },
          ).toList();

          if (localData.isNotEmpty) {
            resultData = localData;
          }
        }

        // --------------------------------------------------------
        // لو مفيش محلي
        // نجيب من السيرفر
        // --------------------------------------------------------

        if (resultData.isEmpty) {
          final response = await AuthHttp.get(
            Uri.parse(
              '$baseUrl/transactions/list/'
              '$companyCode'
              '?start_date=$startDate'
              '&end_date=$endDate',
            ),
          );

          if (response.statusCode != 200) {
            throw Exception(
              'خطأ من السيرفر: '
              '${response.statusCode}',
            );
          }

          final List<dynamic> serverData = jsonDecode(
            response.body,
          );

          for (final rawItem in serverData) {
            if (rawItem is! Map) {
              continue;
            }

            final Map<String, dynamic> item = Map<String, dynamic>.from(
              rawItem,
            );

            if (item['is_deleted'] == true) {
              continue;
            }

            final String serial = item['serial']?.toString() ?? '';

            if (serial.isEmpty) {
              continue;
            }

            await JournalCache.put(_transactionBox, item,
                expectedCompany: companyCode);
          }

          resultData = serverData
              .where(
                (item) => item is Map && item['is_deleted'] != true,
              )
              .toList();
        }

        // --------------------------------------------------------
        // فلترة الفرع
        // --------------------------------------------------------

        if (branchCode != null &&
            ![
              'الكل',
              'كل الفروع',
              'all',
              '',
            ].contains(branchCode)) {
          resultData = resultData
              .where(
                (tx) =>
                    tx is Map && tx['branch_code']?.toString() == branchCode,
              )
              .toList();
        }

        return resultData;
      } catch (e) {
        // --------------------------------------------------------
        // Offline fallback
        // --------------------------------------------------------

        List<dynamic> fallbackData = _transactionBox.values.where(
          (tx) {
            if (tx is! Map) {
              return false;
            }

            if (tx['company_code'] != companyCode) {
              return false;
            }

            if (tx['is_deleted'] == true) {
              return false;
            }

            final String txDate = tx['date']?.toString() ?? '';

            return txDate.compareTo(
                      startDate,
                    ) >=
                    0 &&
                txDate.compareTo(
                      endDate,
                    ) <=
                    0;
          },
        ).toList();

        if (branchCode != null &&
            ![
              'الكل',
              'كل الفروع',
              'all',
              '',
            ].contains(branchCode)) {
          fallbackData = fallbackData
              .where(
                (tx) =>
                    tx is Map && tx['branch_code']?.toString() == branchCode,
              )
              .toList();
        }

        return fallbackData;
      }
    });
  }

  // ============================================================
  // 7. حذف حركة
  // ============================================================

  // يحذف حركة
  Future<void> deleteTransaction(
    String companyCode,
    int serial,
    String branchCode,
  ) async {
    return CachePartitions.run(() async {
      try {
        String? linkedSettlementId;
        for (final raw in _transactionBox.values) {
          if (raw is Map &&
              raw['company_code']?.toString() == companyCode &&
              raw['branch_code']?.toString() == branchCode &&
              raw['serial']?.toString() == serial.toString()) {
            linkedSettlementId = raw['link_id']?.toString();
            break;
          }
        }
        final response = await AuthHttp.delete(
          Uri.parse(
            '$baseUrl/transactions/delete/'
            '$companyCode/'
            '$branchCode/'
            '$serial',
          ),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'فشل حذف الحركة من السيرفر. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        // --------------------------------------------------------
        // السيرفر عمل Soft Delete بنجاح
        // نحذف محليًا فورًا
        // --------------------------------------------------------

        await JournalCache.delete(_transactionBox,
            company: companyCode,
            branch: branchCode,
            serial: serial.toString());
        if (linkedSettlementId != null && linkedSettlementId.isNotEmpty) {
          final settlementBox = CachePartitions.box('supplier_settlement_box');
          for (final key in settlementBox.keys.toList()) {
            final raw = settlementBox.get(key);
            if (raw is! List) continue;
            final list = raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            for (final item in list
                .where((e) => e['link_id']?.toString() == linkedSettlementId)) {
              item['is_deleted'] = true;
            }
            await settlementBox.put(key, list);
          }
        }

        // --------------------------------------------------------
        // تحديث الأرصدة
        // --------------------------------------------------------

        await getDailySummaryLocal(
          companyCode,
          branchCode: branchCode,
        );
      } catch (e) {
        throw Exception(
          'خطأ أثناء الحذف: $e',
        );
      }
    });
  }

  // ============================================================
  // 8. آخر Serial محلي
  // ============================================================

  // يعيد آخر رقم تسلسلي محلي
  int getLastLocalSerial(
    String companyCode,
  ) {
    final List<dynamic> localTx = _transactionBox.values
        .where(
          (e) =>
              e is Map &&
              e['company_code'] == companyCode &&
              e['is_deleted'] != true,
        )
        .toList();

    if (localTx.isEmpty) {
      return 0;
    }

    localTx.sort(
      (a, b) {
        final int aSerial = int.tryParse(
              a['serial']?.toString() ?? '0',
            ) ??
            0;

        final int bSerial = int.tryParse(
              b['serial']?.toString() ?? '0',
            ) ??
            0;

        return aSerial.compareTo(
          bSerial,
        );
      },
    );

    return int.tryParse(
          localTx.last['serial']?.toString() ?? '0',
        ) ??
        0;
  }

  // ============================================================
  // 9. Full Sync
  // ============================================================

  // يزامن كل الحركات
  Future<void> syncAllTransactions(
    String companyCode,
  ) async {
    return CachePartitions.run(() async {
      try {
        final String startDate = '2020-01-01';

        final String endDate = '2100-12-31';

        final response = await AuthHttp.get(
          Uri.parse(
            '$baseUrl/transactions/list/'
            '$companyCode'
            '?start_date=$startDate'
            '&end_date=$endDate',
          ),
        );

        if (response.statusCode != 200) {
          throw Exception(
            'فشل جلب البيانات من السيرفر. '
            'HTTP ${response.statusCode}: '
            '${response.body}',
          );
        }

        final List<dynamic> serverData = jsonDecode(
          response.body,
        );

        // --------------------------------------------------------
        // تخزين البيانات
        // --------------------------------------------------------

        for (final rawItem in serverData) {
          if (rawItem is! Map) {
            continue;
          }

          final Map<String, dynamic> item = Map<String, dynamic>.from(
            rawItem,
          );

          if (item['is_deleted'] == true) {
            continue;
          }

          final String serial = item['serial']?.toString() ?? '';

          if (serial.isEmpty) {
            continue;
          }

          await JournalCache.put(_transactionBox, item,
              expectedCompany: companyCode);
        }

        // --------------------------------------------------------
        // تحديث الأرصدة
        // --------------------------------------------------------

        await getDailySummaryLocal(
          companyCode,
          branchCode: null,
        );

        print(
          "✅ تم مزامنة جميع الحركات "
          "من السيرفر بنجاح "
          "(عدد: ${serverData.length})",
        );
      } catch (e) {
        print(
          "❌ خطأ في مزامنة جميع الحركات: $e",
        );

        rethrow;
      }
    });
  }
}
