// Restaurant reports V1 (0636). The answers are what the database gave for known Niks Cafe test bills on a copy of hosted
// (test/fixtures/rst_reports_server.json): A 2 × Cappuccino cash, B Brownie Pancake UPI with a ₹50 refund, C Americano + Cappuccino by card
// with TEST20 (₹20 off) and the service charge waived, D Peri Peri Fries split ₹100 cash + UPI, E Pasta cancelled after the KOT.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
import 'package:vinii_pos/reports/rst_reports_api.dart';
import 'package:vinii_pos/reports/rst_reports_screen.dart';
import 'package:vinii_pos/stock/closing_stock_screen.dart' show saveSpreadsheet;
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/ui/theme.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_reports_server.json').readAsStringSync()) as Map<String, dynamic>;
final today = DateTime(2026, 10, 31);

class Fake {
  Fake({this.empty = false, this.refuse});
  final bool empty;
  final String? refuse;
  final requests = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> last(String fn) => requests.lastWhere((r) => r.$1 == fn).$2;
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    requests.add((fn, b));
    if (refuse != null) return http.Response(jsonEncode({'detail': refuse, 'code': 'forbidden'}), 403, headers: {'content-type': 'application/json'});
    final answer = switch (fn) {
      'rst_report_sales' => empty ? fx['sales_empty'] : fx['sales'],
      'rst_report_items' => b['menu_item_id'] != null ? fx['items_dish'] : fx['items'],
      'rst_report_audit' => fx['audit'],
      'rst_receipt_view' => {
          'id': b['order_id'], 'display_no': 'P-00001', 'status': 'paid', 'table_label': 'T1', 'subtotal': 198, 'discount': 0, 'service_charge': 19.8, 'gst_amount': 9.9,
          'round_off': 0.3, 'total': 228, 'paid': 228, 'due': 0,
          'items': [{'id': 'i1', 'name': 'Cappuccino', 'qty': 2, 'unit_price': 99, 'line_total': 198}],
        },
      _ => fx[fn.replaceFirst('rst_report_', '')],
    };
    return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  late final api = RstReportsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final bill = BillApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(800, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

String textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  tearDown(OutletScope.reset);

  testWidgets('Reports: the blueprint groups (Sales, Payments, Audit) with seven reports and the sales feed one tap away', (t) async {
    final f = Fake();
    var feed = 0;
    await show(t, RstReportsScreen(api: f.api, bill: f.bill, today: today, openFeed: () => feed++));
    for (final g in ['SALES', 'PAYMENTS', 'AUDIT']) {
      expect(find.text(g), findsOneWidget);
    }
    for (final k in ['sales', 'items', 'categories', 'payments', 'cashiers', 'discounts', 'audit']) {
      expect(find.byKey(ValueKey('reports-open-$k')), findsOneWidget, reason: k);
    }
    await tapKey(t, 'reports-feed');
    expect(feed, 1);
    await tapKey(t, 'reports-open-categories');
    expect(find.byType(RstReportScreen), findsOneWidget);
  });

  testWidgets('Sales summary: today by default; every figure from the database; the period chips ask again; a bill opens', (t) async {
    final f = Fake();
    await show(t, RstReportScreen(kind: 'sales', api: f.api, bill: f.bill, today: today));
    expect(f.last('rst_report_sales'), {'from': '2026-10-31', 'to': '2026-10-31'});
    expect(textOf(t, 'rep-net'), '₹956');
    expect(textOf(t, 'rep-bills'), '4');
    expect(textOf(t, 'rep-average'), '₹239');
    expect(textOf(t, 'rep-collected'), '₹1,289');
    expect(textOf(t, 'rep-gross'), '₹976');
    expect(textOf(t, 'rep-discounts'), '−₹20');
    expect(textOf(t, 'rep-gst'), '₹47.80');
    expect(textOf(t, 'rep-service'), '₹78.80');
    expect(textOf(t, 'rep-total'), '₹1,083');
    expect(textOf(t, 'rep-refunds'), '−₹50');
    expect(textOf(t, 'rep-cancelled'), '1 · ₹245');
    expect(find.text('BILLS (4)'), findsOneWidget);
    await tapKey(t, 'rep-period-yesterday');
    expect(f.last('rst_report_sales'), {'from': '2026-10-30', 'to': '2026-10-30'});
    await tapKey(t, 'rep-period-7days');
    expect(f.last('rst_report_sales'), {'from': '2026-10-25', 'to': '2026-10-31'});
    await tapKey(t, 'rep-period-month');
    expect(f.last('rst_report_sales'), {'from': '2026-10-01', 'to': '2026-10-31'});
    final first = (fx['sales']['bills'] as List).first as Map;
    await tapKey(t, 'rep-bill-${first['order_id']}');
    expect(find.byKey(const ValueKey('rep-bill-sheet')), findsOneWidget);
    expect(f.last('rst_receipt_view'), {'order_id': first['order_id']});
    expect(find.text('2 × Cappuccino'), findsOneWidget);
  });

  testWidgets('an empty period says so', (t) async {
    await show(t, RstReportScreen(kind: 'sales', api: Fake(empty: true).api, today: today));
    expect(find.text('No bills were paid in this period.'), findsOneWidget);
  });

  testWidgets('a refusal from the database is shown as it says', (t) async {
    await show(t, RstReportScreen(kind: 'audit', api: Fake(refuse: 'Your role cannot see the audit.').api, today: today));
    expect(textOf(t, 'rep-error'), 'Your role cannot see the audit.');
  });

  testWidgets('the outlet the app shows is the outlet asked for, and a new choice asks again', (t) async {
    final f = Fake();
    OutletScope.selected.value = 'loc-1';
    await show(t, RstReportScreen(kind: 'payments', api: f.api, today: today));
    expect(f.last('rst_report_payments')['location_id'], 'loc-1');
    OutletScope.selected.value = 'loc-2';
    await t.pumpAndSettle();
    expect(f.last('rst_report_payments')['location_id'], 'loc-2');
  });

  testWidgets('Item-wise: top and slowest, every dish with its share; a dish lists its bills', (t) async {
    final f = Fake();
    await show(t, RstReportScreen(kind: 'items', api: f.api, bill: f.bill, today: today));
    expect(textOf(t, 'rep-items-total'), '₹976');
    expect(find.descendant(of: find.byKey(const ValueKey('rep-top')), matching: find.text('Brownie Pancake')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('rep-slowest')), matching: find.textContaining('0 sold')), findsWidgets);
    await tapKey(t, 'rep-dish-all-Cappuccino');
    expect(f.last('rst_report_items')['menu_item_id'], '38673ba8-bcc1-45b4-a0da-61ef2cedc8f0');
    expect(find.text('Bills with Cappuccino'), findsOneWidget);
    expect(find.textContaining('Bill P-'), findsNWidgets(2));
  });

