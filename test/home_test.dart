import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_api.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
import 'package:vinii_pos/home/home_widgets.dart';
import 'package:vinii_pos/home/hub_screen.dart';

import 'helpers.dart';

/// `GET /api/partner/home` as the server answers it (shape from server/partner-home.ts).
Map<String, dynamic> summaryJson({
  String kind = 'store',
  bool? open = true,
  int orders = 53,
  num total = 21469,
  bool stockTracked = true,
  List<Map<String, dynamic>>? stock,
  List<Map<String, dynamic>>? active,
  Map<String, dynamic>? catalogue,
  Map<String, dynamic>? insights,
  List<Map<String, dynamic>>? outlets,
}) =>
    {
      'person': {'name': 'Riya Sharma', 'role': 'org_owner'},
      'outlet': {'id': 'l1', 'name': 'Latur Main Branch', 'organization': 'Sharma Store', 'kind': kind, 'is_open': open, 'last_sync_at': '2026-10-05T10:28:00Z'},
      'outlets': outlets ?? [{'id': 'l1', 'name': 'Latur Main Branch'}],
      'date': '2026-10-05',
      'timezone': 'Asia/Kolkata',
      'as_of': '2026-10-05T10:30:00Z',
      'sales': {'total': total, 'orders': orders, 'settled': 25, 'pax': 57, 'units': orders == 0 ? 0 : 140, 'active': 8},
      'catalogue': catalogue ?? {'items': 120, 'missing_descriptions': 77, 'missing_photos': 18, 'missing_recipes': kind == 'restaurant' ? 6 : null},
      'active_orders': active ??
          [
            {'id': 'o1', 'number': '2051', 'items': 3, 'total': 340, 'fulfilment': 'pickup', 'status': 'preparing', 'eta_minutes': null},
            {'id': 'o2', 'number': '2050', 'items': 7, 'total': 820, 'fulfilment': 'delivery', 'status': 'out_for_delivery', 'eta_minutes': 12},
            {'id': 'o3', 'number': '2049', 'items': 2, 'total': 156, 'fulfilment': 'pickup', 'status': 'new', 'eta_minutes': null},
          ],
      'stock_tracked': stockTracked,
      'stock_health': stock ??
          [
            {'name': 'Amul Gold / Taaza 1L', 'quantity': 0, 'unit': 'L', 'level': 'out'},
            {'name': 'Bacon Chicken Pkt', 'quantity': 2, 'unit': 'pkt', 'level': 'low'},
          ],
      'stock_low_count': stock?.length ?? 2,
      'top_items': orders == 0 ? <Map<String, dynamic>>[] : [
        {'name': 'Cold Coffee', 'qty': 14, 'revenue': 1620},
        {'name': 'Peri Peri Fries With Cheese', 'qty': 9, 'revenue': 1631},
      ],
      'insights': insights ?? {'expenses': null, 'kot_not_billed': 1, 'grn': {'bills': 3, 'amount': 25000}, 'price_trend': null},
    };

Map<String, dynamic> feedJson({bool compare = true, int days = 7, List<Map<String, dynamic>>? outlets}) => {
      'outlets': outlets ?? [for (var i = 1; i <= 5; i++) {'id': 'l$i', 'name': 'Outlet $i'}],
      'scope': 'All outlets (5)',
      'days': days,
      'date': '2026-10-05',
      'as_of': '2026-10-05T10:30:00Z',
      'today': {'sales': 48920, 'orders': 127, 'is_open': true},
      'period': {'net_sales': 342800, 'orders': 1300, 'orders_completed': 1248, 'aov': 274},
      'previous': compare ? {'net_sales': 306071, 'orders': 1200, 'orders_completed': 1151, 'aov': 277.33} : null,
      'daily': [
        for (var i = 0; i < days; i++) {'date': '2026-10-${(i + 5 - days + 1).clamp(1, 31).toString().padLeft(2, '0')}', 'sales': [20000, 36000, 31000, 54000, 39000, 40000, 52000][i % 7]},
      ],
    };

