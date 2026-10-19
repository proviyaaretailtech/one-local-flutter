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

Map<String, dynamic> dash({bool noKitchen = false, bool noStock = false, String loc = 'l1'}) => {
      'business': 'Satya Kitchen',
      'location': {'id': loc, 'name': loc == 'l1' ? 'Banjara Hills' : 'Jubilee Hills'},
      'outlets': [
        {'id': 'l1', 'name': 'Banjara Hills'},
        {'id': 'l2', 'name': 'Jubilee Hills'},
      ],
      'date_label': 'Sunday, 18 October 2026',
      'orders': {'live': 4, 'today': 19},
      'kot': noKitchen ? null : {'new': 2, 'in_progress': 3, 'ready': 1, 'served': 9, 'delayed': 1},
      'tables': {'all': 10, 'available': 6, 'occupied': 3, 'reserved': 1, 'cleaning': 0},
      'ingredients_low': noStock ? null : {'low': 3, 'critical': 17},
      'sales': {'today': 7402, 'gross': 7402, 'refunds': 0, 'paid_bills': 18},
      'onelocal': {'scope': 'business', 'today': 5, 'open': 2, 'sales_today': 1450},
      'last7': [
        for (var i = 0; i < 7; i++) {'date': '2026-10-${12 + i}', 'label': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i], 'sales': i == 6 ? 7402 : 0, 'orders': i == 6 ? 18 : 0},
      ],
      'not_reported': ['complaints', 'reviews'],
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
    testWidgets('draws the server figures, not the store cards', (t) async {
      final r = await showRst(t);
      // the header's default is "All outlets": the server sums the outlets (0524)
      expect(r.calls.where((c) => c.$1 == 'rst_dashboard_scope'), hasLength(1));
      expect(r.calls.first.$2['location_id'], 'all');
      for (final text in ['ORDERS LIVE', '4', '19 today', 'KOT PENDING', '5', '1 delayed', 'SALES TODAY', '₹7,402', '18 bills paid', 'Banjara Hills', 'Kitchen status', 'New', 'Cooking', 'Ready',
        'Open kitchen display', 'Tables', 'Available', 'Occupied', 'Reserved', 'Cleaning', '10 tables', 'Ingredients low', '17 critical · 3 low', 'ONELOCAL ORDERS', '2 open · 5 today',
        'Last 7 days', 'Sales analytics', 'Quick links', 'Order history', 'Complaints', 'Reviews', 'Settings', 'Outlet info', 'Show all']) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      expect(find.text('Stock health'), findsNothing);
      expect(find.text('Active orders'), findsNothing);
      expect(find.byKey(const ValueKey('bar-2026-10-18')), findsOneWidget);
    });

    testWidgets('complaints and reviews say Not reported, they carry no invented count', (t) async {
      await showRst(t);
      expect(find.text('Not reported'), findsNWidgets(2));
    });

    testWidgets('a block the role cannot read is Not reported, never zero', (t) async {
      await showRst(t, rpc: FakeRst((_) => ok(dash(noKitchen: true, noStock: true))));
      expect(find.text('KOT PENDING'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('Not reported'), findsNWidgets(6)); // KOT tile, kitchen tag, ingredients, complaints, reviews, + kitchen note
      expect(find.text('Not reported: your role cannot see the kitchen display.'), findsOneWidget);
      expect(find.text('17 critical · 3 low'), findsNothing);
    });

    testWidgets('the outlet filter asks again with the chosen outlet', (t) async {
      final r = await showRst(t, rpc: FakeRst((b) => ok(dash(loc: b['location_id'] as String? ?? 'l1'))));
      await t.tap(find.byKey(const ValueKey('outlet-filter')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-l2')));
      await t.pumpAndSettle();
      expect(r.calls.last.$2['location_id'], 'l2');
      expect(find.textContaining('Jubilee Hills'), findsWidgets);
    });

    testWidgets('a server error shows its message and Try again asks again', (t) async {
      var fail = true;
      final r = await showRst(t, rpc: FakeRst((_) => fail ? http.Response(jsonEncode({'detail': 'Your role cannot see the restaurant dashboard.'}), 403, headers: _json) : ok(dash())));
      expect(find.text('Your role cannot see the restaurant dashboard.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(r.calls, hasLength(2));
      expect(find.text('KOT PENDING'), findsOneWidget);
    });

    testWidgets('kitchen display and quick links: honest toast until plugged in, then they open', (t) async {
      await showRst(t);
      await t.ensureVisible(find.text('Open kitchen display'));
      await t.tap(find.text('Open kitchen display'));
      await t.pumpAndSettle();
      expect(find.text('The kitchen display opens in a later release.'), findsOneWidget);
      var kitchen = 0, history = 0;
      HomeNav.kitchen = (_) => kitchen++;
      HomeNav.orderHistory = (_) => history++;
      await t.pumpAndSettle(const Duration(seconds: 4));
      await t.tap(find.text('Open kitchen display'));
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
      var history = 0, kitchen = 0;
      HomeNav.orderHistory = (_) => history++;
      HomeNav.kitchen = (_) => kitchen++;
      await showRst(t);
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restaurant-more')), findsOneWidget);
      for (final l in ['Outlet timings', 'Manage staff', 'Order history', 'Payout', 'Notifications', 'Menu', 'Fees & charges']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('Soon'), findsWidgets);
      expect(find.text('Share feedback'), findsNothing);
      await t.tap(find.text('Kitchen display').last);
      await t.pumpAndSettle();
      expect(kitchen, 1);
      await t.tap(find.text('Order history'));
      await t.pumpAndSettle();
      expect(history, 1);
      expect(find.byKey(const ValueKey('restaurant-logout')), findsOneWidget);
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
  });
}
