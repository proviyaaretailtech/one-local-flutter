import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
import 'package:vinii_pos/restaurant/restaurant_api.dart';

import 'home_test.dart' show FakeHome, summaryJson, showTall;

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> dash({bool noKitchen = false, bool noStock = false, String loc = 'l1', bool old = false}) => {
      'business': 'Satya Kitchen',
      'location': {'id': loc, 'name': loc == 'l1' ? 'Banjara Hills' : 'Jubilee Hills'},
      'outlets': [
        {'id': 'l1', 'name': 'Banjara Hills'},
        {'id': 'l2', 'name': 'Jubilee Hills'},
      ],
      'date_label': 'Sunday, 18 October 2026',
      'orders': old ? {'live': 4, 'today': 19} : {'live': 4, 'new': 1, 'in_progress': 3, 'today': 19},
      'kot': noKitchen ? null : {'new': 2, 'in_progress': 3, 'ready': 1, 'served': 9, 'delayed': 1, 'critical': 2},
      'tables': {'all': 10, 'available': 6, 'occupied': 3, 'reserved': 1, 'cleaning': 0},
      'ingredients_low': noStock ? null : {'low': 3, 'critical': 17},
      'sales': {'today': 7402, 'gross': 7402, 'refunds': 0, 'paid_bills': 18},
      'onelocal': {'scope': 'business', 'today': 5, 'open': 2, 'sales_today': 1450},
      'last7': [
        for (var i = 0; i < 7; i++) {'date': '2026-10-${12 + i}', 'label': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i], 'sales': i == 6 ? 7402 : 0, 'orders': i == 6 ? 18 : 0},
      ],
      'not_reported': ['complaints', 'reviews'],
      if (!old) ...{
        'prev7': {'sales': 3701, 'orders': 20},
        'channel': {'open_outlets': 1, 'outlets': 1},
        'ingredients_items': noStock
            ? null
            : [
                {'name': 'Fresh Paneer (Block)', 'unit': 'kg', 'available': 1.2, 'reorder_level': 10, 'level': 'critical'},
                {'name': 'Fresh Cream', 'unit': 'L', 'available': 2.8, 'reorder_level': 5, 'level': 'low'},
              ],
      },
    };

class FakeRst {
  FakeRst(this.answer);
  final http.Response Function(Map<String, dynamic> body) answer;
  final calls = <(String, Map<String, dynamic>)>[];
  late final api = RestaurantApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((r.url.pathSegments.last, body));
      return answer(body);
    }),
  );
}

http.Response ok(Map<String, dynamic> j) => http.Response(jsonEncode(j), 200, headers: _json);

Future<FakeRst> showRst(WidgetTester t, {FakeRst? rpc}) async {
  final r = rpc ?? FakeRst((_) => ok(dash()));
  await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson(kind: 'restaurant')), restaurantApi: r.api, now: () => DateTime.utc(2026, 10, 18, 10)));
  return r;
}

