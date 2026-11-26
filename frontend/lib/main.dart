import 'services/sync_read_access.dart';
import 'services/work_pool.dart';
import 'services/cache_partitions.dart';
import 'services/staged_inbox.dart';
import 'services/scoped_sync_queue.dart';
import 'services/read_authorization_snapshot.dart';
import 'services/scope_sync_plan.dart';
import 'services/treasury_transfer_service.dart';
import 'dart:async';
import 'core/constants.dart';
import 'services/permissions_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/employee_service.dart';
import 'services/fcm_service.dart';
import 'services/startup_push_state.dart';
import 'core/theme.dart';
import 'services/hr_service.dart';
import 'views/auth/login_screen.dart';
import 'views/auth/phone_entry_screen.dart';
import 'views/dashboard/home_page.dart';
import 'views/auth/forgot_password_screen.dart';
import 'views/auth/verify_email_screen.dart';
import 'firebase_options.dart';
import 'services/deep_link_service.dart';
import 'core/navigator_key.dart';
import 'services/global_sync_service.dart';
import 'services/daily_service.dart';
import 'services/supplier_service.dart';
import 'services/inventory_service.dart';
import 'services/coding_service.dart';
import 'services/supplier_settlement_service.dart';
import 'services/commercial_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_html/html.dart' as html;
import 'services/company_service.dart';
import 'services/user_service.dart';

// ============================================================
// Global Sync Service
// ============================================================

final GlobalSyncService _syncService = GlobalSyncService();

// ============================================================
// متغيرات قديمة للحفاظ على التوافق
// ============================================================

StreamSubscription? globalSyncSubscription;
StreamSubscription? codingSyncSubscription;
StreamSubscription? inventorySyncSubscription;
StreamSubscription? supplierSyncSubscription;

// ============================================================
// منع تشغيل أكثر من مزامنة في نفس الوقت
// ============================================================

bool _isSyncing = false;
bool _deviceHadNoCacheAtStart = false;
// Web only: closed-app push cannot have prepared data (permission not granted or device not registered).
bool _pushUnavailableAtStart = false;
// Set when the startup merge could not apply staged changes (error or permission
// verification failed): the open-time sync wait below then covers them (case 4).
bool _startupMergeFailed = false;
// Startup mode: default = verify + merge staged changes behind the loading page, then open and sync.
// `?startup=bg` (measurement only) = open at once, merge in the background.
final String _startupMergeMode = Uri.base.queryParameters['startup'] ?? 'merge';
// Completes when the startup merge block is over; scoped resyncs wait for it.
Future<void>? _startupMergeGate;
// Measurement only: slows the permissions reconciliation to test the scoped resync under a slow reload.
final int _permDelayMs =
    int.tryParse(Uri.base.queryParameters['permDelay'] ?? '') ?? const int.fromEnvironment('PERM_DELAY_MS');
// Measurement only: rebuilds the old behaviour (always wait) to compare against the new one.
const bool _forceLegacyWait = bool.fromEnvironment('FORCE_WAIT');

// ⭐ يخلص لما أول مزامنة تخلص (نجحت أو فشلت)
final Completer<void> _initialSyncCompleter = Completer<void>();

// ⭐ يخلص لما WebSocket يفشل في الاتصال (سيرفر واقع)
final Completer<void> _wsConnectionFailedCompleter = Completer<void>();

