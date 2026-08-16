class SupplierSettlementModel {
  String companyCode;
  String branchCode;
  String supplierName;
  String date;
  int serial;

  double amount;

  String paymentMethod;
  String treasury;
  String statement;
  String employee;

  String? docId;
  DateTime updatedAt;
  bool isDeleted;

  SupplierSettlementModel({
    required this.companyCode,
    required this.branchCode,
    required this.supplierName,
    required this.date,
    required this.serial,
    required this.amount,
    required this.paymentMethod,
    required this.treasury,
    required this.statement,
    required this.employee,
    this.docId,
    DateTime? updatedAt,
    this.isDeleted = false,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'company_code': companyCode,
        'branch_code': branchCode,
        'supplier_name': supplierName,
        'date': date,
        'serial': serial,
        'amount': amount,
        'payment_method': paymentMethod,
        'treasury': treasury,
        'statement': statement,
        'employee': employee,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'is_deleted': isDeleted,
        if (docId != null) 'doc_id': docId,
      };

  factory SupplierSettlementModel.fromMap(
    Map<String, dynamic> map,
  ) {
    DateTime updated = DateTime.now();

    if (map['updated_at'] != null) {
      try {
        updated = DateTime.parse(
          map['updated_at'].toString(),
        );
      } catch (_) {}
    }

    return SupplierSettlementModel(
      companyCode: map['company_code']?.toString() ?? '',
      branchCode: map['branch_code']?.toString() ?? '',
      supplierName: map['supplier_name']?.toString() ?? '',
      date: map['date']?.toString() ?? '',
      serial: _toInt(map['serial']),
      amount: _toDouble(map['amount']),
      paymentMethod: map['payment_method']?.toString() ?? '',
      treasury: map['treasury']?.toString() ?? '',
      statement: map['statement']?.toString() ?? '',
      employee: map['employee']?.toString() ?? 'غير محدد',
      docId: map['doc_id']?.toString(),
      updatedAt: updated,
      isDeleted: _toBool(map['is_deleted']),
    );
  }
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();

  return double.tryParse(
        value?.toString() ?? '',
      ) ??
      0.0;
}

int _toInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();

  return int.tryParse(
        value?.toString() ?? '',
      ) ??
      0;
}

bool _toBool(dynamic value) {
  if (value is bool) return value;

  if (value is String) {
    return value.toLowerCase() == 'true' ||
        value == '1';
  }

  if (value is num) return value != 0;

  return false;
}