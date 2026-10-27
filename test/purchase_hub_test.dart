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
import 'package:vinii_pos/purchasing/add_supplier_sheet.dart' show pickPhoneContact;
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
      // nothing received yet: total_minor is 0 and the card shows the order's value
      'totals': {'total_minor': 0, 'ordered_total_minor': 125000, 'estimated_minor': 120000}, 'lines': [], 'allowed_actions': [],
    };

final _suppliers = <Map<String, dynamic>>[
  {'id': 'sup_1', 'name': 'ABC Foods', 'phone': '9876543210', 'city': 'Latur', 'gstin': '27ABCDE1234F1Z5', 'contact_person': 'Ravi', 'payment_terms': 'Net 15 Days', 'email': '', 'rating': 0},
];

class Fake {
  Fake([this.override]);
  final http.Response? Function(http.Request r)? override;
  final requests = <http.Request>[];
  final opened = <String>[];
  final receipts = <String?>[]; // receipt notes opened: an id, or null for a new one
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
      case 'inv_document_list':
        Map<String, dynamic> doc(String id, String no, String status, {String po = ''}) =>
            {'id': id, 'doc_no': no, 'status': status, 'doc_type': 'receipt', 'supplier_name': 'ABC Foods', 'po_ref': po, 'invoice_ref': '', 'totals': {'received': 12}, 'created_at': '2026-10-26T10:00:00Z', 'amount_minor': status == 'draft' ? 46800 : 52000, 'amount_kind': status == 'draft' ? 'estimate' : 'invoice'};
        return ok({
          'documents': [
            doc('r0', 'RCV-000', 'draft'),
            doc('r1', 'RCV-001', 'review', po: 'PO-1001'),
            doc('r2', 'RCV-002', 'review'),
            doc('r3', 'RCV-003', 'posted'),
            doc('r9', 'RCV-009', 'cancelled'),
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
    open: (context, page, {itemId}) async => opened.add(itemId == null ? page : '$page:$itemId'),
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
  // these tests check the typed form, which shows where the phone's contacts cannot open (Quick Add's tests cover the contacts)
  final realPicker = pickPhoneContact;
  setUp(() => pickPhoneContact = () async => throw MissingPluginException('no contacts in tests'));
  tearDown(() => pickPhoneContact = realPicker);

  Widget hub(Fake f) => PurchaseHubScreen(env: f.env, stock: f.stock, openReceipt: (_, id) async => f.receipts.add(id));

  testWidgets('+ Add Purchase starts a new receipt note, with or without an order', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('add-purchase')));
    expect(f.receipts, [null]);
  });

  testWidgets('Receipt notes: the open ones with what each waits for; a note being counted opens its count', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    expect(find.textContaining('RCV-000 · '), findsOneWidget);
    expect(find.text('Counting'), findsOneWidget);
    expect(find.text('To check'), findsOneWidget); // r1 is still matching
    expect(find.text('To approve'), findsOneWidget); // r2 waits for the owner
    expect(find.textContaining('RCV-003 · '), findsNothing); // received: under Received
    expect(find.textContaining('RCV-009 · '), findsNothing); // cancelled: never
    expect(find.textContaining('PO-1001 · 12 units'), findsOneWidget);
    expect(find.textContaining('No order · 12 units'), findsWidgets);
    // the supplier, the date and the amount stand out; a note not yet invoiced shows an estimate
    expect(find.text('ABC Foods'), findsWidgets);
    expect(find.text('26 Oct'), findsWidgets);
    expect(find.text('≈ ₹468'), findsOneWidget);
    expect(find.text('₹520'), findsNWidgets(2));
    expect(find.text('Purchase'), findsNothing); // no heading: the switcher above says where you are
    expect((t.widget<Text>(find.byKey(const ValueKey('part-receipts-count')))).data, '3');
    await tap(t, find.byKey(const ValueKey('receipt-r0')));
    expect(f.receipts, ['r0']);
    for (final word in ['SKU', 'GRN']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
  });

  testWidgets('a received note leads to the lot labels and putaway', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('chip-done')));
    expect(find.textContaining('RCV-003 · '), findsOneWidget);
    expect(find.textContaining('RCV-000 · '), findsNothing);
    await tap(t, find.byKey(const ValueKey('receipt-labels-r3')));
    await tap(t, find.byKey(const ValueKey('receipt-putaway-r3')));
    expect(f.opened, ['lot_labels:r3', 'putaway:r3']);
  });

  testWidgets('the delivery check cannot be read: the notes still show', (t) async {
    final f = Fake((r) => fnOf(r) == 'grn_list' ? err(403, 'Your role cannot see this.', 'forbidden') : null);
    await phone(t, hub(f));
    expect(find.textContaining('RCV-001 · '), findsOneWidget);
    expect(find.text('To check'), findsNWidgets(2));
  });

  testWidgets('Purchase orders: open orders and suppliers; Buy again opens Reorder; Due and Waiting chips ask the server', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('part-orders')));
    expect(find.text('PO-1001'), findsOneWidget);
    expect(find.text('To receive'), findsOneWidget);
    expect(find.text('Due 27 Oct'), findsOneWidget);
    expect(find.text('₹1,250'), findsOneWidget);
    expect(find.text('Latur · 9876543210'), findsOneWidget);
    expect(find.text('Buy again · 2'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('po-buy-again')));
    expect(f.opened, ['reorder']);
    await tap(t, find.byKey(const ValueKey('chip-due')));
    expect(f.body(f.calls('pur_po_list').last)['due'], 'overdue');
    expect(find.text('PO-1003'), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('chip-pending')));
    expect(f.body(f.calls('pur_po_list').last)['status'], 'pending');
    expect(find.text('Waiting approval'), findsOneWidget);
  });

  testWidgets('a supplier opens its details and prices; New order is there', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('part-orders')));
    await tap(t, find.byKey(const ValueKey('supplier-sup_1')));
    expect(find.text('27ABCDE1234F1Z5'), findsOneWidget);
    expect(find.text('Ravi'), findsOneWidget);
    expect(find.text('Tata Salt 1kg'), findsOneWidget);
    expect(find.byKey(const ValueKey('supplier-new-order')), findsOneWidget);
  });

  testWidgets('Add supplier: the name is needed; the rest is optional; the new supplier is listed', (t) async {
    final f = Fake();
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('part-orders')));
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
    await phone(t, hub(f));
    await tap(t, find.byKey(const ValueKey('part-orders')));
    await tap(t, find.byKey(const ValueKey('supplier-add')));
    await t.enterText(find.byKey(const ValueKey('supplier-name')), 'ABC Foods');
    await tap(t, find.byKey(const ValueKey('supplier-save')));
    expect(find.text('You already have a supplier named ABC Foods.'), findsOneWidget);
    expect(find.byKey(const ValueKey('supplier-save')), findsOneWidget);
  });

  testWidgets('a wide screen shows Receipt notes and Purchase orders side by side', (t) async {
    final f = Fake();
    t.view.physicalSize = const Size(2000, 3000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: hub(f)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('part-orders')), findsNothing);
    expect(find.textContaining('RCV-000 · '), findsOneWidget);
    expect(find.text('PO-1001'), findsOneWidget);
  });

  testWidgets('inside the Item tab it shows the Products · Stock · Purchase switcher first', (t) async {
    final f = Fake();
    await phone(t, ItemParts(current: 'purchase', select: (_) {}, child: hub(f)));
    expect(find.byKey(const ValueKey('item-part-purchase')), findsOneWidget);
    expect(t.getTopLeft(find.byKey(const ValueKey('item-part-products'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('add-purchase'))).dy));
  });
}