class FakeHome extends HomeApi {
  FakeHome({Map<String, dynamic>? summary, this.failWith}) : _summary = summary ?? summaryJson();
  Map<String, dynamic> _summary;
  Object? failWith;
  final calls = <String>[];

  set summaryBody(Map<String, dynamic> v) => _summary = v;

  @override
  Future<HomeSummary> summary({String? location}) async {
    calls.add('summary ${location ?? 'all'}');
    if (failWith != null) throw failWith!;
    return HomeSummary(_summary);
  }

  @override
  Future<HubFeed> feed({int days = 7, bool compare = true, String? location}) async {
    calls.add('feed $days ${compare ? 'compare' : 'plain'} ${location ?? 'all'}');
    if (failWith != null) throw failWith!;
    return HubFeed(feedJson(compare: compare, days: days));
  }
}

final _clock = DateTime.utc(2026, 10, 5, 10, 30);

/// The dashboard is taller than a phone, and lists build lazily, so tests use a tall view. A fresh key per call
/// makes a second `show` in the same test start a new screen instead of reusing the first one's state.
Future<void> showTall(WidgetTester t, Widget screen) async {
  await show(t, KeyedSubtree(key: UniqueKey(), child: screen));
  t.view.physicalSize = const Size(780, 5200);
  await t.pumpAndSettle();
}

