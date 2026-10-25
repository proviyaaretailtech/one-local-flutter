import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:vinii_pos/catalogue/item_parts.dart';
import 'package:vinii_pos/home/home_widgets.dart';
import 'package:vinii_pos/ui/app_tab_bar.dart';

Widget _part(String name) => Scaffold(body: Column(children: [const ItemPartSwitcher(), Text('$name screen')]));

void main() {
  tearDown(() => ItemHome.requested.value = null);

  testWidgets('Item has three parts: Products first, then Stock and Purchase, one tap each', (t) async {
    await t.pumpWidget(MaterialApp(home: ItemHome(parts: {for (final (id, _, _) in itemParts) id: (_) => _part(id)})));
    expect(find.text('products screen'), findsOneWidget);
    for (final l in ['Products', 'Stock', 'Purchase']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    await t.tap(find.byKey(const ValueKey('item-part-stock')));
    await t.pump();
    expect(find.text('stock screen'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('item-part-purchase')));
    await t.pump();
    expect(find.text('purchase screen'), findsOneWidget);
  });

  testWidgets('another screen can ask Item to show a part (old Stock / Purchase links land in Item)', (t) async {
    ItemHome.requested.value = 'purchase';
    await t.pumpWidget(MaterialApp(home: ItemHome(parts: {for (final (id, _, _) in itemParts) id: (_) => _part(id)})));
    expect(find.text('purchase screen'), findsOneWidget);
    ItemHome.requested.value = 'stock';
    await t.pump();
    expect(find.text('stock screen'), findsOneWidget);
  });

  testWidgets('outside Item the switcher draws nothing', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: ItemPartSwitcher())));
    expect(find.text('Products'), findsNothing);
  });

  testWidgets('the store bar keeps five slots; the old Stock slot is an empty circle that does nothing', (t) async {
    expect(kStoreTabs.map((x) => x.label), ['Home', 'Item', 'Bill', 'Online order', '']);
    final tapped = <String>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: AppTabBar(
          tabs: const [AppTab('home', 'Home', LucideIcons.house), AppTab('slot', '', LucideIcons.circle)],
          onTap: tapped.add,
        ),
      ),
    ));
    expect(find.text('Stock'), findsNothing);
    await t.tap(find.byKey(const ValueKey('tab-slot')));
    await t.tap(find.text('Home'));
    expect(tapped, ['home']);
  });
}
