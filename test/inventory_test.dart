import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/adjustment_screen.dart';
import 'package:vinii_pos/inventory/audit_screen.dart';
import 'package:vinii_pos/inventory/forecast_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/inventory/inventory_dashboard.dart';
import 'package:vinii_pos/inventory/inventory_widgets.dart';
import 'package:vinii_pos/inventory/movement_screen.dart';
import 'package:vinii_pos/inventory/receiving_screen.dart';
import 'package:vinii_pos/inventory/stock_detail_screen.dart';
import 'package:vinii_pos/inventory/stock_list_screen.dart';
import 'package:vinii_pos/inventory/transfer_screen.dart';
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

  group('Dashboard (Figma "Inventory Dashboard")', () {
    testWidgets('shows the store, counts, attention, actions, tools and planning from the server', (t) async {
      final s = Fake();
      await showTall(t, InventoryDashboard(env: InvEnv(api: s.api)));
      expect(find.text('Inventory Dashboard'), findsOneWidget);
      expect(find.textContaining('Latur Main Branch'), findsOneWidget);
      for (final x in ['Stock Overview', 'Total items', 'Low Stock', 'Critical', 'Needs Attention', 'Quick Actions', 'Receive Stock', 'View Inventory', 'Transfer Stock', 'Stock Adjustment', 'Start Stock Audit', 'Inventory Tools', 'Expiry', 'Reservations', 'Warehouse', 'Locations', 'Batch / Lot Tracking', 'Movement History', 'Planning', 'Replenishment', 'Inventory Forecast', 'Stock Risk', 'Inventory Positioning']) {
        expect(find.text(x), findsOneWidget, reason: x);
      }
      expect(find.text('Damaged stock quarantined'), findsOneWidget);
      expect(find.textContaining('AUD-001'), findsOneWidget);
      expect(find.textContaining('75 free · 24 inbound · 99 nominal total'), findsOneWidget);
      expect(find.textContaining('Drafts do not change posted stock'), findsOneWidget);
    });

    testWidgets('a server failure shows its message and a retry', (t) async {
      final s = Fake((r) => err(403, 'INV_FORBIDDEN: your role cannot see stock'));
      await showTall(t, InventoryDashboard(env: InvEnv(api: s.api)));
      expect(find.textContaining('your role cannot see stock'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('Receive Stock, View Inventory, Transfer, Adjustment and Audit open their screens; later tools say so', (t) async {
      final s = Fake();
      await showTall(t, InventoryDashboard(env: InvEnv(api: s.api)));
      for (final (label, type) in [
        ('Receive Stock', ReceivingScreen),
        ('View Inventory', StockListScreen),
        ('Transfer Stock', TransferScreen),
        ('Stock Adjustment', AdjustmentScreen),
        ('Start Stock Audit', AuditScreen),
      ]) {
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        expect(find.byType(type), findsOneWidget, reason: label);
        Navigator.of(t.element(find.byType(type))).pop();
        await t.pumpAndSettle();
      }
      await t.tap(find.text('Warehouse'));
      await t.pump();
      expect(toast('Warehouse opens in a later release.'), findsOneWidget);
    });

    testWidgets('the bottom bar sends other tabs out and Stock returns here', (t) async {
      final s = Fake();
      final out = <String>[];
      await showTall(t, InventoryDashboard(env: InvEnv(api: s.api, onNavigate: out.add)));
      await t.tap(find.byKey(const ValueKey('inv-tab-home')));
      await t.tap(find.byKey(const ValueKey('inv-tab-online')));
      expect(out, ['home', 'online']);
    });
  });

  group('Stock list (Figma "Stock")', () {
    testWidgets('shows filters, search, the server items with their status and the page footer', (t) async {
      final s = Fake();
      await showTall(t, StockListScreen(env: InvEnv(api: s.api)));
      expect(find.text('Store Inventory View'), findsOneWidget);
      for (final x in ['All Items', 'Healthy', 'Low Stock', 'Critical', 'SKU', 'Ingredients', 'Adjust Stock', 'Export', 'View Details']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.text('Paneer'), findsOneWidget);
      expect(find.text('Out of Stock'), findsOneWidget);
      expect(find.textContaining('Showing 1-2 of 2 items'), findsOneWidget);
    });

    testWidgets('a filter chip asks the server for that filter, and so does search', (t) async {
      final s = Fake();
      await showTall(t, StockListScreen(env: InvEnv(api: s.api)));
      await t.tap(find.byKey(const ValueKey('chip-low')));
      await t.pumpAndSettle();
      expect(argsOf(s.requests.last)['filter'], 'low');
      await t.enterText(find.byType(TextField), 'cola');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(argsOf(s.requests.last)['q'], 'cola');
    });

    testWidgets('tapping an item opens its detail', (t) async {
      final s = Fake();
      await showTall(t, StockListScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Paneer'));
      await t.pumpAndSettle();
      expect(find.byType(StockDetailScreen), findsOneWidget);
      expect(s.requests.where((r) => fnOf(r) == 'inv_stock_detail' && argsOf(r)['item_id'] == '40b00000-0000-0000-0000-000000000002'), hasLength(1));
    });

    testWidgets('export is honest about not being built', (t) async {
      final s = Fake();
      await showTall(t, StockListScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Export'));
      await t.pump();
      expect(toast('Export opens in a later release.'), findsOneWidget);
    });
  });

  group('Stock detail (Figma "Stock Detail")', () {
    testWidgets('shows availability, location bars, batches and the latest movement', (t) async {
      final s = Fake();
      await showTall(t, StockDetailScreen(env: InvEnv(api: s.api), itemId: 'x'));
      expect(find.text('Stock Detail'), findsOneWidget);
      expect(find.text('Coca-Cola 500ml'), findsWidgets);
      for (final x in ['Available units', 'Stock days', 'Reserved (Active Carts)', 'In Transit (From Warehouse)', 'Damaged / Quarantine', 'Overview', 'Lots', 'Movements', 'Available by location', 'Batch and expiry', 'Latest posted movement', 'View Movements', 'View Lots', 'Transfer Stock']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('Quarantine Q-01'), findsOneWidget);
    });

    testWidgets('Lots and Movements tabs and the movement link', (t) async {
      final s = Fake();
      await showTall(t, StockDetailScreen(env: InvEnv(api: s.api), itemId: 'x'));
      await t.tap(find.text('View Lots'));
      await t.pumpAndSettle();
      expect(find.text('Earliest expiry first'), findsOneWidget);
      await t.tap(find.text('View Movements'));
      await t.pumpAndSettle();
      expect(find.text('Newest first · posted only'), findsOneWidget);
    });
  });

  group('Movement detail (Figma "Movement Detail")', () {
    testWidgets('shows before, delta, after, source, the linked bill and the audit trail', (t) async {
      final s = Fake();
      String? opened;
      await showTall(t, MovementScreen(env: InvEnv(api: s.api, onOpenOrder: (c, id) => opened = id), movementId: 1));
      expect(find.text('Movement Detail'), findsOneWidget);
      expect(find.text('Posted'), findsOneWidget);
      expect(find.text('90'), findsOneWidget);
      expect(find.text('−6'), findsOneWidget);
      expect(find.text('84'), findsOneWidget);
      expect(find.text('Transaction reference'), findsOneWidget);
      expect(find.text('Posting method'), findsOneWidget);
      expect(find.text('POS checkout'), findsOneWidget);
      expect(find.text('Audit trail'), findsOneWidget);
      expect(find.textContaining('Posted records cannot be edited'), findsOneWidget);
      await t.tap(find.textContaining('Open Linked Transaction'));
      expect(opened, isNotNull);
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
      expect(find.text('Receiving'), findsWidgets);
      for (final x in ['GRN', 'Putaway', 'Count and inspect', 'Receipt reconciliation', 'Send to GRN Review', 'Scan / Enter Items', 'Save Draft', 'Expected shipment', 'Received physical count', 'Accepted / rejected quarantine', 'Quantity still to receive']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('Accepted = received − rejected'), findsOneWidget);
      expect(find.textContaining('24 − 2 = 22'), findsOneWidget);
      expect(find.textContaining('Review Discrepancies · 2 rejects'), findsOneWidget);
    });

    testWidgets('Send to GRN Review saves the draft, then submits it with the version and a key', (t) async {
      final s = Fake((r) {
        final base = route(r);
        if (fnOf(r) == 'inv_document_act') return ok(doc('receipt_review'));
        if (isWrite(r)) return ok(doc('receipt_draft', version: 3));
        return base;
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Send to GRN Review'));
      await t.pumpAndSettle();
      final posts = s.requests.where(isWrite).toList();
      expect(posts, hasLength(2));
      expect(s.body(posts[0])['version'], (fx['receipt_draft'] as Map)['version']);
      expect(s.body(posts[0])['lines'], isA<List>());
      expect(s.body(posts[1]), allOf(containsPair('action', 'submit'), containsPair('version', 3)));
      expect(posts[1].headers['Idempotency-Key'], startsWith('inv-'));
      expect(toast('Sent to GRN review. Stock changes when the receipt is posted.'), findsOneWidget);
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
      expect(find.text('Send to GRN Review'), findsNothing);
      await t.tap(find.text('Post Receipt'));
      await t.pumpAndSettle();
      expect(s.body(s.lastPost)['action'], 'post');
      expect(toast('Receipt posted. The accepted units are now in stock.'), findsOneWidget);
    });

    testWidgets('Putaway is honest about not being built', (t) async {
      final s = Fake(route);
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      await t.tap(find.byKey(const ValueKey('chip-putaway')));
      await t.pump();
      expect(toast('Putaway opens in a later release.'), findsOneWidget);
    });

    testWidgets('no open receipt: say so and offer to start one', (t) async {
      final s = Fake((r) {
        final p = fnOf(r);
        if (p == 'inv_document_list') return ok(docList('receipt', []));
        return null;
      });
      await showTall(t, ReceivingScreen(env: InvEnv(api: s.api)));
      expect(find.textContaining('No receipt is open'), findsOneWidget);
    });
  });

  group('Adjustment (Figma "Adjustment")', () {
    http.Response? route(http.Request r, {String key = 'adjustment_draft', String? status}) {
      final p = fnOf(r);
      if (p == 'inv_document_list') return ok(docList('adjustment', [row(doc(key, status: status))]));
      if (p == 'inv_document_view') return ok(doc(key, status: status));
      return null;
    }

    testWidgets('shows the draft: product, place and lot, type, quantity, reason, the proposed change, evidence and the banner', (t) async {
      final s = Fake(route);
      await showTall(t, AdjustmentScreen(env: InvEnv(api: s.api)));
      expect(find.text('Stock Adjustment'), findsOneWidget);
      for (final x in ['Draft', 'Awaiting approval', 'Posted', 'Product', 'Location / lot', 'Adjustment type', 'Quantity (units)', 'Reason', 'Proposed balance change', 'Evidence and approval', 'Operator note', 'Requested by', 'Required approver', 'Submit for Approval', 'Save Draft']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('Decrease available stock', findRichText: true), findsOneWidget);
      expect(find.textContaining('Current availability stays'), findsOneWidget);
    });

    testWidgets('Submit for Approval saves then submits, and says stock has not changed', (t) async {
      final s = Fake((r) {
        final base = route(r);
        if (fnOf(r) == 'inv_document_act') return ok(doc('adjustment_awaiting'));
        if (isWrite(r)) return ok(doc('adjustment_draft', version: 5));
        return base;
      });
      await showTall(t, AdjustmentScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Submit for Approval'));
      await t.pumpAndSettle();
      final posts = s.requests.where(isWrite).toList();
      expect(posts, hasLength(2));
      expect(s.body(posts[0])['lines'][0]['adjust_type'], 'decrease');
      expect(s.body(posts[1]), allOf(containsPair('action', 'submit'), containsPair('version', 5)));
      expect(toast('Submitted for approval. Stock has not changed yet.'), findsOneWidget);
    });

    testWidgets('an approver sees Approve and Send Back', (t) async {
      final withApprove = doc('adjustment_awaiting', actions: ['approve', 'reject', 'cancel']);
      final s1 = Fake((r) {
        if (fnOf(r) == 'inv_document_list') return ok(docList('adjustment', [row(withApprove)]));
        if (fnOf(r) == 'inv_document_view') return ok(withApprove);
        if (isWrite(r)) return ok(doc('adjustment_posted'));
        return null;
      });
      await showTall(t, AdjustmentScreen(env: InvEnv(api: s1.api)));
      expect(find.text('Approve and Post'), findsOneWidget);
      expect(find.text('Send Back'), findsOneWidget);
      await t.tap(find.text('Approve and Post'));
      await t.pumpAndSettle();
      expect(s1.body(s1.lastPost)['action'], 'approve');
      expect(toast('Adjustment posted.'), findsOneWidget);
    });

    testWidgets('someone who cannot approve sees who is waited for and no approve button', (t) async {
      final s2 = Fake((r) => route(r, key: 'adjustment_awaiting'));
      await showTall(t, AdjustmentScreen(env: InvEnv(api: s2.api)));
      expect(find.text('Approve and Post'), findsNothing);
      expect(find.textContaining('Waiting for'), findsOneWidget);
    });
  });

  group('Transfer (Figma "Transfer")', () {
    http.Response? route(http.Request r, {String key = 'transfer_draft'}) {
      final p = fnOf(r);
      if (p == 'inv_document_list') return ok(docList('transfer', [row(doc(key))]));
      if (p == 'inv_document_view') return ok(doc(key));
      return null;
    }

    testWidgets('shows the draft: places, quantity, balance preview, handling checks, reason, operator, banner', (t) async {
      final s = Fake(route);
      await showTall(t, TransferScreen(env: InvEnv(api: s.api)));
      expect(find.text('Transfer'), findsOneWidget);
      for (final x in ['Internal transfer', 'Inter-facility', 'Product / lot', 'From location', 'To location', 'Transfer quantity (units)', 'Balance preview', 'Handling checks', 'Reason', 'Assigned operator', 'Independent draft', 'Review Transfer', 'Save Draft']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.text('No reserved units selected'), findsOneWidget);
    });

    testWidgets('Review Transfer asks first, then saves and posts', (t) async {
      final s = Fake((r) {
        final base = route(r);
        if (fnOf(r) == 'inv_document_act') return ok(doc('transfer_posted'));
        if (isWrite(r)) return ok(doc('transfer_draft', version: 7));
        return base;
      });
      await showTall(t, TransferScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Review Transfer'));
      await t.pumpAndSettle();
      expect(find.text('Post transfer?'), findsOneWidget);
      expect(s.requests.where(isWrite), isEmpty, reason: 'nothing is sent before the person confirms');
      await t.tap(find.text('Post transfer'));
      await t.pumpAndSettle();
      expect(s.body(s.lastPost), allOf(containsPair('action', 'post'), containsPair('version', 7)));
      expect(toast('Transfer posted.'), findsOneWidget);
    });

    testWidgets('an in-transit transfer offers Receive Transfer', (t) async {
      final s = Fake((r) {
        if (isWrite(r)) return ok(doc('transfer_posted'));
        return route(r, key: 'transfer_in_transit');
      });
      await showTall(t, TransferScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Receive Transfer'));
      await t.pumpAndSettle();
      expect(s.body(s.lastPost)['action'], 'receive');
    });
  });

  group('Stock audit (Figma "Stock Audit")', () {
    http.Response? route(http.Request r, {String key = 'audit_review'}) {
      final p = fnOf(r);
      if (p == 'inv_document_list') return ok(docList('audit', [row(doc(key))]));
      if (p == 'inv_document_view') return ok(doc(key));
      return null;
    }

    testWidgets('shows progress, the counted item with its variance, the summary and the buttons', (t) async {
      final s = Fake((r) => route(r, key: 'audit_counted'));
      await showTall(t, AuditScreen(env: InvEnv(api: s.api)));
      expect(find.text('Stock Audit'), findsOneWidget);
      for (final x in ['In progress', 'Completed', 'System snapshot', 'Counter / approver', 'Count progress', 'Audit summary', 'Net variance', 'Variance explanation', 'Save Audit', 'Send for Review']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.text('1 of 1 SKUs counted'), findsOneWidget);
      expect(find.textContaining('−2 units'), findsWidgets);
      expect(find.textContaining('Count evidence is not a posted balance'), findsOneWidget);
    });

    testWidgets('in review with a variance: Create Adjustment Draft calls the server once and opens the adjustment', (t) async {
      final s = Fake((r) {
        if (fnOf(r) == 'inv_audit_to_adjustment') return ok(doc('adjustment_from_audit'));
        if (fnOf(r) == 'inv_document_list') return ok(docList('audit', [row(doc('audit_review'))]));
        if (fnOf(r) == 'inv_document_view' && argsOf(r)['id'] == (fx['adjustment_from_audit'] as Map)['id']) return ok(doc('adjustment_from_audit'));
        if (fnOf(r) == 'inv_document_view') return ok(doc('audit_review'));
        return null;
      });
      await showTall(t, AuditScreen(env: InvEnv(api: s.api)));
      await t.tap(find.text('Create Adjustment Draft'));
      await t.pumpAndSettle();
      expect(s.requests.where((r) => fnOf(r) == 'inv_audit_to_adjustment'), hasLength(1));
      expect(s.requests.where((r) => fnOf(r) == 'inv_audit_to_adjustment').single.headers['Idempotency-Key'], startsWith('inv-'));
      expect(find.byType(AdjustmentScreen), findsOneWidget);
    });

    testWidgets('no count in progress: offer to start one', (t) async {
      final s = Fake((r) {
        if (fnOf(r) == 'inv_document_list') return ok(docList('audit', []));
        return null;
      });
      await showTall(t, AuditScreen(env: InvEnv(api: s.api)));
      expect(find.textContaining('No count is in progress'), findsOneWidget);
      expect(find.text('Start Stock Audit'), findsOneWidget);
    });
  });

  group('Forecast (Figma "Inventory Forecast")', () {
    testWidgets('shows the horizon tabs, tiles, chart, assumptions, sensitivity and buttons', (t) async {
      final s = Fake();
      await showTall(t, ForecastScreen(env: InvEnv(api: s.api), itemId: 'x'));
      expect(find.text('Inventory Forecast'), findsOneWidget);
      for (final x in ['7 days', '14 days', '30 days', 'Product', 'Projected available stock', 'Assumptions', 'Opening available', 'Demand model', 'Inbound scenario', 'Rejected delivery units', 'Projection', 'Review Scenario', 'Edit Assumptions']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('Sensitivity · next 7 days'), findsOneWidget);
      expect(argsOf(s.requests.last)['days'], 7);
    });

    testWidgets('a longer horizon and a what-if demand are sent to the server, never saved', (t) async {
      final s = Fake();
      await showTall(t, ForecastScreen(env: InvEnv(api: s.api), itemId: 'x'));
      await t.tap(find.byKey(const ValueKey('chip-14')));
      await t.pumpAndSettle();
      expect(argsOf(s.requests.last)['days'], 14);
      await t.tap(find.text('Edit Assumptions'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, '14');
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(argsOf(s.requests.last)['demand_per_day'], 14);
      expect(s.requests.where(isWrite), isEmpty);
    });
  });

  group('Wiring', () {
    test('installRoutes plugs the Stock tab of the control centre into the inventory dashboard', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.stock, isNotNull);
    });

    testWidgets('the Stock hook opens the dashboard', (t) async {
      HomeNav.reset();
      installRoutes();
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => HomeNav.stock!(c), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(InventoryDashboard), findsOneWidget);
    });
  });
}
