import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/ui/app_header.dart';
import 'package:vinii_pos/ui/theme.dart';

void main() {
  tearDown(HomeNav.reset);

  testWidgets('the banner always keeps ☰; a page that can go back gets one back arrow, under the banner', (t) async {
    var menus = 0;
    HomeNav.openMenu = (_) => menus++;
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Column(children: [AppHeader(title: 'Inner page'), Text('inside')])))),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-header-menu')), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    // the arrow sits under the banner card, not in it
    expect(t.getTopLeft(find.byKey(const ValueKey('app-header-back'))).dy, greaterThan(t.getBottomLeft(find.byKey(const ValueKey('app-header-menu'))).dy));

    await t.tap(find.byKey(const ValueKey('app-header-menu')));
    expect(menus, 1);
    await t.tap(find.byKey(const ValueKey('app-header-back')));
    await t.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('a main screen (nothing to go back to) has ☰ and no back arrow', (t) async {
    HomeNav.openMenu = (_) {};
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: const Scaffold(body: AppHeader(title: 'Home'))));
    expect(find.byKey(const ValueKey('app-header-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-header-back')), findsNothing);
  });

  testWidgets('the OneLocal wallet button sits on every banner and opens the wallet', (t) async {
    var opened = 0;
    HomeNav.wallet = (_) => opened++;
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: const Scaffold(body: AppHeader(title: 'Bill'))));
    await t.tap(find.byKey(const ValueKey('app-header-wallet')));
    expect(opened, 1);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: const Scaffold(body: AppHeader(title: 'Bill', wallet: false))));
    expect(find.byKey(const ValueKey('app-header-wallet')), findsNothing);
  });

  test('a long store name shortens to its initials, keeping the outlet', () {
    expect(shortStoreName('SHARMA GENERAL STORE - MAIN'), 'SGS - MAIN');
    expect(shortStoreName('Purushottam Super Market'), 'PSM');
    expect(shortStoreName('Shree Krishna Kirana · Station Road'), 'SKK · Station Road');
    expect(shortStoreName('Reliance'), 'Reliance'); // one word stays as it is
  });

  testWidgets('on a phone the store name that does not fit becomes its initials; a short one stays', (t) async {
    t.view.physicalSize = const Size(390 * 2, 800 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    HomeNav.storeName = 'Sharma General Store Wholesale and Retail - Main';
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: const Scaffold(body: AppHeader(title: 'Bill'))));
    expect(t.widget<Text>(find.byKey(const ValueKey('app-header-kicker'))).data, 'SGSWR - MAIN');
    HomeNav.storeName = 'Sharma Store';
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: const Scaffold(body: AppHeader(title: 'Money'))));
    expect(t.widget<Text>(find.byKey(const ValueKey('app-header-kicker'))).data, 'SHARMA STORE');
  });
}
