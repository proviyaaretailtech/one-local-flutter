import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/service_nav.dart';
import 'package:vinii_pos/service/service_money.dart';

import 'helpers.dart';

// The Service POS frame (founder's sketch, 2 Nov 2026): the bottom bar's tabs and the side menu.
void main() {
  tearDown(HomeNav.reset);

  test('the service bar: Home · Catalogue · Bill (centre) · Bookings, then Ol (3 Nov 2026: Manage moved to the side menu)', () {
    expect(kServiceTabs.map((t) => t.label), ['Home', 'Catalogue', 'Bill', 'Bookings']);
    expect(kServiceTabs.where((t) => t.hero).map((t) => t.label), ['Bill']);
  });

  test('older service screens\' "go to" ids land on the new tabs', () {
    expect(serviceTabFor('home'), 'Home');
    expect(serviceTabFor('item'), 'Catalogue');
    expect(serviceTabFor('bill'), 'Bookings', reason: 'a service\'s old Bill tab was its calendar');
    expect(serviceTabFor('manage'), isNull, reason: 'Service management is in the side menu now');
    expect(serviceTabFor('stock'), isNull);
  });

  test('every tab has a first screen; anything else has none', () {
    const home = Text('home');
    for (final t in kServiceTabs) {
      expect(serviceTabRoot(t.label, home: home, onNavigate: (_) {}), isNotNull, reason: t.label);
    }
    expect(serviceTabRoot('Home', home: home, onNavigate: (_) {}), same(home));
    expect(serviceTabRoot('Item', home: home, onNavigate: (_) {}), isNull);
  });

  testWidgets('side menu: the service rows, the five added from the store, Sign out; each row opens its page', (t) async {
    final opened = <String>[];
    HomeNav.outletInfo = (_) => opened.add('company');
    HomeNav.team = (_) => opened.add('team');
    HomeNav.support = (_) => opened.add('support');
    HomeNav.customers = (_) => opened.add('customers');
    HomeNav.businessProfile = (_) => opened.add('page');
    HomeNav.settings = (_) => opened.add('settings');
    HomeNav.plans = (_) => opened.add('plans');
    var signedOut = false;
    await show(t, Builder(builder: (c) => TextButton(
        onPressed: () => showServiceSideNav(c, name: 'Priya Kulkarni', email: 'owner@test.local', onSignOut: () => signedOut = true),
        child: const Text('menu'))));
    await t.tap(find.text('menu'));
    await t.pumpAndSettle();
    for (final s in ['Priya Kulkarni', 'Service management', 'All bookings', 'Customers', 'Money', 'Reports', 'Media', 'Page Manager', 'Company details', 'Team management', 'Settings', 'Subscription plans', 'Support', 'Sign out']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    for (final s in ['Barcodes', 'Media manager', 'One Local Wallet']) {
      expect(find.text(s), findsNothing, reason: '$s is a store row');
    }
    await t.tap(find.text('Team management'));
    await t.pumpAndSettle();
    expect(opened, ['team']);
    for (final (row, id) in [('Customers', 'customers'), ('Page Manager', 'page'), ('Settings', 'settings'), ('Subscription plans', 'plans')]) {
      await t.tap(find.text('menu'));
      await t.pumpAndSettle();
      await t.tap(find.text(row));
      await t.pumpAndSettle();
      expect(opened.last, id, reason: row);
    }
    await t.tap(find.text('menu'));
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    // sign out asks first (2 Nov 2026, from main): Yes signs out
    await t.tap(find.byKey(const ValueKey('signout-yes')));
    await t.pumpAndSettle();
    expect(signedOut, isTrue);
    // Money (founder, 2 Nov 2026): the service's own Money page
    await t.tap(find.text('menu'));
    await t.pumpAndSettle();
    await t.tap(find.text('Money'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(ServiceMoneyScreen), findsOneWidget);
  });
}
