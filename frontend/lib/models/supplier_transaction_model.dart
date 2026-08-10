// lib/models/supplier_transaction_model.dart
class SupplierItem {
  String code;
  String name;
  double quantity;
  double price;
  String type; // "وارد (دخول بضاعة)" أو "صادر (دفعة)"
  double discountRate;
  double discountAmount;
  double total;

  SupplierItem({
    required this.code,
    required this.name,
    this.quantity = 0.0,
    this.price = 0.0,
    
    this.type = 'وارد (دخول بضاعة)',
    this.discountRate = 0.0,
    this.discountAmount = 0.0,
    this.total = 0.0,
  });

  Map<String, dynamic> toMap() => {
    'code': code,
    'name': name,
    'quantity': quantity,
    'price': price,
    'type': type,
    'discountRate': discountRate,
    'discountAmount': discountAmount,
    'total': total,
  };

  factory SupplierItem.fromMap(Map<String, dynamic> map) => SupplierItem(
    code: map['code']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
    price: (map['price'] as num?)?.toDouble() ?? 0.0,
    type: map['type']?.toString() ?? 'وارد (دخول بضاعة)',
    discountRate: (map['discountRate'] as num?)?.toDouble() ?? 0.0,
    discountAmount: (map['discountAmount'] as num?)?.toDouble() ?? 0.0,
    total: (map['total'] as num?)?.toDouble() ?? 0.0,
  );
}

class SupplierTransactionModel {
  String companyCode;
  String branchCode;
  String storeCode;
  int serial;
  String date;
  String supplierName;
  String paymentMethod;
  String treasury;
  bool isAddToStore; // ✅ زر ON/OFF للإضافة لليوميات
  String employee;
  List<SupplierItem> items;
  double totalAmount;
  double paidAmount;
  String? docId;
  DateTime updatedAt;

  SupplierTransactionModel({
    required this.companyCode,
    required this.branchCode,
    required this.storeCode,
    required this.serial,
    required this.date,
    required this.supplierName,
    required this.paymentMethod,
    required this.treasury,
    this.isAddToStore = false,
    this.employee = 'غير محدد',
    this.items = const [],
    this.totalAmount = 0.0,
    this.paidAmount = 0.0,
    this.docId,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'company_code': companyCode,
    'branch_code': branchCode,
    'store_code': storeCode,
    'serial': serial,
    'date': date,
    'supplier_name': supplierName,
    'payment_method': paymentMethod,
    'treasury': treasury,
    'is_add_to_store': isAddToStore,
    'employee': employee,
    'items': items.map((i) => i.toMap()).toList(),
    'total_amount': totalAmount,
    'paid_amount': paidAmount,
    'updated_at': updatedAt.toIso8601String(),
    if (docId != null) 'doc_id': docId,
  };

  factory SupplierTransactionModel.fromMap(Map<String, dynamic> map) {
    List<SupplierItem> items = [];
    if (map['items'] is List) {
      items = (map['items'] as List)
          .map((e) => SupplierItem.fromMap(Map<String, dynamic>.from(e)))
          .toList();
    }
    return SupplierTransactionModel(
      companyCode: map['company_code'] ?? '',
      branchCode: map['branch_code'] ?? '',
      storeCode: map['store_code'] ?? '',
      serial: map['serial'] as int? ?? 0,
      date: map['date'] ?? '',
      supplierName: map['supplier_name'] ?? '',
      paymentMethod: map['payment_method'] ?? '',
      treasury: map['treasury'] ?? '',
      isAddToStore: map['is_add_to_store'] ?? false,
      employee: map['employee'] ?? 'غير محدد',
      items: items,
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0.0,
      paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0.0,
      docId: map['doc_id']?.toString(),
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'])
          : DateTime.now(),
    );
  }
}