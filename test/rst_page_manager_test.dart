// Page Manager for the restaurant: the readiness card (x/7 ready, what is still missing, published or not), Grow your sales and Your page,
// each opening the storefront screen it names; Share copies the link only once the page is live.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;
import 'package:vinii_pos/restaurant/rst_page_manager.dart';
import 'package:vinii_pos/storefront/menu_link_screen.dart';
import 'package:vinii_pos/storefront/storefront_api.dart';
import 'package:vinii_pos/ui/theme.dart';

Map<String, dynamic> _settings({String? slug, String? logo}) => {
      'profile': {'public_name': 'Niks Cafe', 'description': 'Cozy café', 'address_line': 'Khardekar Stop, Latur', 'store_slug': slug, 'logo_url': logo, 'cover_url': null},
      'hours': {
        'configured': true,
        'show': true,
        'days': [for (var d = 1; d <= 7; d++) {'day': d, 'open': d != 1, 'opens': '12:00', 'closes': '23:00'}],
      },
      'delivery': {'configured': true, 'home_delivery': true, 'radius_km': 5, 'pickup': true, 'min_order_minor': 50000},
    };

void main() {
  late List<String> calls;
  late Map<String, dynamic> settings, builder, link;
  final nav = GlobalKey<NavigatorState>();

  RpcClient rpc() {
    calls = [];
    final client = MockClient((r) async {
      final fn = r.url.pathSegments.last;
      calls.add(fn);
      final answer = switch (fn) {
        'sf_settings_get' => settings,
        'sf_builder_get' => builder,
        'menu_link_get' => link,
        'sf_offer_list' => {'offers': []},
        'sf_ad_list' => {'ads': []},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
    });
    return RpcClient(client: client, baseUrl: 'http://t.test', accessToken: () => 't');
  }

  setUp(() {
    settings = _settings();
    builder = {'published_version': 0, 'has_unpublished_changes': false, 'store': {'name': 'Niks Cafe'}};
    link = {'live': false, 'path': null, 'blockers': ['no_store_link', 'not_published']};
  });
  tearDown(HomeNav.reset);

  Future<void> show(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final r = rpc();
    await t.pumpWidget(MaterialApp(
      navigatorKey: nav,
      theme: posTheme(),
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute(
              builder: (_) => RstPageManagerScreen(api: StorefrontApi(rpc: r), linkApi: MenuLinkApi(rpc: r), today: DateTime(2026, 10, 29), linkBase: 'https://m.test'))),
          child: const Text('go'),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
  }

  test('the seven checks, the hours line and the delivery line', () {
    final checks = pageChecks(Facts(_settings()));
    expect(checks.length, 7);
    expect([for (final c in checks) if (!c.$2) c.$1], ['Logo', 'Banner', 'Store link']);
    final hours = Facts(_settings()).m('hours');
    expect(hoursLine(hours, DateTime(2026, 10, 29)), 'Today 12:00 – 23:00', reason: '29 Oct 2026 is a Thursday');
    expect(hoursLine(hours, DateTime(2026, 10, 26)), 'Closed today', reason: 'Monday is closed');
    expect(hoursLine(const Facts({'configured': false}), DateTime(2026, 10, 29)), 'Not set');
    expect(deliveryLine(Facts(_settings()).m('delivery')), '5 km · Pickup · min ₹500');
    expect(deliveryLine(const Facts({'configured': true, 'pickup': true, 'home_delivery': false})), 'Pickup');
  });

  testWidgets('the card says how ready the page is and what is missing; every tile names its screen', (t) async {
    await show(t);
    expect(find.text('Page Manager'), findsOneWidget);
    expect(find.text('Niks Cafe'), findsOneWidget);
    expect(find.text('Your page is 4/7 ready'), findsOneWidget);
    expect(find.text('57%'), findsOneWidget);
    expect(find.text('Still to add: Logo, Banner, Store link'), findsOneWidget);
    expect(find.text('Not published yet'), findsOneWidget);
    for (final s in ['Grow your sales', 'Ads', 'Offers & promotions', 'Your page', 'Shop profile', 'Store page', 'Business hours', 'Delivery & pickup', 'Store link & QR', 'Reviews']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(t.widget<Text>(find.byKey(const ValueKey('pm-hours-sub'))).data, 'Today 12:00 – 23:00');
    expect(t.widget<Text>(find.byKey(const ValueKey('pm-delivery-sub'))).data, '5 km · Pickup · min ₹500');
    expect(t.widget<Text>(find.byKey(const ValueKey('pm-link-sub'))).data, 'Choose your link');
    expect(find.text('Soon'), findsOneWidget, reason: 'Reviews has no screen plugged in this test');
  });

  testWidgets('Share before the page is live says what to do; once live it copies the link', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await show(t);
    await t.tap(find.byKey(const ValueKey('pm-share')));
    await t.pump();
    expect(copied, isNull);
    expect(find.text('Publish your page and choose a store link first, then share it.'), findsOneWidget);
    await t.pumpAndSettle(const Duration(seconds: 5));

    nav.currentState!.pop();
    await t.pumpAndSettle();
    settings = _settings(slug: 'niks-cafe', logo: 'https://img.test/l.png');
    builder = {'published_version': 3, 'has_unpublished_changes': false};
    link = {'live': true, 'path': '/m/niks-cafe', 'blockers': []};
    await show(t);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Your page is 6/7 ready'), findsOneWidget);
    expect(find.text('Still to add: Banner'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pm-share')));
    await t.pump();
    expect(copied, 'https://m.test/m/niks-cafe');
  });

  testWidgets('each card opens its screen and the page reads again on the way back', (t) async {
    HomeNav.reviews = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('reviews page'))));
    await show(t);
    for (final (key, fn) in [('pm-edit', 'sf_builder_get'), ('pm-ads', 'sf_ad_list'), ('pm-offers', 'sf_offer_list'), ('pm-profile', 'sf_settings_get'), ('pm-hours', 'sf_settings_get'), ('pm-delivery', 'sf_settings_get'), ('pm-link', 'menu_link_get'), ('pm-reviews', null)]) {
      await t.ensureVisible(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
      calls.clear();
      await t.tap(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pm-ready')), findsNothing, reason: '$key covers Page Manager');
      if (fn != null) expect(calls, contains(fn), reason: key);
      if (key == 'pm-reviews') expect(find.text('reviews page'), findsOneWidget);
      calls.clear();
      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pm-ready')), findsOneWidget, reason: 'back from $key');
      expect(calls, containsAll(['sf_settings_get', 'sf_builder_get', 'menu_link_get']), reason: 'reloaded after $key');
    }
  });
}
