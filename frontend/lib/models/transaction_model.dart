class TransactionModel {
  final String? id;
  final double amount;
  final String description;
  final String type; // 'income' أو 'expense'
  final DateTime date;
  final String companyCode; // الحقل الجديد الضروري للفصل

  TransactionModel({
    this.id,
    required this.amount,
    required this.description,
    required this.type,
    required this.date,
    required this.companyCode, // إضافة الكود هنا
  });

  // تحويل البيانات من JSON (اللي جاي من الباك إند) لـ Object
  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    return TransactionModel(
      id: json['id'],
      amount: (json['amount'] as num).toDouble(), // تعديل لضمان عدم حدوث خطأ في الأنواع
      description: json['description'] ?? '',
      type: json['type'] ?? '',
      date: DateTime.parse(json['date']),
      companyCode: json['company_code'] ?? '', // استقبال الكود من السيرفر
    );
  }

  // تحويل الـ Object لـ JSON عشان نبعته للباك إند
  Map<String, dynamic> toJson() {
    return {
      'amount': amount,
      'description': description,
      'type': type,
      'date': date.toIso8601String(),
      'company_code': companyCode, // إرسال الكود للسيرفر عشان يتخزن صح
    };
  }
}