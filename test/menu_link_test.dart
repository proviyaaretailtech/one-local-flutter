import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/storefront/menu_link_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Shaped like menu_link_get (database/tests/571_public_menu_link.sql).
Map<String, dynamic> linkJson({bool live = true}) => {
      'slug': 'demo-spice',
      'path': '/m/demo-spice',
      'live': live,
      'blockers': live ? [] : ['not_published'],
    };

void main() {
  final calls = <http.Request>[];
  Future<void> show(WidgetTester t, Map<String, dynamic> body, {List<Uri>? opened}) async {
    ignoreOverflow();
    t.view.physicalSize = const Size(800, 1800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    calls.clear();
    final rpc = RpcClient(
      baseUrl: 'https://pos.test',
      accessToken: () => 'tok',
      client: MockClient((r) async {
        calls.add(r);
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      }),
    );
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: MenuLinkScreen(api: MenuLinkApi(rpc: rpc), linkBase: 'https://menu.onelocal.co', onOpen: (u) async => opened?.add(u)),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('a live link: the address, its QR, Copy and Open', (t) async {
    final opened = <Uri>[];
    await show(t, linkJson(), opened: opened);
    expect(calls.single.url.path, '/rpc/menu_link_get');
    expect(find.byKey(const ValueKey('menu-link-live')), findsOneWidget);
    expect(find.text('https://menu.onelocal.co/m/demo-spice'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-link-qr')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('menu-link-open')));
    await t.pump();
    expect(opened, [Uri.parse('https://menu.onelocal.co/m/demo-spice')]);
  });

  testWidgets('not published: says why, Open is off, the page builder is one tap away', (t) async {
    final opened = <String>[];
    HomeNav.storefront = (_) => opened.add('storefront');
    addTearDown(HomeNav.reset);
    await show(t, linkJson(live: false));
    expect(find.byKey(const ValueKey('menu-link-off')), findsOneWidget);
    expect(find.text('Publish your menu in the OneLocal page builder.'), findsOneWidget);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('menu-link-open'))).onPressed, isNull);
    await t.tap(find.byKey(const ValueKey('menu-link-publish')));
    expect(opened, ['storefront']);
    await t.pump(const Duration(milliseconds: 500));   // back on this screen: the link is read again
    expect(calls.length, 2);
  });

  testWidgets('no store link chosen yet: says so, no address or QR to share', (t) async {
    await show(t, {'slug': null, 'path': null, 'live': false, 'blockers': ['no_store_link', 'not_published']});
    expect(find.text('Choose your store link in Page Manager (Shop profile).'), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-link-qr')), findsNothing);
    expect(find.byKey(const ValueKey('menu-link-url')), findsNothing);
  });

  test('the link uses the same base as the table QR codes', () {
    expect(MenuLinkApi.urlFor('/m/demo-spice', base: 'https://order.test/'), 'https://order.test/m/demo-spice');
  });
}
