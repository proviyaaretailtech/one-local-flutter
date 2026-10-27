import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/orders/order_widgets.dart';
import 'package:vinii_pos/ui/ol_mascot.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> bar(WidgetTester t) async {
  t.view.physicalSize = const Size(780, 1600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: const SizedBox.expand(), bottomNavigationBar: PosBottomNav(onTap: (_) {}))));
}

void main() {
  testWidgets('Ol sits in the bottom bar\'s empty circle and says hello once; closing it is remembered', (t) async {
    SharedPreferences.setMockInitialValues({});
    olGreets = true;
    addTearDown(() => olGreets = false);
    await bar(t);
    expect(find.byType(OlMascot), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('ol-hello')), findsOneWidget);
    expect(find.textContaining("Hi, I'm Ol!"), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ol-hello-close')));
    await t.pump();
    expect(find.byKey(const ValueKey('ol-hello')), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool('ol_hello_seen'), isTrue);
    // another page's bar: no second hello
    await t.pumpWidget(const SizedBox());
    await bar(t);
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('ol-hello')), findsNothing);
  });

  testWidgets('tapping Ol opens the helper: common jobs, and what you type finds the screen for it', (t) async {
    await bar(t);
    await t.tap(find.byKey(const ValueKey('ol-mascot')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ol-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('ol-job-Receive goods')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ol-ask')), 'zzzz nothing');
    await t.pump();
    expect(find.textContaining("I can't do that yet"), findsOneWidget);
    // what Ol finds, Ol opens
    final opened = <String>[];
    HomeNav.stock = (_) => opened.add('stock');
    addTearDown(HomeNav.reset);
    await t.enterText(find.byKey(const ValueKey('ol-ask')), 'stock');
    await t.pump();
    expect(find.byWidgetPredicate((w) => w is ListTile), findsWidgets);
    await t.tap(find.byWidgetPredicate((w) => w is ListTile).first);
    await t.pumpAndSettle();
    expect(opened, isNotEmpty);
    expect(find.byKey(const ValueKey('ol-sheet')), findsNothing);
  });

  test('Ol keeps still under flutter test, so screens settle', () => expect(olAnimates, isFalse));
}
