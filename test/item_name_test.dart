import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ui/item_name.dart';

// A product's name (founder, 31 Oct 2026): typed in capitals, 10 characters at most, saved and shown in Title Case.

void main() {
  test('Title Case for showing: a capital after a space or sign, sizes stay small', () {
    expect(titleCase('AMUL GHEE'), 'Amul Ghee');
    expect(titleCase('PARLE-G 5KG'), 'Parle-G 5kg');
    expect(titleCase('  TATA   SALT '), 'Tata Salt');
    expect(titleCase('MILK 500ML'), 'Milk 500ml');
  });

  testWidgets('the name box: small letters become capitals, and it stops at 25', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: TextField(controller: c, inputFormatters: itemNameFormatters))));
    await t.enterText(find.byType(TextField), 'amul ghee');
    expect(c.text, 'AMUL GHEE');
    await t.enterText(find.byType(TextField), 'aashirvaad atta whole wheat 5kg');
    expect(c.text, 'AASHIRVAAD ATTA WHOLE WHE');
    expect(c.text.length, kItemNameMax);
  });
}
