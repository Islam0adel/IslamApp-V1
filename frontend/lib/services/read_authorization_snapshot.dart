import 'cache_partitions.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Invalidates reads, never committed write acknowledgements or pending work.
class ReadAuthorizationEpoch {
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  static Listenable get changes => _changes;
  static void invalidate() {
    _changes.value++;
  }

  static int get value => _changes.value;
}

class ReadAuthorizationChanged implements Exception {
  const ReadAuthorizationChanged();
  @override
  String toString() => 'Account or data access changed during this read';
}

/// One read or multi-request batch, tied to its original account and scope.
class ReadAuthorizationSnapshot {
  ReadAuthorizationSnapshot._(
      this._epoch, this._uid, this._preferences, this._company, this._cacheGeneration);
  final int _epoch;
  final int _cacheGeneration;
  final String? _uid;
  final SharedPreferences _preferences;
  final String? _company;

  static String? _currentUid() {
    try {
      final user = FirebaseAuth.instance.currentUser;
      return user == null ? null : jsonEncode([user.uid, user.email]);
    } catch (_) {
      return null;
    }
  }

  static Future<ReadAuthorizationSnapshot> capture() async {
    final epoch = ReadAuthorizationEpoch.value;
    final uid = _currentUid();
    final preferences = await SharedPreferences.getInstance();
    final result = ReadAuthorizationSnapshot._(
        epoch, uid, preferences, preferences.getString('company_code'), CachePartitions.generation);
    result.check();
    return result;
  }

  bool get sameContext =>
      _cacheGeneration == CachePartitions.generation &&
      (!CachePartitions.enabled || CachePartitions.isReady) &&
      _uid == _currentUid() &&
      _company == _preferences.getString('company_code');

  bool get isCurrent => _epoch == ReadAuthorizationEpoch.value && sameContext;

  void check() {
    if (!isCurrent) {
      throw const ReadAuthorizationChanged();
    }
  }
}
