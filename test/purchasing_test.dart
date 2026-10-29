import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/purchasing/po_create_screen.dart';
import 'package:vinii_pos/purchasing/simple_purchase.dart';
import 'package:vinii_pos/purchasing/po_grn_screen.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/purchasing/purchasing_widgets.dart';
import 'package:vinii_pos/purchasing/supplier_price_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (database/tests/430_purchasing.sql story): the app is built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/purchasing_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class Fake {
  Fake([http.Response? Function(http.Request r)? handler]) : _handler = handler;
  final http.Response? Function(http.Request r)? _handler;
  final requests = <http.Request>[];

  late final api = PurchasingApi(
    baseUrl: 'http://pur.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      final custom = _handler?.call(r);
      if (custom != null) return custom;
      return switch (fnOf(r)) {
        'pur_options' => ok(fx['options']),
        'pur_supplier_list' => ok({'suppliers': (fx['options'] as Map)['suppliers']}),
        'pur_item_find' => ok({'items': [if (argsOf(r)['q'] == '8901234567890') {'id': '43b00000-0000-0000-0000-000000000001', 'name': 'Paneer', 'sku': 'PANEER', 'unit': 'kg', 'barcode': '8901234567890'}]}),
        'pur_po_list' => ok(fx['list']),
        'pur_po_view' => ok(switch (argsOf(r)['id']) { final i when i == (fx['po_received'] as Map)['id'] => fx['po_received'], final i when i == (fx['po_pending'] as Map)['id'] => fx['po_pending'], _ => fx['po_partial'] }),
        'pur_price_view' => ok(fx['price']),
        'pur_po_receive' => ok(fx['receive']),
        _ => err(404, 'not found: ${fnOf(r)}'),
      };
    }),
  );

  late final env = PurEnv(api: api, inv: InvEnv());
}

Future<void> showTall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 6400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

