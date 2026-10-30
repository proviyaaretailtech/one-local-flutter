import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/ads/ads_api.dart';
import 'package:vinii_pos/ads/ads_campaign.dart';
import 'package:vinii_pos/ads/ads_screens.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/ui/theme.dart';

// The Ads section (founder's sketch and the "Advertising & Partner Growth System" spec, 29 Oct 2026): a dashboard (coins available, held,
// spent; campaigns by stage; analytics), a new campaign (objective, format, a price only where OneLocal switched one on, else a price
// request), the campaign page (accept a price, hold coins, dispute, report, cancel), the coins wallet and topping it up over UPI.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> _rule(String format, String model, num rate) =>
    {'id': 'r-$format-$model', 'format_id': format, 'pricing_model': model, 'version': 1, 'rate_coins': rate, 'terms': 'Charged per day the ad is booked.', 'status': 'active'};

Map<String, dynamic> _ad(String id, String title, {String format = 'reel', String stage = 'active', String phase = 'live', Map<String, dynamic> more = const {}}) => {
      'id': id, 'title': title, 'format_id': format, 'stage': stage, 'phase': phase, 'media_kind': 'video', 'has_media': true,
      'starts_on': '2026-10-25', 'ends_on': '2026-11-02', 'days': 9, 'pricing_model': 'per_day', 'rate_coins': 10, 'rule_version': 1,
      'budget_coins': 90, 'held': 40, 'spent': 50, 'creative_status': 'approved', 'accepted_at': '2026-10-24', 'funded': true,
      'accepted_terms': 'Charged per day the ad is booked.', 'views': 640, 'clicks': 41, 'valid_clicks': 38, ...more,
    };

Map<String, dynamic> _home({num coins = 120, num pending = 0, String upi = 'onelocal@upi', List<Map<String, dynamic>>? ads}) => {
      'balances': {'available': coins, 'promotional': 0, 'reserved': 30, 'consumed': 90, 'expired': 0, 'pending': pending, 'disputed': 0},
      'coins': coins,
      'pending_coins': pending,
      'coin_rupees': 1,
      'upi_id': upi,
      'payee_name': 'OneLocal',
      'formats': [
        {'id': 'home_banner', 'name': 'Homepage banner', 'models': ['per_day', 'per_week', 'fixed', 'cpm'], 'rules': [_rule('home_banner', 'per_day', 5)]},
        {'id': 'reel', 'name': 'Reel / video', 'models': ['per_day', 'cpc', 'cpm', 'fixed'], 'rules': [_rule('reel', 'per_day', 10)]},
        {'id': 'popup', 'name': 'Pop-up', 'models': ['per_day', 'cpm'], 'rules': [_rule('popup', 'per_day', 15)]},
        {'id': 'category_banner', 'name': 'Category banner', 'models': ['per_day', 'fixed', 'cpm'], 'rules': []},
        {'id': 'sponsored_product', 'name': 'Sponsored product', 'models': ['cpc', 'cpm', 'fixed'], 'rules': [_rule('sponsored_product', 'cpc', 2)]},
      ],
      'counts': {'live': 3, 'upcoming': 2, 'review': 1},
      'series': [for (var i = 0; i < 14; i++) {'day': '2026-10-${(16 + i).toString().padLeft(2, '0')}', 'views': i * 10, 'clicks': i, 'valid_clicks': i, 'spent': 1}],
      'ads': ads ??
          [
            _ad('a1', 'Diwali sweets'),
            _ad('a2', 'Weekend offer', format: 'home_banner', stage: 'scheduled', phase: 'upcoming', more: {'spent': 0, 'held': 10, 'views': 0, 'clicks': 0}),
          ],
      'ledger': [
        {'id': 'l1', 'kind': 'topup', 'coins': 200, 'status': 'done', 'method': 'wallet', 'ref': 'OLW-1A2B3C4D', 'created_at': '2026-10-20T10:00:00Z'},
        {'id': 'l2', 'kind': 'reserve', 'coins': 90, 'status': 'done', 'ad_title': 'Diwali sweets', 'created_at': '2026-10-24T10:00:00Z'},
        {'id': 'l3', 'kind': 'consume', 'coins': 10, 'status': 'done', 'ad_title': 'Diwali sweets', 'created_at': '2026-10-25T10:00:00Z'},
      ],
    };