void main() {
  setUp(() {
    HomeNav.reset();
    OutletScope.reset(); // the header's outlet switcher is app-wide
  });

  group('Restaurant dashboard (home of a restaurant)', () {
    testWidgets('My Feed follows the founder frame section by section, every figure from the server', (t) async {
      final r = await showRst(t);
      // the header's default is "All outlets": the server sums the outlets (0524)
      expect(r.calls.where((c) => c.$1 == 'rst_dashboard_scope'), hasLength(1));
      expect(r.calls.first.$2['location_id'], 'all');
      for (final text in [
        // tabs, title
        'My Feed', 'Sales', 'Funnel', 'Service Quality', 'Restaurant Dashboard', 'Today · Restaurant operations', 'LIVE',
        // orders and KOTs
        'Live orders', '1 new', '3 in progress', 'Pending', '2 critical', 'Kitchen queue',
        // kitchen, tables, sales today
        'Kitchen status', '1 delayed', 'Open kitchen display ›', 'Tables', 'View tables ›', '10 total', '6 Available', '3 Occupied', '1 Reserved', '0 Cleaning',
        'Sales today', '₹7,402', '19 orders received',
        // ingredients, One Local
        'Ingredients', 'View stock ›', '20 low stock', 'Fresh Paneer (Block)', '1.2 kg · reorder at 10 kg', 'CRITICAL', 'Fresh Cream', '2.8 L · reorder at 5 L', 'LOW',
        'OneLocal orders', 'Manage orders received through OneLocal.', '2 open · 5 today · ₹1,450', 'View orders ›',
        // period, today so far, quick links, analytics
        'Last 7 days', 'Compare: Prev period', 'Today so far', 'Open', 'Quick Links', 'Manage daily operations',
        'Order history', 'Complaints', 'Reviews', 'Settings', 'Outlet info', 'Show all',
        'Sales Analytics', 'Net sales', 'Orders delivered', 'Average order value', 'Get deeper insights →',
      ]) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      // the % change is the server's previous 7 days: 7402 vs 3701 = +100.0%, 18 vs 20 orders = -10.0%
      expect(find.descendant(of: find.byKey(const ValueKey('rst-net-sales')), matching: find.text('100.0%')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('rst-orders-delivered')), matching: find.text('10.0%')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-2026-10-18')), findsOneWidget);
      expect(find.text('ORDERS LIVE'), findsNothing); // the old navy band is gone
      expect(find.text('Stock health'), findsNothing);
    });

    testWidgets('Compare: Prev period off hides the % change', (t) async {
      await showRst(t);
      await t.ensureVisible(find.byKey(const ValueKey('rst-compare-label')));
      await t.tap(find.byKey(const ValueKey('rst-compare-label')));
      await t.pumpAndSettle();
      expect(find.text('100.0%'), findsNothing);
    });

    testWidgets('Sales tab shows real sales; Funnel and Service Quality say Coming soon, no invented numbers', (t) async {
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('rst-tab-Sales')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rst-analytics')), findsOneWidget);
      expect(find.byKey(const ValueKey('rst-sales-today')), findsOneWidget);
      expect(find.text('Kitchen status'), findsNothing);
      for (final tab in ['Funnel', 'Service Quality']) {
        await t.ensureVisible(find.byKey(ValueKey('rst-tab-$tab')));
        await t.tap(find.byKey(ValueKey('rst-tab-$tab')));
        await t.pumpAndSettle();
        expect(find.byKey(ValueKey('rst-soon-$tab')), findsOneWidget);
        expect(find.text('Coming soon'), findsOneWidget);
        expect(find.textContaining('₹'), findsNothing);
      }
    });

    testWidgets('complaints and reviews say Not reported, they carry no invented count', (t) async {
      await showRst(t);
      expect(find.text('Not reported'), findsNWidgets(2));
    });

    testWidgets('a block the role cannot read is Not reported, never zero', (t) async {
      await showRst(t, rpc: FakeRst((_) => ok(dash(noKitchen: true, noStock: true))));
      expect(find.text('—'), findsOneWidget); // KOT count
      expect(find.text('Not reported: your role cannot see the kitchen display.'), findsOneWidget);
      expect(find.text('20 low stock'), findsNothing);
      expect(find.text('Fresh Paneer (Block)'), findsNothing);
      expect(find.textContaining('Not reported'), findsNWidgets(6)); // KOT label, kitchen chip + note, ingredients chip, complaints, reviews
    });

    testWidgets('an older server without the 0570 figures says Not reported for them', (t) async {
      await showRst(t, rpc: FakeRst((_) => ok(dash(old: true))));
      expect(find.text('1 new'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('rst-orders')), matching: find.text('Not reported')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('rst-today-so-far')), matching: find.text('Not reported')), findsOneWidget);
      expect(find.text('No earlier data'), findsNWidgets(3));
    });

    testWidgets('the header outlet switcher asks again with the chosen outlet', (t) async {
      final r = await showRst(t, rpc: FakeRst((b) => ok(dash(loc: b['location_id'] as String? ?? 'l1'))));
      OutletScope.selected.value = 'l2';
      await t.pumpAndSettle();
      expect(r.calls.last.$2['location_id'], 'l2');
    });

    testWidgets('a server error shows its message and Try again asks again', (t) async {
      var fail = true;
      final r = await showRst(t, rpc: FakeRst((_) => fail ? http.Response(jsonEncode({'detail': 'Your role cannot see the restaurant dashboard.'}), 403, headers: _json) : ok(dash())));
      expect(find.text('Your role cannot see the restaurant dashboard.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(r.calls, hasLength(2));
      expect(find.text('Restaurant Dashboard'), findsOneWidget);
    });

    testWidgets('kitchen display and quick links: honest toast until plugged in, then they open', (t) async {
      await showRst(t);
      await t.ensureVisible(find.text('Open kitchen display ›'));
      await t.tap(find.text('Open kitchen display ›'));
      await t.pumpAndSettle();
      expect(find.text('The kitchen display opens in a later release.'), findsOneWidget);
      var kitchen = 0, history = 0;
      HomeNav.kitchen = (_) => kitchen++;
      HomeNav.orderHistory = (_) => history++;
      await t.pumpAndSettle(const Duration(seconds: 4));
      await t.tap(find.text('Open kitchen display ›'));
      await t.ensureVisible(find.text('Order history'));
      await t.tap(find.text('Order history'));
      await t.pumpAndSettle();
      expect(kitchen, 1);
      expect(history, 1);
    });

    testWidgets('the bar is the restaurant bar with Home first', (t) async {
      await showRst(t);
      for (final l in ['Home', 'Menu', 'Bill', 'Orders', 'Stock']) {
        expect(find.byKey(ValueKey('tab-$l')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('tab-Money')), findsNothing);
    });
    testWidgets('menu opens the restaurant More page (Figma 45:7539); unbuilt links say Soon', (t) async {
      var history = 0;
      HomeNav.orderHistory = (_) => history++;
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restaurant-more')), findsOneWidget);
      for (final l in ['Outlet timings', 'Manage staff', 'Order history', 'Payout', 'Notifications', 'Menu', 'Fees & charges']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('Soon'), findsWidgets);
      await t.tap(find.text('Order history'));
      await t.pumpAndSettle();
      expect(history, 1);
      expect(find.byKey(const ValueKey('restaurant-logout')), findsOneWidget);
    });

    testWidgets('Show all in Quick Links opens the restaurant More page', (t) async {
      await showRst(t);
      await t.ensureVisible(find.text('Show all'));
      await t.tap(find.text('Show all'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restaurant-more')), findsOneWidget);
    });

    testWidgets('golden: My Feed at phone width', (t) async {
      await showRst(t);
      t.view.physicalSize = const Size(1170, 7400);
      t.view.devicePixelRatio = 3;
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/restaurant_dashboard_feed.png'));
    }, tags: ['golden']);
  });
}