void main() {
  group('formatting', () {
    test('money: Indian grouping, paise only when they exist (or when fixed)', () {
      expect(money(360000), '₹3,600');
      expect(money(363250), '₹3,632.50');
      expect(money(28000, fixed: true), '₹280.00');
      expect(money(387240, fixed: true), '₹3,872.40');
      expect(money(123456789), '₹12,34,567.89');
      expect(money(0), '₹0');
    });
    test('quantities show one decimal at least', () {
      expect(qty1(10), '10.0');
      expect(qty1(18.5), '18.5');
      expect(qty1(0.125), '0.125');
    });
  });

  group('PurchasingApi', () {
    test('reads send the token and the store, writes carry the Idempotency-Key', () async {
      final s = Fake();
      s.api.locationId = 'loc-1';
      final d = await s.api.orders(status: 'pending', due: 'overdue', q: ' paneer ');
      final r = s.requests.single;
      expect(r.url.toString(), 'http://pur.test/rpc/pur_po_list');
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(argsOf(r), {'location_id': 'loc-1', 'status': 'pending', 'due': 'overdue', 'q': 'paneer', 'limit': 20});
      expect(d.l('orders'), isNotEmpty);
      await s.api.receive('po-1', key: 'k-1');
      expect(s.requests.last.headers['Idempotency-Key'], 'k-1');
      expect(argsOf(s.requests.last), {'location_id': 'loc-1', 'id': 'po-1'});
    });

    test('create sends supplier, lines in paise and the key; the answer is a typed order', () async {
      final s = Fake((r) => fnOf(r) == 'pur_po_create' ? ok(fx['po_received']) : null);
      final po = await s.api.create(supplierId: 'sup-abc', lines: [
        {'inventory_item_id': 'i1', 'qty': 10, 'unit_cost_minor': 28000, 'gst_pct': 5}
      ], key: 'k-2');
      final r = s.requests.single;
      expect(r.headers['Idempotency-Key'], 'k-2');
      expect(argsOf(r)['supplier_id'], 'sup-abc');
      expect((argsOf(r)['lines'] as List).single['unit_cost_minor'], 28000);
      expect(po.number, 'SPO-0007');
      expect(po.status, 'Received');
      expect(po.lines.length, 2);
      expect(argsOf(r)['submit'], true);
    });

    test('a server sentence and code survive', () async {
      final s = Fake((r) => err(409, 'Nothing on PO-0001 is left to receive as stock.', 'wrong_state'));
      await expectLater(s.api.receive('po-1'), throwsA(isA<PurchasingApiException>().having((e) => e.code, 'code', 'wrong_state').having((e) => e.message, 'message', contains('left to receive'))));
    });

    test('price, sourcing and audit calls', () async {
      final s = Fake((r) => fnOf(r) == 'pur_sourcing_select' || fnOf(r) == 'pur_audit_record' ? ok(fx['price']) : null);
      await s.api.selectSourcing('p-2', key: 'k-3');
      expect(s.requests.last.headers['Idempotency-Key'], 'k-3');
      await s.api.recordAudit('p-1', [
        {'name': 'Receiving temperature', 'result': 'fail', 'detail': '8.1C'}
      ]);
      expect(argsOf(s.requests.last), {
        'price_id': 'p-1',
        'checks': [
          {'name': 'Receiving temperature', 'result': 'fail', 'detail': '8.1C'}
        ]
      });
    });
  });

  group('A purchase order from what is low', () {
    testWidgets('the items come on with their quantities; the supplier with their prices is chosen; a line without a price is tapped to add it', (t) async {
      final s = Fake();
      await showTall(t, PoCreateScreen(env: s.env, want: const [
        (itemId: '43b00000-0000-0000-0000-000000000001', name: 'Paneer', unit: 'kg', qty: 5),
        (itemId: '43b00000-0000-0000-0000-000000000004', name: 'Red Tomatoes', unit: 'kg', qty: 3),
      ]));
      expect(find.textContaining('ABC Foods', findRichText: true), findsOneWidget); // the supplier with a price for Paneer
      expect(find.text('5 kg · ₹410/kg'), findsOneWidget);
      expect(find.text('3 kg · tap to add the price'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('po-line-43b00000-0000-0000-0000-000000000004')));
      await t.pumpAndSettle();
      expect(find.widgetWithText(TextField, '3'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, '40');
      await t.tap(find.byKey(const ValueKey('po-line-save')));
      await t.pumpAndSettle();
      expect(find.text('3 kg · ₹40/kg'), findsOneWidget);
      expect(find.text('₹2,170'), findsOneWidget); // 5 × 410 + 3 × 40
    });
  });

  group('Purchase order page', () {
    testWidgets('a received order: the Figma discrepancy lines, tax and total as the server computed them; no receive button', (t) async {
      final s = Fake();
      await showTall(t, PoGrnScreen(env: s.env, orderId: (fx['po_received'] as Map)['id'] as String));
      expect(find.text('Purchase order'), findsOneWidget);
      expect(find.text('SPO-0007 · ABC Foods'), findsOneWidget);
      expect(find.text('Received'), findsWidgets);
      expect(find.text('Discrepancy'), findsWidgets);
      expect(find.text('18.5 kg accepted'), findsOneWidget);
      expect(find.text('1.5 kg rejected'), findsOneWidget);
      expect(find.text('Subtotal accepted goods'), findsOneWidget);
      expect(find.text('₹3,632.50'), findsOneWidget);
      expect(find.text('₹239.90'), findsOneWidget);
      expect(find.text('Purchase total'), findsOneWidget);
      expect(find.text('₹3,872.40'), findsOneWidget);
      expect(find.byKey(const ValueKey('po-receive')), findsNothing);
    });

    testWidgets('a partly received order: In progress, what arrived so far, and Received', (t) async {
      final po = Map<String, dynamic>.from(fx['po_partial'] as Map);
      final s = Fake();
      await showTall(t, PoGrnScreen(env: s.env, orderId: po['id'] as String));
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('5.0 kg accepted'), findsOneWidget);
      expect(find.byKey(const ValueKey('po-receive')), findsOneWidget);
    });

    testWidgets('an open order has two outcomes only, Received or Cancel PO (no approval); Cancel asks the server', (t) async {
      final po = Map<String, dynamic>.from(fx['po_pending'] as Map);
      final s = Fake((r) => fnOf(r) == 'pur_po_act' ? ok({...po, 'status': 'Cancelled', 'allowed_actions': <String>[]}) : null);
      await showTall(t, PoGrnScreen(env: s.env, orderId: po['id'] as String));
      expect(find.textContaining('Waiting for approval'), findsNothing);
      expect(find.byKey(const ValueKey('po-receive')), findsOneWidget);
      expect(find.text('Approve order'), findsNothing);
      expect(find.text("Don't approve"), findsNothing);
      await t.tap(find.text('Cancel PO'));
      await t.pumpAndSettle();
      final call = s.requests.lastWhere((r) => fnOf(r) == 'pur_po_act');
      expect(argsOf(call)['action'], 'cancel');
      expect(argsOf(call)['id'], po['id']);
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('a refused cancel shows the server sentence, not a crash', (t) async {
      final po = {...(fx['po_pending'] as Map<String, dynamic>), 'allowed_actions': ['cancel']};
      final s = Fake((r) => fnOf(r) == 'pur_po_view' ? ok(po) : (fnOf(r) == 'pur_po_act' ? err(403, 'Your role cannot cancel this order.', 'forbidden') : null));
      await showTall(t, PoGrnScreen(env: s.env, orderId: po['id'] as String));
      await t.tap(find.text('Cancel PO'));
      await t.pumpAndSettle();
      expect(find.textContaining('Your role cannot cancel this order.'), findsOneWidget);
    });

    testWidgets('Received opens the one-step receive screen with this order (no receipt draft is started)', (t) async {
      final po = Map<String, dynamic>.from(fx['po_partial'] as Map);
      final s = Fake();
      await showTall(t, PoGrnScreen(env: s.env, orderId: po['id'] as String));
      await t.tap(find.byKey(const ValueKey('po-receive')));
      await t.pumpAndSettle();
      expect(find.byType(ReceiveGoodsScreen), findsOneWidget);
      expect(s.requests.where((r) => fnOf(r) == 'pur_po_receive'), isEmpty);
    });
  });

  group('New purchase order', () {
    Future<void> pickAbcAndPaneer(WidgetTester t) async {
      await t.tap(find.textContaining('Choose a supplier'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('supplier-from-phone')), findsOneWidget); // phone contacts, as on Received
      expect(find.text('Who are you ordering from?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('supplier-sup-abc')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-add-items')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-pick-43b00000-0000-0000-0000-000000000001')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-pick-add')));
      await t.pumpAndSettle();
    }

    testWidgets('the item list: search, tick several, Add N items; each comes in at 1 with its price', (t) async {
      final s = Fake();
      await showTall(t, PoCreateScreen(env: s.env));
      await t.tap(find.textContaining('Choose a supplier'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('supplier-sup-abc')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-add-items')));
      await t.pumpAndSettle();
      expect(find.text('Basmati rice'), findsOneWidget);
      expect(find.text('Tick the items to order'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('po-item-search')), 'pan');
      await t.pumpAndSettle();
      expect(find.text('Basmati rice'), findsNothing);
      await t.tap(find.byKey(const ValueKey('po-pick-43b00000-0000-0000-0000-000000000001')));
      await t.enterText(find.byKey(const ValueKey('po-item-search')), '');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-pick-43b00000-0000-0000-0000-000000000004')));
      await t.pumpAndSettle();
      expect(find.text('Add 2 items'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('po-pick-add')));
      await t.pumpAndSettle();
      expect(find.text('1 kg · ₹410/kg'), findsOneWidget);
      expect(find.text('1 kg · tap to add the price'), findsOneWidget);
    });

    testWidgets('Scan barcode adds the scanned item; scanning it again adds one more', (t) async {
      final s = Fake();
      final before = scanForPurchase;
      scanForPurchase = (_) async => '8901234567890';
      addTearDown(() => scanForPurchase = before);
      await showTall(t, PoCreateScreen(env: s.env));
      await t.tap(find.textContaining('Choose a supplier'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('supplier-sup-abc')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('po-scan')));
      await t.pumpAndSettle();
      expect(find.text('1 kg · ₹410/kg'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('po-scan')));
      await t.pumpAndSettle();
      expect(find.text('2 kg · ₹410/kg'), findsOneWidget);
      scanForPurchase = (_) async => '0000';
      await t.tap(find.byKey(const ValueKey('po-scan')));
      await t.pumpAndSettle();
      expect(find.textContaining('No item has barcode 0000'), findsOneWidget);
    });

    testWidgets('supplier, items, estimated total and create; the server gets paise and one key', (t) async {
      final s = Fake((r) => fnOf(r) == 'pur_po_create' ? ok(fx['po_partial']) : null);
      await showTall(t, PoCreateScreen(env: s.env));
      expect(find.text('New purchase order'), findsOneWidget);
      expect(find.text('0 open orders already'), findsOneWidget);
      expect(find.text('Estimated total'), findsOneWidget);
      expect(find.text('₹0'), findsOneWidget);
      expect(tester(t, 'Place order'), isNull); // disabled until a supplier and an item exist
      await pickAbcAndPaneer(t);
      expect(find.text('1 kg · ₹410/kg'), findsOneWidget); // ticked items come in at 1, at the supplier's price
      await t.tap(find.byKey(const ValueKey('po-line-43b00000-0000-0000-0000-000000000001')));
      await t.pumpAndSettle();
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10');
      await t.enterText(fields.at(1), '360');
      expect(find.text('GST (%)'), findsNothing); // no GST while ordering: it comes from the bill
      await t.tap(find.byKey(const ValueKey('po-line-save')));
      await t.pumpAndSettle();
      expect(find.text('10 kg · ₹360/kg'), findsOneWidget);
      expect(find.text('₹3,600'), findsWidgets);
      await t.tap(find.text('Generate PO'));
      await t.pumpAndSettle();
      final call = s.requests.lastWhere((r) => fnOf(r) == 'pur_po_create');
      final a = argsOf(call);
      expect(a['supplier_id'], isNotEmpty);
      expect(a['submit'], true);
      final line = (a['lines'] as List).single as Map;
      expect([line['qty'], line['unit_cost_minor'], line['gst_pct']], [10, 36000, 0]);
      expect(call.headers['Idempotency-Key'], startsWith('pur-'));
    });

    Future<void> createOne(WidgetTester t, Fake s) async {
      await showTall(t, PoCreateScreen(env: s.env));
      await pickAbcAndPaneer(t);
      expect(find.text('1 kg · ₹410/kg'), findsOneWidget); // ticked items come in at 1, at the supplier's price
      await t.tap(find.byKey(const ValueKey('po-line-43b00000-0000-0000-0000-000000000001')));
      await t.pumpAndSettle();
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10');
      await t.enterText(fields.at(1), '360');
      expect(find.text('GST (%)'), findsNothing); // no GST while ordering: it comes from the bill
      await t.tap(find.byKey(const ValueKey('po-line-save')));
      await t.pumpAndSettle();
      await t.tap(find.text('Generate PO'));
      await t.pumpAndSettle();
    }

    testWidgets('Generate PO is one step: the order is live at once, nobody approves it, and the screen goes back to the list', (t) async {
      final live = {...(fx['po_pending'] as Map<String, dynamic>), 'status': 'Approved', 'allowed_actions': ['receive', 'cancel']};
      final s = Fake((r) => fnOf(r) == 'pur_po_create' ? ok(live) : null);
      await createOne(t, s);
      expect(s.requests.where((r) => fnOf(r) == 'pur_po_act'), isEmpty); // no approve call
      expect(toast('${live['number']} generated. Mark it Received when the goods come.'), findsOneWidget);
    });
  });

  group('Send to supplier', () {
    testWidgets('the small send icon opens WhatsApp to the supplier\'s saved number with the order written out', (t) async {
      final po = fx['po_partial'] as Map<String, dynamic>;
      final supplierId = (po['supplier'] as Map)['id'];
      final s = Fake((r) => fnOf(r) == 'pur_supplier_list' ? ok({'suppliers': [{'id': supplierId, 'name': 'ABC Foods', 'phone': '98765 43210'}]}) : null);
      final opened = <Uri>[];
      await showTall(t, PoGrnScreen(env: s.env, orderId: po['id'] as String, openUrl: (u) async { opened.add(u); return true; }));
      await t.tap(find.byKey(const ValueKey('po-send')));
      await t.pumpAndSettle();
      final u = opened.single;
      expect(u.host, 'api.whatsapp.com');
      expect(u.queryParameters['phone'], '919876543210');
      final text = u.queryParameters['text']!;
      expect(text, startsWith('Purchase order ${po['number']}'));
      for (final l in po['lines'] as List) {
        expect(text, contains((l as Map)['name']));
      }
    });
  });

  group('Supplier Price Detail', () {
    testWidgets('overview: active selection, audit-trail banner and contract parameters; unknown figures are dashes', (t) async {
      final s = Fake();
      await showTall(t, SupplierPriceScreen(env: s.env, priceId: 'p-1'));
      expect(find.text('Supplier prices'), findsOneWidget);
      expect(find.textContaining('Fresh Malai Paneer'), findsOneWidget);
      expect(find.textContaining('Supplier: ABC Foods · UOM: Per KG · System Code: INGR-042'), findsOneWidget);
      expect(find.text('AI Inferred'), findsOneWidget);
      for (final x in ['Re-Audit', 'Select Sourcing', 'Overview & Trends', 'Alternative Bids', 'Quality Audit', 'Active Supplier Selection', 'Sourcing Contract Parameters']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.text('ABC Foods (Preferred)'), findsOneWidget);
      expect(find.text('Contract Rate: ₹410/kg · Rating: 4.8★'), findsOneWidget);
      expect(find.text('Bid Rate: ₹425/kg · Rating: 4.2★'), findsOneWidget);
      expect(find.text('Sourcing selection changes require kitchen controller audit trailing.'), findsOneWidget);
      expect(find.text('24 Hours'), findsOneWidget);
      expect(find.text('10 kg'), findsOneWidget);
      expect(find.text('Net 15 Days'), findsOneWidget);
      expect(find.text('98% Guaranteed'), findsOneWidget);
    });

    testWidgets('alternative bids: both suppliers, dashes where nothing is recorded, and Select supplier asks first then calls the server', (t) async {
      final asOwner = {...(fx['price'] as Map<String, dynamic>), 'allowed_actions': ['select_sourcing', 're_audit']};   // the fixture was read by an inventory manager
      final s = Fake((r) => fnOf(r) == 'pur_sourcing_select' ? ok(fx['price_krishna']) : (fnOf(r) == 'pur_price_view' ? ok(asOwner) : null));
      await showTall(t, SupplierPriceScreen(env: s.env, priceId: 'p-1', tab: 'bids'));
      expect(find.text('Available Supplier Bids'), findsOneWidget);
      expect(find.text('2 suppliers · Rates per KG'), findsOneWidget);
      expect(find.text('Krishna Dairy'), findsOneWidget);
      expect(find.text('Lead Time: 36 Hours'), findsOneWidget);
      expect(find.text('Supply Availability: —'), findsOneWidget);
      expect(find.text('Current preferred supplier'), findsOneWidget);
      await t.tap(find.text('Select supplier'));
      await t.pumpAndSettle();
      expect(find.text('Select Krishna Dairy?'), findsOneWidget);
      await t.tap(find.text('Select supplier').last);
      await t.pumpAndSettle();
      final call = s.requests.lastWhere((r) => fnOf(r) == 'pur_sourcing_select');
      expect(argsOf(call)['price_id'], isNotEmpty);
      expect(call.headers['Idempotency-Key'], startsWith('pur-'));
      expect(find.text('Krishna Dairy (Preferred)'), findsWidgets);
    });

    testWidgets('quality audit: no round recorded says so, never made-up checks', (t) async {
      final s = Fake();
      await showTall(t, SupplierPriceScreen(env: s.env, priceId: 'p-1', tab: 'audit'));
      expect(find.text('Key Quality Checks'), findsOneWidget);
      expect(find.text('No audit recorded yet.'), findsOneWidget);
    });

    testWidgets('quality audit: the latest round with the summary banner', (t) async {
      final price = Map<String, dynamic>.from(fx['price_audited'] as Map);   // what the server returned after a round of 4 pass, 1 warning, 1 fail
      final s = Fake((r) => fnOf(r) == 'pur_price_view' ? ok(price) : null);
      await showTall(t, SupplierPriceScreen(env: s.env, priceId: 'p-1', tab: 'audit'));
      expect(find.text('Re-audit required · 4 Pass · 1 Warning · 1 Fail'), findsOneWidget);
      expect(find.text('Receiving temperature'), findsOneWidget);
      expect(find.text('Fail'), findsOneWidget);
      expect(find.text('Warning'), findsOneWidget);
      expect(find.text('Pass'), findsNWidgets(4));
    });

    testWidgets('Re-Audit sends the checks as typed; a role without the action sees both buttons disabled', (t) async {
      final s = Fake((r) => fnOf(r) == 'pur_audit_record' ? ok(fx['price']) : null);
      await showTall(t, SupplierPriceScreen(env: s.env, priceId: 'p-1', tab: 'audit'));
      await t.tap(find.text('Re-Audit'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'Receiving temperature');
      await t.tap(find.text('Fail'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record audit'));
      await t.pumpAndSettle();
      final call = s.requests.lastWhere((r) => fnOf(r) == 'pur_audit_record');
      expect((argsOf(call)['checks'] as List).single['name'], 'Receiving temperature');
      expect((argsOf(call)['checks'] as List).single['result'], 'fail');

      final readOnly = Map<String, dynamic>.from(fx['price'] as Map)..['allowed_actions'] = <String>[];
      final r = Fake((x) => fnOf(x) == 'pur_price_view' ? ok(readOnly) : null);
      await showTall(t, SupplierPriceScreen(env: r.env, priceId: 'p-1'));
      await t.tap(find.text('Re-Audit'));
      await t.pumpAndSettle();
      expect(find.text('Record audit'), findsNothing);
    });
  });
}

/// The tapped-button helper: null when the labelled primary button is disabled.
VoidCallback? tester(WidgetTester t, String label) {
  final w = t.widgetList<InkWell>(find.ancestor(of: find.text(label), matching: find.byType(InkWell)));
  return w.isEmpty ? null : w.first.onTap;
}
