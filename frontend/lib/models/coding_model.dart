// lib/models/coding_model.dart

class CodingModel {
  final String code;
  final String name;

  // لـ types: وارد / صادر
  final String type;

  final String barcode;

  final double wholesalePrice;
  final double sellingPrice;

  final double profitMargin;
  final double profitPercent;

  // Soft Delete
  //
  // false = السجل نشط
  // true  = السجل محذوف من السيرفر
  final bool isDeleted;


  CodingModel({
    required this.code,
    required this.name,

    this.type = "وارد",

    this.barcode = "",

    this.wholesalePrice = 0.0,
    this.sellingPrice = 0.0,

    this.profitMargin = 0.0,
    this.profitPercent = 0.0,

    this.isDeleted = false,
  });


  // ============================================================
  // From Map
  // ============================================================

  factory CodingModel.fromMap(
    Map<String, dynamic> map,
  ) {
    return CodingModel(
      code:
          map['code']?.toString() ?? '',

      name:
          map['name']?.toString() ?? '',

      type:
          map['type']?.toString() ??
              'وارد',

      barcode:
          map['barcode']?.toString() ??
              '',

      wholesalePrice:
          _toDouble(
        map['wholesale_price'] ??
            map['wholesalePrice'],
      ),

      sellingPrice:
          _toDouble(
        map['selling_price'] ??
            map['sellingPrice'],
      ),

      profitMargin:
          _toDouble(
        map['profit_margin'] ??
            map['profitMargin'],
      ),

      profitPercent:
          _toDouble(
        map['profit_percent'] ??
            map['profitPercent'],
      ),

      isDeleted:
          _toBool(
        map['is_deleted'],
      ),
    );
  }


  // ============================================================
  // To Map
  // ============================================================

  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'name': name,

      'type': type,
      'barcode': barcode,

      'wholesale_price':
          wholesalePrice,

      'selling_price':
          sellingPrice,

      'profit_margin':
          profitMargin,

      'profit_percent':
          profitPercent,

      'is_deleted':
          isDeleted,
    };
  }
}


// ============================================================
// Helpers
// ============================================================

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


bool _toBool(
  dynamic value,
) {
  if (value is bool) {
    return value;
  }

  if (value is String) {
    return value.toLowerCase() ==
            'true' ||
        value == '1';
  }

  if (value is num) {
    return value != 0;
  }

  return false;
}