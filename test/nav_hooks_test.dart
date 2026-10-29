import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/orders/orders_board_screen.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/restaurant/restaurant_more_screen.dart';
import 'package:vinii_pos/restaurant/rst_plans_screen.dart';
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
      ('outletTimings', HomeNav.outletTimings), ('phoneNumbers', HomeNav.phoneNumbers), ('outletInfo', HomeNav.outletInfo),
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
    HomeNav.menuLink = rec('menuLink');
    HomeNav.purchases = rec('purchases');
    HomeNav.settings = rec('settings');
    HomeNav.setup = rec('setup');
    HomeNav.outletTimings = rec('outletTimings');
    HomeNav.phoneNumbers = rec('phoneNumbers');
    HomeNav.outletInfo = rec('outletInfo');
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

  group('restaurant side bar (the store design, the restaurant links)', () {
    Future<void> showMore(WidgetTester t, {VoidCallback? onReports}) async {
      ignoreOverflow();
      t.view.physicalSize = const Size(780, 3200);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: posTheme(),
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () => RestaurantMoreScreen.open(c, name: 'Nikhil Agarwal', email: 'n@example.com', outletName: 'Spice Route', onLogout: () {}, onReports: onReports),
                child: const Text('open'))),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('the store\'s ten options, in the store\'s order, and nothing else', (t) async {
      fakeHooks();
      await showMore(t, onReports: () {});
      const ten = ['All Orders', 'Money', 'Inventory', 'Customer', 'Business profile', 'Reports', 'Team', 'Settings', 'One Local Wallet', 'Help & support', 'Subscription plans'];
      final tops = [for (final l in ten) t.getRect(find.text(l)).top];
      expect(tops, [...tops]..sort(), reason: 'in this order');
      for (final gone in ['Kitchen display', 'Purchase orders', 'Table QR codes', 'Menu link', 'Payout', 'Notifications', 'Outlet timings', 'Feedback', 'Taxes']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
    });

    testWidgets('Inventory (0627) folds open after Money; each of its six pages opens through the Inventory hook', (t) async {
      fakeHooks();
      final opened = <String>[];
      HomeNav.inventory = (_, page) async {
        opened.add(page);
        return false;
      };
      addTearDown(() => HomeNav.inventory = null);
      const six = {
        'Purchase': 'purchase', 'Price control': 'prices', 'Closing stock check': 'closing',
        'Recipe': 'recipes', 'Ingredients': 'ingredients', 'Table management': 'tables',
      };
      await showMore(t, onReports: () {});
      for (final l in six.keys) {
        expect(find.text(l), findsNothing, reason: 'folded: $l');
      }
      await t.tap(find.byKey(const ValueKey('side-nav-group-Inventory')));
      await t.pumpAndSettle();
      final tops = [for (final l in six.keys) t.getRect(find.text(l)).top];
      expect(tops, [...tops]..sort(), reason: 'in this order');
      expect(t.getRect(find.text('Purchase')).top, greaterThan(t.getRect(find.text('Inventory')).top));
      expect(t.getRect(find.text('Table management')).top, lessThan(t.getRect(find.text('Page Manager')).top));
      expect(t.getRect(find.text('Page Manager')).top, lessThan(t.getRect(find.text('Customer')).top));
      await t.tap(find.byKey(const ValueKey('side-nav-group-Inventory')));
      await t.pumpAndSettle();
      expect(find.text('Purchase'), findsNothing, reason: 'folds shut again');
      // close the side bar, or the next "open" tap lands on one of its rows
      Navigator.of(t.element(find.byKey(const ValueKey('side-nav-group-Inventory')))).pop();
      await t.pumpAndSettle();
      for (final e in six.entries) {
        await showMore(t, onReports: () {});
        await t.tap(find.byKey(const ValueKey('side-nav-group-Inventory')));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text(e.key));
        await t.pumpAndSettle();
        await t.tap(find.text(e.key));
        await t.pumpAndSettle();
        expect(opened.last, e.value, reason: e.key);
      }
    });

    testWidgets('Back from an Inventory page (Closing stock) opens the side bar again with Inventory unfolded, not the dashboard', (t) async {
      fakeHooks();
      HomeNav.inventory = (c, page) async {
        await Navigator.of(c).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text('page $page')))));
        return true;
      };
      addTearDown(() => HomeNav.inventory = null);
      await showMore(t, onReports: () {});
      await t.tap(find.byKey(const ValueKey('side-nav-group-Inventory')));
      await t.pumpAndSettle();
      await t.tap(find.text('Closing stock check'));
      await t.pumpAndSettle();
      expect(find.text('page closing'), findsOneWidget);
      expect(find.byKey(const ValueKey('side-nav')), findsNothing, reason: 'the side bar closed for the page');
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('side-nav')), findsOneWidget, reason: 'back on the side bar');
      expect(find.text('Closing stock check'), findsOneWidget, reason: 'Inventory is unfolded');
    });

    testWidgets('Back from any page opened from the side bar (Money, Reports) opens the side bar again; a link that only switches a tab does not', (t) async {
      fakeHooks();
      HomeNav.money = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('Money page')))));
      HomeNav.team = (_) {}; // only switches a tab: no page on top
      addTearDown(() {
        HomeNav.money = null;
        HomeNav.team = null;
      });
      await showMore(t, onReports: () {});
      await t.tap(find.text('Money'));
      await t.pumpAndSettle();
      expect(find.text('Money page'), findsOneWidget);
      expect(find.byKey(const ValueKey('side-nav')), findsNothing);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('side-nav')), findsOneWidget, reason: 'back on the side bar');
      expect(find.text('Closing stock check'), findsNothing, reason: 'Inventory folded: it was not opened from there');

      await t.tap(find.text('Team'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('side-nav')), findsNothing, reason: 'nothing to come back from');
    });

    testWidgets('Back from Reports opens the side bar again', (t) async {
      fakeHooks();
      ignoreOverflow();
      t.view.physicalSize = const Size(780, 3200);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: posTheme(),
        home: Builder(
            builder: (c) => TextButton(
                onPressed: () => RestaurantMoreScreen.open(c, name: 'N', outletName: 'Spice Route', onLogout: () {},
                    onReports: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('Reports page')))))),
                child: const Text('open'))),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reports'));
      await t.pumpAndSettle();
      expect(find.text('Reports page'), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('side-nav')), findsOneWidget);
    });

    testWidgets('searching for an Inventory page opens its group', (t) async {
      fakeHooks();
      HomeNav.inventory = (_, _) async => false;
      addTearDown(() => HomeNav.inventory = null);
      await showMore(t, onReports: () {});
      await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'recipe');
      await t.pump();
      expect(find.text('Recipe'), findsOneWidget);
      expect(find.text('Money'), findsNothing);
    });

    testWidgets('each option with a built screen opens it; Reports opens the reports', (t) async {
      HomeNav.customers = null;
      HomeNav.wallet = null;
      const expected = {
        'All Orders': 'history',
        'Money': 'money',
        'Customer': 'customers',
        'Business profile': 'outletInfo',
        'Reports': 'reports',
        'Team': 'team',
        'Settings': 'settings',
        'One Local Wallet': 'wallet',
        'Help & support': 'support',
      };
      for (final e in expected.entries) {
        final opened = fakeHooks();
        HomeNav.customers = (_) => opened.add('customers');
        HomeNav.wallet = (_) => opened.add('wallet');
        await showMore(t, onReports: () => opened.add('reports'));
        await t.tap(find.text(e.key));
        await t.pump();
        expect(opened, [e.value], reason: e.key);
      }
      HomeNav.customers = null;
      HomeNav.wallet = null;
    });

    testWidgets('every option is live (no "Soon"); Subscription plans opens the plans page', (t) async {
      final opened = fakeHooks();
      HomeNav.customers = (_) => opened.add('customers');
      HomeNav.wallet = (_) => opened.add('wallet');
      await showMore(t, onReports: () {});
      expect(find.text('Soon'), findsNothing);
      await t.tap(find.text('Subscription plans'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(RstPlansScreen), findsOneWidget);
      HomeNav.customers = null;
      HomeNav.wallet = null;
    });
  });
}
