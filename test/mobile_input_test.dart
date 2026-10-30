import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ui/mobile_input.dart';

void main() {
  test('a saved or pasted number becomes the 10 digits the box shows', () {
    expect(localMobile('+91 98765 43210'), '9876543210');
    expect(localMobile('919876543210'), '9876543210');
    expect(localMobile('09876543210'), '9876543210');
    expect(localMobile('98765-43210'), '9876543210');
    expect(localMobile('9123456789'), '9123456789', reason: 'a 10-digit number starting 91 is kept');
    expect(localMobile(null), '');
  });

  testWidgets('a mobile box shows +91 in front and keeps only 10 digits, also when a full number is pasted', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: c, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: const InputDecoration(prefixText: kMobilePrefix))),
    ));
    await t.tap(find.byType(TextField));
    await t.pump();
    expect(find.text('+91 '), findsOneWidget);
    await t.enterText(find.byType(TextField), '+91 98765 43210');
    expect(c.text, '9876543210');
    await t.enterText(find.byType(TextField), '98765432109999');
    expect(c.text, '9876543210', reason: 'at most 10 digits');
  });
}
