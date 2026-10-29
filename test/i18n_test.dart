import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/item_parts.dart';
import 'package:vinii_pos/catalogue/quick_add_screen.dart';
import 'package:vinii_pos/home/app_actions.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/orders/order_widgets.dart' show PosBottomNav;
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/ui/i18n.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });
  tearDown(() {
    setAppLanguage('en');
    HomeNav.reset();
  });

  test('English text stays as written; Hindi and Hinglish come from the word list; a line without one stays English', () {
    expect(tr('Bill'), 'Bill');
    setAppLanguage('hi');
    expect(tr('Bill'), 'बिल');
    expect(tr('Add product'), 'प्रोडक्ट जोड़ें');
    expect(tr('Something new'), 'Something new');
    setAppLanguage('hi-en');
    expect(tr('Add product'), 'Product jodein');
    setAppLanguage('mr'); // an old code falls back to English
    expect(appLang.value, 'en');
  });

  testWidgets('switching redraws the screens already open, at once, with nothing restarted', (t) async {
    await show(t, Scaffold(body: Column(children: [const _Probe(), PosBottomNav(active: 'home', onTap: (_) {})])));
    expect(find.text('Add product'), findsOneWidget);
    expect(find.text('Online order'), findsOneWidget);
    setAppLanguage('hi');
    await t.pump();
    expect(find.text('प्रोडक्ट जोड़ें'), findsOneWidget);
    expect(find.text('ऑनलाइन ऑर्डर'), findsOneWidget); // the bottom bar
    setAppLanguage('hi-en');
    await t.pump();
    expect(find.text('Product jodein'), findsOneWidget);
  });

  testWidgets('Quick add in Hindi: its labels and button are in Hindi', (t) async {
    setAppLanguage('hi');
    await show(t, QuickAddScreen(api: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't'), inventory: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't'), purchasing: PurchasingApi(baseUrl: 'http://t.test', accessToken: () => 't')));
    for (final w in ['प्रोडक्ट का नाम', 'बारकोड', 'खरीद दाम', 'बिक्री दाम', 'सप्लायर', 'अभी कितना है', 'प्रोडक्ट जोड़ें']) {
      expect(find.text(w), findsWidgets, reason: w);
    }
    expect(t.takeException(), isNull); // Hindi text fits a phone
  });

  testWidgets('Item switcher and side menu in Hinglish; the search finds actions by their Hinglish names too', (t) async {
    setAppLanguage('hi-en');
    HomeNav.stockPage = (_, page, {itemId}) {};
    await show(t, ItemParts(current: 'products', select: (_) {}, child: const Scaffold(body: ItemPartSwitcher())));
    expect(find.text('Kharid'), findsOneWidget); // Purchase
    await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showStoreSideNav(c, name: 'Raj', onReports: () {}, onSignOut: () {}), child: const Text('menu')))));
    await t.tap(find.text('menu'));
    await t.pumpAndSettle();
    expect(find.text('Saare orders'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(searchActions(appActions(_Ctx()), 'ginein').map((a) => a.title), contains('Count stock'));
  });
}

class _Probe extends StatelessWidget {
  const _Probe();
  @override
  Widget build(BuildContext context) => Text(tr('Add product'));
}

class _Ctx extends Fake implements BuildContext {}
