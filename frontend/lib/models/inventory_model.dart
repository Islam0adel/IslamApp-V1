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
  })  : wholesaleValue =
            wholesaleValue ??
                wholesalePrice * quantity,
        retailValue =
            retailValue ??
                retailPrice * quantity;


  // ============================================================
  // To Map
  // ============================================================

  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,

        'quantity': quantity,

        'wholesalePrice':
            wholesalePrice,

        'retailPrice':
            retailPrice,

        'wholesaleValue':
            wholesaleValue,

        'retailValue':
            retailValue,
      };


  // ============================================================
  // From Map
  // ============================================================

  factory InventoryItem.fromMap(
    Map<String, dynamic> map,
  ) {
    return InventoryItem(
      code:
          map['code']?.toString() ?? '',

      name:
          map['name']?.toString() ?? '',

      quantity:
          _toDouble(
        map['quantity'],
      ),

      wholesalePrice:
          _toDouble(
        map['wholesalePrice'],
      ),

      retailPrice:
          _toDouble(
        map['retailPrice'],
      ),

      wholesaleValue:
          _toDouble(
        map['wholesaleValue'],
      ),

      retailValue:
          _toDouble(
        map['retailValue'],
      ),
    );
  }
}


// ============================================================
// Inventory Model
// ============================================================

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

  // رقم الإذن
  int? serial;

  // Soft Delete
  //
  // لا يظهر للمستخدم،
  // لكنه يسمح للموديل باستقبال بيانات المزامنة.
  bool isDeleted;


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

    this.isDeleted = false,
  }) : updatedAt =
            updatedAt ?? DateTime.now();


  // ============================================================
  // To Map
  // ============================================================

  Map<String, dynamic> toMap() => {
        'company_code':
            companyCode,

        'branch_code':
            branchCode,

        'store_code':
            storeCode,

        'date':
            date,

        'inventory_type':
            inventoryType,

        'items':
            items
                .map(
                  (item) =>
                      item.toMap(),
                )
                .toList(),

        'total_wholesale':
            totalWholesale,

        'total_retail':
            totalRetail,

        'updated_at':
            updatedAt
                .toUtc()
                .toIso8601String(),

        'is_deleted':
            isDeleted,

        if (serial != null)
          'serial': serial,

        if (docId != null)
          'doc_id': docId,
      };


  // ============================================================
  // From Map
  // ============================================================

  factory InventoryModel.fromMap(
    Map<String, dynamic> map,
  ) {
    final List<InventoryItem>
        parsedItems = [];


    // ----------------------------------------------------------
    // Items
    // ----------------------------------------------------------

    if (map['items'] is List) {
      for (final rawItem
          in map['items']) {
        if (rawItem is Map) {
          try {
            parsedItems.add(
              InventoryItem.fromMap(
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
    // Model
    // ----------------------------------------------------------

    return InventoryModel(
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

      date:
          map['date']
                  ?.toString() ??
              '',

      inventoryType:
          map['inventory_type']
                  ?.toString() ??
              'general',

      items:
          parsedItems,

      totalWholesale:
          _toDouble(
        map['total_wholesale'],
      ),

      totalRetail:
          _toDouble(
        map['total_retail'],
      ),

      updatedAt:
          parsedUpdatedAt,

      docId:
          map['doc_id']?.toString(),

      serial:
          _toIntNullable(
        map['serial'],
      ),

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


int? _toIntNullable(
  dynamic value,
) {
  if (value == null) {
    return null;
  }

  if (value is int) {
    return value;
  }

  if (value is num) {
    return value.toInt();
  }

  return int.tryParse(
    value.toString(),
  );
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