Future<void> waitForSyncToComplete({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final startTime = DateTime.now();
  final endTime = startTime.add(timeout);

  print('⏳ waitForSyncToComplete: بداية الانتظار (max ${timeout.inSeconds}s)');

  // المرحلة 1: انتظر لحد ما sync تبدأ
  bool syncStarted = false;
  while (DateTime.now().isBefore(endTime)) {
    if (_isSyncing) {
      syncStarted = true;
      print('✅ sync بدأت — ننتقل لانتظار الانتهاء');
      break;
    }

    if (_wsConnectionFailedCompleter.isCompleted) {
      print('⚠️ WebSocket failed — مفيش sync هتيجي، فتح فوراً');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (!syncStarted) {
    print('⏱️ sync ما بدأتش خلال ${timeout.inSeconds}s — فتح فوراً');
    return;
  }

  // المرحلة 2: انتظر لحد ما sync تخلص (أو timeout)
  while (_isSyncing && DateTime.now().isBefore(endTime)) {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  if (_isSyncing) {
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    print('⏱️ sync لسه شغالة بعد ${elapsed}s — timeout، فتح بالبيانات المتاحة');
  } else {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    print('✅ sync خلصت — إجمالي الانتظار: ${elapsed}ms');
  }
}

// ============================================================
// Sync Manager — Batching
//
//   Batch 1: [اليوميات, التسويات, التكويد]
//   Batch 2: [الموظفين, HR, الموردين]
//   Batch 2.5: [الشركات (Super Admin), المستخدمين (Admin)]
//   Batch 3: [الجرد]
//   Batch 3.5: [المبيعات + المرتجعات + العملاء + التحويلات]
//   retryPending → الأرصدة
// ============================================================

/// مسح مفاتيح آخر مزامنة لإجبار الدفعة التالية على الجلب الكامل،
/// ثم تشغيل المزامنة. يُستخدم عند اتساع نطاق الصلاحيات/الفروع.
final _scopeSyncQueue = ScopedSyncQueue(
  waitForData: () async {
    final current = _dataSyncWork;
    if (current != null) await current;
  },
  reconcile: _forceScopeResync,
);
/// Set only while a scoped resync runs: modules outside it were already synced by the open-time pass.
Set<String>? _resyncOnly;
Future<bool>? _dataSyncWork;
String? _dataSyncOwner;
String? _dataSyncCompany;
String? _dataReadyOwner;
String? _dataReadyCompany;
int? _dataReadyEpoch;

/// Sets [_pushUnavailableAtStart] and shows the approved note on the loading page.
/// Granted permission + registered device (alerts muted or not) is the normal path and shows nothing.
Future<void> _detectPushUnavailable() async {
  if (!kIsWeb) return;
  try {
    bool supported = false;
    String? raw;
    try {
      supported = html.Notification.supported;
      raw = html.Notification.permission;
    } catch (_) {}
    final registered = await FcmService.instance.isSystemNotificationsEnabled();
    _pushUnavailableAtStart = pushUnavailableAtStart(
      permission: parseBrowserPushPermission(raw, supported: supported),
      registrationEnabled: registered,
    );
    print('🔔 push at start: permission=$raw supported=$supported registered=$registered '
        '-> unavailable=$_pushUnavailableAtStart');
    if (_pushUnavailableAtStart) {
      final el = html.document.getElementById('loading-note');
      if (el != null) {
        el.text = pushUnavailableLoadingNote;
        el.style.display = 'block';
      }
    }
  } catch (e) {
    print('⚠️ push state check failed: $e');
  }
}

void _scheduleScopeResync(String code) {
  final modules = PermissionsService().takeScopeSyncModules();
  if (modules.isEmpty) return;
  unawaited(_scopeSyncQueue.add(code, modules).catchError((Object error) {
    print('⚠️ Scoped sync deferred: $error');
  }));
}

Future<void> _forceScopeResync(String companyCode, Set<String> modules) async {
  // A resync must not run beside the startup merge (it moves the authorization epoch under it).
  final startupGate = _startupMergeGate;
  if (startupGate != null) {
    try {
      await startupGate.timeout(const Duration(seconds: 15));
    } catch (_) {}
  }
  // Order: let the connection's permission reconciliation finish first. Starting earlier makes the
  // pass read while the authorization epoch moves, so it is aborted and its requests repeated.
  final waitStart = DateTime.now();
  while (!_syncService.authorizationReady &&
      !_wsConnectionFailedCompleter.isCompleted &&
      DateTime.now().difference(waitStart) < const Duration(seconds: 4)) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  print('🧭 scoped resync starts after ${DateTime.now().difference(waitStart).inMilliseconds}ms wait, authorizationReady=${_syncService.authorizationReady}');
  return CachePartitions.run(() async {
    final scope = await ReadAuthorizationSnapshot.capture();
    final prefs = await CachePartitions.preferences();
    scope.check();
    if (prefs.getString('company_code') != companyCode) return;
    final keys = ScopeSyncPlan.cursorKeys(companyCode, modules);
    for (final key in keys) {
      if (!scope.sameContext) return;
      await prefs.remove(key);
    }
    if (!scope.sameContext) return;
    print('🔄 scoped resync: ${modules.join(', ')} (${keys.length} cursors)');
    _resyncOnly = modules;
    try {
      // The permissions reload can move the authorization epoch while this pass reads. The pass then
      // fails ("access changed during this read") and its cursors stay reset. Do not depend on some
      // later pass: retry here until a pass completes at the current epoch (bounded).
      for (var attempt = 0; attempt < 4; attempt++) {
        await syncAllDataIfNeeded(companyCode);
        if (_dataReadyCompany == companyCode &&
            _dataReadyEpoch == ReadAuthorizationEpoch.value) break;
        if (!scope.sameContext) break;
        print('🔁 scoped resync not completed at the current epoch, retry ${attempt + 1}');
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        if (!scope.sameContext) break;
      }
    } finally {
      _resyncOnly = null;
    }
  });
}

Future<void> syncAllDataIfNeeded(String companyCode) async {
  return CachePartitions.run(() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final existing = _dataSyncWork;
    if (existing != null) {
      final same = _dataSyncOwner == uid && _dataSyncCompany == companyCode;
      await existing;
      if (same) return;
    }
    if (uid.isEmpty || FirebaseAuth.instance.currentUser?.uid != uid) return;
    _dataReadyOwner = null;
    _dataReadyCompany = null;
    _dataReadyEpoch = null;
    _dataSyncOwner = uid;
    _dataSyncCompany = companyCode;
    final done = Completer<bool>();
    _dataSyncWork = done.future;
    try {
      final readScope = await ReadAuthorizationSnapshot.capture();
      final succeeded = await _runDataSync(companyCode);
      if (succeeded &&
          readScope.isCurrent &&
          FirebaseAuth.instance.currentUser?.uid == uid &&
          PermissionsService().isLoaded) {
        _dataReadyOwner = uid;
        _dataReadyCompany = companyCode;
        _dataReadyEpoch = ReadAuthorizationEpoch.value;
      }
      done.complete(succeeded);
    } catch (error) {
      done.complete(false);
      rethrow;
    } finally {
      if (identical(_dataSyncWork, done.future)) _dataSyncWork = null;
    }
  });
}

Future<bool> _runDataSync(String companyCode) async {
  return CachePartitions.run(() async {
    if (_isSyncing) {
      print("⚠️ مزامنة قيد التنفيذ، تم تجاهل الطلب الجديد");
      return false;
    }

    var succeeded = true;
    final syncElapsed = Stopwatch()..start();
    _isSyncing = true;
    print("🔄 بدء المزامنة للشركة: $companyCode");

    try {
      final prefs = await CachePartitions.preferences();
      final runScope = await ReadAuthorizationSnapshot.capture();
      final syncStartedAt = DateTime.now().toUtc().toIso8601String();

      // ⭐ helper: sync قسم مع lastSync management
      Future<void> syncOneWithLastSync({
        required String name,
        required String module,
        required String lastSyncKey,
        required Future<void> Function() full,
        required Future<void> Function(String since) incremental,
      }) async {
        try {
          runScope.check();
          if (!SyncReadAccess.allows(module)) return;
          final only = _resyncOnly;
          if (only != null && !only.contains(module)) return;
          if (module == 'daily') {
            // Ordering only: let in-flight permission refreshes finish so the
            // merge does not start just before they invalidate its scope.
            await PermissionsService().whenRefreshesIdle();
            runScope.check();
            await StagedInbox.mergeDaily(companyCode);
          }
          final lastSync = prefs.getString(lastSyncKey);
          if (lastSync == null) {
            await full();
            runScope.check();
            await prefs.setString(lastSyncKey, syncStartedAt);
          } else {
            await incremental(lastSync);
          }
          if (module == 'daily') await StagedInbox.publishAfterSync(companyCode);
          print("  ✅ $name");
        } catch (e) {
          succeeded = false;
          print("  ❌ $name: $e");
        }
      }

      // ⭐ helper: sync قسم مخصص
      Future<void> syncOneCustom({
        required String name,
        required Future<void> Function() runner,
        String? module,
      }) async {
        try {
          runScope.check();
          final only = _resyncOnly;
          if (only != null && module != null && !only.contains(module)) return;
          await runner();
          runScope.check();
          print("  ✅ $name");
        } catch (e) {
          succeeded = false;
          print("  ❌ $name: $e");
        }
      }

      final modules = WorkPool(3);
      // Administrative lists are refreshed promptly, but do not block business pulls.
      final administration = (() async {
        if (PermissionsService().isSuperAdmin) {
          print("📦 [Super Admin] مزامنة الشركات...");
          try {
            await CompanyService().fetchAllCompanies();
            print("  ✅ الشركات");
          } catch (e) {
            succeeded = false;
            print("  ❌ الشركات: $e");
          }
        }

        // ──────────────────────────────────────────────────────
        // ⭐ مزامنة المستخدمين — للأدمن فقط (شركته فقط)
        // ──────────────────────────────────────────────────────
        if (PermissionsService().currentRole == 'admin') {
          print("📦 [Admin] مزامنة مستخدمي شركته...");
          try {
            await UserService().fetchAllUsers(companyCode: companyCode);
            print("  ✅ المستخدمين");
          } catch (e) {
            succeeded = false;
            print("  ❌ المستخدمين: $e");
          }
        }
      })();
      final tasks = <Future<void>>[
        modules.run(() => (() => syncOneCustom(
            name: 'تحويلات الخزائن',
            module: 'transfers',
            runner: () => TreasuryTransferService().sync(companyCode)))()),
        modules.run(() => (() => syncOneWithLastSync(
              name: 'اليوميات',
              module: 'daily',
              lastSyncKey: 'last_sync_daily_$companyCode',
              full: () => DailyService().syncAllTransactions(companyCode),
              incremental: (since) =>
                  DailyService().syncChangesFromServer(companyCode, since),
            ))()),
        modules.run(() => (() => syncOneWithLastSync(
              name: 'التسويات',
              module: 'settlement',
              lastSyncKey: 'last_sync_settlement_$companyCode',
              full: () =>
                  SupplierSettlementService().fetchAllSettlements(companyCode),
              incremental: (since) => SupplierSettlementService()
                  .syncChangesFromServer(companyCode, since),
            ))()),
        modules.run(() => (() => syncOneWithLastSync(
              name: 'التكويد',
              module: 'coding',
              lastSyncKey: 'last_sync_coding_$companyCode',
              full: () => CodingService().fetchAllCoding(companyCode),
              incremental: (since) =>
                  CodingService().syncChangesFromServer(companyCode, since),
            ))()),
        modules.run(() => (() => syncOneWithLastSync(
              name: 'الموردين',
              module: 'supplier',
              lastSyncKey: 'last_sync_supplier_$companyCode',
              full: () => SupplierService().fetchAllSupplier(companyCode),
              incremental: (since) =>
                  SupplierService().syncChangesFromServer(companyCode, since),
            ))()),
        modules.run(() => (() => syncOneWithLastSync(
              name: 'الجرد',
              module: 'inventory',
              lastSyncKey: 'last_sync_inventory_$companyCode',
              full: () => InventoryService().fetchAllInventory(companyCode),
              incremental: (since) =>
                  InventoryService().syncChangesFromServer(companyCode, since),
            ))()),
        modules.run(() => (() async {
              await syncOneWithLastSync(
                name: 'الموظفين',
                module: 'employees',
                lastSyncKey: 'last_sync_employees_$companyCode',
                full: () => EmployeeService().fetchAllEmployees(companyCode),
                incremental: (since) =>
                    EmployeeService().syncChangesFromServer(companyCode, since),
              );
              runScope.check();
              await syncOneCustom(
                name: 'HR',
                module: 'hr',
                runner: () async {
                  final results = await HRService().syncAll(companyCode);
                  if (results.values.any((v) => v != 'ok' && v != 'skipped'))
                    throw StateError('HR sync incomplete');
                },
              );
            })()),
        modules.run(() => (() async {
              try {
                await CommercialService().syncPending(companyCode);
              } catch (error) {
                succeeded = false;
                print('Commercial pending failed: $error');
              }
              runScope.check();
              await Future.wait([
                syncOneWithLastSync(
                  name: 'المبيعات',
                  module: 'sales',
                  lastSyncKey: '${ApiConstants.LAST_SYNC_SALES}$companyCode',
                  full: () =>
                      CommercialService().fetchAll('sales', companyCode),
                  incremental: (since) => CommercialService()
                      .syncChangesFromServer('sales', companyCode, since),
                ),
                syncOneWithLastSync(
                  name: 'المرتجعات',
                  module: 'returns',
                  lastSyncKey: '${ApiConstants.LAST_SYNC_RETURNS}$companyCode',
                  full: () =>
                      CommercialService().fetchAll('returns', companyCode),
                  incremental: (since) => CommercialService()
                      .syncChangesFromServer('returns', companyCode, since),
                ),
                syncOneWithLastSync(
                  name: 'تحصيلات العملاء',
                  module: 'customer-payments',
                  lastSyncKey:
                      '${ApiConstants.LAST_SYNC_CUSTOMER_PAYMENTS}$companyCode',
                  full: () => CommercialService()
                      .fetchAll('customer-payments', companyCode),
                  incremental: (since) => CommercialService()
                      .syncChangesFromServer(
                          'customer-payments', companyCode, since),
                ),
                syncOneWithLastSync(
                  name: 'التحويلات المخزنية',
                  module: 'transfers',
                  lastSyncKey:
                      '${ApiConstants.LAST_SYNC_TRANSFERS}$companyCode',
                  full: () =>
                      CommercialService().fetchAll('transfers', companyCode),
                  incremental: (since) => CommercialService()
                      .syncChangesFromServer('transfers', companyCode, since),
                ),
              ]);
            })()),
      ];
      await awaitWithCompanion(administration, () async {
        await Future.wait(tasks);
        // ──────────────────────────────────────────────────────
        // retryPending (HR)
        // ──────────────────────────────────────────────────────
        try {
          await HRService().retryAllPending(companyCode);
          print("  ✅ retryPending");
        } catch (e) {
          succeeded = false;
          print("  ❌ retryPending: $e");
        }

        // ──────────────────────────────────────────────────────
        // الأرصدة المحلية
        // ──────────────────────────────────────────────────────
        try {
          await DailyService().getDailySummaryLocal(companyCode);
          print("  ✅ الأرصدة المحلية");
        } catch (e) {
          succeeded = false;
          print("  ❌ الأرصدة المحلية: $e");
        }
      });
      print("═══════════════════════════════════════");
      print("✅ اكتملت المزامنة");
      print("═══════════════════════════════════════");
    } catch (e) {
      succeeded = false;
      print("❌ فشلت المزامنة المركزية: $e");
    } finally {
      _isSyncing = false;
      syncElapsed.stop();
      print('[Sync] completed ms=${syncElapsed.elapsedMilliseconds} success=$succeeded');

      // ⭐ إشارة إن أول مزامنة خلصت
      if (!_initialSyncCompleter.isCompleted) {
        _initialSyncCompleter.complete();
      }
    }
    return succeeded;
  });
}

// ============================================================
// تشغيل Global Sync
// ============================================================

void initializeGlobalListener(String companyCode) {
  print("🌐 طلب تشغيل المزامنة للشركة: $companyCode");
  CommercialService.startBackgroundSync(companyCode);

  // ربط الـ callback مرة واحدة فقط
  _syncService.onWebSocketConnected ??= () async {
    // auth_success now runs the current permission reconciliation FIRST.
    // Starting a second refresh here would invalidate the data sync it joins.
    if (!_syncService.authorizationReady || !PermissionsService().isLoaded)
      return;
    await syncAllDataIfNeeded(
      _syncService.currentCompanyCode ?? companyCode,
    );
  };

  // Verify current scope first. Only changed data modules invalidate their
  // own company cursors; queued changes wait for the old data run to settle.
  PermissionsService().onScopeNarrowed ??= () {
    final code = _syncService.currentCompanyCode ?? companyCode;
    print("🔐 نطاق الصلاحيات اتغير: تحديث الأقسام المتأثرة بعد التطهير");
    _scheduleScopeResync(code);
  };

  _syncService.onPermissionsChanged ??= ({required bool resync}) async {
    print("🔐 معالجة permissions_changed (resync=$resync)");
    if (_permDelayMs > 0) await Future.delayed(Duration(milliseconds: _permDelayMs));
    try {
      // resync=false means the server signalled no narrowing: re-verify without
      // hiding the current scope, so the dashboard cards stay put. resync=true
      // keeps the fail-closed hold until the narrowed scope is applied.
      await PermissionsService().verifyCurrentEffectiveProfile(restrictWhileLoading: resync);
    } catch (e) {
      print("⚠️ فشل تحديث الصلاحيات: $e");
      rethrow;
    }
    if (resync) {
      _scheduleScopeResync(_syncService.currentCompanyCode ?? companyCode);
    }
  };

  // ⭐ WebSocket فشل → إشارة فورية
  _syncService.onWebSocketConnectionFailed ??= () {
    print("⚠️ WebSocket connection failed — signaling main()");

    if (!_wsConnectionFailedCompleter.isCompleted) {
      _wsConnectionFailedCompleter.complete();
    }
  };

  // لو WebSocket شغال بالفعل لنفس الشركة
  if (_syncService.isConnected &&
      _syncService.currentCompanyCode == companyCode) {
    print("✅ WebSocket شغال بالفعل للشركة: $companyCode");
    return;
  }

  print("🌐 بدء WebSocket للشركة: $companyCode");

  _syncService.startSync(companyCode);
}

// ============================================================
// إيقاف Global Sync
// ============================================================

void disposeGlobalListener() {
  globalSyncSubscription?.cancel();
  codingSyncSubscription?.cancel();
  inventorySyncSubscription?.cancel();
  supplierSyncSubscription?.cancel();

  _syncService.stopSync();
  _dataReadyOwner = null;
  _dataReadyCompany = null;

  print("🔌 تم إيقاف المزامنة");
}

// ============================================================
// Main
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open-timing measurement (log only): main() start -> first rendered frame.
  // Flutter engine startup before main() is not measurable from Dart.
  final Stopwatch appStartWatch = Stopwatch()..start();
  int mergeMs = 0;    // startup merge block duration (applying staged changes)
  int syncWaitMs = 0; // open-time sync wait duration
  // Checkpoint hooks must exist before the first sync of this run, not only once a merge has run.
  StagedInbox.installHooks();

  // ==========================================================
  // Firebase
  // ==========================================================

  await (() => Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ))();

  if (const bool.fromEnvironment('EMU')) {
    // LOCAL EXPERIMENT ONLY: emulators, and no FCM registration with the real project.
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
    FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8081);
    FirebaseDatabase.instance.useDatabaseEmulator('localhost', 9000);
  } else {
    await (() => FcmService.instance.initialize())();
  }
  PermissionsService().onOwnAccountDeleted = () {
    disposeGlobalListener();
    appNavigatorKey.currentState
        ?.pushNamedAndRemoveUntil('/login', (_) => false);
  };

  // ==========================================================
  // Hive
  // ==========================================================

  await (() => Hive.initFlutter())();

  CachePartitions.enable();
  final startupPrefs = await SharedPreferences.getInstance();
  final startupUid = FirebaseAuth.instance.currentUser?.uid;
  final startupCompany = startupPrefs.getString('company_code');
  if (startupUid != null &&
      startupCompany != null &&
      startupCompany.isNotEmpty) {
    // Decided BEFORE activate() creates the boxes: no cache box for this user+company on this
    // device means first use, the only case that still waits for the first full sync.
    _deviceHadNoCacheAtStart = !(await Hive.boxExists(
        CachePartitions.physicalName('cache_metadata_box', startupUid, startupCompany)));
    print('🧭 first use on this device (no Hive boxes at start): $_deviceHadNoCacheAtStart');
    if (!_deviceHadNoCacheAtStart) {
      // Early freshness probe: when something is staged, the daily feed's
      // server check starts NOW, overlapping the box opening below instead of
      // waiting for it. No extra calls: it fires only when batches are staged,
      // and not at all once the backend returns the scope fingerprint with the
      // verified profile (remembered in plain SharedPreferences).
      unawaited(StagedInbox.peekStagedCountFor(startupUid, startupCompany)
          .then((staged) {
        if (staged > 0 &&
            startupPrefs.getString('profile_scope_fp_v1') != '1') {
          StagedInbox.startEarlyDailyProbe(startupCompany);
        }
      }));
    }
    await (() => CachePartitions.activate(startupUid, startupCompany))();
  }

  // ==========================================================
  // SharedPreferences
  // ==========================================================

  final prefs = await CachePartitions.preferences();

  final bool rememberMe = prefs.getBool('remember_me') ?? false;
  final String? userName = prefs.getString('user_name');
  final String? companyName = prefs.getString('company_name');
  final String? companyCode = prefs.getString('company_code');
  final String savedTheme = prefs.getString('theme_mode') ?? 'dark';

  // ==========================================================
  // الشاشة الأولى
  // ==========================================================

  Widget initialScreen;

  if (rememberMe &&
      userName != null &&
      companyCode != null &&
      CachePartitions.isReady) {
    // --------------------------------------------------------
    // تحميل الصلاحيات أولاً (سريع — من Hive)
    // --------------------------------------------------------
    // ثبّت خطاف resync قبل أي انتقال صلاحيات محتمل أثناء التحميل
    // (سباق بدء التشغيل: لقطة Firestore الأولى قد تسبق ربط UI)
    PermissionsService().onScopeNarrowed ??= () {
      print("🔐 نطاق الصلاحيات اتغير أثناء بدء التشغيل: resync");
      _scheduleScopeResync(companyCode);
    };
    // Listener deferred: it starts after the startup merge block below, so
    // its first snapshot and refresh neither gate the merge nor move the
    // authorization epoch under it.
    await (() => PermissionsService().loadPermissions(deferListener: true))();

    unawaited(FcmService.instance.restoreRegistrationIfEnabled());
    DeepLinkService.instance.initialize();
    await _detectPushUnavailable();

    // Startup order (loading page stays up until runApp): open -> verify -> merge the changes the
    // service worker staged while the app was closed. No WebSocket and no old sync run yet; the
    // listener (WebSocket + incremental sync) starts after this block, in its original order.
    // Bounded by the old 10s sync wait. On timeout the merge keeps going and the sync joins it.
    // `?startup=bg` restores the previous mode (merge in the background, home right away).
    if (_startupMergeMode == 'bg') {
      unawaited(StagedInbox.mergeDaily(companyCode, eagerVerify: false).then((_) => StagedInbox.mergeTreasury(companyCode)).then((_) => StagedInbox.mergeCoding(companyCode)).then((_) => StagedInbox.mergeEmployees(companyCode)).then((_) => StagedInbox.mergeSupplier(companyCode)).then((_) => StagedInbox.mergeSettlement(companyCode)).then((_) => StagedInbox.mergeInventory(companyCode)).then((_) => StagedInbox.mergeAllCommercial(companyCode)));
    } else {
      bool online = true;
      if (kIsWeb) {
        try {
          online = html.window.navigator.onLine ?? true;
        } catch (_) {}
      }
      final gate = Completer<void>();
      _startupMergeGate = gate.future;
      final Stopwatch swStartMerge = Stopwatch()..start();
      String reason;
      try {
        if (!online) {
          reason = 'skipped: offline';
        } else if (_deviceHadNoCacheAtStart) {
          reason = 'skipped: first use on this device (nothing can be staged)';
        } else {
          // Prefetch result from the page: nothing staged = open at once, no loading wait.
          final staged = await StagedInbox.peekStagedCount()
              .timeout(const Duration(milliseconds: 1500), onTimeout: () => -1);
          if (staged == 0) {
            reason = 'skipped: nothing staged';
          } else {
            bool gateExpired = false;
            try {
              // One 10 s budget for: verify permissions, let the listener's first snapshot and any
              // refresh it starts settle (they move the authorization epoch), then merge.
              bool verified = true;
              await (() async {
                try {
                  await PermissionsService().verifyCurrentEffectiveProfile();
                } catch (_) {
                  verified = false;
                }
                if (!verified) return;
                final fs = PermissionsService().firstSnapshotHandled;
                if (fs != null) {
                  try { await fs; } catch (_) {}
                }
                // Every server refresh the listener's snapshot started must be finished first.
                await PermissionsService().whenRefreshesIdle();
                // Gate expired while waiting for permissions: do not start the merge beside the sync.
                if (gateExpired) return;
                await StagedInbox.mergeDaily(companyCode, eagerVerify: false);
                if (gateExpired) return;
                await StagedInbox.mergeTreasury(companyCode);
                if (gateExpired) return;
                await StagedInbox.mergeCoding(companyCode);
                if (gateExpired) return;
                await StagedInbox.mergeEmployees(companyCode);
                await StagedInbox.mergeSupplier(companyCode);
                await StagedInbox.mergeSettlement(companyCode);
                await StagedInbox.mergeInventory(companyCode);
                await StagedInbox.mergeAllCommercial(companyCode);
              })()
                  .timeout(const Duration(seconds: 10));
              reason = verified
                  ? 'merge finished (${staged < 0 ? 'staged count unknown' : '$staged batch(es) staged'})'
                  : 'permission verification not completed: nothing merged, data left staged';
              if (!verified) _startupMergeFailed = true;
            } on TimeoutException {
              gateExpired = true;
              reason = 'TIMEOUT after 10s: opening; staged data is left to the still-running merge or the normal sync';
            }
          }
        }
      } catch (e) {
        reason = 'error: $e';
        _startupMergeFailed = true;
      } finally {
        gate.complete();
      }
      mergeMs = swStartMerge.elapsedMilliseconds;
      print('🧭 startup merge: $reason | result: ${StagedInbox.lastOutcome} | waited ${swStartMerge.elapsedMilliseconds}ms before the first screen');
    }
    // Deferred above: the listener starts now on every path (merge done,
    // skipped, or running in background), so no permission change is missed.
    PermissionsService().ensurePermissionListenerStarted();

    // --------------------------------------------------------
    // فحص التحقق من الإيميل
    // --------------------------------------------------------
    bool needsEmailVerification = false;
    String currentEmail = '';
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await (() => currentUser.reload())();
        currentEmail = currentUser.email ?? '';
        if (!currentUser.emailVerified && currentEmail.isNotEmpty) {
          try {
            final userDoc = await FirebaseFirestore.instance
                .collection('users')
                .doc(currentEmail.toLowerCase())
                .get()
                .timeout(const Duration(seconds: 5));
            if (userDoc.exists) {
              needsEmailVerification =
                  userDoc.data()?['requires_email_verification'] == true;
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      print('⚠️ email verification check: $e');
    }

    if (needsEmailVerification) {
      initialScreen = VerifyEmailScreen(email: currentEmail);
    } else {
      // --------------------------------------------------------
      // فحص الإنترنت فوراً
      // --------------------------------------------------------
      bool isOnline = true;
      if (kIsWeb) {
        try {
          final onlineValue = html.window.navigator.onLine;
          isOnline = onlineValue ?? true;
          print("🌐 navigator.onLine = $onlineValue → isOnline = $isOnline");
        } catch (e) {
          print("⚠️ Failed to check onLine: $e");
        }
      }

      // --------------------------------------------------------
      // تشغيل WebSocket
      // --------------------------------------------------------
      initializeGlobalListener(companyCode);

      // --------------------------------------------------------
      // منطق الانتظار:
      //  • Online → استنى: (المزامنة تخلص) أو (WebSocket يفشل) أو (10s)
      //  • Offline → افتح فوراً
      // --------------------------------------------------------
      // Open-time wait happens only when there is nothing local to show (first use)
      // or the startup merge failed and the open-time sync must cover it (case 4).
      // Push availability never gates opening: a device with cached boxes opens
      // instantly and syncs in the background, with or without push.
      if (isOnline && (_deviceHadNoCacheAtStart || _forceLegacyWait || _startupMergeFailed)) {
        // One 10s budget across the startup merge and this wait: a late merge
        // failure waits only for what is left, never a second 10s.
        final remainingMs =
            _startupMergeFailed ? (10000 - mergeMs).clamp(0, 10000) : 10000;
        if (remainingMs <= 0) {
          print('⏳ open-sync wait skipped: the merge already used the 10s budget; '
              'opening now, sync continues in background');
        } else {
          final swWait = Stopwatch()..start();
          print('⏳ open-sync wait: noBoxes=$_deviceHadNoCacheAtStart mergeFailed=$_startupMergeFailed budget=${remainingMs}ms');
          print(_startupMergeFailed
              ? "⏳ فشل الدمج: ننتظر المزامنة (max ${(remainingMs / 1000).toStringAsFixed(0)}s)..."
              : "⏳ أول استخدام: ننتظر الجلب الأولي (max ${(remainingMs / 1000).toStringAsFixed(0)}s)...");
          try {
            await Future.any([
              _initialSyncCompleter.future,
              _wsConnectionFailedCompleter.future,
            ]).timeout(Duration(milliseconds: remainingMs));
            print("✅ المزامنة اكتملت أو الاتصال فشل — فتح التطبيق");
          } on TimeoutException {
            print("⏱️ المهلة عدّت — فتح التطبيق بالبيانات الحالية");
          } catch (e) {
            print("⚠️ خطأ أثناء الانتظار: $e — فتح التطبيق");
          }
          syncWaitMs = swWait.elapsedMilliseconds;
        }
      } else if (isOnline) {
        print("⚡ جهاز عنده بيانات محفوظة — فتح فوري والمزامنة في الخلفية");
      } else {
        print("📵 مفيش نت — فتح فوري");
      }

      initialScreen = HomePage(
        userName: userName,
        companyName: companyName ?? 'شركتي',
        companyCode: companyCode,
      );
    }
  } else {
    initialScreen = const LoginScreen();
  }

  // ==========================================================
  // تشغيل التطبيق
  // ==========================================================

  if (FirebaseAuth.instance.currentUser == null || !CachePartitions.isReady) {
    initialScreen = const LoginScreen();
  }
  final preRunAppMs = appStartWatch.elapsedMilliseconds;
  runApp(
    IslamApp(
      initialScreen: initialScreen,
      initialThemeMode:
          savedTheme == 'light' ? ThemeMode.light : ThemeMode.dark,
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    print('⏱️ open timing: total=${appStartWatch.elapsedMilliseconds}ms '
        '| init=${preRunAppMs - mergeMs - syncWaitMs}ms '
        '| merge=${mergeMs}ms | syncWait=${syncWaitMs}ms '
        '| firstFrame=+${appStartWatch.elapsedMilliseconds - preRunAppMs}ms');
  });
}

// ============================================================
// IslamApp
// ============================================================

class IslamApp extends StatefulWidget {
  final Widget initialScreen;
  final ThemeMode initialThemeMode;

  const IslamApp({
    super.key,
    required this.initialScreen,
    this.initialThemeMode = ThemeMode.dark,
  });

  static _IslamAppState of(BuildContext context) {
    return context.findAncestorStateOfType<_IslamAppState>()!;
  }

  @override
  State<IslamApp> createState() => _IslamAppState();
}

// ============================================================
// App State
// ============================================================

class _IslamAppState extends State<IslamApp> with WidgetsBindingObserver {
  late ThemeMode _themeMode;
  bool _resumeSyncInProgress = false;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncWhenAppResumes();
    }
  }

  // ==========================================================
  // Sync عند رجوع التطبيق
  // ==========================================================
  Future<void> _syncWhenAppResumes() async {
    if (_resumeSyncInProgress || _isSyncing) return;

    _resumeSyncInProgress = true;

    try {
      final prefs = await CachePartitions.preferences();

      final bool rememberMe = prefs.getBool('remember_me') ?? false;
      final String? companyCode = prefs.getString('company_code');

      if (!rememberMe || companyCode == null || companyCode.isEmpty) {
        return;
      }

      // ⭐ لو WebSocket متصل → syncPending بس (توفير bandwidth)
      if (_syncService.isConnected &&
          _syncService.currentCompanyCode == companyCode) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (!_syncService.authorizationReady ||
            _dataReadyOwner != uid ||
            _dataReadyCompany != companyCode ||
            _dataReadyEpoch != ReadAuthorizationEpoch.value) {
          await PermissionsService().verifyCurrentEffectiveProfile();
          await syncAllDataIfNeeded(companyCode);
          return;
        }
        print("✅ WebSocket متصل؛ جاري syncPending فقط...");
        try {
          await CommercialService().syncPending(companyCode);
          print("  ✅ Commercial pending synced (resume)");
        } catch (e) {
          print("  ⚠️ Commercial pending (resume): $e");
        }
        return;
      }

      // WebSocket غير متصل → أعد الاتصال (بيبدأ sync كامل عند النجاح)
      print("🔌 WebSocket غير متصل؛ جاري إعادة الاتصال");
      initializeGlobalListener(companyCode);
    } catch (e) {
      print("❌ تعذر التحقق من اتصال المزامنة بعد العودة: $e");
    } finally {
      _resumeSyncInProgress = false;
    }
  }

  // ==========================================================
  // Theme
  // ==========================================================
  void changeTheme(ThemeMode themeMode) async {
    setState(() {
      _themeMode = themeMode;
    });

    try {
      final prefs = await CachePartitions.preferences();
      await prefs.setString(
        'theme_mode',
        themeMode == ThemeMode.light ? 'light' : 'dark',
      );
    } catch (e) {
      print("⚠️ فشل حفظ الثيم: $e");
    }
  }

  // ==========================================================
  // Dispose
  // ==========================================================
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeGlobalListener();
    super.dispose();
  }

  // ==========================================================
  // Build
  // ==========================================================
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IslamApp V1.0',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: widget.initialScreen,
      routes: {
        '/login': (context) => const LoginScreen(),
        '/register': (context) => const PhoneEntryScreen(),
        '/forgot-password': (context) => const ForgotPasswordScreen(),
      },
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
    );
  }
}
