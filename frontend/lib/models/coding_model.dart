// frontend/lib/models/coding_model.dart

// نموذج بيانات الترميز (كود الصنف أو الحساب)
class CodingModel {
  final String code;
  final String name;
  final String? branchCode;

  // لـ types: وارد / صادر
  final String type;

  final String barcode;

  final double wholesalePrice;
  final double sellingPrice;

  final double profitMargin;
  final double profitPercent;

  // سعر الشراء "غير محدد": سجّله كاتب بلا حق تكلفة،
  // ولا يُستخدم في الجرد/المشتريات حتى يحدده صاحب الحق.
  final bool costPending;

  // تأكيد صريح أن صفر التكلفة مقصود — يُرسل فقط عند
  // تأكيد المستخدم، والخادم يشترط حق سعر الشراء له.
  final bool confirmZeroCost;

  // Soft Delete
  //
  // false = السجل نشط
  // true  = السجل محذوف من السيرفر
  final bool isDeleted;

  CodingModel({
    required this.code,
    required this.name,
    this.branchCode,
    this.type = "وارد",
    this.barcode = "",
    this.wholesalePrice = 0.0,
    this.sellingPrice = 0.0,
    this.profitMargin = 0.0,
    this.profitPercent = 0.0,
    this.costPending = false,
    this.confirmZeroCost = false,
    this.isDeleted = false,
  });

  // ============================================================
  // From Map
  // ============================================================

  // ينشئ كائنًا من خريطة بيانات قادمة من الخادم أو التخزين المحلي
  factory CodingModel.fromMap(
    Map<String, dynamic> map,
  ) {
    return CodingModel(
      code: map['code']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      branchCode: map['branch_code']?.toString(),
      type: map['type']?.toString() ?? 'وارد',
      barcode: map['barcode']?.toString() ?? '',
      wholesalePrice: _toDouble(
        map['wholesale_price'] ?? map['wholesalePrice'],
      ),
      sellingPrice: _toDouble(
        map['selling_price'] ?? map['sellingPrice'],
      ),
      profitMargin: _toDouble(
        map['profit_margin'] ?? map['profitMargin'],
      ),
      profitPercent: _toDouble(
        map['profit_percent'] ?? map['profitPercent'],
      ),
      costPending: _toBool(
        map['cost_pending'] ?? map['costPending'],
      ),
      isDeleted: _toBool(
        map['is_deleted'],
      ),
    );
  }

  // ============================================================
  // To Map
  // ============================================================

  // يحوّل الكائن إلى خريطة (Map) جاهزة للتخزين أو الإرسال
  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'name': name,
      if (branchCode != null) 'branch_code': branchCode,
      'type': type,
      'barcode': barcode,
      'wholesale_price': wholesalePrice,
      'selling_price': sellingPrice,
      'profit_margin': profitMargin,
      'profit_percent': profitPercent,
      if (confirmZeroCost) 'confirm_zero_cost': true,
      'is_deleted': isDeleted,
    };
  }
}

// ============================================================
// Helpers
// ============================================================

// يحوّل قيمة ديناميكية إلى عدد عشري بأمان
double _toDouble(
  dynamic value,
) {
  if (value is num) {
    return value.toDouble();
  }

  return double.tryParse(
        value?.toString() ?? '',
      ) ??
      0.0;
}

// يحوّل قيمة ديناميكية إلى قيمة منطقية بأمان
bool _toBool(
  dynamic value,
) {
  if (value is bool) {
    return value;
  }

  if (value is String) {
    return value.toLowerCase() == 'true' || value == '1';
  }

  if (value is num) {
    return value != 0;
  }

  return false;
}
