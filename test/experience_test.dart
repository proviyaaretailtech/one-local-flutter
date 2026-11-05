// Guest experience builder (spec specs/guest-experience-builder): the restaurant edits its branded guest page and publishes it. The
// screen loads gx_builder_get, saves every edit as the draft with the version it saw, shows the three publish outcomes in plain words,
// and offers Roll back only on an approved version that is not the live one. Spec part 2 (contract D): Create with AI fills the draft
// (never publishes), Import menu reads a pasted menu and adds the dishes the owner keeps through quick add, the stock switches and the
// offers card.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/experience/experience_api.dart';
import 'package:vinii_pos/experience/experience_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/restaurant/rst_page_manager.dart';
import 'package:vinii_pos/experience/experience_import.dart';
import 'package:vinii_pos/storefront/growth_screens.dart' show OfferEditScreen;
import 'package:vinii_pos/storefront/menu_link_screen.dart';
import 'package:vinii_pos/storefront/storefront_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> block(String type, Map<String, dynamic> props, {bool enabled = true}) => {'id': type, 'type': type, 'enabled': enabled, 'props': props};

/// Shaped like gx__default('bistro_dark') after gx__clean (migration 0654).
Map<String, dynamic> draftJson() => {
      'look': 'bistro_dark',
      'theme': {...gxLooks['bistro_dark']!},
      'blocks': [
        block('welcome', {'headline': 'Food looks better when you explore it.', 'subtext': 'Swipe through dishes, set a budget, and order together.', 'image_id': null, 'cta_label': 'Start exploring'}),
        block('order_mode', {'dine_in': true, 'pre_order': false, 'dine_in_label': 'Dine-in', 'pre_order_label': 'Pre-order'}),
        block('budget', {'min': 500, 'max': 20000, 'default': 2000, 'split': true}),
        block('categories', {'style': 'grid'}),
        block('swipe', {'card_style': 'stack', 'budget_ring': true}),
        block('highlights', {'picks_title': "Chef's picks", 'pick_ids': [], 'limited_title': 'Limited today', 'limited_ids': [], 'limited_until': null}, enabled: false),
        block('preorder', {'days_ahead': 5, 'slot_minutes': 30, 'opens': '09:00', 'closes': '21:00', 'lead_minutes': 30, 'note_hint': null}, enabled: false),
        block('tracking', {'show_eta': true}),
        block('bill', {'split': true, 'feedback': true}),
      ],
    };

Map<String, dynamic> version(int n, String status, {String summary = '1 look and layout change(s).', String? reviewNote, String? ask, List<String> categories = const [], List<Map<String, dynamic>>? changes}) => {
      'id': 'v$n',
      'version': n,
      'status': status,
      'risk': status == 'pending_human' ? 'high' : 'low',
      'categories': categories,
      'summary': summary,
      'ai_note': null,
      'review_note': reviewNote,
      'ask_message': ask,
      'source': 'publish',
      'rollback_of': null,
      'submitted_at': '2026-11-0${n}T10:30:00',
      'decided_at': null,
      'decided_kind': 'rules',
      'decided_by_name': null,
      'change_count': changes?.length ?? 1,
      'changes': ?changes,
    };

Map<String, dynamic> builderJson({bool canPublish = true, Map<String, dynamic>? pending, Map<String, dynamic>? lastDecision, List<Map<String, dynamic>>? history, List<String> blockers = const []}) => {
      'draft': draftJson(),
      'draft_version': 3,
      'has_unpublished': true,
      'live_version': 2,
      'live': draftJson(),
      'pending': pending,
      'last_decision': lastDecision,
      'history': history ?? [version(2, 'auto_approved'), version(1, 'auto_approved')],
      'business': {'name': 'Niks Cafe', 'store_link': 'niks-cafe', 'path': '/niks-cafe'},
      'blockers': blockers,
      'can_publish': canPublish,
      'dishes': [
        {'id': 'd1', 'name': 'Penne Arrabbiata', 'price': 260, 'image_url': null},
        {'id': 'd2', 'name': 'Paneer Tikka', 'price': 280, 'image_url': null},
      ],
    };

const highChange = {'path': 'blocks.welcome.headline', 'label': 'Welcome: headline', 'from': 'Food looks better when you explore it.', 'to': '50% OFF today', 'risk': 'high', 'category': 'money', 'why': 'mentions a price or an offer'};

/// The draft as gx_ai_create answers it (the server laid the AI's page over the draft and saved it with gx_draft_save).
Map<String, dynamic> aiDraftJson() {
  final d = draftJson();
  return {
    ...d,
    'look': 'bakery_warm',
    'theme': {...gxLooks['bakery_warm']!},
    'blocks': [
      for (final b in d['blocks'] as List)
        if ((b as Map)['type'] == 'welcome')
          block('welcome', {'headline': 'Slow coffee, warm bakes.', 'subtext': 'Pick a dish and take your time.', 'image_id': null, 'cta_label': 'See the menu'})
        else if (b['type'] == 'highlights')
          block('highlights', {'picks_title': 'Our favourites', 'pick_ids': ['d2'], 'limited_title': 'Limited today', 'limited_ids': [], 'limited_until': null})
        else
          b,
    ],
  };
}

