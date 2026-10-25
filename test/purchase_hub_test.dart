import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/item_parts.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/purchasing/purchase_hub_screen.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

// shapes as the local server answers them (pur_po_list / pur_po_json, grn_list, pur_supplier_list, pur_options, inv_dashboard)
Map<String, dynamic> po(String id, String number, String status, {bool overdue = false}) => {
      'id': id, 'number': number, 'status': status, 'overdue': overdue, 'expected_delivery': '2026-10-27', 'supplier': {'id': 'sup_1', 'name': 'ABC Foods'},
      'totals': {'total_minor': 125000, 'estimated_minor': 120000}, 'lines': [], 'allowed_actions': [],
    };

final _suppliers = <Map<String, dynamic>>[
  {'id': 'sup_1', 'name': 'ABC Foods', 'phone': '9876543210', 'city': 'Latur', 'gstin': '27ABCDE1234F1Z5', 'contact_person': 'Ravi', 'payment_terms': 'Net 15 Days', 'email': '', 'rating': 0},
];

class Fake {
  Fake([this.override]);
  final http.Response? Function(http.Request r)? override;
  final requests = <http.Request>[];
  final opened = <String>[];
  var suppliers = [..._suppliers];

  late final client = MockClient((r) async {
    requests.add(r);
    final o = override?.call(r);
    if (o != null) return o;
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    switch (fnOf(r)) {
      case 'inv_dashboard':
        return ok({'replenishment': [{'id': 'i1', 'name': 'Tata Salt'}, {'id': 'i2', 'name': 'Parle-G'}], 'counts': {}});
      case 'pur_po_list':
        if (b['due'] == 'overdue') return ok({'orders': [po('p3', 'PO-1003', 'Approved', overdue: true)], 'open_count': 1});
        return ok({
          'orders': switch (b['status']) {
            'open' => [po('p1', 'PO-1001', 'Approved')],
            'pending' => [po('p2', 'PO-1002', 'Pending'), po('p4', 'PO-1004', 'Draft')],
            'received' => <Map<String, dynamic>>[],
            _ => <Map<String, dynamic>>[],
          },
          'open_count': 1,
        });
      case 'grn_list':
        return ok({
          'items': [
            {'receipt_document_id': 'r1', 'doc_no': 'RCV-001', 'review_status': 'matching', 'supplier_name': 'ABC Foods', 'has_invoice': true},
            {'receipt_document_id': 'r2', 'doc_no': 'RCV-002', 'review_status': 'approval_due', 'supplier_name': 'ABC Foods'},
            {'receipt_document_id': 'r3', 'doc_no': 'RCV-003', 'review_status': 'approved', 'supplier_name': 'ABC Foods'},
          ],
        });
      case 'pur_supplier_list':
        return ok({'suppliers': suppliers});
      case 'pur_options':
        return ok({'suppliers': [], 'items': [], 'prices': [{'price_id': 'pr1', 'supplier_id': 'sup_1', 'ingredient_name': 'Tata Salt 1kg', 'unit': 'unit', 'price_minor': 2200}]});
      case 'pur_supplier_save':
        final s = {'id': 'sup_2', 'name': b['name'], 'phone': b['phone'] ?? '', 'city': b['city'] ?? '', 'gstin': b['gstin'] ?? '', 'payment_terms': 'Net 15 Days', 'contact_person': ''};
        suppliers = [...suppliers, s];
        return ok(s);
    }
    return err(404, 'not found: ${fnOf(r)}');
  });

