// frontend/lib/services/transfers_service.dart
import 'commercial_service.dart';

// وحدة التحويلات المخزنية: تغلّف الخدمة التجارية
/// ⭐ وحدة التحويلات المخزنية — واجهة مستقلة فوق نفس محرك التخزين المحلي
/// (Hive) وطابور العمليات والمزامنة المستخدم في الوحدة التجارية.
/// لا يوجد نسخ مكرر من منطق المزامنة: كل العمليات تمر على CommercialService.
class TransfersService {
  final CommercialService _inner = CommercialService();

  static const String kind = 'transfers';

  // ينشئ معرّفًا جديدًا للتحويل
  String newId() => _inner.newId();

  // يجلب التحويلات المخزنية
  Future<List<Map<String, dynamic>>> fetch(String companyCode,
          {String? branchCode, bool forceRefresh = false}) =>
      _inner.fetch(kind, companyCode,
          branchCode: branchCode, forceRefresh: forceRefresh);

  // يحفظ تحويلًا مخزنيًا
  Future<Map<String, dynamic>> save(Map<String, dynamic> data) =>
      _inner.save(kind, data);

  // يحذف تحويلًا مخزنيًا
  Future<void> delete(String companyCode, String id) =>
      _inner.delete(kind, companyCode, id);
}
