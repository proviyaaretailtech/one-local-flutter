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
  FakeRst(this.answer, {this.others});
  final http.Response Function(Map<String, dynamic> body) answer;

  /// The Home's extra reads (rst_home_insights, rst_channel_orders), by function; without it they are not found (the cards stay out).
  final Map<String, Map<String, dynamic>>? others;
  final calls = <(String, Map<String, dynamic>)>[];
  late final api = RestaurantApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      final fn = r.url.pathSegments.last;
      if (fn == 'rst_home_insights' || fn == 'rst_channel_orders') {
        final o = others?[fn];
        return o == null ? http.Response(jsonEncode({'detail': 'not found'}), 404, headers: _json) : ok(o);
      }
      calls.add((fn, body));
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
        'My Feed', 'Sales', 'Restaurant Dashboard', 'Today · Restaurant operations', 'LIVE',
        // orders and KOTs
        'Live orders', '1 new', '3 in progress', 'Pending', '2 critical', 'Kitchen queue',
        // kitchen, tables, sales today
        'Tables', 'View tables ›', '10 total', '6 Available', '3 Occupied', '1 Reserved', '0 Cleaning',
        'Sales today', '₹7,402', '19 orders received',
        // ingredients: one quiet line each
        'Ingredients', 'View stock ›', '20 low stock', 'Fresh Paneer (Block)', '1.2 kg left', 'Fresh Cream', '2.8 L left',
      ]) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      // My Feed is today's operations only (founder, 29 Oct 2026): no repeats of the Sales tab, Delivery today or the side bar
      for (final gone in ['OneLocal orders', 'Today so far', 'Quick Links', 'Sales Analytics', 'Show all', 'Complaints', 'CRITICAL']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      // Sales: the period, the compare switch, the analytics; the % change is the server's previous 7 days: 7402 vs 3701 = +100.0%, 18 vs 20 = -10.0%
      await t.tap(find.byKey(const ValueKey('rst-tab-Sales')));
      await t.pumpAndSettle();
      for (final text in ['Last 7 days', 'Compare with the 7 days before', 'Sales Analytics', 'Net sales', 'Orders delivered', 'Average order value', 'Get deeper insights →']) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      expect(find.descendant(of: find.byKey(const ValueKey('rst-net-sales')), matching: find.text('100.0%')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('rst-orders-delivered')), matching: find.text('10.0%')), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-2026-10-18')), findsOneWidget);
      expect(find.text('ORDERS LIVE'), findsNothing); // the old navy band is gone
      expect(find.text('Stock health'), findsNothing);
    });

    testWidgets('Compare off (on the Sales tab) hides the % change', (t) async {
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('rst-tab-Sales')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('rst-compare-label')));
      await t.tap(find.byKey(const ValueKey('rst-compare-label')));
      await t.pumpAndSettle();
      expect(find.text('100.0%'), findsNothing);
    });

    testWidgets('only My Feed and Sales: Funnel and Service Quality are gone; Sales shows real sales', (t) async {
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('rst-tab-Sales')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rst-analytics')), findsOneWidget);
      expect(find.byKey(const ValueKey('rst-sales-today')), findsOneWidget);
      expect(find.text('Kitchen status'), findsNothing);
      for (final tab in ['Funnel', 'Service Quality']) {
        expect(find.byKey(ValueKey('rst-tab-$tab')), findsNothing, reason: '$tab is off the Home for now');
      }
    });

    testWidgets('more on My Feed: delivery by source with logos, how orders were served, payments, top dishes, menu health', (t) async {
      final r = FakeRst((_) => ok(dash()), others: {
        'rst_channel_orders': {
          'channels': [
            {'key': 'onelocal', 'label': 'OneLocal', 'count': 4, 'new': 1, 'total': 1228},
            {'key': 'swiggy', 'label': 'Swiggy', 'count': 3, 'new': 1, 'total': 1161},
            {'key': 'zomato', 'label': 'Zomato', 'count': 3, 'new': 0, 'total': 1404},
            {'key': 'on_call', 'label': 'On call delivery', 'count': 2, 'new': 0, 'total': 884},
          ],
          'orders': [],
        },
        'rst_home_insights': {
          'mix': {'orders': 20, 'sales': 8746, 'avg_bill': 437.3, 'by': [
            {'key': 'dine_in', 'label': 'Dine in', 'orders': 8, 'sales': 4069},
            {'key': 'takeaway', 'label': 'Takeaway', 'orders': 0, 'sales': 0},
            {'key': 'delivery', 'label': 'Delivery', 'orders': 12, 'sales': 4677},
          ]},
          'payments': [{'method': 'cash', 'amount': 3452, 'count': 8}, {'method': 'card', 'amount': 617, 'count': 2}],
          'top': [{'name': 'Americano', 'qty': 15, 'sales': 1035}, {'name': 'Ice Mint Mocha', 'qty': 7, 'sales': 1323}],
          'menu': {'dishes': 11, 'low': [{'name': 'Cappuccino', 'can_make': 4}], 'out': 0, 'food_cost_avg': 35.8,
            'high_cost': [{'name': 'Americano', 'pct': 45.2}], 'no_recipe': 0, 'no_photo': 1, 'no_description': 0},
          'ready': 2,
        },
      });
      await showRst(t, rpc: r);
      for (final k in ['onelocal', 'swiggy', 'zomato', 'on_call']) {
        expect(find.descendant(of: find.byKey(ValueKey('rst-delivery-$k')), matching: find.byKey(ValueKey('channel-logo-$k'))), findsOneWidget, reason: k);
      }
      expect(find.text('20 orders today · average bill ₹437.30'), findsOneWidget);
      expect(find.text('8 · '), findsOneWidget);
      expect(find.byKey(const ValueKey('rst-pay-cash')), findsOneWidget);
      expect(find.text('Payments today'), findsOneWidget);
      expect(find.text('Top dishes today'), findsOneWidget);
      expect(find.text('15 sold · '), findsOneWidget);
      expect(find.text('Food cost 35.8%'), findsOneWidget);
      expect(find.text('45.2%'), findsOneWidget);
      expect(find.text('4 left'), findsOneWidget);
      expect(find.text('2 ready to serve'), findsOneWidget);
      expect(find.text('1 without a photo'), findsOneWidget);
    });

    testWidgets('a full answer leaves nothing Not reported on My Feed', (t) async {
      await showRst(t);
      expect(find.text('Not reported'), findsNothing);
    });

    testWidgets('a block the role cannot read is Not reported, never zero', (t) async {
      await showRst(t, rpc: FakeRst((_) => ok(dash(noKitchen: true, noStock: true))));
      expect(find.text('—'), findsOneWidget); // KOT count
      expect(find.text('20 low stock'), findsNothing);
      expect(find.text('Fresh Paneer (Block)'), findsNothing);
      expect(find.textContaining('Not reported'), findsNWidgets(2)); // KOT label, ingredients chip
    });

    testWidgets('an older server without the 0570 figures says Not reported for them', (t) async {
      await showRst(t, rpc: FakeRst((_) => ok(dash(old: true))));
      expect(find.text('1 new'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('rst-orders')), matching: find.text('Not reported')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rst-tab-Sales')));
      await t.pumpAndSettle();
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

    testWidgets('the KOTs card opens the kitchen display: an honest toast until plugged in, then it opens', (t) async {
      await showRst(t);
      expect(find.text('Kitchen status'), findsNothing, reason: 'the Kitchen status card is gone; the kitchen is in Orders');
      await t.ensureVisible(find.byKey(const ValueKey('rst-kots')));
      await t.tap(find.byKey(const ValueKey('rst-kots')));
      await t.pumpAndSettle();
      expect(find.text('The kitchen display opens in a later release.'), findsOneWidget);
      var kitchen = 0;
      HomeNav.kitchen = (_) => kitchen++;
      await t.pumpAndSettle(const Duration(seconds: 4));
      await t.tap(find.byKey(const ValueKey('rst-kots')));
      await t.pumpAndSettle();
      expect(kitchen, 1);
    });

    testWidgets('the bar is the restaurant bar with Home first', (t) async {
      await showRst(t);
      for (final l in ['Home', 'Menu', 'Bill', 'Orders']) {
        expect(find.byKey(ValueKey('tab-$l')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('tab-Money')), findsNothing);
      expect(find.byKey(const ValueKey('tab-Stock')), findsNothing, reason: 'Stock is off the restaurant bar for now');
    });
    testWidgets('menu opens the side bar with the store\'s ten options; search narrows them; Reports opens the reports', (t) async {
      var history = 0, team = 0;
      HomeNav.orderHistory = (_) => history++;
      HomeNav.team = (_) => team++;
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      final nav = find.byKey(const ValueKey('side-nav'));
      expect(nav, findsOneWidget);
      expect(t.getRect(nav).left, 0, reason: 'slides in from the left, like the store');
      for (final l in ['All Orders', 'Money', 'Customer', 'Business profile', 'Reports', 'Team', 'Settings', 'One Local Wallet', 'Help & support', 'Subscription plans', 'Sign out']) {
        expect(find.descendant(of: nav, matching: find.text(l)), findsOneWidget, reason: l);
      }
      expect(find.descendant(of: nav, matching: find.text('Kitchen display')), findsNothing, reason: 'the old restaurant links are gone');
      await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'team');
      await t.pump();
      expect(find.descendant(of: nav, matching: find.text('Team')), findsOneWidget);
      expect(find.descendant(of: nav, matching: find.text('Money')), findsNothing, reason: 'search narrows the rows');
      // a link closes the side bar, then opens its screen
      await t.tap(find.descendant(of: nav, matching: find.text('Team')));
      await t.pumpAndSettle();
      expect(team, 1);
      expect(find.byKey(const ValueKey('side-nav')), findsNothing);
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byKey(const ValueKey('side-nav')), matching: find.text('All Orders')));
      await t.pumpAndSettle();
      expect(history, 1);
    });
    testWidgets('Bill on a restaurant opens the tables floor, not the store cart', (t) async {
      var tables = 0, cart = 0;
      HomeNav.tables = (_) => tables++;
      HomeNav.bill = (_) => cart++;
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pumpAndSettle();
      expect(tables, 1);
      expect(cart, 0);
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
