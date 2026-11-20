import 'commercial_service.dart';

/// ⭐ وحدة التحويلات المخزنية — واجهة مستقلة فوق نفس محرك التخزين المحلي
/// (Hive) وطابور العمليات والمزامنة المستخدم في الوحدة التجارية.
/// لا يوجد نسخ مكرر من منطق المزامنة: كل العمليات تمر على CommercialService.
class TransfersService {
  final CommercialService _inner = CommercialService();

  static const String kind = 'transfers';

  String newId() => _inner.newId();

  Future<List<Map<String, dynamic>>> fetch(String companyCode,
          {String? branchCode, bool forceRefresh = false}) =>
      _inner.fetch(kind, companyCode, branchCode: branchCode, forceRefresh: forceRefresh);

  Future<Map<String, dynamic>> save(Map<String, dynamic> data) => _inner.save(kind, data);

  Future<void> delete(String companyCode, String id) => _inner.delete(kind, companyCode, id);
}
