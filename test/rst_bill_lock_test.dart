// A generated bill is locked; changes need an admin PIN and a note (0645). The server's answers follow what the database gave on the local
// test database (server/scripts/rst-bill-lock-e2e.mjs): 403 admin_pin_required, a wrong PIN {ok: false, tries_left}, a right one a pass.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/reports/rst_reports_api.dart';
import 'package:vinii_pos/reports/rst_reports_screen.dart';
import 'package:vinii_pos/restaurant/home_insights.dart';
import 'package:vinii_pos/restaurant/restaurant_api.dart';
import 'package:vinii_pos/tables/admin_pin.dart';
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/tables/bill_discount_sheet.dart';

import 'helpers.dart';

http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, String code) => http.Response(jsonEncode({'detail': detail, 'code': code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
const needPin = 'This bill is generated, so it can only be changed with an admin PIN; enter an admin PIN and a note.';

class Fake {
  Fake({this.on = const {}});
  final Map<String, http.Response Function(Map<String, dynamic> b)> on;
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> of(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, b));
    final h = on[fn];
    if (h != null) return h(b);
    return switch (fn) {
      // a generated bill: refused without a pass, done with one
      'rst_bill_discount' => b['admin_pass'] == null ? err(403, needPin, 'admin_pin_required') : ok({'id': 'o1', 'discount': 80}),
      'rst_admin_pin_check' => b['pin'] == '482915' ? ok({'ok': true, 'pass_id': 'pass-1', 'approver': 'ZZ own'}) : ok({'ok': false, 'tries_left': 3}),
      'rst_admin_pin_status' => ok({'can_set': true, 'has_pin': false, 'admins_with_pin': 0}),
      'rst_admin_pin_set' => ok({'can_set': true, 'has_pin': true, 'admins_with_pin': 1}),
      _ => err(404, 'Not found', 'not_found'),
    };
  });
  late final api = BillApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
}

Facts generatedBill() => Facts({
      'id': 'o1', 'display_no': 'P-00042', 'status': 'awaiting_payment', 'bill_generated': true, 'discount_limit_pct': 10, 'manual_discount': null,
      'items': [{'id': 'i1', 'name': 'Thali', 'qty': 2, 'unit_price': 400, 'line_total': 800}],
    });

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

