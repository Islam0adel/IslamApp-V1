import 'package:flutter_test/flutter_test.dart';
import 'package:islam_app/models/coding_model.dart';

void main() {
  test('cost_pending يُحمّل من الخريطة ولا يُرسل في toMap', () {
    final m = CodingModel.fromMap({
      'code': 'Z9', 'name': 'صنف', 'wholesale_price': 0.0,
      'cost_pending': true,
    });
    expect(m.costPending, isTrue);
    expect(m.confirmZeroCost, isFalse);
    expect(m.toMap().containsKey('cost_pending'), isFalse,
        reason: 'العلامة ملك الخادم، لا يعيد العميل كتابتها');
    expect(m.toMap().containsKey('confirm_zero_cost'), isFalse,
        reason: 'لا تأكيد صفري إلا بطلب صريح');
  });

  test('تأكيد الصفر الصريح وحده يُرسل confirm_zero_cost', () {
    final m = CodingModel(
      code: 'Z9', name: 'صنف', wholesalePrice: 0.0,
      confirmZeroCost: true,
    );
    expect(m.toMap()['confirm_zero_cost'], isTrue);
    final m2 = CodingModel(code: 'Z9', name: 'صنف');
    expect(m2.toMap().containsKey('confirm_zero_cost'), isFalse);
  });
}
