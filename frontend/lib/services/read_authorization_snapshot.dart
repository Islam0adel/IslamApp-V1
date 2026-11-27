// frontend/lib/services/read_authorization_snapshot.dart
import 'cache_partitions.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

// عهد تفويض القراءة: يبطل القراءات ولا يمس العمليات المؤكدة
/// Invalidates reads, never committed write acknowledgements or pending work.
class ReadAuthorizationEpoch {
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  // يعيد مصدر إشعار تغيّر العهد
  static Listenable get changes => _changes;

  // يبطل القراءات الجارية
  static void invalidate() {
    _changes.value++;
  }

  // يعيد رقم العهد الحالي
  static int get value => _changes.value;
}

// استثناء يدل على تغيّر الحساب أو صلاحية البيانات أثناء القراءة
class ReadAuthorizationChanged implements Exception {
  const ReadAuthorizationChanged();

  // يعيد رسالة الاستثناء
  @override
  String toString() => 'Account or data access changed during this read';
}

// لقطة تفويض القراءة: ترتبط بقراءة واحدة أو دفعة طلبات
/// One read or multi-request batch, tied to its original account and scope.
class ReadAuthorizationSnapshot {
  ReadAuthorizationSnapshot._(this._epoch, this._uid, this._preferences,
      this._company, this._cacheGeneration);
  final int _epoch;
  final int _cacheGeneration;
  final String? _uid;
  final SharedPreferences _preferences;
  final String? _company;

  // يعيد معرّف المستخدم الحالي
  static String? _currentUid() {
    try {
      final user = FirebaseAuth.instance.currentUser;
      return user == null ? null : jsonEncode([user.uid, user.email]);
    } catch (_) {
      return null;
    }
  }

  // يلتقط لقطة تفويض القراءة
  static Future<ReadAuthorizationSnapshot> capture() async {
    final epoch = ReadAuthorizationEpoch.value;
    final uid = _currentUid();
    final preferences = await SharedPreferences.getInstance();
    final result = ReadAuthorizationSnapshot._(epoch, uid, preferences,
        preferences.getString('company_code'), CachePartitions.generation);
    result.check();
    return result;
  }

  // يحدد هل السياق ما زال نفسه
  bool get sameContext =>
      _cacheGeneration == CachePartitions.generation &&
      (!CachePartitions.enabled || CachePartitions.isReady) &&
      _uid == _currentUid() &&
      _company == _preferences.getString('company_code');

  // يحدد هل اللقطة ما زالت صالحة
  bool get isCurrent => _epoch == ReadAuthorizationEpoch.value && sameContext;

  // يتحقق من صلاحية اللقطة ويرمي استثناءً إن تغيّرت
  void check() {
    if (!isCurrent) {
      throw const ReadAuthorizationChanged();
    }
  }
}
