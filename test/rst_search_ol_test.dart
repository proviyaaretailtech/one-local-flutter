// Search the app and Ol for a restaurant (founder, 3 Nov 2026: "Search the app and Ol show store actions to a restaurant. Searching
// 'barcode' offered Barcodes, Quick add product and Shelf labels. Devices in search opens the store's device page, and Money opens the
// store's money page. Train Ol for restaurant").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/assistant/ol_ask.dart';
import 'package:vinii_pos/home/app_actions.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/settings/rst_devices_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

class _Shell implements TabShell {
  _Shell(this.kind);
  @override
  String kind;
  @override
  void setKind(String k) => kind = k;
  @override
  bool show(String label) => false;
}

/// Plugs the hooks the lists use with a recorder: each records which hook opened.
final opened = <String>[];
void plugHooks() {
  opened.clear();
  HomeRoute rec(String name) => (_) => opened.add(name);
  HomeNav.home = rec('home');
  HomeNav.tables = rec('tables');
  HomeNav.bill = rec('bill (the store till)');
  HomeNav.menu = rec('menu');
  HomeNav.orders = rec('orders');
  HomeNav.orderHistory = rec('orderHistory');
  HomeNav.money = rec('money');
  HomeNav.moneyScreen = (_, s) => opened.add('moneyScreen $s');
  HomeNav.barcodes = rec('barcodes');
  HomeNav.quickAdd = rec('quickAdd');
  HomeNav.stockPage = (_, p, {itemId}) => opened.add('stockPage $p');
  HomeNav.billPage = (_, p) => opened.add('billPage $p');
  HomeNav.inventory = (_, p) async {
    opened.add('inventory $p');
    return false;
  };
  HomeNav.settings = rec('settings');
  HomeNav.team = rec('team');
  HomeNav.kitchenSetup = rec('kitchenSetup');
  HomeNav.kitchenDisplay = rec('kitchenDisplay');
  HomeNav.kotView = rec('kotView');
}

Future<List<AppAction>> actionsIn(WidgetTester t) async {
  late List<AppAction> all;
  ignoreOverflow();
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: Builder(builder: (c) {
    all = appActions(c);
    return const Scaffold(body: SizedBox());
  })));
  return all;
}

List<String> titles(List<AppAction> all, String q) => [for (final a in searchActions(all, q)) a.title];

void main() {
  tearDown(() => HomeNav.shell = null);

  testWidgets('a restaurant\'s search: no store pages; "barcode" finds the ingredients (they have barcodes), never Barcodes, Quick add or Shelf labels', (t) async {
    HomeNav.shell = _Shell('restaurant');
    plugHooks();
    final all = await actionsIn(t);
    final names = all.map((a) => a.title).toSet();
    for (final store in ['Barcodes', 'Quick add product', 'Shelf labels', 'Putaway', 'Open carts', 'Cash shift', 'Cashbook', 'Payments', 'Media manager', 'Store page']) {
      expect(names, isNot(contains(store)), reason: store);
    }
    expect(titles(all, 'barcode'), ['Ingredients']);
    for (final restaurant in ['Bill', 'Menu', 'Reservations', 'Dining areas', 'Day end', 'Leakage audit', 'Kitchen setup', 'Devices', 'Approvals', 'Recipe']) {
      expect(names, contains(restaurant), reason: restaurant);
    }
  });

  testWidgets('a restaurant\'s search opens its own pages: Money and Day end the restaurant Money, Bill the floor, Devices its printers', (t) async {
    HomeNav.shell = _Shell('restaurant');
    plugHooks();
    final all = await actionsIn(t);
    AppAction first(String q) => searchActions(all, q).first;
    first('money').open();
    first('day end').open();
    first('bill').open();
    first('recipe').open();
    expect(opened, ['money', 'money', 'tables', 'inventory recipes'], reason: 'never the store Money screens or the store till');
    expect(titles(all, 'cashbook'), isEmpty);
    all.firstWhere((a) => a.title == 'Devices').open();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(RstDevicesScreen, skipOffstage: false), findsOneWidget, reason: 'the restaurant devices page, not the store\'s device manager');
  });

  testWidgets('words restaurant staff use find the right page', (t) async {
    HomeNav.shell = _Shell('restaurant');
    plugHooks();
    final all = await actionsIn(t);
    expect(titles(all, 'kot').first, 'KOT view');
    expect(titles(all, 'booking'), contains('Reservations'));
    expect(titles(all, 'swiggy'), contains('Orders'));
    expect(titles(all, 'leakage'), contains('Leakage audit'));
    expect(titles(all, 'close day'), contains('Day end'));
    expect(titles(all, 'udhar'), contains('Dues'));
  });

  testWidgets('a store keeps its own list', (t) async {
    HomeNav.shell = _Shell('store');
    plugHooks();
    final all = await actionsIn(t);
    expect(titles(all, 'barcode'), containsAll(['Barcodes', 'Quick add product', 'Shelf labels']));
    expect(all.map((a) => a.title), isNot(contains('Reservations')));
  });

  group('Ol, trained for the restaurant', () {
    const g = OlGuide();
    test('the newer jobs are answered in the restaurant\'s words', () {
      expect(g.answer('how do I end the day').text, 'To end the day:');
      expect(g.answer('count cash drawer at night').text, 'To end the day:');
      expect(g.answer('give 10% discount').text, 'To give a discount:');
      expect(g.answer('table booking for 4').text, 'Reservations are in the side menu:');
      expect(g.answer('where do I type the upi reference').text, startsWith('A card or UPI payment always keeps its reference'));
      expect(g.answer('takeaway payment').text, 'To take payment for a takeaway or a phone delivery:');
      expect(g.answer('accept swiggy order').text, startsWith('Swiggy, Zomato and OneLocal orders'));
      expect(g.answer('what is revenue leakage').text, startsWith('Revenue leakage is on Home'));
      expect(g.answer('add a kot printer').text, 'Printers and kitchen stations are in Settings:');
      expect(g.answer('cancel a dish').text, 'To cancel a dish, refund or void a bill:');
      expect(g.answer('split equally between guests').steps.join(' '), contains('By dish'));
      expect(g.answer('add dining area rooftop').text, 'Tables are managed from Bill:');
    });
    test('the quick questions lead to answers, never to "not sure"', () {
      for (final tab in ['Home', 'Menu', 'Bill', 'Orders']) {
        for (final q in g.quickFor(tab)) {
          expect(g.answer(q).text, isNot(OlGuide.notSure), reason: '$tab: $q');
        }
      }
    });
  });
}
