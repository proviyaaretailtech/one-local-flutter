import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/storefront/builder_screen.dart';
import 'package:vinii_pos/storefront/growth_screens.dart';
import 'package:vinii_pos/storefront/publish_screens.dart';
import 'package:vinii_pos/storefront/section_editors.dart';
import 'package:vinii_pos/storefront/settings_screens.dart';
import 'package:vinii_pos/storefront/sf_widgets.dart';
import 'package:vinii_pos/storefront/storefront_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (server/scripts/storefront-fixtures.mjs, the NOICE story of the Figma frames).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/storefront_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class FakePicker extends DocumentPicker {
  const FakePicker();
  @override
  Future<PickedDocument?> pick() async => PickedDocument(name: 'a.png', bytes: Uint8List.fromList([1, 2, 3]), contentType: 'image/png');
}

/// Fake server: records each request, answers from [handler] first, then from the fixtures.
class Fake {
  Fake([this.handler, this.starter = false, this.canPublish = true]);
  final http.Response? Function(http.Request r)? handler;
  final bool starter, canPublish;
  final requests = <http.Request>[];

  Map<String, dynamic> get builder => {...(starter ? fx['builder_starter'] : fx['draft_saved']) as Map<String, dynamic>, 'can_publish': canPublish};

  late final api = StorefrontApi(
    baseUrl: 'http://sf.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      if (r.method == 'PUT') return http.Response('', 200);
      final custom = handler?.call(r);
      if (custom != null) return custom;
      return switch (fnOf(r)) {
        'sf_options' => ok(fx['options']),
        'sf_builder_get' => ok(builder),
        'sf_draft_save' => ok({...builder, 'draft_version': ((builder['draft_version'] as num?) ?? 0) + 1}),
        'sf_preview' => ok(fx['preview']),
        'sf_publish' => ok(fx['published']),
        'sf_products' => ok(argsOf(r)['filter'] == 'on_offer' ? fx['products_on_offer'] : fx['products_all']),
        'sf_product_save' => ok(fx['product_saved']),
        'sf_settings_get' => ok(fx['settings']),
        'sf_profile_save' || 'sf_hours_save' || 'sf_delivery_save' => ok(fx['settings']),
        'sf_offer_list' => ok(fx['offers']),
        'sf_offer_save' => ok(fx['offer']),
        'sf_offer_act' => ok(fx['offer']),
        'sf_ad_list' => ok(fx['ads']),
        'sf_ad_save' || 'sf_ad_act' => ok(fx['ad']),
        'sf_image_library' => ok(fx['images']),
        'storefront_image_slot' => ok({'path': 'org/sf-banner/x.png', 'upload_url': 'http://storage.test/up', 'max_bytes': 5242880}),
        'storefront_image_attach' => ok({'id': 'new-image', 'kind': 'banner', 'image_url': null}),
        _ => err(404, 'not found: ${fnOf(r)}'),
      };
    }),
  );

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Map<String, dynamic> last(String fn) => argsOf(calls(fn).last);
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4800);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).first);
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('StorefrontApi', () {
    test('sends the token and the body to /rpc/<name>', () async {
      final s = Fake();
      final b = await s.api.saveDraft(3, {'sections': []});
      final r = s.requests.single;
      expect(r.url.toString(), 'http://sf.test/rpc/sf_draft_save');
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(argsOf(r), {'expected_draft_version': 3, 'definition': {'sections': []}});
      expect(b.n('draft_version'), 2);
    });

    test('a stale draft is a StorefrontException with stale = true and the server sentence', () async {
      final s = Fake((r) => err(409, 'The page was changed on another device.', 'version_conflict'));
      await expectLater(s.api.saveDraft(0, {}), throwsA(isA<StorefrontException>().having((e) => e.stale, 'stale', true).having((e) => e.message, 'message', contains('another device'))));
    });

    test('a picture goes slot, bytes to the signed address, then confirm; the app never sends a storage key', () async {
      final s = Fake();
      final up = await s.api.uploadImage(kind: 'banner', bytes: Uint8List.fromList([1, 2, 3]), contentType: 'image/png');
      expect(s.requests.map((r) => '${r.method} ${r.url.path}').toList(), ['POST /rpc/storefront_image_slot', 'PUT /up', 'POST /rpc/storefront_image_attach']);
      expect(argsOf(s.requests.first), {'kind': 'banner', 'content_type': 'image/png', 'size': 3});
      expect(argsOf(s.requests.last)['path'], 'org/sf-banner/x.png');
      expect(up.s('id'), 'new-image');
      expect(s.requests.every((r) => !(r.headers['Authorization'] ?? '').contains('service')), true);
    });

    test('a failed upload says so and does not confirm', () async {
      final s = Fake();
      final bad = StorefrontApi(baseUrl: 'http://sf.test', accessToken: () => 't', client: MockClient((r) async => r.method == 'PUT' ? http.Response('no', 500) : ok({'path': 'p/sf-ad/a.png', 'upload_url': 'http://storage.test/up'})));
      await expectLater(bad.uploadImage(kind: 'ad', bytes: Uint8List(3), contentType: 'image/png'), throwsA(isA<StorefrontException>().having((e) => e.message, 'm', contains('did not finish'))));
      expect(s.requests, isEmpty);
    });
  });

  group('Store Page Builder', () {
    testWidgets('lists the draft sections, shows the unpublished note and the shortcuts', (t) async {
      final s = Fake();
      await show(t, StorePageBuilder(api: s.api));
      expect(find.text('Store Page Builder'), findsOneWidget);
      for (final n in ['Header', 'Banner / Slider', 'Shop by Category', 'Weekend Binge, Lowest Prices!', 'Deals']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('Add Section'), findsOneWidget);
      expect(find.textContaining('Changes saved as a draft'), findsOneWidget);
      expect(find.text('Profile · Offers · Hours · Delivery'), findsOneWidget);
      await t.tap(find.text('Profile · Offers · Hours · Delivery'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('store-settings-delivery')), findsOneWidget); // named on the link, now there
      expect(find.byKey(const ValueKey('store-settings-profile')), findsOneWidget);
      Navigator.of(t.element(find.byKey(const ValueKey('store-settings-ads')))).pop();
      await t.pumpAndSettle();
      expect(find.text('Preview Store'), findsOneWidget);
    });

    testWidgets('a brand-new business starts with a header only and no draft note', (t) async {
      await show(t, StorePageBuilder(api: Fake(null, true).api));
      expect(find.text('Header'), findsOneWidget);
      expect(find.textContaining('Changes saved as a draft'), findsNothing);
    });

    testWidgets('Add Section shows the 8 types the server offers', (t) async {
      await show(t, StorePageBuilder(api: Fake().api));
      await tapText(t, 'Add Section');
      for (final n in ['Banner / Slider', 'Category Grid', 'Product List', 'Deals / Offer Section', 'Custom Card', 'Brand Section', 'Divider', 'Ads']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('Show products in a grid or list'), findsOneWidget);
    });

    testWidgets('adding a Divider saves the draft with the version the person saw', (t) async {
      final s = Fake();
      await show(t, StorePageBuilder(api: s.api));
      await tapText(t, 'Add Section');
      await tapText(t, 'Divider');
      final a = s.last('sf_draft_save');
      expect(a['expected_draft_version'], 1);
      final secs = (a['definition']['sections'] as List);
      expect(secs.last['type'], 'divider');
      expect(secs.length, 6);
      expect(a['definition']['theme']['primary'], '#76EC00');
    });

    testWidgets('hiding a section sends enabled:false and shows Hidden', (t) async {
      final s = Fake();
      await show(t, StorePageBuilder(api: s.api));
      await t.tap(find.byTooltip('More for Banner / Slider'));
      await t.pumpAndSettle();
      await tapText(t, 'Hide from storefront');
      final secs = s.last('sf_draft_save')['definition']['sections'] as List;
      expect(secs.firstWhere((x) => x['id'] == 'ban')['enabled'], false);
    });

    testWidgets('a stale save reloads the page and tells the person to redo the change', (t) async {
      var first = true;
      final s = Fake((r) {
        if (fnOf(r) == 'sf_draft_save' && first) { first = false; return err(409, 'The page was changed on another device.', 'version_conflict'); }
        return null;
      });
      await show(t, StorePageBuilder(api: s.api));
      await tapText(t, 'Add Section');
      await tapText(t, 'Divider');
      expect(find.textContaining('changed on another device'), findsOneWidget);
      expect(s.calls('sf_builder_get').length, 2, reason: 'reloaded after the conflict');
    });

    testWidgets('a load failure shows the sentence and Try again', (t) async {
      var fail = true;
      final s = Fake((r) => fnOf(r) == 'sf_builder_get' && fail ? err(500, 'Something went wrong. Please try again.') : null);
      await show(t, StorePageBuilder(api: s.api));
      expect(find.text('Could not load the page'), findsOneWidget);
      fail = false;
      await tapText(t, 'Try again');
      expect(find.text('Banner / Slider'), findsOneWidget);
    });
  });

  group('section editors', () {
    BuilderController ctl(Fake s) {
      final c = BuilderController(s.api, picker: const FakePicker());
      return c;
    }

    testWidgets('Edit Category Grid: title, layout, columns, categories; Save returns the changed section', (t) async {
      final s = Fake();
      final c = ctl(s);
      await c.load();
      final sec = c.sections.firstWhere((x) => x.type == 'category_grid');
      Section? out;
      await show(t, Builder(builder: (ctx) => Scaffold(body: Center(child: ElevatedButton(onPressed: () async => out = await Navigator.of(ctx).push<Section>(MaterialPageRoute(builder: (_) => CategoryGridEditor(section: sec, c: c))), child: const Text('open'))))));
      await tapText(t, 'open');
      expect(find.text('Edit Category Grid'), findsOneWidget);
      expect(find.text('Best Deals'), findsOneWidget);
      expect(find.text('Indian sweets'), findsOneWidget);
      await tapText(t, 'List');
      await tapText(t, '4');
      await t.tap(find.byTooltip('Remove Indian sweets'));
      await t.pumpAndSettle();
      await tapText(t, 'Save');
      expect(out!.config['layout'], 'list');
      expect(out!.config['columns'], 4);
      expect((out!.config['categories'] as List).length, 1);
    });

    testWidgets('Add Category needs a name, counts characters and returns id, name and picture', (t) async {
      final s = Fake();
      final c = ctl(s);
      await c.load();
      Map<String, dynamic>? out;
      await show(t, Builder(builder: (ctx) => Scaffold(body: Center(child: ElevatedButton(onPressed: () async => out = await Navigator.of(ctx).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => CategoryEditScreen(c: c))), child: const Text('open'))))));
      await tapText(t, 'open');
      expect(find.text('Add Category'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'Best Deals');
      await t.pumpAndSettle();
      expect(find.text('10/30'), findsOneWidget);
      await tapText(t, 'Save');
      expect(out!['name'], 'Best Deals');
      expect(out!['image_id'], isNull);
    });

    testWidgets('Edit Banner: a picture is required, the link to a category lists the page categories, the slide is returned', (t) async {
      final s = Fake();
      final c = ctl(s);
      await c.load();
      final sec = c.sections.firstWhere((x) => x.type == 'banner');
      Section? out;
      await show(t, Builder(builder: (ctx) => Scaffold(body: Center(child: ElevatedButton(onPressed: () async => out = await Navigator.of(ctx).push<Section>(MaterialPageRoute(builder: (_) => BannerEditor(section: sec, c: c))), child: const Text('open'))))));
      await tapText(t, 'open');
      await tapText(t, 'The NOICE Store');
      expect(find.text('Edit Banner'), findsOneWidget);
      expect(find.text('Best Deals'), findsOneWidget);
      expect(find.text('15/40'), findsOneWidget);
      expect(find.text('27/60'), findsOneWidget);
      await tapText(t, 'Save');
      await tapText(t, 'Save');
      expect((out!.config['slides'] as List).single['link_target'], 'c-best');
    });

    testWidgets('Select Products: filters, discount chips, tick two, the button says Add 2 Products and returns the ids', (t) async {
      final s = Fake();
      final c = ctl(s);
      List<String>? out;
      await show(t, Builder(builder: (ctx) => Scaffold(body: Center(child: ElevatedButton(onPressed: () async => out = await Navigator.of(ctx).push<List<String>>(MaterialPageRoute(builder: (_) => SelectProductsScreen(api: s.api, c: c, selected: const []))), child: const Text('open'))))));
      await tapText(t, 'open');
      expect(find.text('NOICE Rajasthani Aloo Bhujia'), findsOneWidget);
      expect(find.text('50% OFF'), findsOneWidget);
      await t.tap(find.byType(Checkbox).at(0));
      await t.tap(find.byType(Checkbox).at(1));
      await t.pumpAndSettle();
      expect(find.text('Add 2 Products'), findsOneWidget);
      await tapText(t, 'On Offer');
      expect(argsOf(s.requests.last)['filter'], 'on_offer');
      await tapText(t, 'Add 2 Products');
      expect(out!.length, 2);
    });

    testWidgets('Edit Product Details sends only what changed with the item version; a price above MRP shows the catalogue sentence', (t) async {
      final s = Fake((r) => fnOf(r) == 'sf_product_save' && argsOf(r)['price_minor'] == 9900 ? err(400, 'The selling price cannot be above the MRP.', 'bad_request') : null);
      final c = ctl(s);
      await c.load();
      final p = (fx['products_all']['items'] as List).first as Map<String, dynamic>;
      await show(t, ProductEditScreen(api: s.api, c: c, product: Facts(p)));
      expect(find.text('Edit Product Details'), findsOneWidget);
      expect(find.text('Show on storefront'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(2), '99');
      await t.pumpAndSettle();
      await tapText(t, 'Save Product');
      expect(find.text('The selling price cannot be above the MRP.'), findsOneWidget);
      expect(s.last('sf_product_save')['version'], p['version']);
      expect(s.last('sf_product_save').containsKey('name'), false, reason: 'unchanged fields are not sent');
    });
  });

  group('theme, preview, publish', () {
    testWidgets('Theme & Publish: bad colour blocks saving; good colours save the draft then publish and show Your page is live!', (t) async {
      final s = Fake();
      final c = BuilderController(s.api);
      await c.load();
      await show(t, ThemeScreen(api: s.api, c: c));
      expect(find.text('Theme & Publish'), findsOneWidget);
      expect(find.text('Save & Publish'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'green');
      await t.pumpAndSettle();
      expect(find.text('Use #RRGGBB'), findsOneWidget);
      await t.tap(find.text('Save & Publish'));
      await t.pumpAndSettle();
      expect(s.calls('sf_publish'), isEmpty);
      await t.enterText(find.byType(TextField).first, '#ff0000');
      await tapText(t, 'Square');
      await tapText(t, 'Save & Publish');
      expect(s.last('sf_draft_save')['definition']['theme'], {'primary': '#FF0000', 'secondary': '#0A0A0A', 'background': '#FFFFFF', 'section_style': 'square'});
      expect(s.last('sf_publish'), {'expected_version': 0, 'expected_draft_version': 2});
      expect(find.text('Your page is live!'), findsOneWidget);
      expect(find.textContaining('/m/noice-'), findsOneWidget);   // the public menu link (0571)
      expect(find.text('Copy Store Link'), findsOneWidget);
      expect(find.text('View Live Store'), findsOneWidget);
    });

    testWidgets('a person who cannot publish sees Save Theme and never calls publish', (t) async {
      final s = Fake(null, false, false);
      final c = BuilderController(s.api);
      await c.load();
      await show(t, ThemeScreen(api: s.api, c: c));
      expect(find.text('Save Theme'), findsOneWidget);
      expect(find.text('Save & Publish'), findsNothing);
    });

    testWidgets('Live Preview draws the page from the server facts: header, categories, products, discount, delivery lines', (t) async {
      final s = Fake();
      final c = BuilderController(s.api);
      await c.load();
      await show(t, PreviewScreen(api: s.api, c: c));
      expect(find.text('Live Preview'), findsOneWidget);
      expect(find.text('Best Deals'), findsWidgets);
      expect(find.text('Weekend Binge, Lowest Prices!'), findsWidgets);
      expect(find.text('50% OFF'), findsWidgets);
      expect(find.text('NOICE Rajasthani Aloo Bhujia'), findsWidgets);
      expect(find.text('Open daily · 9:00 AM – 9:00 PM'), findsOneWidget);
      expect(find.text('Delivery within 5 km · 30–45 min'), findsOneWidget);
      expect(find.text('₹30 delivery · Free above ₹499'), findsOneWidget);
      expect(find.text('Minimum order ₹99 · Store pickup available'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Publish'), findsOneWidget);
    });

    testWidgets('Publish from the preview calls sf_publish with the live version and the draft version', (t) async {
      final s = Fake();
      final c = BuilderController(s.api);
      await c.load();
      await show(t, PreviewScreen(api: s.api, c: c));
      await tapText(t, 'Publish');
      expect(s.last('sf_publish'), {'expected_version': 0, 'expected_draft_version': 1});
      expect(find.text('Your page is live!'), findsOneWidget);
    });

    testWidgets('the owner has not set up the profile: the server sentence is shown and the page stays', (t) async {
      final s = Fake((r) => fnOf(r) == 'sf_publish' ? err(409, 'Add your business name and store link in Business Profile first.', 'not_ready') : null);
      final c = BuilderController(s.api);
      await c.load();
      await show(t, PreviewScreen(api: s.api, c: c));
      await tapText(t, 'Publish');
      expect(find.textContaining('Business Profile first'), findsOneWidget);
      expect(find.text('Live Preview'), findsOneWidget);
    });

    testWidgets('a marketing manager sees the preview, a note, and Publish is off', (t) async {
      final s = Fake(null, false, false);
      final c = BuilderController(s.api);
      await c.load();
      await show(t, PreviewScreen(api: s.api, c: c));
      expect(find.textContaining('cannot publish'), findsOneWidget);
      await t.tap(find.text('Publish'));
      await t.pumpAndSettle();
      expect(s.calls('sf_publish'), isEmpty);
    });
  });

  group('settings screens', () {
    testWidgets('Business Hours: seven days, Apply to all, summary text, Save sends all seven days', (t) async {
      final s = Fake();
      await show(t, HoursScreen(api: s.api));
      expect(find.text('Business Hours'), findsOneWidget);
      for (final d in kWeekdays) {
        expect(find.text(d), findsOneWidget);
      }
      expect(find.text('Your storefront will show: Open daily · 9:00 AM – 9:00 PM.'), findsOneWidget);
      await t.tap(find.byType(Switch).at(1)); // Monday off
      await t.pumpAndSettle();
      await t.tap(find.text('Apply to all'));
      await t.pumpAndSettle();
      await tapText(t, 'Save Hours');
      final a = s.last('sf_hours_save');
      expect((a['days'] as List).length, 7);
      expect(a['show'], true);
      expect((a['days'] as List).every((d) => d['open'] == false), true, reason: 'Apply to all copies Monday');
    });

    testWidgets('Delivery Settings: rupees are sent as paise; at least one way is required', (t) async {
      final s = Fake();
      await show(t, DeliveryScreen(api: s.api));
      expect(find.text('Delivery area & charges'), findsOneWidget);
      expect(find.text('Own Delivery'), findsOneWidget);
      expect(find.text('5 km'), findsOneWidget);
      expect(find.text('30–45 minutes'), findsOneWidget);
      await tapText(t, 'Save Delivery Settings');
      final a = s.last('sf_delivery_save');
      expect(a['delivery_fee_minor'], 3000);
      expect(a['min_order_minor'], 9900);
      expect(a['free_above_minor'], 49900);
      expect(a['home_delivery'], true);
      expect(a['method'], 'own');
      expect(a['est_min_minutes'], 30);
    });

    testWidgets('Delivery Settings: with both ways off the button is disabled', (t) async {
      final s = Fake();
      await show(t, DeliveryScreen(api: s.api));
      await t.tap(find.byType(Switch).at(0));
      await t.tap(find.byType(Switch).at(1));
      await t.pumpAndSettle();
      await t.tap(find.text('Save Delivery Settings'));
      await t.pumpAndSettle();
      expect(s.calls('sf_delivery_save'), isEmpty);
    });

    testWidgets('Business Profile: prefilled from the server, a taken store link shows the sentence', (t) async {
      final s = Fake((r) => fnOf(r) == 'sf_profile_save' ? err(409, 'That store link is already taken.', 'conflict') : null);
      await show(t, ProfileScreen(api: s.api, picker: const FakePicker()));
      expect(find.text('Shop profile'), findsOneWidget);
      expect(find.text('The NOICE Store'), findsOneWidget);
      expect(find.text('${(fx['settings']['profile']['description'] as String).length}/200'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-logo')), findsOneWidget);
      await tapText(t, 'Save Profile');
      expect(find.text('That store link is already taken.'), findsOneWidget);
      expect(s.last('sf_profile_save')['store_slug'], (fx['settings']['profile']['store_slug']));
    });

    testWidgets('Business Profile as designed: category is a dropdown; the bottom link opens the store page, offers, hours, delivery and ads', (t) async {
      final s = Fake();
      await show(t, ProfileScreen(api: s.api, picker: const FakePicker()));
      expect(find.byKey(const ValueKey('profile-category')), findsOneWidget);
      expect(find.text('Snacks & Grocery'), findsWidgets); // the shop's category, chosen
      // it drops down under the box as a short list, not over the whole screen
      final field = t.getRect(find.byKey(const ValueKey('profile-category')));
      await t.ensureVisible(find.byKey(const ValueKey('profile-category')));
      await t.tap(find.byKey(const ValueKey('profile-category')));
      await t.pumpAndSettle();
      final menuItem = find.text('Dairy & Bakery').last;
      expect(menuItem, findsWidgets);
      final menu = t.getRect(find.ancestor(of: menuItem, matching: find.byType(Material)).first);
      expect(menu.height, lessThanOrEqualTo(300));
      expect(t.getRect(menuItem).top, greaterThan(t.getRect(find.byKey(const ValueKey('profile-category'))).top));
      await t.tap(menuItem);
      await t.pumpAndSettle();
      expect(field.height, greaterThan(0));
      expect(find.text('Store page · Offers & Promotions · Hours · Delivery'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('profile-more')));
      await t.tap(find.byKey(const ValueKey('profile-more')));
      await t.pumpAndSettle();
      for (final k in ['page', 'offers', 'hours', 'delivery', 'ads']) {
        expect(find.byKey(ValueKey('store-settings-$k')), findsOneWidget, reason: k);
      }
      expect(find.byKey(const ValueKey('store-settings-profile')), findsNothing); // already here
      await t.tap(find.byKey(const ValueKey('store-settings-delivery')));
      await t.pumpAndSettle();
      expect(find.byType(DeliveryScreen), findsOneWidget);
    });

    testWidgets('Business Profile: saving stays on the page (it is the first screen of Business profile)', (t) async {
      final s = Fake();
      await show(t, ProfileScreen(api: s.api, picker: const FakePicker()));
      await tapText(t, 'Save Profile');
      expect(s.calls('sf_profile_save'), hasLength(1));
      expect(find.text('Shop profile'), findsOneWidget);
    });

    testWidgets('Business Profile: changing the logo uses the setup picture handlers, then reloads', (t) async {
      final s = Fake((r) => fnOf(r) == 'partner_setup_image_slot' ? ok({'path': 'o/logo/a.png', 'upload_url': 'http://storage.test/up'}) : fnOf(r) == 'partner_setup_image_attach' ? ok({}) : null);
      await show(t, ProfileScreen(api: s.api, picker: const FakePicker()));
      await t.tap(find.byKey(const ValueKey('profile-logo')));
      await t.pumpAndSettle();
      expect(s.requests.map((r) => fnOf(r)), containsAllInOrder(['partner_setup_image_slot', 'up', 'partner_setup_image_attach']));
      expect(s.calls('sf_settings_get').length, 2);
    });
  });

  group('offers and ads', () {
    testWidgets('Offers list shows the offer with its phase; New offer opens the Figma form', (t) async {
      final s = Fake();
      await show(t, OffersScreen(api: s.api));
      expect(find.text('Weekend Binge, Lowest Prices!'), findsOneWidget);
      expect(find.text('live'), findsOneWidget);
      await tapText(t, 'New offer');
      expect(find.text('Section Title'), findsOneWidget);
      expect(find.text('Promotion Message'), findsOneWidget);
      expect(find.text('Products on Offer'), findsOneWidget);
      expect(find.text('Save Offers'), findsOneWidget);
    });

    testWidgets('Offer form: title required; saving sends the title, products and show flag', (t) async {
      final s = Fake();
      await show(t, OfferEditScreen(api: s.api));
      await t.tap(find.text('Save Offers'));
      await t.pumpAndSettle();
      expect(s.calls('sf_offer_save'), isEmpty);
      await t.enterText(find.byType(TextField).at(0), 'Diwali deals');
      await t.pumpAndSettle();
      await tapText(t, 'Save Offers');
      final a = s.last('sf_offer_save');
      expect(a['title'], 'Diwali deals');
      expect(a['product_ids'], []);
      expect(a['show_on_storefront'], true);
      expect(a.containsKey('id'), false);
    });

    testWidgets('Editing an offer sends its id and the version it was opened at', (t) async {
      final s = Fake();
      final o = (fx['offers']['offers'] as List).first as Map<String, dynamic>;
      await show(t, OfferEditScreen(api: s.api, offer: Facts(o)));
      await tapText(t, 'Save Offers');
      expect(s.last('sf_offer_save')['id'], o['id']);
      expect(s.last('sf_offer_save')['version'], o['version']);
    });

    testWidgets('Ads list shows Pending review and the budget per day', (t) async {
      final s = Fake();
      await show(t, AdsScreen(api: s.api));
      expect(find.text('The NOICE Store'), findsOneWidget);
      expect(find.text('Pending review'), findsOneWidget);
      expect(find.textContaining('₹100/day'), findsOneWidget);
    });

    testWidgets('Ad form: image and title needed; Save Ad sends paise and dates; the screen says it goes for review', (t) async {
      final s = Fake();
      await show(t, AdEditScreen(api: s.api, categories: const [], picker: const FakePicker()));
      await t.tap(find.text('Save Ad'));
      await t.pumpAndSettle();
      expect(s.calls('sf_ad_save'), isEmpty);
      final ad = (fx['ads']['ads'] as List).first as Map<String, dynamic>;
      await t.pumpWidget(const SizedBox());
      await show(t, AdEditScreen(api: s.api, ad: Facts(ad), categories: const [], picker: const FakePicker()));
      await tapText(t, 'Save Ad');
      final a = s.last('sf_ad_save');
      expect(a['daily_budget_minor'], 10000);
      expect(a['starts_on'], '2026-10-10');
      expect(a['ends_on'], '2026-10-31');
      expect(a['id'], ad['id']);
      expect(a.containsKey('status'), false, reason: 'a partner never sends a review status');
    });
  });

  group('helpers', () {
    test('hours summary', () {
      List<Map<String, dynamic>> week(bool Function(int) open) => [for (var d = 1; d <= 7; d++) {'day': d, 'open': open(d), 'opens': '09:00', 'closes': '21:00'}];
      expect(hoursSummary(week((_) => true)), 'Open daily · 9:00 AM – 9:00 PM');
      expect(hoursSummary(week((d) => d != 7)), 'Mon–Sat 9:00 AM – 9:00 PM · Sun closed');
      expect(hoursSummary(week((_) => false)), 'Closed');
    });
    test('money and times', () {
      expect(rs(3000), '₹30');
      expect(rs(9950), '₹99.50');
      expect(paise('30'), 3000);
      expect(paise(''), isNull);
      expect(clock12('00:30'), '12:30 AM');
      expect(clock12('21:00'), '9:00 PM');
      expect(rupeeText(49900), '499');
    });
    test('hex colours', () {
      expect(hexColor('#76EC00'), const Color(0xFF76EC00));
      expect(hexColor('nope'), kLine);
    });
  });
}