class Fake {
  Fake({this.home});
  Map<String, dynamic>? home;
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final api = AdsApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    if (r.method == 'PUT') return http.Response('', 200); // the signed upload
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'ads_home' => ok(home ?? _home()),
      'ads_media_slot' => ok({'path': 'org/ads/x.${(b['content_type'] as String).startsWith('video') ? 'mp4' : 'jpg'}', 'media_kind': (b['content_type'] as String).startsWith('video') ? 'video' : 'image', 'upload_url': 'http://up.test/x', 'max_bytes': 1}),
      'ads_save' => ok({'ad': {'id': 'a9', 'funded': true}, 'balances': {'available': 50}, 'replayed': false}),
      'ads_stop' => ok({'ad': {'id': b['id']}, 'refunded': 40, 'coins': 160}),
      'ads_accept' => ok({'ad': {'id': b['id'], 'stage': 'scheduled', 'funded': true}}),
      'ads_dispute' => ok({'dispute': {'id': 'd1'}}),
      'ads_report' => ok({'days': [{'day': '2026-10-25', 'views': 100, 'clicks': 7, 'valid_clicks': 6, 'visits': 0, 'leads': 0, 'spent': 10}]}),
      'wallet_overview' => ok({'unsettled': {'due_minor': 300000}, 'owed_to_onelocal': {'amount_minor': 20000}, 'ad_credits_moved': {'amount_minor': 0}}),
      'ads_wallet_move' => ok({'id': 'm1', 'amount_minor': b['amount_minor'], 'replayed': false}),
      _ => ok({}),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 4400);
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

String textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

// a 9×16 PNG, so the photo reads as 9:16
final _png916 = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAkAAAAQCAIAAABLKsIUAAAAEUlEQVR4nGNowA0YRuUGvRwADNPYAX5xbNEAAAAASUVORK5CYII=');

