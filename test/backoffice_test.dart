import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/backoffice/backoffice_api.dart';
import 'package:vinii_pos/backoffice/backoffice_widgets.dart';
import 'package:vinii_pos/backoffice/low_stock_screen.dart';
import 'package:vinii_pos/backoffice/purchase_suggestions_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'backoffice_fixtures.dart';
import 'helpers.dart';

/// Fake One Local server for `POST /rpc/<backoffice function>`: records each request and answers from [handler].
class FakeBackoffice {
  FakeBackoffice(this.handler, {String? locationId}) : _location = locationId;
  final http.Response Function(http.Request r) handler;
  final String? _location;
  final requests = <http.Request>[];
  late final api = BackofficeApi(
    baseUrl: 'http://pos.test/',
    accessToken: () => 'token-123',
    locationId: _location,
    client: MockClient((r) async {
      requests.add(r);
      return handler(r);
    }),
  );
  Iterable<http.Request> calls(String fn) => requests.where((r) => r.method == 'POST' && r.url.path == '/rpc/$fn');
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

/// The usual server: low stock, suggestions (refresh and list), close.
http.Response Function(http.Request) server({http.Response Function(http.Request)? close, http.Response Function(http.Request)? refresh}) => (r) {
      final p = r.url.path;
      if (p == '/rpc/backoffice_low_stock') return ok(lowStockJson());
      if (p == '/rpc/purchase_suggestions_refresh') return refresh?.call(r) ?? ok({'recorded': 1});
      if (p == '/rpc/purchase_suggestions_close') return close?.call(r) ?? ok({'closed': 2, 'purchase_order_ref': 'PO-0001'});
      if (p == '/rpc/purchase_suggestions_list') return ok(suggestionsJson());
      return err(404, 'Not found.');
    };

Future<void> showTall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 5600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Finder _card(String name) => find.ancestor(of: find.text(name), matching: find.byType(BoCard));

void main() {
  group('BackofficeApi', () {
    test('low stock is POST /rpc/backoffice_low_stock with the token, the location, the filter and the trimmed search', () async {
      final s = FakeBackoffice(server(), locationId: 'loc-1');
      final v = await s.api.lowStock(filter: 'critical', q: ' pan ');
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rpc/backoffice_low_stock');
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(jsonDecode(r.body), {'location_id': 'loc-1', 'filter': 'critical', 'q': 'pan'});
      expect(v.low, 15);
      expect(v.critical, 8);
      expect(v.items.first.critical, isTrue);
      expect(v.items.first.daysCover, 0.5);
      expect(v.items.first.reorderLevel, isNull);
      expect(v.snapshot.locationName, 'Latur Main Branch');
    });

    test('no location: the question covers the whole business (no location_id)', () async {
      final s = FakeBackoffice(server());
      await s.api.suggestions();
      expect(s.requests.single.url.path, '/rpc/purchase_suggestions_list');
      expect(jsonDecode(s.requests.single.body), isEmpty);
    });

    test('someone who works at some stores is switched to their own store and asked again', () async {
      final s = FakeBackoffice((r) {
        final body = jsonDecode(r.body) as Map;
        if (r.url.path == '/rpc/inv_options') return ok({'location': {'id': 'loc-own', 'name': 'Latur Second'}});
        if (body['location_id'] == null) return err(403, 'Choose your store: you can only see and buy for the stores you work at.', 'store_scope');
        return ok(lowStockJson());
      });
      final v = await s.api.lowStock();
      expect(s.requests.map((r) => r.url.path), ['/rpc/backoffice_low_stock', '/rpc/inv_options', '/rpc/backoffice_low_stock']);
      expect(jsonDecode(s.requests.last.body)['location_id'], 'loc-own');
      expect(s.api.locationId, 'loc-own');
      expect(v.items, isNotEmpty);
    });

    test('a role refusal is not a store question: passed on, no store lookup', () async {
      final s = FakeBackoffice((_) => err(403, 'Your role cannot see stock.', 'forbidden'));
      await expectLater(s.api.lowStock(), throwsA(isA<BackofficeApiException>().having((e) => e.status, 'status', 403)));
      expect(s.requests, hasLength(1));
      expect(s.api.locationId, isNull);
    });

    test('refresh records with an idempotency key, then reads the list', () async {
      final s = FakeBackoffice(server());
      final v = await s.api.refreshSuggestions(key: 'bo-1234');
      expect(s.requests.map((r) => r.url.path), ['/rpc/purchase_suggestions_refresh', '/rpc/purchase_suggestions_list']);
      expect(s.requests.first.headers['Idempotency-Key'], 'bo-1234');
      expect(v.suggestions.map((x) => x.suggestedQty), [6, 2, null]);
    });

    test('mark ordered sends ids, the outcome, the reference and the quantities', () async {
      final s = FakeBackoffice(server());
      final n = await s.api.markOrdered({'s-paneer': 2, 's-gulab': 1.5}, reference: ' PO-77 ', key: 'bo-9');
      final r = s.requests.single;
      expect(r.url.path, '/rpc/purchase_suggestions_close');
      expect(r.headers['Idempotency-Key'], 'bo-9');
      expect(jsonDecode(r.body), {
        'ids': ['s-paneer', 's-gulab'],
        'outcome': 'ordered',
        'purchase_order_ref': 'PO-77',
        'quantities': {'s-paneer': 2, 's-gulab': 1.5},
      });
      expect(n, 2);
    });

    test('dismiss sends the ids and the outcome only', () async {
      final s = FakeBackoffice(server(close: (_) => ok({'closed': 1})));
      expect(await s.api.dismiss(['s-1'], key: 'bo-d'), 1);
      expect(jsonDecode(s.requests.single.body), {'ids': ['s-1'], 'outcome': 'dismissed'});
    });

    test('server refusals keep their message and code', () async {
      final s = FakeBackoffice((_) => err(409, 's-1 is already ordered.', 'conflict'));
      await expectLater(
        s.api.markOrdered({'s-1': 1}, reference: 'PO-1', key: 'k'),
        throwsA(isA<BackofficeApiException>().having((e) => e.code, 'code', 'conflict').having((e) => e.status, 'status', 409)),
      );
    });

    test('signed out: no request', () async {
      final requests = <http.Request>[];
      final api = BackofficeApi(baseUrl: 'http://x', accessToken: () => null, client: MockClient((r) async {
        requests.add(r);
        return ok({});
      }));
      await expectLater(api.lowStock(), throwsA(isA<Exception>()));
      expect(requests, isEmpty);
    });

    test('keys are unique', () {
      final keys = List.generate(50, (_) => BackofficeApi.newKey()).toSet();
      expect(keys.length, 50);
      expect(keys.first, matches(RegExp(r'^bo-[0-9a-f]{32}$')));
    });
  });

  group('formatting', () {
    test('quantities, units, initials, snapshot', () {
      expect(qty(3), '3');
      expect(qty(0.5), '0.5');
      expect(qty(2.250), '2.25');
      expect(withUnit(12, 'units'), '12 units');
      expect(initialsOf('Rahul Sharma'), 'RS');
      expect(initialsOf('rahul'), 'R');
      expect(initialsOf(null), '');
      expect(snapshotLine(DateTime(2026, 10, 5, 10, 30), 'Latur Main Branch'), '05 Oct 2026 · 10:30 snapshot · Latur Main Branch');
      expect(snapshotLine(DateTime(2026, 10, 5, 10, 30), null), '05 Oct 2026 · 10:30 snapshot · All locations');
      expect(inboundTitle(daysCover: 0.5, inboundQty: 15, inboundEta: DateTime(2026, 10, 6), unit: 'units'), '0.5 days cover · 15u inbound · ETA 06 Oct');
      expect(inboundTitle(daysCover: 0.5, inboundQty: null, unit: 'units'), isNull);
    });
  });

  group('Low Stock', () {
    testWidgets('draws the Figma frame from the server answer', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, LowStockScreen(api: s.api));
      expect(find.text('Stock Management / Inventory'), findsOneWidget);
      expect(find.text('Low Stock'), findsWidgets);
      expect(find.text('RS'), findsOneWidget);
      expect(find.textContaining('Latur Main Branch'), findsOneWidget);
      expect(find.text('Items needing replenishment · 15 low stock · 8 critical'), findsOneWidget);
      expect(find.text('Showing recorded items only. Reorder levels and short quantities are not recorded.'), findsOneWidget);
      expect(find.text('3 units'), findsOneWidget);
      expect(find.text('12 units'), findsOneWidget);
      expect(find.text('4 units'), findsOneWidget);
      expect(find.descendant(of: _card('Biryani'), matching: find.text('Urgent')), findsOneWidget);
      expect(find.descendant(of: _card('Paneer'), matching: find.text('Low Stock')), findsOneWidget);
      expect(find.text('0.5 days cover · 15u inbound · ETA 06 Oct'), findsOneWidget);
      expect(find.text('Review inbound before ordering.'), findsOneWidget);
      expect(find.text('Not set'), findsNWidgets(3));
      expect(find.text('Not recorded'), findsNWidgets(3));
      expect(find.text('Supplier: Not recorded · Last purchase price: Not recorded'), findsNWidgets(3));
      expect(find.text('View Item'), findsNWidgets(3));
      expect(find.text('Restock Items'), findsOneWidget);
      expect(find.textContaining('Drafts do not change posted stock.'), findsOneWidget);
    });

    testWidgets('recorded levels, shortfalls and prices are shown; the note is hidden when nothing is missing', (t) async {
      final s = FakeBackoffice((_) => ok(lowStockJson(missingLevels: false, items: [
            {'id': 'i1', 'name': 'Paneer', 'unit': 'kg', 'available': 12, 'level': 'low', 'reorder_level': 20, 'quantity_short': 8, 'supplier_name': 'Amul Dairy', 'last_purchase_price': 340},
          ])));
      await showTall(t, LowStockScreen(api: s.api));
      expect(find.text('20 kg'), findsOneWidget);
      expect(find.text('8 kg'), findsOneWidget);
      expect(find.text('Supplier: Amul Dairy · Last purchase price: ₹340'), findsOneWidget);
      expect(find.textContaining('Showing recorded items only'), findsNothing);
      expect(find.byType(InboundBox), findsNothing);
    });

    testWidgets('filters and search go to the server', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, LowStockScreen(api: s.api));
      await t.tap(find.text('Critical'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['filter'], 'critical');
      await t.enterText(find.byType(TextField), 'bir');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body), {'filter': 'critical', 'q': 'bir'});
    });

    testWidgets('View Item opens section H with the item id, or says it is not built', (t) async {
      String? opened;
      final s = FakeBackoffice(server());
      await showTall(t, LowStockScreen(api: s.api, onViewItem: (_, id) => opened = id));
      await t.tap(find.descendant(of: _card('Paneer'), matching: find.text('View Item')));
      expect(opened, 'i-paneer');

      await showTall(t, LowStockScreen(api: FakeBackoffice(server()).api));
      await t.tap(find.text('View Item').first);
      await t.pump();
      expect(toast('Stock detail opens in a later release.'), findsOneWidget);
    });

    testWidgets('Restock Items opens Purchase Suggestions, which records suggestions first', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, LowStockScreen(api: s.api));
      await t.tap(find.text('Restock Items'));
      await t.pumpAndSettle();
      expect(find.byType(PurchaseSuggestionsScreen), findsOneWidget);
      expect(s.calls('purchase_suggestions_refresh'), hasLength(1));
    });

    testWidgets('bottom bar: other tabs go to their sections', (t) async {
      final tabs = <String>[];
      await showTall(t, LowStockScreen(api: FakeBackoffice(server()).api, onNavigate: tabs.add));
      await t.tap(find.text('Money'));
      await t.tap(find.text('Stock'));
      expect(tabs, ['money']);
    });

    testWidgets('nothing low: an honest empty state', (t) async {
      await showTall(t, LowStockScreen(api: FakeBackoffice((_) => ok(lowStockJson(items: [], missingLevels: false))).api));
      expect(find.text('Nothing is running low. Items at or under their reorder level show here.'), findsOneWidget);
    });

    testWidgets('a failure shows the server message and retries', (t) async {
      var fail = true;
      final s = FakeBackoffice((r) => fail ? err(403, 'Your role cannot see stock.') : ok(lowStockJson()));
      await showTall(t, LowStockScreen(api: s.api));
      expect(find.text('Your role cannot see stock.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('Biryani'), findsOneWidget);
    });
  });

  group('Purchase Suggestions', () {
    testWidgets('draws the Figma frame from the server answer', (t) async {
      await showTall(t, PurchaseSuggestionsScreen(api: FakeBackoffice(server()).api));
      expect(find.text('Purchase Suggestions'), findsOneWidget);
      expect(find.text('Review items and quantities, then mark them ordered with your purchase order number.'), findsOneWidget);
      expect(find.text('Select items to include. Quantities are recorded suggestions, not calculated shortfalls.'), findsOneWidget);
      expect(find.text('3 units in stock'), findsOneWidget);
      expect(find.text('Reason: Urgent replenishment · 0.5 days cover'), findsOneWidget);
      expect(find.text('Reason: Low stock'), findsNWidgets(2));
      expect(find.text('15u inbound · Inbound ETA 06 Oct'), findsOneWidget);
      expect(find.text('Review inbound before ordering. The recorded 6u suggestion is not a net requirement.'), findsOneWidget);
      expect(find.text('Suggested quantity'), findsNWidgets(3));
      expect(find.widgetWithText(TextField, '6'), findsOneWidget);
      expect(find.widgetWithText(TextField, '2'), findsOneWidget);
      expect(find.text('No suggestion quantity recorded. Enter a quantity before including this item.'), findsOneWidget);
      expect(find.text('Estimate unavailable'), findsNWidgets(3));
      expect(find.text('Selected: none'), findsOneWidget);
      expect(find.text('Estimated total: Estimate unavailable'), findsOneWidget);
      expect(find.text('Mark as Ordered'), findsOneWidget);
    });

    testWidgets('ticking an item with a quantity selects it (Figma: Paneer · 2 units)', (t) async {
      await showTall(t, PurchaseSuggestionsScreen(api: FakeBackoffice(server()).api));
      await t.tap(find.bySemanticsLabel('Include Paneer'));
      await t.pump();
      expect(find.text('Selected: Paneer · 2 units suggested'), findsOneWidget);
    });

    testWidgets('an item with no recorded quantity needs one before it can be ticked', (t) async {
      await showTall(t, PurchaseSuggestionsScreen(api: FakeBackoffice(server()).api));
      await t.tap(find.bySemanticsLabel('Include Gulab Jamun'));
      await t.pump();
      expect(toast('Enter a quantity before including this item.'), findsOneWidget);
      expect(find.text('Selected: none'), findsOneWidget);
      final field = find.descendant(of: _card('Gulab Jamun'), matching: find.byType(TextField));
      await t.enterText(field, '5');
      await t.pump();
      expect(find.text('No suggestion quantity recorded. Enter a quantity before including this item.'), findsNothing);
      await t.tap(find.bySemanticsLabel('Include Gulab Jamun'));
      await t.pump();
      expect(find.text('Selected: Gulab Jamun · 5 units suggested'), findsOneWidget);
      // clearing the quantity takes it out again
      await t.enterText(field, '');
      await t.pump();
      expect(find.text('Selected: none'), findsOneWidget);
    });

    testWidgets('Mark as Ordered asks for the purchase order number and sends the ticked lines with typed quantities', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      final listsBefore = s.calls('purchase_suggestions_list').length;
      await t.enterText(find.descendant(of: _card('Biryani'), matching: find.byType(TextField)), '4');
      await t.tap(find.bySemanticsLabel('Include Biryani'));
      await t.tap(find.bySemanticsLabel('Include Paneer'));
      await t.pump();
      await t.tap(find.text('Mark as Ordered'));
      await t.pumpAndSettle();
      expect(find.text('Purchase order number'), findsOneWidget);
      await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'PO-0001');
      await t.tap(find.text('Mark as ordered'));
      await t.pumpAndSettle();
      final r = s.calls('purchase_suggestions_close').single;
      expect(jsonDecode(r.body), {
        'ids': ['s-biryani', 's-paneer'],
        'outcome': 'ordered',
        'purchase_order_ref': 'PO-0001',
        'quantities': {'s-biryani': 4, 's-paneer': 2},
      });
      expect(r.headers['Idempotency-Key'], startsWith('bo-'));
      expect(toast('Marked as ordered under PO-0001.'), findsOneWidget);
      expect(find.text('Selected: none'), findsOneWidget);
      expect(s.calls('purchase_suggestions_list').length, listsBefore + 1); // reloaded
    });

    testWidgets('nothing ticked: says so and sends nothing', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      await t.tap(find.text('Mark as Ordered'));
      await t.pump();
      expect(toast('Select items to include.'), findsOneWidget);
      expect(s.calls('purchase_suggestions_close'), isEmpty);
    });

    testWidgets('cancelling the number sends nothing', (t) async {
      final s = FakeBackoffice(server());
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      await t.tap(find.bySemanticsLabel('Include Paneer'));
      await t.pump();
      await t.tap(find.text('Mark as Ordered'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(s.calls('purchase_suggestions_close'), isEmpty);
      expect(find.text('Selected: Paneer · 2 units suggested'), findsOneWidget);
    });

    testWidgets('a refusal keeps the selection and retries with the same key', (t) async {
      var refuse = true;
      final s = FakeBackoffice(server(close: (_) => refuse ? err(503, 'Try again in a moment.') : ok({'closed': 1})));
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      await t.tap(find.bySemanticsLabel('Include Paneer'));
      await t.pump();
      Future<void> mark() async {
        await t.tap(find.text('Mark as Ordered'));
        await t.pumpAndSettle();
        await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'PO-7');
        await t.tap(find.text('Mark as ordered'));
        await t.pumpAndSettle();
      }

      await mark();
      expect(toast('Try again in a moment.'), findsOneWidget);
      expect(find.text('Selected: Paneer · 2 units suggested'), findsOneWidget);
      refuse = false;
      await mark();
      final keys = s.calls('purchase_suggestions_close').map((r) => r.headers['Idempotency-Key']).toList();
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });

    testWidgets('a role that cannot record suggestions still sees the open ones', (t) async {
      final s = FakeBackoffice(server(refresh: (_) => err(403, 'Your role cannot manage purchase suggestions', 'forbidden')));
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      expect(s.calls('purchase_suggestions_list'), hasLength(1));
      expect(find.text('Biryani'), findsOneWidget);
    });

    testWidgets('estimates: quantity x unit cost, totalled when every ticked item has one', (t) async {
      final s = FakeBackoffice((r) => ok(suggestionsJson(suggestions: [
            {'id': 's1', 'name': 'Paneer', 'unit': 'kg', 'available': 12, 'level': 'low', 'reason': 'low_stock', 'suggested_qty': 2, 'supplier_name': 'Amul Dairy', 'estimated_unit_cost': 340, 'delivery_days': 2},
          ])));
      await showTall(t, PurchaseSuggestionsScreen(api: s.api));
      expect(find.text('Amul Dairy'), findsOneWidget);
      expect(find.text('₹680'), findsOneWidget);
      expect(find.text('In 2 days'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Include Paneer'));
      await t.pump();
      expect(find.text('Estimated total: ₹680'), findsOneWidget);
    });

    testWidgets('no suggestions: an honest empty state and no purchase order', (t) async {
      await showTall(t, PurchaseSuggestionsScreen(api: FakeBackoffice((_) => ok(suggestionsJson(suggestions: []))).api));
      expect(find.text('No purchase suggestions. Items running low are suggested here.'), findsOneWidget);
      final cta = t.widget<LimeCta>(find.byType(LimeCta));
      expect(cta.onPressed, isNull);
    });
  });

  group('routes', () {
    tearDown(HomeNav.reset);
    test('installRoutes plugs Low Stock into the control centre', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.lowStock, isNotNull);
      expect(HomeNav.stockItem, isNotNull); // section H's stock detail ("view item")
    });
  });
}
