import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/inventory/inventory_widgets.dart';
import 'package:vinii_pos/inventory/receiving_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (database/tests/400_inventory_section_h.sql story): the app is built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/inventory_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
const _writeFns = {'inv_document_save', 'inv_document_act', 'inv_audit_to_adjustment'};
bool isWrite(http.Request r) => _writeFns.contains(fnOf(r));

/// Fake server: records each request and answers from [handler], falling back to the fixtures for reads.
class Fake {
  Fake([http.Response? Function(http.Request r)? handler]) : _handler = handler;
  final http.Response? Function(http.Request r)? _handler;
  final requests = <http.Request>[];

  late final api = InventoryApi(
    baseUrl: 'http://inv.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      final custom = _handler?.call(r);
      if (custom != null) return custom;
      final p = fnOf(r);
      if (p == 'inv_options') return ok(fx['options']);
      if (p == 'inv_dashboard') return ok(fx['dashboard']);
      if (p == 'inv_stock_list') return ok(fx['stock_list']);
      if (p == 'inv_stock_detail') return ok(fx['stock_detail']);
      if (p == 'inv_movement_list') return ok(fx['movements']);
      if (p == 'inv_movement_detail') return ok(fx['movement']);
      if (p == 'inv_document_list') return ok(fx['documents_receipt']);
      if (p == 'inv_forecast') return ok(fx['forecast']);
      return err(404, 'not found: $p');
    }),
  );

  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
  http.Request get lastPost => requests.lastWhere(isWrite);
}

Future<void> showTall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 6400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

/// A document answer with its status and actions changed (what the server sends after an action).
Map<String, dynamic> doc(String key, {String? status, int? version, List<String>? actions}) =>
    {...(fx[key] as Map<String, dynamic>), 'status': ?status, 'version': ?version, 'allowed_actions': ?actions};

Map<String, dynamic> docList(String type, List<Map<String, dynamic>> docs) => {'documents': docs};

Map<String, dynamic> row(Map<String, dynamic> d) => {
      'id': d['id'], 'doc_no': d['doc_no'], 'doc_type': d['doc_type'], 'status': d['status'], 'title': d['title'], 'reason': d['reason'],
      'supplier_name': d['supplier_name'], 'po_ref': d['po_ref'], 'invoice_ref': d['invoice_ref'], 'created_at': d['created_at'], 'posted_at': d['posted_at'],
      'totals': {'lines': 1, 'expected': 24, 'received': 24, 'rejected': 2},
    };

