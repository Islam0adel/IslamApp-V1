// lib/models/employee_model.dart

/// نموذج الموظف — مستقل تمامًا عن CodingModel
/// يحتوي على حقول HR كاملة + توافق مع الواجهة
class EmployeeModel {
  // ============ أساسيات (متوافقة مع CodingModel) ============
  final String code;
  final String name;
  final bool isDeleted;

  // ============ بيانات شخصية ============
  final String phone;
  final String email;
  final String nationalId;
  final String address;
  final String gender; // male / female
  final String birthDate; // ISO 8601

  // ============ بيانات وظيفية ============
  final String jobTitle;
  final String department;
  final String branchCode;
  final String hireDate; // ISO 8601
  final String endDate; // ISO 8601
  final double salary;
  final String contractType; // permanent / temporary / part-time
  final String status; // active / on_leave / suspended / terminated
  final String managerUid;

  // ============ ربط Firebase (اختياري) ============
  final String userUid;
  final String userEmail;

  // ============ إضافي ============
  final String emergencyContact;
  final String bankAccount;
  final String bankName;
  final String notes;
  final Map<String, dynamic> meta;

  EmployeeModel({
    required this.code,
    required this.name,
    this.isDeleted = false,

    this.phone = '',
    this.email = '',
    this.nationalId = '',
    this.address = '',
    this.gender = '',
    this.birthDate = '',

    this.jobTitle = '',
    this.department = '',
    this.branchCode = '',
    this.hireDate = '',
    this.endDate = '',
    this.salary = 0.0,
    this.contractType = '',
    this.status = 'active',
    this.managerUid = '',

    this.userUid = '',
    this.userEmail = '',

    this.emergencyContact = '',
    this.bankAccount = '',
    this.bankName = '',
    this.notes = '',
    this.meta = const {},
  });

  // ============================================================
  // From Map
  // ============================================================

  factory EmployeeModel.fromMap(Map<String, dynamic> map) {
    return EmployeeModel(
      code: map['code']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      isDeleted: _toBool(map['is_deleted']),

      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      nationalId: map['national_id']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      gender: map['gender']?.toString() ?? '',
      birthDate: map['birth_date']?.toString() ?? '',

      jobTitle: map['job_title']?.toString() ?? '',
      department: map['department']?.toString() ?? '',
      branchCode: map['branch_code']?.toString() ?? '',
      hireDate: map['hire_date']?.toString() ?? '',
      endDate: map['end_date']?.toString() ?? '',
      salary: _toDouble(map['salary']),
      contractType: map['contract_type']?.toString() ?? '',
      status: map['status']?.toString() ?? 'active',
      managerUid: map['manager_uid']?.toString() ?? '',

      userUid: map['user_uid']?.toString() ?? '',
      userEmail: map['user_email']?.toString() ?? '',

      emergencyContact: map['emergency_contact']?.toString() ?? '',
      bankAccount: map['bank_account']?.toString() ?? '',
      bankName: map['bank_name']?.toString() ?? '',
      notes: map['notes']?.toString() ?? '',
      meta: (map['meta'] is Map)
          ? Map<String, dynamic>.from(map['meta'] as Map)
          : const {},
    );
  }

  // ============================================================
  // To Map (للحفظ في Hive + إرسال للـ API)
  // ============================================================

  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'name': name,
      'is_deleted': isDeleted,

      'phone': phone,
      'email': email,
      'national_id': nationalId,
      'address': address,
      'gender': gender,
      'birth_date': birthDate,

      'job_title': jobTitle,
      'department': department,
      'branch_code': branchCode,
      'hire_date': hireDate,
      'end_date': endDate,
      'salary': salary,
      'contract_type': contractType,
      'status': status,
      'manager_uid': managerUid,

      'user_uid': userUid,
      'user_email': userEmail,

      'emergency_contact': emergencyContact,
      'bank_account': bankAccount,
      'bank_name': bankName,
      'notes': notes,
      'meta': meta,
    };
  }

  // ============================================================
  // Copy with (للـ edit form)
  // ============================================================

  EmployeeModel copyWith({
    String? code,
    String? name,
    bool? isDeleted,
    String? phone,
    String? email,
    String? nationalId,
    String? address,
    String? gender,
    String? birthDate,
    String? jobTitle,
    String? department,
    String? branchCode,
    String? hireDate,
    String? endDate,
    double? salary,
    String? contractType,
    String? status,
    String? managerUid,
    String? userUid,
    String? userEmail,
    String? emergencyContact,
    String? bankAccount,
    String? bankName,
    String? notes,
    Map<String, dynamic>? meta,
  }) {
    return EmployeeModel(
      code: code ?? this.code,
      name: name ?? this.name,
      isDeleted: isDeleted ?? this.isDeleted,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      nationalId: nationalId ?? this.nationalId,
      address: address ?? this.address,
      gender: gender ?? this.gender,
      birthDate: birthDate ?? this.birthDate,
      jobTitle: jobTitle ?? this.jobTitle,
      department: department ?? this.department,
      branchCode: branchCode ?? this.branchCode,
      hireDate: hireDate ?? this.hireDate,
      endDate: endDate ?? this.endDate,
      salary: salary ?? this.salary,
      contractType: contractType ?? this.contractType,
      status: status ?? this.status,
      managerUid: managerUid ?? this.managerUid,
      userUid: userUid ?? this.userUid,
      userEmail: userEmail ?? this.userEmail,
      emergencyContact: emergencyContact ?? this.emergencyContact,
      bankAccount: bankAccount ?? this.bankAccount,
      bankName: bankName ?? this.bankName,
      notes: notes ?? this.notes,
      meta: meta ?? this.meta,
    );
  }
}

// ============================================================
// Helpers
// ============================================================

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

bool _toBool(dynamic value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  if (value is num) return value != 0;
  return false;
}