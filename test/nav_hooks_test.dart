import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/orders/orders_board_screen.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/restaurant/restaurant_more_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// The ☰ store side nav and the restaurant More page open the screens of the merged sections (K money, L team, M storefront,
/// N notices, P settings and support) through their HomeNav hooks. An entry with no screen on this line keeps its "Soon" tag.
/// The "Soon" tag inside the tappable row or tile that carries [label].
Finder soonOn(String label) => find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first, matching: find.text('Soon'));

void main() {
  setUp(HomeNav.reset);
  tearDown(HomeNav.reset);

  group('order tab per kind of business', () {
    Future<void> root(WidgetTester t, String kind, String label) async {
      ignoreOverflow();
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: shellTabRoot(kind, label)!));
      await t.pumpAndSettle();
    }

    testWidgets("a store's Online order tab is Orders History (section E), not the restaurant board", (t) async {
      await root(t, 'store', 'Online order');
      expect(find.byType(OrdersHome), findsOneWidget);
      expect(find.byType(OrdersBoardScreen), findsNothing);
      expect(find.text('Dine In'), findsNothing);
      expect(find.text('Hold orders'), findsNothing);
    });

    testWidgets("a restaurant's Orders tab is the Live | Hold board", (t) async {
      await root(t, 'restaurant', 'Orders');
      expect(find.byType(OrdersBoardScreen), findsOneWidget);
    });
  });

  test('installRoutes plugs every hook the side nav and the More page use', () {
    installRoutes();
    for (final (name, hook) in [
      ('money', HomeNav.money), ('team', HomeNav.team), ('storefront', HomeNav.storefront), ('deliverySettings', HomeNav.deliverySettings),
      ('kitchen', HomeNav.kitchen), ('settings', HomeNav.settings), ('support', HomeNav.support), ('notifications', HomeNav.notifications),
      ('reviews', HomeNav.reviews), ('items', HomeNav.items), ('orderHistory', HomeNav.orderHistory), ('setup', HomeNav.setup),
    ]) {
      expect(hook, isNotNull, reason: name);
    }
    expect(HomeNav.moneyScreen, isNotNull);
    expect(identical(HomeNav.kitchen, HomeNav.kitchenDisplay), isTrue, reason: 'dashboard button and More tile open the same KDS');
  });

  /// Plugs a recording hook into every slot; [opened] collects what was opened.
  List<String> fakeHooks() {
    final opened = <String>[];
    HomeRoute rec(String name) => (_) => opened.add(name);
    HomeNav.money = rec('money');
    HomeNav.moneyScreen = (_, screen) => opened.add('money:$screen');
    HomeNav.team = rec('team');
    HomeNav.storefront = rec('storefront');
    HomeNav.deliverySettings = rec('delivery');
    HomeNav.kitchen = rec('kitchen');
    HomeNav.tableQr = rec('tableQr');
    HomeNav.settings = rec('settings');
    HomeNav.setup = rec('setup');
    HomeNav.support = rec('support');
    HomeNav.notifications = rec('notifications');
    HomeNav.reviews = rec('reviews');
    HomeNav.items = rec('items');
    HomeNav.orderHistory = rec('history');
    HomeNav.bill = rec('bill');
    HomeNav.grn = rec('grn');
    HomeNav.stock = rec('stock');
    return opened;
  }

  group('store side nav', () {
    Future<void> openSideNav(WidgetTester t) async {
      ignoreOverflow();
      t.view.physicalSize = const Size(780, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: posTheme(),
        home: Builder(builder: (c) => Scaffold(body: Center(child: TextButton(
          onPressed: () => showStoreSideNav(c, name: 'Asha Stores', onReports: () {}, onSignOut: () {}),
          child: const Text('open'),
        )))),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('Money, Team, OneLocal page, Settings and Help open their screens', (t) async {
      for (final (label, hook) in [('Money', 'money'), ('Team', 'team'), ('OneLocal page', 'storefront'), ('Settings', 'settings'), ('Help & support', 'support')]) {
        final opened = fakeHooks();
        await openSideNav(t);
        expect(soonOn(label), findsNothing, reason: label);
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        expect(opened, [hook], reason: label);
        expect(find.byKey(const ValueKey('side-nav')), findsNothing, reason: 'the panel closes first');
      }
    });

    testWidgets('One Local Wallet and Customer have no screen on this line: they keep "Soon" and open nothing', (t) async {
      final opened = fakeHooks();
      await openSideNav(t);
      expect(soonOn('One Local Wallet'), findsOneWidget);
      expect(soonOn('Customer'), findsOneWidget);
      expect(find.text('Soon'), findsNWidgets(2)); // wallet, customer
      expect(find.bySemanticsLabel('Manage account'), findsOneWidget); // the profile block now
      await t.tap(find.text('One Local Wallet'));
      await t.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.byKey(const ValueKey('side-nav')), findsOneWidget);
    });

    testWidgets('Settings falls back to workspace setup when the settings page is not plugged', (t) async {
      final opened = fakeHooks();
      HomeNav.settings = null;
      await openSideNav(t);
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      expect(opened, ['setup']);
    });
  });

  group('restaurant More page', () {
    Future<void> showMore(WidgetTester t) async {
      ignoreOverflow();
      t.view.physicalSize = const Size(780, 2400);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: RestaurantMoreScreen(outletName: 'Spice Route', onLogout: () {})));
      await t.pump();
    }

    testWidgets('every quick link with a built screen opens it; Money links open the named Money screen', (t) async {
      const expected = {
        'Manage staff': 'team',
        'OneLocal manager': 'storefront',
        'Delivery settings': 'delivery',
        'Kitchen display': 'kitchen',
        'Table QR codes': 'tableQr',
        'Payout': 'money:payouts',
        'Invoices': 'money:invoices',
        'Fees & charges': 'money:settlements',
        'Notifications': 'notifications',
        'Customer support': 'support',
        'Feedback': 'reviews',
        'Outlet timings': 'settings',
        'Phone numbers': 'settings',
        'Outlet info': 'setup',
        'Order history': 'history',
        'Menu': 'items',
      };
      for (final e in expected.entries) {
        final opened = fakeHooks();
        await showMore(t);
        await t.tap(find.text(e.key));
        await t.pump();
        expect(opened, [e.value], reason: e.key);
      }
    });

    testWidgets('only Taxes still says "Soon" (no tax screen yet) and opens nothing', (t) async {
      final opened = fakeHooks();
      await showMore(t);
      expect(find.text('Soon'), findsOneWidget);
      expect(soonOn('Taxes'), findsOneWidget);
      expect(soonOn('Payout'), findsNothing);
      await t.tap(find.text('Taxes'));
      await t.pump();
      expect(opened, isEmpty);
    });

    testWidgets('with no hooks plugged every link says "Soon"', (t) async {
      await showMore(t);
      expect(find.text('Soon'), findsNWidgets(17));
    });
  });
}