void main() {
  tearDown(HomeNav.reset);

  group('InventoryApi', () {
    test('reads send the token and the store, and parse the server facts', () async {
      final s = Fake();
      s.api.locationId = 'loc-1';
      final d = await s.api.dashboard();
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'http://inv.test/rpc/inv_dashboard');
      expect(argsOf(r), {'location_id': 'loc-1'});
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(d.m('counts').n('total'), 2);
      expect(d.m('location').s('name'), 'Latur Main Branch');
    });

    test('stock list sends filter, search, category and page', () async {
      final s = Fake();
      await s.api.stock(filter: 'low', q: ' cola ', category: 'Beverages', page: 2);
      expect(s.requests.single.url.path, '/rpc/inv_stock_list');
      expect(argsOf(s.requests.single), {'filter': 'low', 'q': 'cola', 'category': 'Beverages', 'page': 2, 'page_size': 8});
    });

    test('creating a draft sends the key, the type and only ids and quantities', () async {
      final s = Fake((r) => ok(fx['receipt_draft']));
      final line = DraftLine(itemId: 'item-1', itemName: 'Coca-Cola 500ml', qty: 24, rejectedQty: 2, rejectReason: 'Broken seal', lotCode: 'CC-C', expiryDate: DateTime(2026, 11, 15));
      final d = await s.api.createDraft('receipt', fields: {'supplier_name': 'Coca-Cola Bottling'}, lines: [line], key: 'inv-abc');
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rpc/inv_document_save');
      expect(r.headers['Idempotency-Key'], 'inv-abc');
      expect(s.body(r), {
        'doc_type': 'receipt',
        'supplier_name': 'Coca-Cola Bottling',
        'lines': [
          {'inventory_item_id': 'item-1', 'lot_code': 'CC-C', 'expiry_date': '2026-11-15', 'qty': 24, 'rejected_qty': 2, 'reject_reason': 'Broken seal'}
        ],
      });
      expect(d.number, startsWith('RCV-'));
    });

    test('saving a draft carries the version the person saw; an action carries its own key', () async {
      final s = Fake((r) => ok(fx['receipt_draft']));
      await s.api.saveDraft('doc-1', version: 4, fields: {'note': 'x'});
      expect(s.body(s.lastPost), {'id': 'doc-1', 'version': 4, 'note': 'x'});
      expect(s.requests.last.url.path, '/rpc/inv_document_save');
      await s.api.act('doc-1', 'submit', version: 4, key: 'inv-k1');
      expect(s.requests.last.url.path, '/rpc/inv_document_act');
      expect(s.requests.last.headers['Idempotency-Key'], 'inv-k1');
      expect(s.body(s.lastPost), {'id': 'doc-1', 'action': 'submit', 'version': 4});
      await s.api.act('doc-1', 'reject', version: 5, note: 'why');
      expect(s.requests.last.headers['Idempotency-Key'], startsWith('inv-'));
      expect(s.body(s.lastPost)['note'], 'why');
    });

    test('server refusals keep their message and code; a stale version is flagged', () async {
      final s = Fake((r) => err(409, 'INV_STALE: someone changed RCV-002 since you opened it', 'version_conflict'));
      await expectLater(
          s.api.act('d', 'post', version: 1),
          throwsA(isA<InventoryApiException>().having((e) => e.stale, 'stale', true).having((e) => e.message, 'message', contains('someone changed'))));
    });

    test('no token: sign in again, nothing is sent', () async {
      final s = Fake();
      final api = InventoryApi(baseUrl: 'http://inv.test', accessToken: () => null, client: MockClient((r) async {
        s.requests.add(r);
        return ok({});
      }));
      await expectLater(api.dashboard(), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 401)));
      expect(s.requests, isEmpty);
    });

    test('keys are fresh per intent', () => expect(InventoryApi.newKey(), isNot(InventoryApi.newKey())));

    test('quantity and date formatting for display', () {
      expect(qty(1248), '1,248');
      expect(qty(342800), '3,42,800');
      expect(qty(0.5), '0.5');
      expect(qty(18.6), '18.6');
      expect(qty(11.25), '11.25');
      expect(qty(-2), '−2');
      expect(signed(12), '+12');
      expect(signed(-6), '−6');
      expect(units(1), '1 unit');
      expect(units(84), '84 units');
      expect(units(2.5, 'kg'), '2.5 kg');
      expect(dayMonth(DateTime(2026, 10, 5), year: true), '05 Oct 2026');
    });
  });

  group('Receiving (Figma "Receiving")', () {
    http.Response? route(http.Request r, {String status = 'draft'}) {
      final key = status == 'review' ? 'receipt_review' : 'receipt_draft';
      final p = fnOf(r);
      if (p == 'inv_document_list') return ok(docList('receipt', [row(doc(key))]));
      if (p == 'inv_document_view') return ok(doc(key));
      return null;
    }

    testWidgets('shows the open receipt: counts, reconciliation, the four buttons', (t) async {
      final s = Fake(route);
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      expect(find.text('Receive goods'), findsWidgets);
      expect(find.byKey(const ValueKey('purchase-steps-2')), findsOneWidget);
      for (final x in ['Count and inspect', 'Receipt reconciliation', 'Done counting · Match bill', 'Scan / add item', '+ New item', 'Save Draft', 'Expected shipment', 'Received physical count', 'Good / damaged', 'Quantity still to receive', 'Damaged']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('Good = received − damaged'), findsOneWidget);
      expect(find.textContaining('24 − 2 = 22'), findsOneWidget);
      expect(find.textContaining('Differences · '), findsOneWidget);
    });

    testWidgets('Send to GRN Review saves the draft, then submits it with the version and a key', (t) async {
      final s = Fake((r) {
        final base = route(r);
        if (fnOf(r) == 'inv_document_act') return ok(doc('receipt_review'));
        if (isWrite(r)) return ok(doc('receipt_draft', version: 3));
        return base;
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      final opened = <String>[];
      final real = openMatchBill;
      openMatchBill = (_, id) => opened.add(id);
      addTearDown(() => openMatchBill = real);
      await t.tap(find.text('Done counting · Match bill'));
      await t.pumpAndSettle();
      expect(opened, hasLength(1)); // step 3: match the bill
      final posts = s.requests.where(isWrite).toList();
      expect(posts, hasLength(2));
      expect(s.body(posts[0])['version'], (fx['receipt_draft'] as Map)['version']);
      expect(s.body(posts[0])['lines'], isA<List>());
      expect(s.body(posts[1]), allOf(containsPair('action', 'submit'), containsPair('version', 3)));
      expect(posts[1].headers['Idempotency-Key'], startsWith('inv-'));
      expect(toast('Counted. Now match the supplier bill.'), findsOneWidget);
    });

    testWidgets('a stale version shows the server message and reloads the document', (t) async {
      final s = Fake((r) {
        if (isWrite(r)) return err(409, 'INV_STALE: someone changed RCV-002 since you opened it', 'version_conflict');
        return route(r);
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Save Draft'));
      await t.pumpAndSettle();
      expect(toast('INV_STALE: someone changed RCV-002 since you opened it'), findsOneWidget);
      expect(s.requests.where((r) => fnOf(r) == 'inv_document_view'), isNotEmpty);
    });

    testWidgets('a receipt in review offers Post Receipt only when the server allows it', (t) async {
      final s = Fake((r) {
        if (isWrite(r)) return ok(doc('receipt_posted'));
        return route(r, status: 'review');
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api), documentId: (fx['receipt_review'] as Map)['id'] as String));
      expect(find.text('Done counting · Match bill'), findsNothing);
      final opened = <String>[];
      HomeNav.stockPage = (c, page, {itemId}) async => opened.add('$page:$itemId');
      addTearDown(() => HomeNav.stockPage = null);
      await t.tap(find.text('Post Receipt'));
      await t.pumpAndSettle();
      expect(s.body(s.lastPost)['action'], 'post');
      // received: asked whether to print; Not now leaves it
      expect(find.text('Print labels for this lot?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('labels-offer-no')));
      await t.pumpAndSettle();
      expect(opened, isEmpty);
      expect(toast('Receipt posted. The good units are now in stock.'), findsOneWidget);
    });

    testWidgets('no tab strip: Purchase and Putaway are not chips here (they are buttons once a delivery is checked)', (t) async {
      final s = Fake(route);
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      expect(find.byKey(const ValueKey('chip-putaway')), findsNothing);
      expect(find.byKey(const ValueKey('chip-grn')), findsNothing);
      expect(find.text('Putaway'), findsNothing);
    });

    testWidgets('+ New item: a product the shop does not have joins the note, flagged as not on the order; damaged units are flagged', (t) async {
      final real = newItemForReceiving;
      newItemForReceiving = (_, {name, barcode}) async => Facts({'id': 'new1', 'name': 'Kurkure Masala', 'sku': 'KURKUR-482'});
      addTearDown(() => newItemForReceiving = real);
      final s = Fake((r) {
        if (isWrite(r)) return ok(doc('receipt_draft', version: 3));
        return route(r);
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      expect(find.byKey(const ValueKey('receiving-flag-40b00000-0000-0000-0000-000000000001')), findsOneWidget);
      expect(find.text('2 damaged'), findsOneWidget); // the ordered line matches the order; only its damage shows
      await t.ensureVisible(find.byKey(const ValueKey('receiving-new-item')));
      await t.tap(find.byKey(const ValueKey('receiving-new-item')));
      await t.pumpAndSettle();
      expect(toast('Kurkure Masala added to the shop and to this receipt note.'), findsOneWidget);
      expect(find.text('Not on order'), findsOneWidget);
      expect(find.textContaining('Differences · 2'), findsOneWidget);
      await t.ensureVisible(find.text('Save Draft'));
      await t.tap(find.text('Save Draft'));
      await t.pumpAndSettle();
      final lines = s.body(s.requests.where(isWrite).last)['lines'] as List;
      expect(lines.map((l) => (l as Map)['inventory_item_id']), contains('new1'));
    });

    testWidgets('the damaged sheet offers Damaged first and keeps the reason already chosen', (t) async {
      final s = Fake(route);
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      await t.ensureVisible(find.byKey(const ValueKey('receiving-damaged')));
      await t.tap(find.byKey(const ValueKey('receiving-damaged')));
      await t.pumpAndSettle();
      expect(find.text('Damaged units'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Damaged'), findsOneWidget);
      expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, (fx['receipt_draft'] as Map)['lines'][0]['reject_reason'] as String)).selected, isTrue);
    });

    testWidgets('+ Add Purchase opens a new, empty receipt note even while another is being counted', (t) async {
      final s = Fake(route);
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api), startNew: true));
      expect(find.text('New receipt note'), findsOneWidget);
      expect(find.text('Coca-Cola 500ml'), findsNothing);
      expect(find.byKey(const ValueKey('receiving-supplier')), findsOneWidget);
      expect(find.byKey(const ValueKey('receiving-new-item')), findsOneWidget);
      expect(s.requests.where((r) => fnOf(r) == 'inv_document_view'), isEmpty);
    });

    testWidgets('no open receipt: say so and offer to start one', (t) async {
      final s = Fake((r) {
        final p = fnOf(r);
        if (p == 'inv_document_list') return ok(docList('receipt', []));
        return null;
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      expect(find.textContaining('No delivery is open'), findsOneWidget);
    });
  });


  group('Wiring', () {
    test('installRoutes plugs the Stock tab, one item, every stock page and Low stock into the new stock screens', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.stock, isNotNull);
      expect(HomeNav.stockItem, isNotNull);
      expect(HomeNav.stockPage, isNotNull);
      expect(HomeNav.lowStock, isNotNull);
    });
  });
}
