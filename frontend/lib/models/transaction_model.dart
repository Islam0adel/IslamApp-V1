class TransactionModel {
  final String? id;
  final double amount;
  final String description;
  final String type; // 'income' أو 'expense'
  final DateTime date;

  TransactionModel({
    this.id,
    required this.amount,
    required this.description,
    required this.type,
    required this.date,
  });

  // تحويل البيانات من JSON (اللي جاي من الباك إند) لـ Object فلاتر يفهمه
  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    return TransactionModel(
      id: json['id'],
      amount: json['amount'].toDouble(),
      description: json['description'],
      type: json['type'],
      date: DateTime.parse(json['date']),
    );
  }

  // تحويل الـ Object لـ JSON عشان نبعته للباك إند
  Map<String, dynamic> toJson() {
    return {
      'amount': amount,
      'description': description,
      'type': type,
      'date': date.toIso8601String(),
    };
  }
}