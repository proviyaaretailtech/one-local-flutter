import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/app_actions.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// Every hook plugged in, each recording what it opened.
List<String> plugAll() {
  final opened = <String>[];
  HomeRoute rec(String id) => (_) => opened.add(id);
  HomeNav.home = rec('home');
  HomeNav.bill = rec('bill');
  HomeNav.items = rec('items');
  HomeNav.quickAdd = rec('quick-add');
  HomeNav.orders = rec('orders');
  HomeNav.orderHistory = rec('order-history');
  HomeNav.stock = rec('stock');
  HomeNav.grn = rec('purchase');
  HomeNav.money = rec('money');
  HomeNav.customers = rec('customers');
  HomeNav.team = rec('team');
  HomeNav.settings = rec('settings');
  HomeNav.deliverySettings = rec('delivery');
  HomeNav.storefront = rec('storefront');
  HomeNav.wallet = rec('wallet');
  HomeNav.notifications = rec('notifications');
  HomeNav.support = rec('support');
  HomeNav.account = rec('account');
  HomeNav.stockPage = (_, page, {itemId}) => opened.add('stock:$page');
  HomeNav.billPage = (_, page) => opened.add('bill:$page');
  HomeNav.moneyScreen = (_, screen) => opened.add('money:$screen');
  return opened;
}

Future<void> openMenu(WidgetTester t) async {
  t.view.physicalSize = const Size(780, 1700);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showStoreSideNav(c, name: 'Raj', onReports: () {}, onSignOut: () {}), child: const Text('menu')))),
  ));
  await t.tap(find.text('menu'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });
  tearDown(HomeNav.reset);

  testWidgets('the search sits at the top of the menu, above the list; typing shows matching actions in place of the list', (t) async {
    plugAll();
    await openMenu(t);
    final search = find.byKey(const ValueKey('side-nav-search'));
    expect(search, findsOneWidget);
    expect(t.getTopLeft(search).dy, lessThan(t.getTopLeft(find.text('All Orders')).dy));
    await t.enterText(search, 'supplier');
    await t.pump();
    expect(find.text('All Orders'), findsNothing); // the list gives way to the results
    expect(find.byKey(const ValueKey('side-nav-result-Purchase')), findsOneWidget);
    expect(find.text('Item → Purchase'), findsWidgets);
  });

  testWidgets('a result opens its screen (the menu closes first)', (t) async {
    final opened = plugAll();
    await openMenu(t);
    await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'adjust');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('side-nav-result-Adjust stock')));
    await t.pumpAndSettle();
    expect(opened, ['stock:adjust']);
    expect(find.byKey(const ValueKey('side-nav')), findsNothing);
  });

  testWidgets('words people use find actions deep in the app; Enter opens the first', (t) async {
    final opened = plugAll();
    await openMenu(t);
    await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'refund');
    await t.pump();
    expect(find.byKey(const ValueKey('side-nav-result-Returns & refunds')), findsOneWidget);
    expect(find.byKey(const ValueKey('side-nav-result-Refunds')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'delivery km');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(opened, ['delivery']);
  });

  testWidgets('no match says so; clearing brings the menu back', (t) async {
    plugAll();
    await openMenu(t);
    await t.enterText(find.byKey(const ValueKey('side-nav-search')), 'zzzz');
    await t.pump();
    expect(find.textContaining('Nothing matches'), findsOneWidget);
    await t.tap(find.byTooltip('Clear'));
    await t.pump();
    expect(find.text('All Orders'), findsOneWidget);
  });

  test('every store action is searchable by its own name; an unplugged screen is left out', () {
    plugAll();
    final all = appActions(_FakeContext(), onReports: () {});
    expect(all.length, greaterThan(40));
    for (final a in all) {
      expect(searchActions(all, a.title), contains(a), reason: a.title);
    }
    HomeNav.wallet = null;
    expect(appActions(_FakeContext()).map((a) => a.title), isNot(contains('OneLocal Wallet')));
    expect(searchActions(all, 'quick add').first.title, 'Quick add product');
    expect(searchActions(all, 'ginti').single.title, 'Count stock'); // a Hinglish word people use
  });
}

class _FakeContext extends Fake implements BuildContext {}
