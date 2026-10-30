// OneLocal Admin (0635): OneLocal's side of ad credits. Ads to check (approve, ask for changes, reject, then send the price) and giving
// a business ad credits in rupees. Only platform admins get answers; the side bar shows the link only to them.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/admin/ol_admin_screen.dart';
import 'package:vinii_pos/ads/ads_api.dart';
import 'package:vinii_pos/ui/theme.dart';

http.Response ok(Object b) => http.Response(jsonEncode(b), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> _ad(String id, {String creative = 'pending', String stage = 'under_review', String model = 'per_day'}) => {
      'id': id, 'business': 'Niks Cafe', 'title': 'Diwali thali', 'message': '20% off all week', 'format_id': 'reel', 'stage': stage,
      'creative_status': creative, 'starts_on': '2026-11-01', 'ends_on': '2026-11-07', 'days': 7, 'pricing_model': model, 'rate_coins': 100,
      'budget_coins': model == 'cpc' ? 500 : 700, 'media_kind': 'image',
    };

class Fake {
  Fake({List<Map<String, dynamic>>? review, this.admin = true}) : review = review ?? [_ad('a1')];
  List<Map<String, dynamic>> review;
  final bool admin;
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final api = AdsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    if (!admin && fnOf(r) != 'ol_admin_me') {
      return http.Response(jsonEncode({'detail': 'Only OneLocal can do this.', 'code': 'forbidden'}), 403, headers: {'content-type': 'application/json'});
    }
    return switch (fnOf(r)) {
      'ol_admin_me' => ok({'admin': admin}),
      'ads_admin_queue' => ok({
          'review': review,
          'businesses': (b['q'] ?? '') == '' ? [] : [{'id': 'org-niks', 'name': 'Niks Cafe', 'credits': 800}],
          'grants': [{'id': 'g1', 'business': 'Demo Spice', 'amount': 300, 'note': 'Welcome offer', 'created_at': '2026-10-30T10:00:00Z'}],
        }),
      'ads_admin_review' => () {
          review = [for (final a in review) a['id'] == b['id'] ? {...a, 'creative_status': b['decision']} : a]
              .where((a) => a['creative_status'] != 'rejected')
              .toList();
          return ok({'id': b['id']});
        }(),
      'ads_admin_offer' => () {
          review = review.where((a) => a['id'] != b['id']).toList();
          return ok({'id': b['id'], 'stage': 'awaiting_acceptance'});
        }(),
      'ads_grant' => ok({'id': 'g2'}),
      _ => ok({}),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(800, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pump();
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('an ad waiting for OneLocal: Approve, then Send price with the rate in rupees; the business then accepts and pays', (t) async {
    final f = Fake();
    await show(t, OlAdminScreen(api: f.api));
    expect(find.text('Ads to check (1)'), findsOneWidget);
    expect(find.text('Niks Cafe'), findsOneWidget);
    expect(find.text('Diwali thali'), findsOneWidget);
    expect(find.textContaining('budget ₹700'), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-price-a1')), findsNothing, reason: 'the ad is checked before it gets a price');
    await tapKey(t, 'admin-approve-a1');
    expect(f.body('ads_admin_review'), {'id': 'a1', 'decision': 'approved'});
    expect(find.byKey(const ValueKey('admin-price-a1')), findsOneWidget);
    await tapKey(t, 'admin-price-a1');
    expect(find.textContaining('Price for Niks Cafe'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('admin-rate')), '120');
    await tapKey(t, 'admin-price-send');
    expect(f.body('ads_admin_offer'), {'id': 'a1', 'pricing_model': 'per_day', 'rate_coins': 120});
    expect(find.text('No ads waiting for OneLocal.'), findsOneWidget);
  });

  testWidgets('per click needs the most it can spend; Changes and Reject need a reason', (t) async {
    final f = Fake(review: [_ad('a2', model: 'cpc', creative: 'approved', stage: 'approved'), _ad('a3')]);
    await show(t, OlAdminScreen(api: f.api));
    await tapKey(t, 'admin-price-a2');
    await t.enterText(find.byKey(const ValueKey('admin-rate')), '3');
    await t.enterText(find.byKey(const ValueKey('admin-budget')), '');
    await tapKey(t, 'admin-price-send');
    expect(f.calls('ads_admin_offer'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('admin-budget')), '600');
    await tapKey(t, 'admin-price-send');
    expect(f.body('ads_admin_offer'), {'id': 'a2', 'pricing_model': 'cpc', 'rate_coins': 3, 'budget_coins': 600});
    await tapKey(t, 'admin-reject-a3');
    await t.enterText(find.byKey(const ValueKey('admin-note')), 'no');
    await tapKey(t, 'admin-note-send');
    expect(f.calls('ads_admin_review'), isEmpty, reason: 'a reason of 3 characters or more');
    await tapKey(t, 'admin-changes-a3');
    await t.enterText(find.byKey(const ValueKey('admin-note')), 'Use a brighter photo');
    await tapKey(t, 'admin-note-send');
    expect(f.body('ads_admin_review'), {'id': 'a3', 'decision': 'changes_requested', 'note': 'Use a brighter photo'});
  });

  testWidgets('Give credits: find a business, give it rupees with a note; what was given before is listed', (t) async {
    final f = Fake(review: []);
    await show(t, OlAdminScreen(api: f.api));
    await tapKey(t, 'admin-tab-1');
    expect(find.text('Demo Spice'), findsOneWidget);
    expect(find.text('+₹300'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('admin-search')), 'niks');
    await tapKey(t, 'admin-search-go');
    expect(f.body('ads_admin_queue'), {'q': 'niks'});
    expect(find.text('Ad credits ₹800'), findsOneWidget);
    await tapKey(t, 'admin-business-org-niks');
    await t.enterText(find.byKey(const ValueKey('admin-give-amount')), '500');
    await t.enterText(find.byKey(const ValueKey('admin-give-note')), 'Welcome to OneLocal');
    await tapKey(t, 'admin-give-send');
    expect(f.body('ads_grant'), {'organization_id': 'org-niks', 'coins': 500, 'note': 'Welcome to OneLocal'});
    expect(find.textContaining('Gave ₹500 of ad credits to Niks Cafe'), findsOneWidget);
  });

  testWidgets('someone who is not a OneLocal admin is told so and sees nothing', (t) async {
    final f = Fake(admin: false);
    await show(t, OlAdminScreen(api: f.api));
    expect(find.text('Only OneLocal can do this.'), findsOneWidget);
    expect(find.text('Diwali thali'), findsNothing);
  });

  testWidgets('OlAdmin.check asks once and remembers the answer for the side bar', (t) async {
    final f = Fake();
    OlAdmin.isAdmin.value = false;
    await OlAdmin.check(api: f.api);
    await OlAdmin.check(api: f.api);
    expect(OlAdmin.isAdmin.value, isTrue);
    expect(f.calls('ol_admin_me').length, 1);
  });
}
