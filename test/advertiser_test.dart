import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/ads/ads_api.dart';
import 'package:vinii_pos/ads/ads_screens.dart';
import 'package:vinii_pos/ads/advertiser_screens.dart';
import 'package:vinii_pos/screens/register_account_type_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

// Advertising-only partners (the Advertising & Partner Growth spec §1, 29 Oct 2026): sign up to advertise without selling, OneLocal
// verifies the brand, then the app is Ads only. A store that fills in a brand profile becomes hybrid.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> _get({Map<String, dynamic>? app}) => {
      'exists': app != null,
      'application': app,
      'terms': 'You join OneLocal to advertise.\nEvery ad is checked by OneLocal before it runs.',
      'terms_version': 'adv-terms-2026-10-29',
      'categories': ['Food & restaurants', 'Fashion & accessories', 'Other'],
      'objectives': ['awareness', 'product', 'launch', 'sales'],
      'formats': [
        {'id': 'reel', 'name': 'Reel / video'},
        {'id': 'home_banner', 'name': 'Homepage banner'},
      ],
    };

class Fake {
  Fake({this.kind = 'commerce', this.submitStatus = 'submitted'});
  final String kind, submitStatus;
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final client = MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'adv_app_get' => ok(_get()),
      'adv_app_save' => ok(_get(app: {...b, 'status': 'draft', 'reference': 'ADV-1A2B3C4D'})),
      'adv_app_submit' => ok(_get(app: {'status': submitStatus, 'reference': 'ADV-1A2B3C4D', 'brand_name': 'Sunrise Tea', 'business_category': 'Food & restaurants', 'target_locations': ['Baner']})),
      'ads_profile' => ok({'partner_kind': kind, 'can_edit': true, 'categories': ['Food & restaurants', 'Other'], 'profile': null}),
      'ads_profile_save' => ok({'partner_kind': kind == 'commerce' ? 'hybrid' : kind, 'profile': b}),
      'ads_home' => ok({'balances': {'available': 0}, 'coins': 0, 'coin_rupees': 10, 'formats': [], 'counts': {}, 'series': [], 'ads': [], 'ledger': []}),
      _ => ok({}),
    };
  });
  late final api = AdvertiserApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
  late final ads = AdsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client);
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 5200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pump();
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  await t.ensureVisible(f.first);
  await t.tap(f.first);
  await t.pumpAndSettle();
}

Future<void> typeIn(WidgetTester t, String key, String text) async {
  final f = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField));
  await t.enterText(f.evaluate().isEmpty ? find.byKey(ValueKey(key)) : f, text);
  await t.pump();
}

void main() {
  testWidgets('the account choice offers Only advertise when onboarding asks for it', (t) async {
    var opened = false;
    await show(t, RegisterAccountTypeScreen(onChosen: (_) {}, onAdvertise: () => opened = true));
    expect(find.text('Only advertise'), findsOneWidget);
    await tapKey(t, 'account-advertise');
    expect(opened, isTrue);
  });

  testWidgets('without onAdvertise the choice is the three business types only', (t) async {
    await show(t, RegisterAccountTypeScreen(onChosen: (_) {}));
    expect(find.byKey(const ValueKey('account-advertise')), findsNothing);
  });

  testWidgets('sign-up: brand, representative, areas, goals and terms; refused until the terms are ticked; then sent for review', (t) async {
    final f = Fake();
    await show(t, AdvertiserSignupScreen(api: f.api, phone: '+919876501234', name: 'Asha Rao'));
    // the name and mobile from sign-up are filled in
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('9876501234'), findsOneWidget);
    await typeIn(t, 'adv-brand', 'Sunrise Tea');
    await tapText(t, 'Choose');
    await tapText(t, 'Food & restaurants');
    await typeIn(t, 'adv-area', 'Baner');
    await tapKey(t, 'adv-area-add');
    expect(find.byKey(const ValueKey('adv-area-Baner')), findsOneWidget);
    await tapText(t, 'Brand awareness');
    await tapText(t, 'New launch');
    await tapText(t, 'Reel / video');
    expect(find.text('Every ad is checked by OneLocal before it runs.'), findsOneWidget);
    await tapKey(t, 'adv-submit');
    expect(f.calls('adv_app_submit'), isEmpty); // the terms are not ticked
    await tapKey(t, 'adv-agree');
    await tapKey(t, 'adv-submit');
    final b = f.body('adv_app_save');
    expect(b, containsPair('brand_name', 'Sunrise Tea'));
    expect(b, containsPair('business_category', 'Food & restaurants'));
    expect(b, containsPair('representative_name', 'Asha Rao'));
    expect(b, containsPair('phone', '9876501234'));
    expect(b['target_locations'], ['Baner']);
    expect(b['objectives'], ['awareness', 'launch']);
    expect(b['formats'], ['reel']);
    expect(f.body('adv_app_submit'), {'agree': true});
    expect(find.byType(AdvertiserStatusScreen), findsOneWidget);
    expect(find.text('OneLocal is checking your brand.'), findsOneWidget);
    expect(find.textContaining('ADV-1A2B3C4D'), findsOneWidget);
  });

  testWidgets('approved: Open Ads opens the advertiser app, Ads with a menu and no back arrow', (t) async {
    final f = Fake(kind: 'advertising');
    await show(t, AdvertiserStatusScreen(api: f.api, application: const {'status': 'approved', 'reference': 'ADV-1', 'brand_name': 'Sunrise Tea'}));
    expect(find.text('You are ready to advertise.'), findsOneWidget);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: AdvertiserHomeScreen(adsApi: f.ads, api: f.api)));
    await t.pumpAndSettle();
    expect(find.byType(AdsHomeScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('app-header-back')), findsNothing);
    await tapKey(t, 'app-header-menu');
    expect(find.byKey(const ValueKey('adv-menu-profile')), findsOneWidget);
    expect(find.byKey(const ValueKey('adv-menu-signout')), findsOneWidget);
    await tapKey(t, 'adv-menu-profile');
    expect(find.byKey(const ValueKey('brand-kind-advertising')), findsOneWidget);
  });

  testWidgets('a store saving a brand profile becomes hybrid', (t) async {
    final f = Fake();
    await show(t, BrandProfileScreen(api: f.api));
    expect(find.byKey(const ValueKey('brand-kind-commerce')), findsOneWidget);
    await typeIn(t, 'brand-name', 'Sharma Stores');
    await tapKey(t, 'brand-save');
    expect(f.body('ads_profile_save'), containsPair('brand_name', 'Sharma Stores'));
  });
}
