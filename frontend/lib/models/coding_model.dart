class CodingModel {
  final String code;
  final String name;
  final String type; // لـ "types" (وارد / صادر)
  final String barcode;
  final double wholesalePrice;
  final double sellingPrice;
  final double profitMargin;
  final double profitPercent;

  CodingModel({
    required this.code,
    required this.name,
    this.type = "وارد",
    this.barcode = "",
    this.wholesalePrice = 0.0,
    this.sellingPrice = 0.0,
    this.profitMargin = 0.0,
    this.profitPercent = 0.0,
  });

  // 🔥 تحويل آمن وقوي جداً من الخرائط (Maps) القادمة من السيرفر أو Hive مع معالجة الـ null والأرقام
  factory CodingModel.fromMap(Map<String, dynamic> map) {
    return CodingModel(
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      type: (map['type'] ?? 'وارد').toString(),
      barcode: (map['barcode'] ?? '').toString(),
      wholesalePrice: double.tryParse((map['wholesale_price'] ?? map['wholesalePrice'] ?? 0).toString()) ?? 0.0,
      sellingPrice: double.tryParse((map['selling_price'] ?? map['sellingPrice'] ?? 0).toString()) ?? 0.0,
      profitMargin: double.tryParse((map['profit_margin'] ?? map['profitMargin'] ?? 0).toString()) ?? 0.0,
      profitPercent: double.tryParse((map['profit_percent'] ?? map['profitPercent'] ?? 0).toString()) ?? 0.0,
    );
  }

  // 🔥 تحويل الكائن إلى خريطة Map لحفظه في السيرفر (بنظام snake_case) والـ Hive بالتوافق التام مع الشاشات
  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'name': name,
      'type': type,
      'barcode': barcode,
      'wholesale_price': wholesalePrice,
      'selling_price': sellingPrice,
      'profit_margin': profitMargin,
      'profit_percent': profitPercent,
    };
  }
}