  testWidgets('Category-wise: the sub-category counts under its main category; a category opens its dishes; unsold categories listed', (t) async {
    final f = Fake();
    await show(t, RstReportScreen(kind: 'categories', api: f.api, today: today));
    expect(textOf(t, 'rep-cat-value-Hot Beverages'), '₹386');
    expect(textOf(t, 'rep-cat-value-Uncategorised'), '₹340');
    expect(find.byKey(const ValueKey('rep-cat-Black Coffee')), findsNothing);
    expect(find.text('Americano'), findsNothing);
    await tapKey(t, 'rep-cat-Hot Beverages');
    expect(find.text('Americano'), findsOneWidget);
    expect(find.text('NOTHING SOLD'), findsOneWidget);
  });

  testWidgets('Payment mode: each method with its refunds, the split bill, and the reconciliation', (t) async {
    await show(t, RstReportScreen(kind: 'payments', api: Fake().api, today: today));
    expect(textOf(t, 'rep-collected'), '₹1,289');
    expect(textOf(t, 'rep-difference'), '₹0');
    expect(find.text('Fully reconciled'), findsOneWidget);
    expect(find.text('SPLIT BILLS (1)'), findsOneWidget);
    expect(find.text('Cash + UPI'), findsOneWidget);
    expect(find.textContaining('refunds ₹50'), findsOneWidget);
  });

  testWidgets('Cashier & day close: who took what by method, and the day not closed yet', (t) async {
    await show(t, RstReportScreen(kind: 'cashiers', api: Fake().api, today: today));
    expect(textOf(t, 'rep-cashier-Asha Cashier'), '₹1,289');
    expect(find.textContaining('5 bills'), findsOneWidget);
    expect(find.text('Not closed'), findsOneWidget);
  });

  testWidgets('Discounts: the coupon, who applied it, the service charge waived with its reason, the free dish', (t) async {
    await show(t, RstReportScreen(kind: 'discounts', api: Fake().api, today: today));
    expect(textOf(t, 'rep-disc-total'), '₹20');
    expect(textOf(t, 'rep-waived'), '₹16.80');
    expect(find.text('TEST20'), findsOneWidget);
    expect(find.textContaining('Coupon TEST20 by Asha Cashier'), findsOneWidget);
    expect(find.textContaining('waived by Asha Cashier: Regular guest'), findsOneWidget);
    expect(find.text('Water bottle'), findsOneWidget);
    expect(find.textContaining('Manual discounts and approvals are not recorded'), findsOneWidget);
  });

  testWidgets('Leakage audit: the cancelled bill after the KOT with who and why, the reprint, the change after the bill, the refund', (t) async {
    await show(t, RstReportScreen(kind: 'audit', api: Fake().api, today: today));
    expect(textOf(t, 'rep-audit-cancelled'), '1');
    expect(find.textContaining('after the kitchen got it · by Asha Cashier · Guest left'), findsOneWidget);
    expect(textOf(t, 'rep-audit-reprints'), '1');
    expect(textOf(t, 'rep-audit-after'), '1');
    expect(find.textContaining('Cold food'), findsOneWidget);
  });

  testWidgets('Export Excel saves the report with its rows', (t) async {
    Uint8List? file;
    String? name;
    final before = saveSpreadsheet;
    saveSpreadsheet = (b, n) async {
      file = b;
      name = n;
    };
    addTearDown(() => saveSpreadsheet = before);
    await show(t, RstReportScreen(kind: 'items', api: Fake().api, today: today));
    await tapKey(t, 'rep-export');
    expect(name, 'items-2026-10-31.xlsx');
    final sheet = utf8.decode(ZipDecoder().decodeBytes(file!).findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet, contains('Brownie Pancake'));
    expect(sheet, contains('<v>340'), reason: 'the revenue, as a number');
  });
}
