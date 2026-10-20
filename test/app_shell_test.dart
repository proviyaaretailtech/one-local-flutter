import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/app_shell.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/home_widgets.dart';
import 'package:vinii_pos/ui/app_tab_bar.dart';

import 'helpers.dart';

/// A tab's first screen: its own bar (which must hide inside the shell) and a button that opens a detail page.
class _Root extends StatelessWidget {
  const _Root(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('root $label'),
            TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(body: Center(child: Text('detail $label'))))),
              child: Text('open $label'),
            ),
          ]),
        ),
        bottomNavigationBar: FloatingTabBar(tabs: kStoreTabs, onTap: (_) {}, current: label),
      );
}

Widget? _roots(String kind, String label) => label == 'Online order' ? null : _Root('$kind $label');

Future<void> _show(WidgetTester t) async {
  await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const AppShell(rootFor: _roots, initialKind: 'store'))), child: const Text('enter'))));
  await t.tap(find.text('enter'));
  await t.pumpAndSettle();
}

Future<void> _tab(WidgetTester t, String label) async {
  await t.tap(find.byKey(ValueKey('tab-$label')));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  testWidgets('one bar: pages inside the shell draw none of their own', (t) async {
    await _show(t);
    expect(find.text('root store Home'), findsOneWidget);
    expect(find.byType(AppTabBar), findsNWidgets(2));        // the shell's, and Home's own (drawn as nothing)
    expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
    expect(HomeNav.shell, isNotNull);
  });

  testWidgets('tabs swap under the bar and keep their own back stack; tapping the current tab goes to its first screen', (t) async {
    await _show(t);
    await _tab(t, 'Item');
    expect(find.text('root store Item'), findsOneWidget);
    await t.tap(find.text('open store Item'));
    await t.pumpAndSettle();
    expect(find.text('detail store Item'), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-Item')), findsOneWidget, reason: 'the bar stays over a pushed page');

    await _tab(t, 'Stock');
    expect(find.text('root store Stock'), findsOneWidget);
    await _tab(t, 'Item');
    expect(find.text('detail store Item'), findsOneWidget, reason: 'Item kept its place');
    await _tab(t, 'Item');
    expect(find.text('root store Item'), findsOneWidget);
  });

  testWidgets('a tab with no screen yet says so and stays put', (t) async {
    await _show(t);
    await _tab(t, 'Online order');
    expect(find.text('root store Home'), findsOneWidget);
    expect(toast('Online order opens in a later release.'), findsOneWidget);
  });

  testWidgets('back pops inside the tab, then goes Home, then leaves the shell', (t) async {
    await _show(t);
    await _tab(t, 'Bill');
    await t.tap(find.text('open store Bill'));
    await t.pumpAndSettle();
    final back = t.binding.handlePopRoute;
    await back();
    await t.pumpAndSettle();
    expect(find.text('root store Bill'), findsOneWidget);
    await back();
    await t.pumpAndSettle();
    expect(find.text('root store Home'), findsOneWidget);
    await back();
    await t.pumpAndSettle();
    expect(find.text('enter'), findsOneWidget);
    expect(HomeNav.shell, isNull);
  });

  testWidgets('the Home screen sets the kind: a restaurant gets Menu and Orders, and Bill is its own first screen', (t) async {
    await _show(t);
    HomeNav.shell!.setKind('restaurant');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('tab-Menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-Item')), findsNothing);
    await _tab(t, 'Bill');
    expect(find.text('root restaurant Bill'), findsOneWidget);
  });

  testWidgets('the bar steps aside while a sheet or dialog is open in the tab, and comes back after', (t) async {
    await _show(t);
    final ctx = t.element(find.text('root store Home'));
    showModalBottomSheet<void>(context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('a sheet')));
    await t.pumpAndSettle();
    expect(find.text('a sheet'), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-Home')), findsNothing);
    Navigator.of(t.element(find.text('a sheet'))).pop();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
  });

  testWidgets('HomeNav hooks switch tabs while the shell is up', (t) async {
    await _show(t);
    expect(HomeNav.shell!.show('Stock'), isTrue);
    await t.pumpAndSettle();
    expect(find.text('root store Stock'), findsOneWidget);
    expect(HomeNav.shell!.show('Menu'), isFalse, reason: 'a store has no Menu tab: the caller opens it the old way');
  });
}