void main() {
  tearDown(() {
    pickAdMedia = ({required bool video}) async => null;
  });

  group('Ads dashboard', () {
    testWidgets('available, held and spent ad credits in rupees, live and upcoming counts, analytics and the campaigns; the tiles filter the list', (t) async {
      final f = Fake();
      await show(t, AdsHomeScreen(api: f.api));
      expect(textOf(t, 'ads-coins'), '120');
      expect(find.textContaining('coin'), findsNothing, reason: 'rupees, no coins');
      expect(find.descendant(of: find.byKey(const ValueKey('ads-held')), matching: find.text('₹30')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('ads-spent')), matching: find.text('₹90')), findsOneWidget);
      expect(find.text('Live ads'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.textContaining("waiting for OneLocal's check"), findsOneWidget);
      expect(find.text('910'), findsOneWidget); // views over 14 days
      expect(find.text('91'), findsWidgets); // clicks and valid clicks
      expect(find.text('10.0%'), findsOneWidget);
      expect(find.text('₹14'), findsOneWidget); // spent
      expect(find.text('Diwali sweets'), findsOneWidget);
      expect(find.text('₹50 spent'), findsOneWidget);
      expect(find.text('₹10 held'), findsOneWidget);
      await tapKey(t, 'ads-upcoming');
      expect(find.text('Diwali sweets'), findsNothing);
      expect(find.text('Weekend offer'), findsOneWidget);
    });

    testWidgets('campaigns that need the shop show a banner', (t) async {
      final f = Fake(home: _home(ads: [_ad('a3', 'Needs a price ok', stage: 'awaiting_acceptance', phase: 'review')]));
      await show(t, AdsHomeScreen(api: f.api));
      expect(find.byKey(const ValueKey('ads-needs-you')), findsOneWidget);
      expect(find.text('Price to accept'), findsOneWidget);
    });

    testWidgets('credits still waiting show on the ad credits card', (t) async {
      final f = Fake(home: _home(pending: 500));
      await show(t, AdsHomeScreen(api: f.api));
      expect(find.byKey(const ValueKey('ads-pending')), findsOneWidget);
      expect(find.textContaining('+₹500'), findsOneWidget);
    });
  });

  group('Campaign page', () {
    testWidgets('a live campaign: steps, price, held and spent; cancel gives the rest back', (t) async {
      final f = Fake();
      await show(t, AdsHomeScreen(api: f.api));
      await tapKey(t, 'ad-a1');
      expect(find.byType(CampaignScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('campaign-steps')), findsOneWidget);
      expect(find.text('Running now.'), findsOneWidget);
      expect(textOf(t, 'campaign-held'), '₹40');
      expect(textOf(t, 'campaign-spent'), '₹50');
      expect(find.byKey(const ValueKey('ad-media-open')), findsOneWidget);
      expect(find.byKey(const ValueKey('ad-pause')), findsNothing); // booked days cannot be paused
      await tapKey(t, 'ad-stop');
      await tapKey(t, 'ad-stop-confirm');
      expect(f.body('ads_stop'), {'id': 'a1'});
      expect(find.textContaining('₹40 back in your credits'), findsOneWidget);
    });

    testWidgets('a price from OneLocal: accepted only after ticking the terms', (t) async {
      final ad = _ad('a4', 'Quote', format: 'category_banner', stage: 'awaiting_acceptance', phase: 'review',
          more: {'rule_version': null, 'accepted_at': null, 'accepted_terms': null, 'offer_terms': '4 coins a day', 'rate_coins': 4, 'budget_coins': 20, 'held': 0, 'spent': 0, 'funded': false});
      final f = Fake(home: _home(ads: [ad]));
      await show(t, CampaignScreen(api: f.api, ad: ad, home: _home(ads: [ad])));
      expect(find.text('4 coins a day'), findsOneWidget);
      await tapKey(t, 'ad-accept');
      expect(f.calls('ads_accept'), isEmpty);
      await tapKey(t, 'ad-accept-terms');
      await tapKey(t, 'ad-accept');
      expect(f.body('ads_accept'), {'id': 'a4', 'agree': true});
    });

    testWidgets('dispute charges and copy the report', (t) async {
      final f = Fake();
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await show(t, CampaignScreen(api: f.api, ad: _ad('a1', 'Diwali sweets'), home: _home()));
      await tapKey(t, 'ad-report');
      expect(copied, startsWith('Day,Views,Clicks,Valid clicks'));
      expect(copied, contains('2026-10-25,100,7,6,0,0,10'));
      await tapKey(t, 'ad-dispute');
      await tapKey(t, 'dispute-kind-invalid_clicks');
      await t.enterText(find.byKey(const ValueKey('dispute-reason')), 'Lots of clicks from one place');
      await t.enterText(find.byKey(const ValueKey('dispute-coins')), '5');
      await tapKey(t, 'dispute-send');
      expect(f.body('ads_dispute'), {'ad_id': 'a1', 'kind': 'invalid_clicks', 'reason': 'Lots of clicks from one place', 'coins': 5});
    });
  });

  group('Create campaign', () {
    testWidgets('a 9:16 photo, the format, the dates; the amount is worked out from the active price; the terms must be ticked', (t) async {
      final f = Fake();
      pickAdMedia = ({required bool video}) async => PickedDocument(name: 'diwali.png', bytes: Uint8List.fromList(_png916), contentType: 'image/png');
      await show(t, AdCreateScreen(api: f.api, home: _home(), today: DateTime(2026, 10, 29)));
      // Reel by default, 30 Oct – 5 Nov: 7 days × ₹10
      expect(textOf(t, 'ad-cost'), '70');
      expect(textOf(t, 'ad-left'), '₹50');
      await tapKey(t, 'ad-format-popup');
      expect(textOf(t, 'ad-cost'), '105');
      await tapKey(t, 'ad-format-home_banner');
      expect(textOf(t, 'ad-cost'), '35');
      // nothing picked yet
      await tapKey(t, 'ad-create');
      expect(f.calls('ads_save'), isEmpty);
      await tapKey(t, 'ad-pick-photo');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // the photo is measured
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-ratio-warning')), findsNothing); // it is 9:16
      await t.enterText(find.byKey(const ValueKey('ad-title')), 'Diwali sweets');
      await tapKey(t, 'ad-create');
      expect(f.calls('ads_save'), isEmpty); // the terms are not ticked
      await tapKey(t, 'ad-terms');
      await tapKey(t, 'ad-create');
      expect(f.body('ads_media_slot'), {'content_type': 'image/png', 'size': _png916.length});
      final b = f.body('ads_save');
      expect(b, containsPair('format_id', 'home_banner'));
      expect(b, containsPair('pricing_model', 'per_day'));
      expect(b, containsPair('objective', 'product'));
      expect(b, containsPair('accept_terms', true));
      expect(b, containsPair('media_kind', 'image'));
      expect(b, containsPair('media_path', 'org/ads/x.jpg'));
      expect(b, containsPair('starts_on', '2026-10-30'));
      expect(b, containsPair('ends_on', '2026-11-05'));
      expect(f.calls('ads_save').single.headers['Idempotency-Key'], startsWith('ad-'));
    });

    testWidgets('no active price: the shop requests one, with nothing held', (t) async {
      final f = Fake();
      pickAdMedia = ({required bool video}) async => PickedDocument(name: 'reel.mp4', bytes: Uint8List(2048), contentType: 'video/mp4');
      await show(t, AdCreateScreen(api: f.api, home: _home(), today: DateTime(2026, 10, 29)));
      await tapKey(t, 'ad-format-category_banner');
      expect(find.byKey(const ValueKey('ad-no-price')), findsOneWidget);
      expect(find.text('Request a price'), findsOneWidget);
      await tapKey(t, 'ad-pick-video');
      expect(find.text('reel.mp4'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('ad-title')), 'New arrivals');
      await tapKey(t, 'ad-create');
      final b = f.body('ads_save');
      expect(b, allOf(containsPair('media_kind', 'video'), containsPair('format_id', 'category_banner')));
      expect(b.containsKey('accept_terms'), isFalse);
    });

    testWidgets('per click: a budget, worked out as clicks', (t) async {
      final f = Fake();
      await show(t, AdCreateScreen(api: f.api, home: _home(), today: DateTime(2026, 10, 29)));
      await tapKey(t, 'ad-format-sponsored_product');
      await t.enterText(find.byKey(const ValueKey('ad-budget')), '50');
      await t.pumpAndSettle();
      expect(textOf(t, 'ad-cost'), '50');
      expect(find.textContaining('Up to 25 valid clicks'), findsOneWidget);
    });

    testWidgets('not enough ad credits: it can still be sent; Add credits fills in what is missing (at least ₹100)', (t) async {
      final f = Fake();
      await show(t, AdCreateScreen(api: f.api, home: _home(coins: 20), today: DateTime(2026, 10, 29)));
      expect(textOf(t, 'ad-left'), '₹50 more');
      await tapKey(t, 'ad-topup');
      expect(find.byType(TopUpScreen), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('topup-amount'))).controller!.text, '100'); // ₹50 still needed; ₹100 is the least that moves
    });

    testWidgets('Save draft sends nothing to review', (t) async {
      final f = Fake();
      await show(t, AdCreateScreen(api: f.api, home: _home(), today: DateTime(2026, 10, 29)));
      await tapKey(t, 'ad-draft');
      expect(f.body('ads_save'), containsPair('draft', true));
    });
  });

  group('Ad credits', () {
    testWidgets('the wallet: available, held and spent kept apart, the Ads and Discount tiles, and the history', (t) async {
      final f = Fake();
      await show(t, CoinsScreen(api: f.api));
      expect(textOf(t, 'coins-balance'), '120');
      expect(textOf(t, 'coins-held'), '₹30');
      expect(textOf(t, 'coins-spent'), '₹90');
      expect(find.byKey(const ValueKey('coins-ads')), findsOneWidget);
      expect(find.byKey(const ValueKey('coins-discount')), findsOneWidget);
      expect(find.text('From your OneLocal wallet · OLW-1A2B3C4D'), findsOneWidget);
      expect(find.text('+₹200'), findsOneWidget);
      expect(find.text('Held for: Diwali sweets'), findsOneWidget);
      expect(find.text('-₹90'), findsOneWidget);
      expect(find.text('Spent: Diwali sweets'), findsOneWidget);
    });

    testWidgets('add ad credits: what the OneLocal wallet can give, the amount, and the move off the next settlement', (t) async {
      final f = Fake();
      await show(t, TopUpScreen(api: f.api, home: _home()));
      expect(textOf(t, 'topup-free'), '₹2,800', reason: '₹3,000 not settled less ₹200 owed to OneLocal');
      await t.enterText(find.byKey(const ValueKey('topup-amount')), '50');
      await t.pump();
      await tapKey(t, 'topup-pay');
      expect(f.calls('ads_wallet_move'), isEmpty, reason: 'at least ₹100');
      await t.enterText(find.byKey(const ValueKey('topup-amount')), '5000');
      await t.pump();
      await tapKey(t, 'topup-pay');
      expect(f.calls('ads_wallet_move'), isEmpty, reason: 'more than the wallet can give');
      expect(find.textContaining('Only ₹2,800 can be moved'), findsOneWidget);
      await tapKey(t, 'topup-quick-1000');
      expect(textOf(t, 'topup-free'), '₹2,800');
      await tapKey(t, 'topup-pay');
      expect(f.body('ads_wallet_move'), {'amount_minor': 100000});
      expect(f.calls('ads_wallet_move').single.headers['Idempotency-Key'], isNotEmpty);
      expect(find.text('₹1,000 added to ad credits'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('next weekly OneLocal settlement')), findsOneWidget);
      await tapKey(t, 'topup-ok');
      expect(find.byType(TopUpScreen), findsNothing);
    });
  });
}