const aiNoteText = "AI filled your look and colours, welcome words and chef's picks. Nothing is live yet: review the preview and press Publish.";

/// rst_menu as the local database answers it: every dish with its stock state (in and out of stock).
Map<String, dynamic> menuJson({bool canEdit = true}) => {
      'can_edit': canEdit,
      'location': {'id': 'loc1', 'name': 'Main'},
      'categories': [
        {
          'id': 'c1',
          'name': 'Mains',
          'count': 2,
          'items': [
            {'id': 'd1', 'name': 'Penne Arrabbiata', 'price_minor': 26000, 'food_type': 'veg', 'image_url': null, 'in_stock': true},
            {'id': 'd2', 'name': 'Paneer Tikka', 'price_minor': 28000, 'food_type': 'veg', 'image_url': null, 'in_stock': true},
          ],
        },
        {
          'id': 'c2',
          'name': 'Desserts',
          'count': 1,
          'items': [
            {'id': 'd3', 'name': 'Brownie Pancake', 'price_minor': 34000, 'food_type': 'egg', 'image_url': null, 'in_stock': false},
          ],
        },
      ],
    };

/// Fake server: records each request, answers from [handler] first, then like the local database would.
class FakeGx {
  FakeGx({Map<String, dynamic>? builder, this.handler, this.publishResult = 'auto_approved'}) : builder = builder ?? builderJson();
  Map<String, dynamic> builder;
  final http.Response? Function(http.Request r)? handler;
  final String publishResult;
  final requests = <http.Request>[];

  /// A call named here waits until its completer completes (to see a busy state).
  final holds = <String, Completer<void>>{};

  /// The menu's categories (menu_category_save adds to it).
  final categories = <Map<String, dynamic>>[
    {'id': 'c1', 'name': 'Hot Beverages', 'parent_id': null, 'sort_order': 0, 'dishes': 2},
  ];

  late final client = MockClient((r) async {
    requests.add(r);
    if (r.method == 'PUT') return http.Response('', 200);
    final hold = holds[fnOf(r)];
    if (hold != null) await hold.future;
    final custom = handler?.call(r);
    if (custom != null) return custom;
    final a = argsOf(r);
    switch (fnOf(r)) {
      case 'gx_ai_create':
        builder = {...builder, 'draft': aiDraftJson(), 'draft_version': (builder['draft_version'] as int) + 1, 'has_unpublished': true};
        return ok({...builder, 'ai_note': aiNoteText, 'ai_filled': ['look and colours', 'welcome words', "chef's picks"]});
      case 'menu_ai_import':
        return ok({
          'dishes': [
            {'name': 'Cold Coffee', 'category': 'Beverages', 'price': 120, 'veg': true, 'description': null},
            {'name': 'Chicken Burger', 'category': 'Burgers', 'price': 180, 'veg': false, 'description': null},
            {'name': 'Masala Chai', 'category': 'hot beverages', 'price': 40, 'veg': null, 'description': null},
            {'name': 'Brownie', 'category': 'Desserts', 'price': 150, 'veg': true, 'description': null},
          ],
          'dropped': 1,
          'model': 'openai/gpt-oss-20b',
        });
      case 'menu_category_list':
        return ok({'can_edit': true, 'categories': categories});
      case 'menu_category_save':
        categories.add({'id': 'c${categories.length + 1}', 'name': a['name'], 'parent_id': null, 'sort_order': categories.length, 'dishes': 0});
        return ok({'can_edit': true, 'categories': categories});
      case 'menu_item_quick_add':
        if (a['name'] == 'Chicken Burger') return err(409, 'Chicken Burger is already in this category.', 'conflict');
        return ok({'id': 'new-${a['name']}', 'name': a['name'], 'version': 1, 'price_minor': ((a['price'] as num) * 100).round()});
      case 'rst_menu':
        return ok(menuJson());
      case 'rst_menu_stock_set':
        if (a['id'] == 'd3') return err(403, 'Your role cannot change the menu.', 'forbidden');
        return ok({'updated': 1, 'in_stock': a['in_stock'], 'drafts_skipped': 0});
      case 'sf_offer_list':
        return ok({
          'offers': [
            {'id': 'o1', 'title': 'Weekend coffee', 'message': 'Coffee with every pancake', 'phase': 'live', 'editable': true, 'product_ids': [], 'show_on_storefront': true},
            {'id': 'o2', 'title': 'Diwali week', 'message': null, 'phase': 'ended', 'editable': true, 'product_ids': []},
          ],
        });
      case 'pos_coupon_list':
        return ok({
          'coupons': [
            {'code': 'WELCOME10', 'kind': 'percent', 'value': 10, 'min_order': 200, 'active': true, 'ends_at': null, 'label': null},
            {'code': 'OLD50', 'kind': 'flat', 'value': 50, 'active': false, 'ends_at': null},
            {'code': 'GONE', 'kind': 'flat', 'value': 30, 'active': true, 'ends_at': '2026-10-01T00:00:00Z'},
          ],
        });
      case 'gx_builder_get':
        return ok(builder);
      case 'gx_draft_save':
        builder = {...builder, 'draft': a['definition'], 'draft_version': (builder['draft_version'] as int) + 1, 'has_unpublished': true};
        return ok(builder);
      case 'gx_publish':
        final v = version(4, publishResult, summary: publishResult == 'pending_human' ? 'Held for review: Welcome: headline mentions a price or an offer ("50% OFF today").' : 'New wording in Welcome: headline.',
            categories: publishResult == 'pending_human' ? ['money'] : [], changes: [publishResult == 'pending_human' ? highChange : {...highChange, 'to': 'Fresh bakes daily', 'risk': 'ai', 'why': null}]);
        builder = {...builder, 'has_unpublished': false, if (publishResult == 'pending_human' || publishResult == 'pending_ai') 'pending': v};
        return ok({'result': publishResult, 'version': v, 'path': '/niks-cafe', 'builder': builder});
      case 'gx_rollback':
        builder = {...builder, 'live_version': 5, 'has_unpublished': false};
        return ok({'result': 'auto_approved', 'version': {...version(5, 'auto_approved'), 'source': 'rollback', 'rollback_of': a['version']}, 'builder': builder});
      case 'sf_image_library':
        return ok({'images': [{'id': 'img1', 'kind': 'banner', 'image_url': null}]});
      case 'storefront_image_slot':
        return ok({'path': 'org/sf-banner/x.png', 'upload_url': 'http://storage.test/up'});
      case 'storefront_image_attach':
        return ok({'id': 'img-new', 'kind': 'banner', 'image_url': null});
      case 'sf_settings_get':
        return ok({'profile': {'public_name': 'Niks Cafe', 'store_slug': 'niks-cafe'}, 'hours': {'configured': false}, 'delivery': {'configured': false}});
      case 'sf_builder_get':
        return ok({'published_version': 1, 'has_unpublished_changes': false});
      case 'menu_link_get':
        return ok({'live': true, 'path': '/m/niks-cafe', 'blockers': []});
    }
    return err(404, 'not found: ${fnOf(r)}');
  });
  late final rpc = RpcClient(baseUrl: 'http://gx.test', accessToken: () => 'tok', client: client);
  late final api = ExperienceApi(rpc: rpc);
  late final storefront = StorefrontApi(rpc: rpc, client: client);

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Map<String, dynamic> last(String fn) => argsOf(calls(fn).last);
}

