// lib/models/supplier_transaction_model.dart

class SupplierItem {
  String code;
  String name;
  double quantity;
  double price;

  // "وارد (دخول بضاعة)" أو "صادر (دفعة)"
  String type;

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

  // ============================================================
  // To Map
  // ============================================================

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

  // ============================================================
  // From Map
  // ============================================================

  factory SupplierItem.fromMap(
    Map<String, dynamic> map,
  ) {
    return SupplierItem(
      code: map['code']?.toString() ?? '',
      name: map['name']?.toString() ?? '',

      quantity: _toDouble(
        map['quantity'],
      ),

      price: _toDouble(
        map['price'],
      ),

      type: map['type']?.toString() ??
          'وارد (دخول بضاعة)',

      discountRate: _toDouble(
        map['discountRate'],
      ),

      discountAmount: _toDouble(
        map['discountAmount'],
      ),

      total: _toDouble(
        map['total'],
      ),
    );
  }
}


// ============================================================
// Supplier Transaction
// ============================================================

class SupplierTransactionModel {
  String companyCode;
  String branchCode;
  String storeCode;

  int serial;

  String date;
  String supplierName;
  String paymentMethod;
  String treasury;

  bool isAddToStore;

  String employee;

  List<SupplierItem> items;

  double totalAmount;
  double paidAmount;

  String? docId;

  DateTime updatedAt;

  // Soft Delete
  //
  // مش شرط نستخدمه في الواجهة،
  // لكنه يسمح للموديل باستقبال بيانات السيرفر الجديدة.
  bool isDeleted;


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

    this.isDeleted = false,
  }) : updatedAt =
            updatedAt ?? DateTime.now();


  // ============================================================
  // To Map
  // ============================================================

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

        'items': items
            .map(
              (item) => item.toMap(),
            )
            .toList(),

        'total_amount': totalAmount,

        'paid_amount': paidAmount,

        'updated_at':
            updatedAt.toUtc().toIso8601String(),

        'is_deleted': isDeleted,

        if (docId != null)
          'doc_id': docId,
      };


  // ============================================================
  // From Map
  // ============================================================

  factory SupplierTransactionModel.fromMap(
    Map<String, dynamic> map,
  ) {
    // ----------------------------------------------------------
    // Items
    // ----------------------------------------------------------

    final List<SupplierItem> parsedItems = [];

    if (map['items'] is List) {
      for (final rawItem in map['items']) {
        if (rawItem is Map) {
          try {
            parsedItems.add(
              SupplierItem.fromMap(
                Map<String, dynamic>.from(
                  rawItem,
                ),
              ),
            );
          } catch (_) {
            // تجاهل العنصر غير الصالح
          }
        }
      }
    }


    // ----------------------------------------------------------
    // updated_at
    // ----------------------------------------------------------

    DateTime parsedUpdatedAt =
        DateTime.now();

    final dynamic rawUpdatedAt =
        map['updated_at'];

    if (rawUpdatedAt != null) {
      try {
        parsedUpdatedAt =
            DateTime.parse(
          rawUpdatedAt.toString(),
        );
      } catch (_) {
        parsedUpdatedAt =
            DateTime.now();
      }
    }


    // ----------------------------------------------------------
    // Build Model
    // ----------------------------------------------------------

    return SupplierTransactionModel(
      companyCode:
          map['company_code']
                  ?.toString() ??
              '',

      branchCode:
          map['branch_code']
                  ?.toString() ??
              '',

      storeCode:
          map['store_code']
                  ?.toString() ??
              '',

      serial:
          _toInt(
        map['serial'],
      ),

      date:
          map['date']
                  ?.toString() ??
              '',

      supplierName:
          map['supplier_name']
                  ?.toString() ??
              '',

      paymentMethod:
          map['payment_method']
                  ?.toString() ??
              '',

      treasury:
          map['treasury']
                  ?.toString() ??
              '',

      isAddToStore:
          _toBool(
        map['is_add_to_store'],
      ),

      employee:
          map['employee']
                  ?.toString() ??
              'غير محدد',

      items:
          parsedItems,

      totalAmount:
          _toDouble(
        map['total_amount'],
      ),

      paidAmount:
          _toDouble(
        map['paid_amount'],
      ),

      docId:
          map['doc_id']?.toString(),

      updatedAt:
          parsedUpdatedAt,

      isDeleted:
          _toBool(
        map['is_deleted'],
      ),
    );
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


int _toInt(
  dynamic value,
) {
  if (value is int) {
    return value;
  }

  if (value is num) {
    return value.toInt();
  }

  return int.tryParse(
        value?.toString() ?? '',
      ) ??
      0;
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