/// A tap while a spinner turns behind a dialog (the sheet's Save waits for the PIN): pump a while instead of settling.
Future<void> tapBusy(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget opener(Fake f, ValueChanged<bool> done) => Builder(
      builder: (c) => Scaffold(
        body: TextButton(
          key: const ValueKey('open'),
          onPressed: () async {
            final r = await showManualDiscountSheet(c, api: f.api, order: generatedBill());
            done(r);
          },
          child: const Text('open'),
        ),
      ),
    );

void main() {
  testWidgets('a discount on a generated bill: the server asks for the admin PIN; a wrong one says so; the right one and a note give it', (t) async {
    final f = Fake();
    bool? given;
    await show(t, opener(f, (v) => given = v));
    await tapKey(t, 'open');
    await t.enterText(find.byKey(const ValueKey('disc-value')), '10');
    await tapKey(t, 'disc-reason-Regular guest');
    await tapBusy(t, 'disc-save');
    expect(find.text('Admin PIN needed'), findsOneWidget);
    expect(find.text(needPin), findsOneWidget, reason: 'the server\'s own sentence');

    await tapBusy(t, 'admin-go');
    expect(find.text('Enter the 6-digit admin PIN.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('admin-pin')), '000000');
    await tapBusy(t, 'admin-go');
    expect(find.text('Write a note: why this change (3 characters or more).'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('admin-note')), 'Owner allowed it');
    await tapBusy(t, 'admin-go');
    expect(find.text('Wrong PIN. 3 tries left.'), findsOneWidget);
    expect(f.of('rst_bill_discount').length, 1, reason: 'nothing sent again on a wrong PIN');

    await t.enterText(find.byKey(const ValueKey('admin-pin')), '482915');
    await tapBusy(t, 'admin-go');
    final sent = f.of('rst_bill_discount').last;
    expect(sent['admin_pass'], 'pass-1');
    expect(sent['admin_note'], 'Owner allowed it');
    expect(sent['value'], 10);
    expect(given, isTrue);
  });

  testWidgets('Cancel on the PIN leaves the discount sheet open, nothing changed', (t) async {
    final f = Fake();
    bool? given;
    await show(t, opener(f, (v) => given = v));
    await tapKey(t, 'open');
    await t.enterText(find.byKey(const ValueKey('disc-value')), '10');
    await tapKey(t, 'disc-reason-Regular guest');
    await tapBusy(t, 'disc-save');
    await tapBusy(t, 'admin-cancel');
    expect(find.text('Admin PIN needed'), findsNothing);
    expect(find.byKey(const ValueKey('disc-save')), findsOneWidget);
    expect(f.of('rst_bill_discount').length, 1);
    expect(given, isNull);
  });

  testWidgets('too many wrong tries: the server\'s lock-out sentence', (t) async {
    final f = Fake(on: {'rst_admin_pin_check': (_) => err(429, 'Too many wrong PINs; try again in 15 minutes.', 'rate_limited')});
    await show(t, opener(f, (_) {}));
    await tapKey(t, 'open');
    await t.enterText(find.byKey(const ValueKey('disc-value')), '10');
    await tapKey(t, 'disc-reason-Regular guest');
    await tapBusy(t, 'disc-save');
    await t.enterText(find.byKey(const ValueKey('admin-pin')), '482915');
    await t.enterText(find.byKey(const ValueKey('admin-note')), 'Owner allowed it');
    await tapBusy(t, 'admin-go');
    expect(find.text('Too many wrong PINs; try again in 15 minutes.'), findsOneWidget);
  });

  testWidgets('Settings → Admin PIN: the owner sets 6 digits twice; different PINs are refused', (t) async {
    final f = Fake();
    await show(t, AdminPinScreen(api: f.api));
    await t.pumpAndSettle();
    expect(find.text('You have no admin PIN yet.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('pin-new')), '482915');
    await t.enterText(find.byKey(const ValueKey('pin-again')), '482916');
    await tapKey(t, 'pin-save');
    expect(find.text('The two PINs are not the same.'), findsOneWidget);
    expect(f.of('rst_admin_pin_set'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('pin-again')), '482915');
    await tapKey(t, 'pin-save');
    expect(f.of('rst_admin_pin_set').single, {'pin': '482915'});
    expect(find.text('Your admin PIN is set.'), findsOneWidget);
  });

  testWidgets('Settings → Admin PIN for a cashier: cannot set one, sees whether the owner has', (t) async {
    final f = Fake(on: {'rst_admin_pin_status': (_) => ok({'can_set': false, 'has_pin': false, 'admins_with_pin': 1})});
    await show(t, AdminPinScreen(api: f.api));
    await t.pumpAndSettle();
    expect(find.text('The owner has set an admin PIN.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-save')), findsNothing);
  });

  testWidgets('Leakage audit: the admin PIN changes come first, in red, with the note, who did it and whose PIN', (t) async {
    final client = MockClient((r) async => ok({
          'cancelled': {'bills': 0, 'value_minor': 0, 'list': []},
          'unpaid': {'bills': 0, 'value_minor': 0, 'list': []},
          'reprints': {'count': 0, 'list': []},
          'after_bill': {'count': 1, 'list': [{'order_id': 'o1', 'bill': 'P-00042', 'at': '2026-11-03T09:00:00Z', 'kind': 'manual_discount', 'what': 'Manual discount 80 (10%) on P-00042', 'by': 'ZZ cash'}]},
          'refunds': {'count': 0, 'amount_minor': 0, 'list': []},
          'overrides': {'count': 1, 'list': [{'order_id': 'o1', 'bill': 'P-00042', 'at': '2026-11-03T09:00:00Z', 'action': 'discount',
            'what': 'Discount changed after the bill · Owner allowed it', 'note': 'Owner allowed it', 'by': 'ZZ cash', 'approved_by': 'ZZ own'}]},
          'not_recorded': ['price_edit'],
        }));
    await show(t, RstReportScreen(kind: 'audit', api: RstReportsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client), today: DateTime(2026, 11, 3)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('rep-overrides')), findsOneWidget);
    expect(find.text('CHANGED WITH AN ADMIN PIN · 1'), findsOneWidget);
    expect(find.textContaining('Discount changed after the bill · Owner allowed it · by ZZ cash · PIN of ZZ own'), findsOneWidget);
    expect(find.text('CHANGED AFTER THE BILL'), findsOneWidget);
  });

  testWidgets('the owner\'s dashboard: Revenue leakage in red with today\'s admin PIN changes', (t) async {
    final client = MockClient((r) async {
      if (r.url.pathSegments.last == 'rst_home_insights') {
        return ok({
          'mix': {}, 'payments': [], 'top': [], 'menu': {}, 'ready': 0,
          'leakage': {'admin_changes': 2, 'latest': [{'bill': 'P-00042', 'what': 'Discount changed after the bill · Owner allowed it', 'by': 'ZZ cash'}]},
        });
      }
      return err(404, 'Not found', 'not_found');
    });
    await show(t, SingleChildScrollView(child: RestaurantInsights(api: RestaurantApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('rst-leakage')), findsOneWidget);
    expect(find.text('2 changes with an admin PIN'), findsOneWidget);
    expect(find.textContaining('#P-00042 · Discount changed after the bill'), findsOneWidget);
  });
}