void main() {
  tearDown(HomeNav.reset);

  Future<List<Uri>> show(WidgetTester t, FakeGx g, {MenuFilePicker? pickFile}) async {
    ignoreOverflow();
    t.view.physicalSize = const Size(780, 16000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final opened = <Uri>[];
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: ExperienceScreen(api: g.api, storefront: g.storefront, linkBase: 'https://g.test', onOpen: (u) async => opened.add(u), pickMenuFile: pickFile, today: DateTime(2026, 11, 5)),
    ));
    await t.pumpAndSettle();
    return opened;
  }

  group('ExperienceApi', () {
    test('sends the draft with the version seen to /rpc/gx_draft_save', () async {
      final g = FakeGx();
      final b = await g.api.saveDraft(3, {'look': 'custom'});
      final r = g.requests.single;
      expect(r.url.toString(), 'http://gx.test/rpc/gx_draft_save');
      expect(r.headers['Authorization'], 'Bearer tok');
      expect(argsOf(r), {'expected_draft_version': 3, 'definition': {'look': 'custom'}});
      expect(b.n('draft_version'), 4);
    });

    test('a stale draft is an ExperienceException with stale = true; a refused page keeps the server sentence', () async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_draft_save' ? err(409, 'The page was changed on another device.', 'version_conflict') : null);
      await expectLater(g.api.saveDraft(0, {}), throwsA(isA<ExperienceException>().having((e) => e.stale, 'stale', true)));
      final h = FakeGx(handler: (r) => err(400, 'The headline can be up to 60 characters.', 'bad_request'));
      await expectLater(h.api.saveDraft(0, {}), throwsA(isA<ExperienceException>().having((e) => e.stale, 'stale', false).having((e) => e.message, 'message', 'The headline can be up to 60 characters.')));
    });

    test('the link is the guest web base and the store path', () {
      expect(ExperienceApi.urlFor('/niks-cafe', base: 'https://onelocal.co/'), 'https://onelocal.co/niks-cafe');
    });
  });

  group('builder', () {
    testWidgets('loads and renders every block in order: locks on the five the page needs, switches on the rest', (t) async {
      final g = FakeGx();
      await show(t, g);
      expect(g.calls('gx_builder_get').length, 1);
      expect(g.calls('sf_image_library').length, 1, reason: 'the welcome picture comes from the storefront library');
      final types = ['welcome', 'order_mode', 'budget', 'categories', 'swipe', 'highlights', 'preorder', 'tracking', 'bill'];
      final tops = [for (final ty in types) t.getTopLeft(find.byKey(ValueKey('gx-block-$ty'))).dy];
      expect(tops, [...tops]..sort(), reason: 'in the draft order');
      for (final ty in ['welcome', 'order_mode', 'swipe', 'tracking', 'bill']) {
        expect(find.byKey(ValueKey('gx-lock-$ty')), findsOneWidget, reason: ty);
        expect(find.byKey(ValueKey('gx-switch-$ty')), findsNothing, reason: ty);
      }
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-switch-budget'))).value, isTrue);
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-switch-highlights'))).value, isFalse);
      // the preview shows the draft's welcome screen and a dish from the menu
      expect(t.widget<Text>(find.byKey(const ValueKey('gx-preview-headline'))).data, 'Food looks better when you explore it.');
      expect(find.descendant(of: find.byKey(const ValueKey('gx-preview')), matching: find.text('Penne Arrabbiata')), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-link-live')), findsOneWidget);
      expect(find.text('https://g.test/niks-cafe'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('gx-status'))).data, 'Draft');
      expect(find.byKey(const ValueKey('gx-rules')), findsOneWidget);
    });

    testWidgets('a switch saves the whole draft with the version seen', (t) async {
      final g = FakeGx();
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-switch-highlights')));
      await t.pumpAndSettle();
      final a = g.last('gx_draft_save');
      expect(a['expected_draft_version'], 3);
      final blocks = (a['definition']['blocks'] as List).cast<Map<String, dynamic>>();
      expect(blocks.firstWhere((b) => b['type'] == 'highlights')['enabled'], isTrue);
      expect(blocks.length, 9);
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-switch-highlights'))).value, isTrue);
    });

    testWidgets('choosing a look fills its colours', (t) async {
      final g = FakeGx();
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-look-bakery_warm')));
      await t.pumpAndSettle();
      final a = g.last('gx_draft_save')['definition'] as Map<String, dynamic>;
      expect(a['look'], 'bakery_warm');
      expect(a['theme'], {'background': '#F6F1EA', 'surface': '#FFFFFF', 'text': '#2B1D14', 'muted': '#8A7766', 'accent': '#2B1D14', 'accent_text': '#FFFFFF', 'font': 'serif'});
    });

    testWidgets('editing the welcome screen: markup is refused here, the new headline is saved and shows in the preview', (t) async {
      final g = FakeGx();
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-block-welcome')));
      await t.pumpAndSettle();
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('gx-headline')), matching: find.byType(TextField)), 'Fresh <b>bakes</b>');
      await t.pumpAndSettle();
      expect(find.text('The headline cannot contain < or >.'), findsOneWidget);
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('gx-headline')), matching: find.byType(TextField)), 'Fresh bakes daily');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('gx-sheet-save')));
      await t.pumpAndSettle();
      final w = ((g.last('gx_draft_save')['definition']['blocks'] as List).first as Map)['props'] as Map;
      expect(w['headline'], 'Fresh bakes daily');
      expect(w['cta_label'], 'Start exploring');
      expect(t.widget<Text>(find.byKey(const ValueKey('gx-preview-headline'))).data, 'Fresh bakes daily');
    });

    testWidgets('a draft changed on another device reloads and says so', (t) async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_draft_save' ? err(409, 'The page was changed on another device.', 'version_conflict') : null);
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-switch-budget')));
      await t.pumpAndSettle();
      expect(g.calls('gx_builder_get').length, 2);
      expect(find.text('This page was changed on another device. It has been reloaded; please make your change again.'), findsOneWidget);
    });
  });

  group('publish', () {
    Future<void> publish(WidgetTester t, FakeGx g) async {
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-publish')));
      await t.pumpAndSettle();
      expect(g.last('gx_publish'), {'expected_draft_version': 3});
    }

    testWidgets('auto approved: Live now with the link', (t) async {
      final g = FakeGx();
      await publish(t, g);
      expect(find.byKey(const ValueKey('gx-outcome-live')), findsOneWidget);
      expect(find.text('Live now'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-outcome-link')), findsOneWidget);
      expect(t.widget<SelectableText>(find.byKey(const ValueKey('gx-outcome-link'))).data, 'https://g.test/niks-cafe');
      await t.tap(find.byKey(const ValueKey('gx-outcome-ok')));
      await t.pumpAndSettle();
      expect(find.text('Up to date'), findsOneWidget, reason: 'the builder answer that came with the publish');
    });

    testWidgets('pending AI: Checking wording, no link yet', (t) async {
      final g = FakeGx(publishResult: 'pending_ai');
      await publish(t, g);
      expect(find.byKey(const ValueKey('gx-outcome-checking')), findsOneWidget);
      expect(find.text('Checking wording…'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-outcome-link')), findsNothing);
      await t.tap(find.byKey(const ValueKey('gx-outcome-ok')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gx-banner-checking')), findsOneWidget);
    });

    testWidgets('pending human: sent to OneLocal with the summary, the category and each change', (t) async {
      final g = FakeGx(publishResult: 'pending_human');
      await publish(t, g);
      expect(find.byKey(const ValueKey('gx-outcome-review')), findsOneWidget);
      expect(find.text('Sent to OneLocal for review'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('gx-outcome-summary'))).data, 'Held for review: Welcome: headline mentions a price or an offer ("50% OFF today").');
      expect(find.byKey(const ValueKey('gx-category-money')), findsOneWidget);
      expect(find.text('Money'), findsOneWidget);
      expect(find.text('Welcome: headline'), findsOneWidget);
      expect(find.text('Food looks better when you explore it.  →  50% OFF today'), findsOneWidget);
      expect(find.text('mentions a price or an offer'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gx-outcome-ok')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gx-banner-waiting')), findsOneWidget);
    });

    testWidgets('an AI-flagged publish answers the version without changes: they come from pending', (t) async {
      final held = version(4, 'pending_human', summary: 'Held: the AI reviewer flagged the wording.', categories: ['content'], changes: [highChange]);
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_publish'
          ? ok({'result': 'pending_human', 'version': {...held}..remove('changes'), 'path': '/niks-cafe', 'builder': builderJson(pending: held)})
          : null);
      await publish(t, g);
      expect(find.byKey(const ValueKey('gx-outcome-review')), findsOneWidget);
      expect(find.text('Food looks better when you explore it.  →  50% OFF today'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-category-content')), findsOneWidget);
    });

    testWidgets('nothing to publish: the server sentence', (t) async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_publish' ? err(409, 'The guest page already looks like this.', 'nothing_to_publish') : null);
      await publish(t, g);
      expect(find.text('The guest page already looks like this.'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-outcome-live')), findsNothing);
    });

    testWidgets('a role that cannot publish: the button is off and says why', (t) async {
      final g = FakeGx(builder: builderJson(canPublish: false));
      await show(t, g);
      expect(find.byKey(const ValueKey('gx-no-publish')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gx-publish')));
      await t.pumpAndSettle();
      expect(g.calls('gx_publish'), isEmpty);
      expect(find.byKey(const ValueKey('gx-rollback-1')), findsNothing);
    });
  });

  group('banner and history', () {
    testWidgets('OneLocal asked a question: the question shows at the top', (t) async {
      final p = version(4, 'pending_human', ask: 'Is the 50% off for every guest?');
      await show(t, FakeGx(builder: builderJson(pending: p, lastDecision: p)));
      expect(find.byKey(const ValueKey('gx-banner-ask')), findsOneWidget);
      expect(find.text('Is the 50% off for every guest?'), findsOneWidget);
    });

    testWidgets('OneLocal did not approve: the reason shows at the top', (t) async {
      final d = version(4, 'rejected', reviewNote: 'Offers need a start and end date.');
      await show(t, FakeGx(builder: builderJson(lastDecision: d, history: [d, version(2, 'auto_approved')])));
      expect(find.byKey(const ValueKey('gx-banner-rejected')), findsOneWidget);
      expect(find.text('Offers need a start and end date.'), findsOneWidget);
    });

    testWidgets('Roll back only on approved versions that are not live; it asks, then brings the version back', (t) async {
      final g = FakeGx(
        builder: builderJson(history: [
          version(6, 'pending_human'),
          version(5, 'rejected', reviewNote: 'No.'),
          version(4, 'superseded'),
          version(3, 'human_approved'),
          version(2, 'auto_approved'),
          version(1, 'ai_approved'),
        ]),
      );
      await show(t, g);
      for (final n in [1, 3]) {
        expect(find.byKey(ValueKey('gx-rollback-$n')), findsOneWidget, reason: 'v$n was approved and is not live');
      }
      for (final n in [2, 4, 5, 6]) {
        expect(find.byKey(ValueKey('gx-rollback-$n')), findsNothing, reason: 'v$n is live, replaced, refused or waiting');
      }
      expect(find.descendant(of: find.byKey(const ValueKey('gx-history-2')), matching: find.byKey(const ValueKey('gx-history-live'))), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gx-rollback-1')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gx-rollback-dialog')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gx-rollback-confirm')));
      await t.pumpAndSettle();
      expect(g.last('gx_rollback'), {'version': 1});
      expect(find.byKey(const ValueKey('gx-outcome-live')), findsOneWidget);
    });

    testWidgets('a page that is not open to guests says why, with the menu link wording', (t) async {
      await show(t, FakeGx(builder: builderJson(blockers: ['not_approved'])));
      expect(find.byKey(const ValueKey('gx-link-off')), findsOneWidget);
      expect(find.text(menuLinkReasons['not_approved']!), findsOneWidget);
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('gx-link-open'))).onPressed, isNull);
    });
  });

  Finder field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField));
  Text textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key)));

  group('Create with AI', () {
    testWidgets('sends the style line, shows progress, then the preview shows the filled draft and the note; it never publishes', (t) async {
      final g = FakeGx()..holds['gx_ai_create'] = Completer<void>();
      await show(t, g);
      await t.enterText(field('gx-ai-style'), '  warm bakery,   rustic ');
      await t.tap(find.byKey(const ValueKey('gx-ai-create')));
      await t.pump();
      expect(find.byKey(const ValueKey('gx-ai-busy')), findsOneWidget);
      expect(find.text('Reading your menu and filling the page…'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-publish')).hitTestable(), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gx-publish')));
      await t.pump();
      expect(g.calls('gx_publish'), isEmpty, reason: 'publish waits while the AI works');
      g.holds['gx_ai_create']!.complete();
      await t.pumpAndSettle();
      expect(g.last('gx_ai_create'), {'style': 'warm bakery, rustic'});
      expect(find.byKey(const ValueKey('gx-ai-busy')), findsNothing);
      expect(textOf(t, 'gx-preview-headline').data, 'Slow coffee, warm bakes.');
      expect(find.descendant(of: find.byKey(const ValueKey('gx-preview-cta')), matching: find.text('See the menu')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('gx-preview')), matching: find.text('Paneer Tikka')), findsOneWidget, reason: 'the AI\'s pick is the sample dish');
      expect(find.text('AI filled your page — review and Publish'), findsOneWidget);
      expect(textOf(t, 'gx-ai-note-text').data, aiNoteText);
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-switch-highlights'))).value, isTrue);
      expect(textOf(t, 'gx-status').data, 'Draft');
      expect(g.calls('gx_publish'), isEmpty, reason: 'Create with AI never publishes');
      expect(g.calls('gx_draft_save'), isEmpty, reason: 'the server saved the draft itself');
    });

    testWidgets('Undo brings back the page as it was before AI', (t) async {
      final g = FakeGx();
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-ai-create')));
      await t.pumpAndSettle();
      expect(g.last('gx_ai_create'), <String, dynamic>{}, reason: 'no style line: nothing extra is sent');
      await t.tap(find.byKey(const ValueKey('gx-ai-undo')));
      await t.pumpAndSettle();
      final saved = g.last('gx_draft_save');
      expect(saved['expected_draft_version'], 4);
      expect(saved['definition'], draftJson());
      expect(textOf(t, 'gx-preview-headline').data, 'Food looks better when you explore it.');
      expect(find.byKey(const ValueKey('gx-ai-note')), findsNothing);
      expect(find.text('Your page is back as it was before AI.'), findsOneWidget);
    });

    testWidgets('AI unavailable: the server sentence shows and nothing changes', (t) async {
      const down = 'AI could not fill your page right now. Try again in a minute, or edit it yourself.';
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_ai_create' ? err(503, down, 'ai_unavailable') : null);
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-ai-create')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gx-ai-error')), findsOneWidget);
      expect(find.text(down), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-ai-note')), findsNothing);
      expect(textOf(t, 'gx-preview-headline').data, 'Food looks better when you explore it.');
      expect(g.calls('gx_builder_get').length, 1);
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-switch-highlights'))).value, isFalse);
    });

    testWidgets('the page changed on another device: it reloads and says so', (t) async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'gx_ai_create' ? err(409, 'The page was changed on another device.', 'version_conflict') : null);
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-ai-create')));
      await t.pumpAndSettle();
      expect(g.calls('gx_builder_get').length, 2);
      expect(find.text('This page was changed on another device. It has been reloaded; try Create with AI again.'), findsOneWidget);
    });

    testWidgets("the preview's sample dish is one with a real photo", (t) async {
      final b = builderJson();
      b['dishes'] = [
        {'id': 'd1', 'name': 'Penne Arrabbiata', 'price': 260, 'image_url': null},
        {'id': 'd2', 'name': 'Paneer Tikka', 'price': 280, 'image_url': 'http://img.test/paneer.jpg'},
      ];
      await show(t, FakeGx(builder: b));
      final preview = find.byKey(const ValueKey('gx-preview'));
      expect(find.descendant(of: preview, matching: find.text('Paneer Tikka')), findsOneWidget);
      expect(
        find.descendant(of: preview, matching: find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage && (w.image as NetworkImage).url == 'http://img.test/paneer.jpg')),
        findsOneWidget,
      );
    });
  });

  group('Import menu', () {
    Future<void> openImport(WidgetTester t, FakeGx g, {MenuFilePicker? pickFile}) async {
      await show(t, g, pickFile: pickFile);
      await t.tap(find.byKey(const ValueKey('gx-import')));
      await t.pumpAndSettle();
      expect(find.byType(GxImportScreen), findsOneWidget);
    }

    testWidgets('paste, Read with AI, review and edit, then Add calls quick add per dish (missing categories first) with per-dish errors', (t) async {
      final g = FakeGx();
      await openImport(t, g);
      await t.tap(find.byKey(const ValueKey('gx-import-read')));
      await t.pump();
      expect(g.calls('menu_ai_import'), isEmpty, reason: 'a few characters are not a menu');
      const menu = 'Beverages\nCold Coffee 120\nBurgers\nChicken Burger 180\nMasala Chai 40\nBrownie 150';
      await t.enterText(field('gx-import-text'), menu);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('gx-import-read')));
      await t.pumpAndSettle();
      expect(g.last('menu_ai_import'), {'text': menu});
      expect(find.text('4 dishes found. Check each one; untick any you do not want.'), findsOneWidget);
      expect(find.text('Check veg'), findsOneWidget, reason: 'Masala Chai: the menu did not say');
      expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('gx-import-food-1-non_veg'))).selected, isTrue);
      // the owner fixes a price, marks the chai as egg-free veg (already), unticks the brownie
      await t.enterText(find.byKey(const ValueKey('gx-import-price-1')), '199');
      await t.tap(find.byKey(const ValueKey('gx-import-include-3')));
      await t.pump();
      expect(find.text('Add 3 dishes'), findsOneWidget);
      expect(g.calls('menu_item_quick_add'), isEmpty, reason: 'nothing is saved before Add');

      await t.tap(find.byKey(const ValueKey('gx-import-add')));
      await t.pumpAndSettle();
      expect(g.calls('menu_category_list').length, 1);
      expect([for (final r in g.calls('menu_category_save')) argsOf(r)['name']], ['Beverages', 'Burgers'], reason: '"hot beverages" is already on the menu');
      expect([for (final r in g.calls('menu_item_quick_add')) argsOf(r)], [
        {'name': 'Cold Coffee', 'category': 'Beverages', 'price': 120.0, 'food_type': 'veg', 'course': 'eat'},
        {'name': 'Chicken Burger', 'category': 'Burgers', 'price': 199.0, 'food_type': 'non_veg', 'course': 'eat'},
        {'name': 'Masala Chai', 'category': 'Hot Beverages', 'price': 40.0, 'food_type': 'veg', 'course': 'eat'},
      ], reason: 'one by one, as edited; the unticked brownie is not sent');
      expect(find.byKey(const ValueKey('gx-import-added-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-import-added-2')), findsOneWidget);
      expect(textOf(t, 'gx-import-error-1').data, 'Chicken Burger is already in this category.');
      expect(textOf(t, 'gx-import-summary').data, '2 added, 1 not added. Fix them and add again, or untick them.');
      expect(find.byType(GxImportScreen), findsOneWidget, reason: 'stays open while a dish failed');

      // fixed and added again: only that dish is sent; then the screen closes and the builder reads the menu again
      await t.enterText(find.byKey(const ValueKey('gx-import-name-1')), 'Chicken Burger (Spicy)');
      await t.pump();
      expect(find.text('Add 1 dish'), findsOneWidget);
      final builderReads = g.calls('gx_builder_get').length, menuReads = g.calls('rst_menu').length;
      await t.tap(find.byKey(const ValueKey('gx-import-add')));
      await t.pumpAndSettle();
      expect(g.calls('menu_item_quick_add').length, 4);
      expect(argsOf(g.calls('menu_item_quick_add').last)['name'], 'Chicken Burger (Spicy)');
      expect(g.calls('menu_category_save').length, 2, reason: 'Burgers exists now');
      expect(find.byType(GxImportScreen), findsNothing);
      expect(find.text('1 dish added to your menu.'), findsOneWidget);
      expect(g.calls('gx_builder_get').length, builderReads + 1, reason: 'the builder\'s dish list refreshes');
      expect(g.calls('rst_menu').length, menuReads + 1, reason: 'and the dishes card');
    });

    testWidgets('a .csv file fills the text; AI unavailable says so and keeps the text', (t) async {
      const down = 'AI could not read the menu right now. Try again in a minute, or add the dishes yourself.';
      final g = FakeGx(handler: (r) => fnOf(r) == 'menu_ai_import' ? err(503, down, 'ai_unavailable') : null);
      const csv = 'name,category,price\nCold Coffee,Beverages,120\nMasala Chai,Beverages,40';
      await openImport(t, g, pickFile: () async => (name: 'menu.csv', bytes: Uint8List.fromList(utf8.encode(csv))));
      await t.tap(find.byKey(const ValueKey('gx-import-file')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field('gx-import-text')).controller!.text, csv);
      await t.tap(find.byKey(const ValueKey('gx-import-read')));
      await t.pumpAndSettle();
      expect(g.last('menu_ai_import'), {'text': csv});
      expect(textOf(t, 'gx-import-error').data, down);
      expect(find.byKey(const ValueKey('gx-import-add')), findsNothing);
      expect(g.calls('menu_item_quick_add'), isEmpty);
    });
  });

  group('Dishes & stock', () {
    testWidgets('every dish with its price and an In stock switch; a switch moves at once and calls rst_menu_stock_set', (t) async {
      final g = FakeGx()..holds['rst_menu_stock_set'] = Completer<void>();
      await show(t, g);
      expect(g.calls('rst_menu').length, 1);
      expect(find.byKey(const ValueKey('gx-dish-d3')), findsOneWidget);
      expect(find.text('₹260 · Mains'), findsOneWidget);
      expect(find.text('₹340 · Desserts · Out of stock'), findsOneWidget);
      expect(textOf(t, 'gx-stock-count').data, '3 dishes · 1 out');
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d1'))).value, isTrue);
      await t.tap(find.byKey(const ValueKey('gx-stock-d1')));
      await t.pump();
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d1'))).value, isFalse, reason: 'optimistic');
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d1'))).onChanged, isNull, reason: 'one change at a time');
      g.holds['rst_menu_stock_set']!.complete();
      await t.pumpAndSettle();
      expect(g.last('rst_menu_stock_set'), {'id': 'd1', 'in_stock': false});
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d1'))).value, isFalse);
      expect(textOf(t, 'gx-stock-count').data, '3 dishes · 2 out');
    });

    testWidgets('a refused stock change moves the switch back and says why', (t) async {
      final g = FakeGx();
      await show(t, g);
      await t.tap(find.byKey(const ValueKey('gx-stock-d3')));
      await t.pumpAndSettle();
      expect(g.last('rst_menu_stock_set'), {'id': 'd3', 'in_stock': true});
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d3'))).value, isFalse);
      expect(find.text('Your role cannot change the menu.'), findsOneWidget);
    });

    testWidgets('a role that cannot change the menu sees the switches off', (t) async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'rst_menu' ? ok(menuJson(canEdit: false)) : null);
      await show(t, g);
      expect(t.widget<Switch>(find.byKey(const ValueKey('gx-stock-d1'))).onChanged, isNull);
      expect(find.byKey(const ValueKey('gx-stock-readonly')), findsOneWidget);
    });
  });

  group('Offers', () {
    testWidgets('lists live offers and active coupons, says offers show by themselves, and opens the offer editor', (t) async {
      final g = FakeGx();
      await show(t, g);
      expect(find.byKey(const ValueKey('gx-offer-o1')), findsOneWidget);
      expect(find.text('Weekend coffee'), findsOneWidget);
      expect(find.text('Coffee with every pancake'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-offer-o2')), findsNothing, reason: 'an ended offer is not shown');
      expect(find.byKey(const ValueKey('gx-coupon-WELCOME10')), findsOneWidget);
      expect(find.text('10% off · orders from ₹200'), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-coupon-OLD50')), findsNothing, reason: 'switched off');
      expect(find.byKey(const ValueKey('gx-coupon-GONE')), findsNothing, reason: 'ended');
      expect(find.textContaining('show on your guest page by themselves'), findsOneWidget);
      expect(find.textContaining('Never type an offer or a price into the welcome words'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('gx-offer-create')));
      await t.pumpAndSettle();
      expect(find.byType(OfferEditScreen), findsOneWidget);
      expect(t.widget<OfferEditScreen>(find.byType(OfferEditScreen)).offer, isNull, reason: 'a new offer');
      Navigator.of(t.element(find.byType(OfferEditScreen))).pop();
      await t.pumpAndSettle();
      expect(g.calls('sf_offer_list').length, 2, reason: 'read again after the editor closes');

      await t.tap(find.byKey(const ValueKey('gx-offer-o1')));
      await t.pumpAndSettle();
      expect(t.widget<OfferEditScreen>(find.byType(OfferEditScreen)).offer?.s('id'), 'o1');
    });

    testWidgets('a role that cannot see coupons still sees the offers', (t) async {
      final g = FakeGx(handler: (r) => fnOf(r) == 'pos_coupon_list' ? err(403, 'Your role cannot see coupons.', 'forbidden') : null);
      await show(t, g);
      expect(find.byKey(const ValueKey('gx-offer-o1')), findsOneWidget);
      expect(find.byKey(const ValueKey('gx-coupon-WELCOME10')), findsNothing);
      expect(find.text('Your role cannot see coupons.'), findsNothing);
    });
  });

  testWidgets('Page Manager has a Guest experience tile that opens the builder', (t) async {
    ignoreOverflow();
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final g = FakeGx();
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: RstPageManagerScreen(api: g.storefront, linkApi: MenuLinkApi(rpc: g.rpc), experienceApi: g.api, today: DateTime(2026, 11, 4), linkBase: 'https://g.test'),
    ));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const ValueKey('pm-guest')), 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    expect(find.text('Guest experience'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pm-guest')));
    await t.pumpAndSettle();
    expect(g.calls('gx_builder_get').length, 1);
    expect(find.text('Your guest page'), findsOneWidget);
  });
}
