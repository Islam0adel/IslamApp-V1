import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import '../core/constants.dart';
import 'auth_http.dart';
import 'journal_save_intent.dart';

class JournalSaveFailure implements Exception {
  final int? statusCode;
  final bool canReplace;
  const JournalSaveFailure({this.statusCode, this.canReplace = false});
  @override
  String toString() {
    if (statusCode == 403)
      return 'لا توجد صلاحية لتأكيد أو تنفيذ الحفظ. المحاولة الأصلية محفوظة.';
    if (statusCode == 409)
      return 'تغيّر السجل أو رُفضت بيانات المحاولة. راجع السجل قبل التعديل.';
    if (statusCode == 400 || statusCode == 422)
      return 'رفض الخادم البيانات. راجعها ثم أعد الحفظ.';
    return 'لم يتأكد الحفظ. اضغط حفظ مرة أخرى لتأكيد نفس المحاولة، بدون إنشاء إذن جديد.';
  }
}

class _JournalFlight {
  final String payload;
  final Future<Map<String, dynamic>> future;
  _JournalFlight(this.payload, this.future);
}

/// A foreground submission, not an automatic offline queue. The server receipt
/// is authoritative. Only an uncertain or previously preserved attempt uses GET.
class JournalSaveClient {
  static final Map<String, _JournalFlight> _flights = {};
  final JournalIntentStore store;
  JournalSaveClient({JournalIntentStore? store})
      : store = store ?? JournalIntentStore();
  String get _base => '${ApiConstants.baseUrl}/transactions';
  bool _sameOwner(JournalSaveIntent intent) =>
      FirebaseAuth.instance.currentUser?.uid == intent.ownerUid;
  void _guard(JournalSaveIntent intent) {
    if (!_sameOwner(intent))
      throw StateError('تغيّر الحساب. لم تُرسل محاولة باسم حساب آخر.');
  }

  Future<Map<String, dynamic>> submit(JournalSaveIntent intent,
      {required Future<bool> Function(Map<String, dynamic>) applySnapshot}) {
    _guard(intent);
    if (!intent.submitted) throw StateError('No captured journal intention');
    final key = jsonEncode([intent.ownerUid, intent.operationId]);
    final encoded = jsonEncode(intent.payload);
    final current = _flights[key];
    if (current != null) {
      if (current.payload != encoded)
        throw StateError('Concurrent journal payload differs');
      return current.future;
    }
    late Future<Map<String, dynamic>> future;
    future = _submit(intent, applySnapshot).whenComplete(() {
      if (identical(_flights[key]?.future, future)) _flights.remove(key);
    });
    _flights[key] = _JournalFlight(encoded, future);
    return future;
  }

  Map<String, dynamic> _decode(String body) {
    final value = jsonDecode(body);
    if (value is! Map || value['status'] != 'success') {
      throw const FormatException('Invalid journal acknowledgement');
    }
    return Map<String, dynamic>.from(value);
  }

  void _verifyRecord(Map<String, dynamic> result, JournalSaveIntent intent) {
    if (result['available'] == false && result['committed'] == true) return;
    final record = result['record'];
    if (record is! Map ||
        record['company_code'] != intent.companyCode ||
        (int.tryParse(record['serial'].toString()) ?? 0) <= 0 ||
        record['branch_code']?.toString().isNotEmpty != true ||
        DateTime.tryParse(record['updated_at']?.toString() ?? '') == null ||
        result['serial']?.toString() != record['serial']?.toString()) {
      throw const FormatException('Journal acknowledgement scope is invalid');
    }
  }

  Future<Map<String, dynamic>?> _status(JournalSaveIntent intent) async {
    _guard(intent);
    final uri = Uri.parse(
            '$_base/save-status/${Uri.encodeComponent(intent.companyCode)}/${Uri.encodeComponent(intent.operationId)}')
        .replace(queryParameters: {'branch_code': intent.branchCode});
    final response =
        await AuthHttp.get(uri).timeout(const Duration(seconds: 20));
    _guard(intent);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200)
      throw JournalSaveFailure(statusCode: response.statusCode);
    final result = _decode(response.body);
    if (result['committed'] != true ||
        (result['available'] != false && result['record'] is! Map)) {
      throw const FormatException('Unverified journal status');
    }
    _verifyRecord(result, intent);
    return result;
  }

  Future<Map<String, dynamic>> _submit(JournalSaveIntent intent,
      Future<bool> Function(Map<String, dynamic>) applySnapshot) async {
    final old = await store.load(
        ownerUid: intent.ownerUid,
        companyCode: intent.companyCode,
        branchCode: intent.branchCode,
        serial: intent.serial);
    _guard(intent);
    // save refuses a different pending operation or a changed preserved payload.
    await store.save(intent);
    _guard(intent);
    Map<String, dynamic>? result;
    if (old != null) {
      try {
        result = await _status(intent);
      } on JournalSaveFailure {
        rethrow;
      } catch (_) {
        throw const JournalSaveFailure();
      }
    }
    if (result == null) {
      var statusChecked = false;
      try {
        _guard(intent);
        final response = await AuthHttp.post(Uri.parse('$_base/save'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(intent.payload))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          if (response.statusCode == 409) {
            // A receipt replay can report a committed but now unavailable row
            // as 409. Establish the outcome before allowing a different intent.
            statusChecked = true;
            result = await _status(intent);
          }
          if (result == null) {
            if ({400, 404, 409, 422}.contains(response.statusCode)) {
              if (_sameOwner(intent)) await store.acknowledge(intent);
              throw JournalSaveFailure(
                  statusCode: response.statusCode, canReplace: true);
            }
            throw JournalSaveFailure(statusCode: response.statusCode);
          }
        } else {
          result = _decode(response.body);
          _verifyRecord(result, intent);
        }
      } catch (error) {
        if (error is JournalSaveFailure && error.canReplace) rethrow;
        if (statusChecked) {
          if (error is JournalSaveFailure) rethrow;
          throw const JournalSaveFailure();
        }
        if (!_sameOwner(intent))
          throw StateError(
              'تغيّر الحساب بعد الإرسال. احتُفظ بمحاولته الأصلية.');
        // One read after an uncertain response, never a second automatic POST.
        try {
          result = await _status(intent);
        } on JournalSaveFailure {
          rethrow;
        } catch (_) {
          throw const JournalSaveFailure();
        }
        if (result == null) {
          if (error is JournalSaveFailure) throw error;
          throw const JournalSaveFailure();
        }
      }
    }
    if (!_sameOwner(intent)) {
      // Preserve the old owner's pending intention for their later reconciliation.
      return {
        'success': true,
        'committed': true,
        'owner_changed': true,
        'refresh_pending': true,
        'available': result['available'] != false
      };
    }
    var refreshed = false;
    if (result['available'] != false) {
      try {
        refreshed = await applySnapshot(result);
      } catch (_) {
        refreshed = false;
      }
    }
    var intentPending = true;
    if (_sameOwner(intent)) {
      // A cache/storage error after a confirmed commit must not invite a new
      // business write. Leaving a failed acknowledgement is safe: status retries it.
      try {
        await store.acknowledge(intent);
        intentPending = false;
      } catch (_) {
        refreshed = false;
      }
    }
    return {
      ...result,
      'success': true,
      'committed': true,
      'owner_changed': !_sameOwner(intent),
      'intent_pending': intentPending,
      'available': result['available'] != false,
      'refresh_pending': !refreshed
    };
  }
}
