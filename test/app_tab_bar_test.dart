import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/home_widgets.dart';
import 'package:vinii_pos/ui/ol_mascot.dart';

// The store and restaurant bars move like the service bar (founder, 6 Nov 2026), with their own names and icons, unchanged.

Widget _bar(List<BarTab> tabs, String? current, ValueChanged<String> onTap, {Widget? trailing}) => MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: FloatingTabBar(tabs: tabs, onTap: onTap, current: current, trailing: trailing),
      ),
    );

void main() {
  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('store: the same names, the bubble rises over the picked tab and glides to the next, Ol keeps his slot', (t) async {
    phone(t);
    final taps = <String>[];
    await t.pumpWidget(_bar(kStoreTabs, 'Home', taps.add));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    for (final s in ['Home', 'Item', 'Bill', 'Online order']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.byType(OlMascot), findsOneWidget);
    double bubbleX() => t.getCenter(find.byKey(const ValueKey('tab-bubble'))).dx;
    expect((bubbleX() - t.getCenter(find.byKey(const ValueKey('tab-Home'))).dx).abs(), lessThan(1));
    expect(t.getTopLeft(find.byKey(const ValueKey('tab-bubble'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('tab-Home'))).dy), reason: 'it rises above the bar');

    await t.tap(find.byKey(const ValueKey('tab-Online order')));
    expect(taps, ['Online order']);
    await t.pumpWidget(_bar(kStoreTabs, 'Online order', taps.add));
    await t.pump(const Duration(milliseconds: 120));
    expect(bubbleX(), greaterThan(t.getCenter(find.byKey(const ValueKey('tab-Home'))).dx), reason: 'on its way');
    expect(bubbleX(), lessThan(t.getCenter(find.byKey(const ValueKey('tab-Online order'))).dx));
    await t.pumpAndSettle();
    expect((bubbleX() - t.getCenter(find.byKey(const ValueKey('tab-Online order'))).dx).abs(), lessThan(1));
  });

  testWidgets('restaurant: its four tabs and the helper after them fit a 375 px phone', (t) async {
    phone(t);
    await t.pumpWidget(_bar(kHubTabs, 'Bill', (_) {}, trailing: const SizedBox(key: ValueKey('ol'))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    for (final s in ['Home', 'Menu', 'Bill', 'Orders']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.byKey(const ValueKey('ol')), findsOneWidget);
    expect((t.getCenter(find.byKey(const ValueKey('tab-bubble'))).dx - t.getCenter(find.byKey(const ValueKey('tab-Bill'))).dx).abs(), lessThan(1));
  });

  testWidgets('no tab picked: no bubble, and every tab can still be tapped', (t) async {
    final taps = <String>[];
    await t.pumpWidget(_bar(kHubTabs, null, taps.add));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('tab-bubble')), findsNothing);
    await t.tap(find.byKey(const ValueKey('tab-Bill')));
    expect(taps, ['Bill']);
  });
}