  late final stock = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    open: (context, page, {itemId}) async => opened.add(page),
    onOpenReceiving: (_) => opened.add('receiving'),
  );
  late final env = PurEnv(api: PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client), inv: stock.inv);

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// A 390-point phone with the real fonts, so an overflow here is a real one.
Future<void> phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(780, 5000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f.first);
  await t.tap(f.first);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  testWidgets('To do counts each come from their source; open orders and suppliers are listed; plain words only', (t) async {
    final f = Fake();
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    String countOf(String key) => (t.widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)).at(0))).data!;
    expect(countOf('todo-buy'), '2'); // two replenishment suggestions
    expect(countOf('todo-due'), '1'); // one approved order to receive
    expect(countOf('todo-match'), '1'); // one receipt still matching (approved and approval_due are not)
    expect(countOf('todo-approve'), '2'); // one pending order + one receipt awaiting approval (a draft is not waiting)
    expect(find.text('PO-1001 · ABC Foods'), findsOneWidget);
    expect(find.text('To receive'), findsOneWidget);
    expect(find.text('ABC Foods'), findsOneWidget); // the supplier row
    expect(find.text('Latur · 9876543210'), findsOneWidget);
    for (final word in ['SKU', 'GRN']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
  });

  testWidgets('Buy again opens Reorder; Due and Waiting chips ask for overdue and pending orders', (t) async {
    final f = Fake();
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    await tap(t, find.byKey(const ValueKey('todo-buy')));
    expect(f.opened, ['reorder']);
    await tap(t, find.byKey(const ValueKey('chip-due')));
    expect(f.body(f.calls('pur_po_list').last)['due'], 'overdue');
    expect(find.text('PO-1003 · ABC Foods'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('chip-pending')));
    expect(f.body(f.calls('pur_po_list').last)['status'], 'pending');
    expect(find.text('Waiting approval'), findsOneWidget);
  });

  testWidgets('a source that cannot be read leaves its card without a number; the rest still show', (t) async {
    final f = Fake((r) => fnOf(r) == 'grn_list' ? err(403, 'Your role cannot see this.', 'forbidden') : null);
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    String countOf(String key) => (t.widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)).at(0))).data!;
    expect(countOf('todo-match'), '');
    expect(countOf('todo-buy'), '2');
    expect(countOf('todo-approve'), '1'); // the pending order alone
  });

  testWidgets('a supplier opens its details and prices; New order is there', (t) async {
    final f = Fake();
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    await tap(t, find.byKey(const ValueKey('supplier-sup_1')));
    expect(find.text('27ABCDE1234F1Z5'), findsOneWidget);
    expect(find.text('Ravi'), findsOneWidget);
    expect(find.text('Tata Salt 1kg'), findsOneWidget);
    expect(find.byKey(const ValueKey('supplier-new-order')), findsOneWidget);
  });

  testWidgets('Add supplier: the name is needed; the rest is optional; the new supplier is listed', (t) async {
    final f = Fake();
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    await tap(t, find.byKey(const ValueKey('supplier-add')));
    await tap(t, find.byKey(const ValueKey('supplier-save')));
    expect(find.text('Enter the supplier name.'), findsOneWidget);
    expect(f.calls('pur_supplier_save'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('supplier-name')), 'Fresh Farms');
    await t.enterText(find.byKey(const ValueKey('supplier-city')), 'Pune');
    await tap(t, find.byKey(const ValueKey('supplier-save')));
    final save = f.calls('pur_supplier_save').single;
    expect(f.body(save), {'name': 'Fresh Farms', 'city': 'Pune'});
    expect(save.headers['Idempotency-Key'], startsWith('pur-'));
    expect(toast('Fresh Farms added.'), findsOneWidget);
    expect(find.text('Fresh Farms'), findsOneWidget);
  });

  testWidgets('a refused supplier keeps the sheet open with the reason', (t) async {
    final f = Fake((r) => fnOf(r) == 'pur_supplier_save' ? err(409, 'You already have a supplier named ABC Foods.', 'duplicate') : null);
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    await tap(t, find.byKey(const ValueKey('supplier-add')));
    await t.enterText(find.byKey(const ValueKey('supplier-name')), 'ABC Foods');
    await tap(t, find.byKey(const ValueKey('supplier-save')));
    expect(find.text('You already have a supplier named ABC Foods.'), findsOneWidget);
    expect(find.byKey(const ValueKey('supplier-save')), findsOneWidget);
  });

  testWidgets('Receive a delivery is one tap, with or without a purchase order', (t) async {
    final f = Fake();
    await phone(t, PurchaseHubScreen(env: f.env, stock: f.stock));
    await t.ensureVisible(find.byKey(const ValueKey('receive-delivery')));
    await t.tap(find.byKey(const ValueKey('receive-delivery')));
    expect(f.opened, ['receiving']);
  });

  testWidgets('inside the Item tab it shows the Products · Stock · Purchase switcher first', (t) async {
    final f = Fake();
    await phone(t, ItemParts(current: 'purchase', select: (_) {}, child: PurchaseHubScreen(env: f.env, stock: f.stock)));
    expect(find.byKey(const ValueKey('item-part-purchase')), findsOneWidget);
    expect(t.getTopLeft(find.byKey(const ValueKey('item-part-products'))).dy, lessThan(t.getTopLeft(find.text('To do')).dy));
  });
}
