import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/service/service_nav.dart' show kServiceTabs;
import 'package:vinii_pos/service/service_tab_bar.dart';

// The interactive service bar (founder's reference, 4 Nov 2026): the picked tab lifts into a bubble over a dip that slides to it.

Widget _bar(String? current, ValueChanged<String> onTap) => MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: ServiceTabBar(tabs: kServiceTabs, onTap: onTap, current: current, trailing: const SizedBox(key: ValueKey('ol'))),
      ),
    );

void main() {
  testWidgets('on a 375 px phone: four tabs and Ol fit; the bubble sits over the picked tab and glides to the next one', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final taps = <String>[];
    await t.pumpWidget(_bar('Home', taps.add));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    for (final s in ['Home', 'Catalogue', 'Bill', 'Bookings']) {
      expect(find.byKey(ValueKey('tab-$s')), findsOneWidget, reason: s);
    }
    expect(find.byKey(const ValueKey('ol')), findsOneWidget);
    double bubbleX() => t.getCenter(find.byKey(const ValueKey('tab-bubble'))).dx;
    expect((bubbleX() - t.getCenter(find.byKey(const ValueKey('tab-Home'))).dx).abs(), lessThan(1));
    expect(t.getTopLeft(find.byKey(const ValueKey('tab-bubble'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('tab-Home'))).dy),
        reason: 'it rises above the bar');

    await t.tap(find.byKey(const ValueKey('tab-Bookings')));
    expect(taps, ['Bookings']);
    await t.pumpWidget(_bar('Bookings', taps.add));
    await t.pump(const Duration(milliseconds: 120));
    final mid = bubbleX();
    expect(mid, greaterThan(t.getCenter(find.byKey(const ValueKey('tab-Home'))).dx), reason: 'on its way');
    expect(mid, lessThan(t.getCenter(find.byKey(const ValueKey('tab-Bookings'))).dx));
    await t.pumpAndSettle();
    expect((bubbleX() - t.getCenter(find.byKey(const ValueKey('tab-Bookings'))).dx).abs(), lessThan(1));
  });

  testWidgets('with no tab picked the bubble is gone', (t) async {
    await t.pumpWidget(_bar(null, (_) {}));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('tab-bubble')), findsNothing);
  });
}
