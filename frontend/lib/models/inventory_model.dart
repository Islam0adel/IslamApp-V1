// lib/models/inventory_model.dart
class InventoryItem {
  String code;
  String name;
  double quantity;
  double wholesalePrice;
  double retailPrice;
  double wholesaleValue;
  double retailValue;

  InventoryItem({
    required this.code,
    required this.name,
    this.quantity = 0.0,
    this.wholesalePrice = 0.0,
    this.retailPrice = 0.0,
    double? wholesaleValue,
    double? retailValue,
  })  : wholesaleValue = wholesaleValue ?? wholesalePrice * quantity,
        retailValue = retailValue ?? retailPrice * quantity;

  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,
        'quantity': quantity,
        'wholesalePrice': wholesalePrice,
        'retailPrice': retailPrice,
        'wholesaleValue': wholesaleValue,
        'retailValue': retailValue,
      };

  factory InventoryItem.fromMap(Map<String, dynamic> map) => InventoryItem(
        code: map['code']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
        wholesalePrice: (map['wholesalePrice'] as num?)?.toDouble() ?? 0.0,
        retailPrice: (map['retailPrice'] as num?)?.toDouble() ?? 0.0,
        wholesaleValue: (map['wholesaleValue'] as num?)?.toDouble() ?? 0.0,
        retailValue: (map['retailValue'] as num?)?.toDouble() ?? 0.0,
      );
}

class InventoryModel {
  String companyCode;
  String branchCode;
  String storeCode;
  String date;
  String inventoryType;
  List<InventoryItem> items;
  double totalWholesale;
  double totalRetail;
  DateTime updatedAt;
  String? docId;
  int? serial; // ✅ إضافة رقم الإذن

  InventoryModel({
    required this.companyCode,
    required this.branchCode,
    required this.storeCode,
    required this.date,
    this.inventoryType = 'general',
    this.items = const [],
    this.totalWholesale = 0.0,
    this.totalRetail = 0.0,
    DateTime? updatedAt,
    this.docId,
    this.serial,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'company_code': companyCode,
        'branch_code': branchCode,
        'store_code': storeCode,
        'date': date,
        'inventory_type': inventoryType,
        'items': items.map((i) => i.toMap()).toList(),
        'total_wholesale': totalWholesale,
        'total_retail': totalRetail,
        'updated_at': updatedAt.toIso8601String(),
        if (serial != null) 'serial': serial!,
        if (docId != null) 'doc_id': docId,
      };

  factory InventoryModel.fromMap(Map<String, dynamic> map) {
    List<InventoryItem> items = [];
    if (map['items'] is List) {
      items = (map['items'] as List)
          .map((e) => InventoryItem.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    return InventoryModel(
      companyCode: map['company_code'] ?? '',
      branchCode: map['branch_code'] ?? '',
      storeCode: map['store_code'] ?? '',
      date: map['date'] ?? '',
      inventoryType: map['inventory_type'] ?? 'general',
      items: items,
      totalWholesale: (map['total_wholesale'] as num?)?.toDouble() ?? 0.0,
      totalRetail: (map['total_retail'] as num?)?.toDouble() ?? 0.0,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'])
          : DateTime.now(),
      docId: map['doc_id']?.toString(),
      serial: map['serial'] as int?,
    );
  }
}