Future<FakeHome> showHome(WidgetTester t, {Map<String, dynamic>? summary}) async {
  final api = FakeHome(summary: summary);
  await showTall(t, ControlCentreScreen(api: api, now: () => _clock));
  return api;
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text).first);
  await t.tap(find.text(text).first);
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    HomeNav.reset();
    OutletScope.reset(); // the header's outlet switcher is app-wide
  });

  group('formatting', () {
    test('rupees use Indian grouping and keep paise only when present', () {
      expect(rupees(342800), '₹3,42,800');
      expect(rupees(21469), '₹21,469');
      expect(rupees(156), '₹156');
      expect(rupees(270.44), '₹270.44');
      expect(rupees(12345678), '₹1,23,45,678');
      expect(count(1248), '1,248');
    });
    test('dates, initials, sync age', () {
      expect(dayLabel(DateTime(2026, 10, 5)), '5 OCT');
      expect(dayLabel(DateTime(2026, 10, 5), caps: false), '5 Oct');
      expect(initials('Riya Sharma'), 'RS');
      expect(initials('riya'), 'R');
      expect(initials(''), '?');
      expect(ago(DateTime(2026, 1, 1, 10, 28), DateTime(2026, 1, 1, 10, 30)), '2 min ago');
      expect(ago(DateTime(2026, 1, 1, 10, 30), DateTime(2026, 1, 1, 10, 30)), 'just now');
    });
    test('percent change needs something to compare with', () {
      expect(percentChange(342800, 306071)!.round(), 12);
      expect(percentChange(10, 0), isNull);
      expect(percentChange(10, null), isNull);
    });
    test('chart axis rounds the peak up to a readable step', () {
      expect(SalesBars.axisTop(54000), 60000);
      expect(SalesBars.axisTop(1820), 2000);
      expect(SalesBars.axisTop(0), 0);
      expect(SalesBars.short(60000), '₹60k');
      expect(SalesBars.short(30000), '₹30k');
    });
  });

  group('HomeApi', () {
    const base = 'http://api.test';
    test('summary sends the session token and the chosen outlet', () async {
      late http.Request seen;
      final api = HomeApi(
        client: MockClient((r) async {
          seen = r;
          return http.Response(jsonEncode(summaryJson()), 200);
        }),
        baseUrl: '$base/',
        accessToken: () => 'tok',
      );
      final s = await api.summary(location: 'l1');
      expect(seen.url.toString(), '$base/api/partner/home?location=l1');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(s.outletName, 'Latur Main Branch');
      expect(s.salesTotal, 21469);
      expect(s.activeOrders.length, 3);
      expect(s.expenses, isNull);
      expect(s.grnBills, 3);
    });
    test('feed sends days and compare', () async {
      late http.Request seen;
      final api = HomeApi(
        client: MockClient((r) async {
          seen = r;
          return http.Response(jsonEncode(feedJson()), 200);
        }),
        baseUrl: base,
        accessToken: () => 'tok',
      );
      final f = await api.feed(days: 30, compare: false);
      expect(seen.url.path, '/api/partner/home/feed');
      expect(seen.url.queryParameters, {'days': '30', 'compare': '0'});
      expect(f.netSales, 342800);
    });
    test('server refusal surfaces its message; no session never calls the server', () async {
      final refusing = HomeApi(client: MockClient((_) async => http.Response(jsonEncode({'detail': 'Outlet not found.'}), 404)), baseUrl: base, accessToken: () => 't');
      await expectLater(refusing.summary(location: 'x'), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 404).having((e) => e.message, 'message', 'Outlet not found.')));
      var called = false;
      final none = HomeApi(
          client: MockClient((_) async {
            called = true;
            return http.Response('{}', 200);
          }),
          baseUrl: base,
          accessToken: () => null);
      await expectLater(none.summary(), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 401)));
      expect(called, isFalse);
    });
  });

  group('Control centre', () {
    testWidgets('header band shows the server figures', (t) async {
      await showHome(t);
      expect(find.text('OneLocal'), findsOneWidget);
      expect(find.text('SHOWING DATA FOR'), findsOneWidget, reason: 'the outlet switcher header (founder, 20 Oct)');
      expect(find.text('Store Open'), findsOneWidget);
      expect(find.text('Latur Main Branch · Synced 2 min ago'), findsWidgets);
      expect(find.text('SALES · 5 OCT'), findsOneWidget);
      expect(find.text('₹21,469'), findsWidgets);
      expect(find.text('53'), findsOneWidget);
      expect(find.text('8 active now'), findsOneWidget);
      expect(find.text('140'), findsOneWidget);
      expect(find.text('25 bills settled · 57 pax · 8 open'), findsOneWidget);
    });

    testWidgets('no bills yet: items tile says Not reported, open status unknown says so', (t) async {
      await showHome(t, summary: summaryJson(orders: 0, total: 0, open: null));
      expect(find.text('Not reported'), findsOneWidget);
      expect(find.text('Status not set'), findsOneWidget);
      expect(find.text('Nothing sold yet today.'), findsOneWidget);
    });

    testWidgets('closed store says Store Closed', (t) async {
      await showHome(t, summary: summaryJson(open: false));
      expect(find.text('Store Closed'), findsOneWidget);
    });

    testWidgets('item data gaps: the store card hides recipes, none means no card (a restaurant has its own dashboard)', (t) async {
      await showHome(t);
      expect(find.text('Item data needs attention'), findsOneWidget);
      expect(find.text('77 items'), findsOneWidget);
      expect(find.text('18 items'), findsOneWidget);
      expect(find.text('Missing recipes'), findsNothing);

      await showHome(t, summary: summaryJson(catalogue: {'items': 10, 'missing_descriptions': 0, 'missing_photos': 0, 'missing_recipes': null}));
      expect(find.text('Item data needs attention'), findsNothing);
    });

    testWidgets('active orders: number, status, items, total, fulfilment, ETA', (t) async {
      await showHome(t);
      expect(find.text('3 active'), findsNothing);
      expect(find.text('8 active'), findsOneWidget);
      expect(find.text('Order #2050'), findsOneWidget);
      expect(find.text('Out for delivery'), findsOneWidget);
      expect(find.text('7 items · ₹820 · Delivery · ETA 12 min'), findsOneWidget);
      expect(find.text('Preparing'), findsOneWidget);
      expect(find.text('3 items · ₹340 · Pickup'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
    });

    testWidgets('no open orders shows an empty note', (t) async {
      await showHome(t, summary: summaryJson(active: []));
      expect(find.text('No open orders right now.'), findsOneWidget);
    });

    testWidgets('stock: out and low rows with restock; untracked and all-fine states have no button', (t) async {
      await showHome(t);
      expect(find.text('Amul Gold / Taaza 1L'), findsOneWidget);
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('2 pkt left'), findsOneWidget);
      expect(find.text('Restock critical items'), findsOneWidget);

      await showHome(t, summary: summaryJson(stockTracked: false, stock: []));
      expect(find.textContaining('Stock is not tracked for this outlet yet.'), findsOneWidget);
      expect(find.text('Restock critical items'), findsNothing);

      await showHome(t, summary: summaryJson(stock: []));
      expect(find.text('Everything is above its reorder level.'), findsOneWidget);
    });

    testWidgets('insights: no expense figure is invented; leakage, GRN, top items and the empty price trend', (t) async {
      await showHome(t);
      expect(find.text('Not tracked yet'), findsOneWidget);
      expect(find.text('1 KOT not billed'), findsOneWidget);
      expect(find.text('3 bills · ₹25,000'), findsOneWidget);
      expect(find.text('Cold Coffee · 14 sold'), findsOneWidget);
      expect(find.text('₹1,631'), findsOneWidget);
      expect(find.textContaining('no trend to show'), findsOneWidget);

      await showHome(t, summary: summaryJson(insights: {'expenses': 11005, 'kot_not_billed': 0, 'grn': {'bills': 0, 'amount': 0}, 'price_trend': null}));
      expect(find.text('₹11,005'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('None today'), findsOneWidget);
    });

    testWidgets('store tab bar (the restaurant bar is checked in restaurant_dashboard_test.dart)', (t) async {
      await showHome(t);
      for (final l in ['Home', 'Item', 'Bill', 'Online order', 'Stock']) {
        expect(find.byKey(ValueKey('tab-$l')), findsOneWidget);
      }
    });

    testWidgets('screens owned by other phases: honest toast until plugged in, then they open', (t) async {
      await showHome(t);
      await tapText(t, 'View all');
      expect(toast('Orders opens in a later release.'), findsOneWidget);

      var opened = 0;
      HomeNav.orders = (_) => opened++;
      await tapText(t, 'View all');
      await t.tap(find.byKey(const ValueKey('tab-Online order')));
      await t.pumpAndSettle();
      expect(opened, 2);

      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500)); // the previous toast animates out first
      expect(toast('Billing opens in a later release.'), findsOneWidget);
    });

    testWidgets('menu: store side nav (Figma 39:7416) with settings (section C hook) and sign out', (t) async {
      var setup = 0;
      HomeNav.setup = (_) => setup++;
      await showHome(t);
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('side-nav')), findsOneWidget);
      for (final l in ['Dashboard', 'Store POS', 'Catalogue', 'GRN', 'Stock management', 'All Orders', 'One Local Wallet', 'Money', 'Customer', 'Reports', 'Settings', 'Manage account', 'Sign out']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      // Screens that are not built say so instead of looking live.
      expect(find.text('Soon'), findsWidgets);
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      expect(setup, 1);
      expect(find.byKey(const ValueKey('side-nav')), findsNothing);

      final auth = FakeAuth();
      await showTall(t, ControlCentreScreen(api: FakeHome(), auth: auth, now: () => _clock));
      await t.tap(find.byKey(const ValueKey('home-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      expect(auth.calls, ['signOut']);
    });

    testWidgets('several outlets: the outlet line picks one, and the server is asked for it', (t) async {
      final api = await showHome(t, summary: summaryJson(outlets: [{'id': 'l1', 'name': 'Latur Main Branch'}, {'id': 'l2', 'name': 'Udgir Road'}]));
      await t.tap(find.text('Latur Main Branch · Synced 2 min ago').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Udgir Road'));
      await t.pumpAndSettle();
      expect(api.calls, ['summary all', 'summary l2']);
    });

    testWidgets('load failure: server message and retry', (t) async {
      final api = FakeHome(failWith: const PartnerApiException(403, 'No outlet is assigned to you yet.'));
      await showTall(t, ControlCentreScreen(api: api, now: () => _clock));
      expect(find.text('Your dashboard did not load.'), findsOneWidget);
      expect(find.text('No outlet is assigned to you yet.'), findsOneWidget);
      api.failWith = null;
      await tapText(t, 'Try again');
      expect(find.text('Store Open'), findsOneWidget);

      await showTall(t, ControlCentreScreen(api: FakeHome(failWith: Exception('socket')), now: () => _clock));
      expect(find.text('We could not reach OneLocal.'), findsOneWidget);
    });

    testWidgets('Business insights See all opens the sales feed', (t) async {
      final api = await showHome(t);
      await tapText(t, 'See all');
      expect(find.byType(HubScreen), findsOneWidget);
      expect(api.calls.last, 'feed 7 compare all');
    });
  });

  group('Sales feed (split-nav-hub)', () {
    Future<FakeHome> showHub(WidgetTester t) async {
      final api = FakeHome();
      await showTall(t, HubScreen(api: api));
      return api;
    }

    testWidgets('today, quick links and analytics from the server', (t) async {
      await showHub(t);
      expect(find.text('SHOWING DATA FOR'), findsOneWidget);
      expect(find.text('All outlets (5)'), findsOneWidget);
      expect(find.text('Today so far'), findsOneWidget);
      expect(find.text('₹48,920'), findsOneWidget);
      expect(find.text('127 orders received'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      for (final l in ['Order history', 'Complaints', 'Reviews', 'Settings', 'Outlet info', 'Show all']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.text('₹3,42,800'), findsOneWidget);
      expect(find.text('1,248'), findsOneWidget);
      expect(find.text('₹274'), findsOneWidget);
      expect(find.text('12%'), findsOneWidget);
      expect(find.text('8.4%'), findsOneWidget);
      expect(find.text('1.2%'), findsOneWidget);
      expect(find.byType(SalesBars), findsOneWidget);
      for (final l in ['Home', 'Menu', 'Bill', 'Orders', 'Stock']) {
        expect(find.byKey(ValueKey('tab-$l')), findsOneWidget);
      }
    });

    testWidgets('compare off asks without the previous period and hides the changes', (t) async {
      final api = await showHub(t);
      await t.tap(find.byKey(const ValueKey('hub-compare')));
      await t.pumpAndSettle();
      expect(api.calls.last, 'feed 7 plain all');
      expect(find.text('12%'), findsNothing);
    });

    testWidgets('period picker asks for 30 days', (t) async {
      final api = await showHub(t);
      await t.tap(find.byKey(const ValueKey('hub-range')));
      await t.pumpAndSettle();
      await t.tap(find.text('Last 30 days'));
      await t.pumpAndSettle();
      expect(api.calls.last, 'feed 30 compare all');
      expect(find.text('Last 30 days'), findsOneWidget);
    });

    testWidgets('outlet picker narrows the feed to one outlet', (t) async {
      final api = await showHub(t);
      await t.tap(find.byKey(const ValueKey('hub-outlet')));
      await t.pumpAndSettle();
      await t.tap(find.text('Outlet 3'));
      await t.pumpAndSettle();
      expect(api.calls.last, 'feed 7 compare l3');
    });

    testWidgets('Funnel and Service Quality have no source and say so', (t) async {
      await showHub(t);
      await tapText(t, 'Funnel');
      expect(find.textContaining('no funnel to show'), findsOneWidget);
      expect(find.text('Today so far'), findsNothing);
      await tapText(t, 'Service Quality');
      expect(find.textContaining('no service score to show'), findsOneWidget);
      await tapText(t, 'Sales');
      expect(find.text('Sales Analytics'), findsOneWidget);
      expect(find.text('Today so far'), findsNothing);
    });

    testWidgets('quick links use the hooks', (t) async {
      await showHub(t);
      var history = 0;
      HomeNav.orderHistory = (_) => history++;
      await tapText(t, 'Order history');
      expect(history, 1);
      await tapText(t, 'Complaints');
      expect(toast('Complaints opens in a later release.'), findsOneWidget);
    });
  });
}
