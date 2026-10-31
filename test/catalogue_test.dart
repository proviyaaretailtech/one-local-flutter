import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/catalogue_format.dart';
import 'package:vinii_pos/catalogue/catalogue_screen.dart';
import 'package:vinii_pos/catalogue/grn_screens.dart';
import 'package:vinii_pos/catalogue/item_form_screen.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/catalogue/item_sheets.dart';
import 'package:vinii_pos/catalogue/quick_add_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'catalogue_fixtures.dart';
import 'helpers.dart' show toast;

const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: _json);

class Fake {
  Fake(this.handler);
  final http.Response Function(http.Request r) handler;
  final requests = <http.Request>[];
  late final api = CatalogueApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: MockClient((r) async {
    // the SKU picker's lists (not counted as the screen's own requests)
    final sku = skuFixture(r.url.path.split('/').last);
    if (sku != null) return ok(sku);
    requests.add(r);
    return handler(r);
  }));
  Iterable<http.Request> where(String method, String pathEnd) => requests.where((r) => r.method == method && r.url.path.endsWith(pathEnd));
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
}

/// The SKU picker's lists: a subcategory, LSE (fits both price types) and the units.
Map<String, dynamic>? skuFixture(String fn) => switch (fn) {
      'sku_options' => {
          'subcategories': [{'code': 'SNK', 'name': 'Snacks & Namkeen', 'category': 'Groceries', 'examples': 'Chips, namkeen'}],
          'units': [for (final u in ['G', 'KG', 'PC', 'PK']) {'code': u}],
          'brands': [{'code': 'LSE', 'name': 'Loose / Unbranded', 'kind': 'reserved', 'status': 'approved'}],
          'store_initials': 'SGS', 'lot': '3110',
        },
      'sku_variants' => {'variants': []},
      'sku_lookup' => {'found': false},
      _ => null,
    };

/// Subcategory, brand and unit: the SKU's parts.
Future<void> pickSku(WidgetTester t) async {
  for (final k in ['sku-sub', 'sku-sub-SNK', 'sku-brand', 'sku-brand-LSE', 'sku-unit-PK']) {
    await t.ensureVisible(find.byKey(ValueKey(k)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(k)));
    await t.pumpAndSettle();
  }
}

/// A 405 pt wide phone window with the real Inter and Lucide fonts, so a layout overflow here is a real overflow (no ignoreOverflow).
Future<void> phone(WidgetTester t, Widget screen, {double height = 2400}) async {
  t.view.physicalSize = Size(810, height);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });
  tearDown(HomeNav.reset);

  group('formatting', () {
    test('money is paise with Indian grouping', () {
      expect(money(4000), '₹40');
      expect(money(56), '₹0.56');
      expect(money(3000, fixed: true), '₹30.00');
      expect(money(12345678), '₹1,23,456.78');
      expect(money(-6000, fixed: true), '-₹60.00');
    });
    test('typed prices become paise; junk is refused', () {
      expect(parsePriceMinor('40'), 4000);
      expect(parsePriceMinor('₹1,234.5'), 123450);
      expect(parsePriceMinor('0.56'), 56);
      expect(parsePriceMinor(''), isNull);
      expect(parsePriceMinor('4.567'), isNull);
      expect(parsePriceMinor('-4'), isNull);
      expect(parsePriceMinor('abc'), isNull);
    });
    test('a product billed on two lines at different prices shows the average, never zero', () {
      expect(invoiceUnitMinor({'qty': 20, 'unit_price_minor': null, 'price_mixed': true, 'amount_minor': 50000}), 2500);
      expect(invoiceUnitMinor({'qty': 24, 'unit_price_minor': 3000, 'amount_minor': 72000}), 3000);
      expect(invoiceUnitMinor(null), isNull);
    });
    test('unit labels follow the Figma list rows', () {
      expect(unitShort('l'), 'L');
      expect(unitSub('l'), 'Lts');
      expect(unitSub('pc'), 'Nos');
      expect(unitShort('dozen'), 'Dz');
      expect(qty(84), '84');
      expect(qty(0.5), '0.5');
    });
  });

  group('CatalogueApi', () {
    test('list sends the token and the filters', () async {
      final s = Fake((_) => ok(catalogueList(sixItems)));
      final l = await s.api.list(q: ' coca ', category: 'Beverages', page: 2, pageSize: 6);
      final r = s.requests.single;
      expect(r.url.path, '/rpc/cat_item_list');
      expect(r.method, 'POST');
      expect(jsonDecode(r.body), {'q': 'coca', 'category': 'Beverages', 'page': 2, 'page_size': 6});
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(l.items.length, 6);
      expect(l.count('total'), 142);
      expect(l.items.first.name, 'Coca-Cola 500ml');
    });

    test('creating sends a key; changing sends the id and the version in the body', () async {
      final s = Fake((_) => ok(item('i1', 'X', 'X1', 100)));
      await s.api.save({'mode': 'quick', 'name': 'X', 'sku': 'X1', 'price_minor': 100}, key: 'cat-key-1');
      await s.api.save({'version': 3, 'name': 'Y'}, id: 'i1');
      expect(s.requests[0].url.path, '/rpc/cat_item_save');
      expect(s.requests[0].headers['Idempotency-Key'], 'cat-key-1');
      expect(s.requests[1].url.path, '/rpc/cat_item_save');
      expect(s.requests[1].headers['Idempotency-Key'], isNull);
      expect(s.body(s.requests[1]), {'version': 3, 'name': 'Y', 'id': 'i1'});
    });

    test('refusals keep their message and code', () async {
      final s = Fake((_) => err(422, 'Complete the HSN and GST rate.', 'tax_required'));
      await expectLater(s.api.save({'name': 'x'}), throwsA(isA<CatalogueApiException>().having((e) => e.taxRequired, 'tax', true).having((e) => e.message, 'message', 'Complete the HSN and GST rate.')));
    });

    test('no token means no request', () async {
      final api = CatalogueApi(baseUrl: 'http://x', accessToken: () => null, client: MockClient((_) async => throw StateError('must not call')));
      await expectLater(api.list(), throwsA(isA<Exception>()));
    });

    test('GRN calls hit the receipt id paths with versions', () async {
      final s = Fake((r) => ok(grnView()));
      await s.api.grnOpen('r1');
      await s.api.grnResolve('r1', version: 4, resolution: 'accept_claim_credit', claimRef: ' CLM-105 ', evidence: 'photos');
      await s.api.grnRequestApproval('r1', version: 5);
      await s.api.grnDecide('r1', version: 6, approve: false, note: 'again');
      expect(s.requests.map((r) => '${r.method} ${r.url.path}'), ['POST /rpc/grn_open', 'POST /rpc/grn_resolve', 'POST /rpc/grn_request_approval', 'POST /rpc/grn_decide']);
      expect(s.body(s.requests[1]), {'receipt_document_id': 'r1', 'version': 4, 'resolution': 'accept_claim_credit', 'claim_ref': 'CLM-105', 'evidence': 'photos'});
      expect(s.body(s.requests[3]), {'receipt_document_id': 'r1', 'version': 6, 'decision': 'reject', 'note': 'again'});
    });
  });

  group('Catalogue list', () {
    Fake server() => Fake((r) {
          final p = r.url.path;
          if (p.endsWith('/cat_item_list')) return ok(catalogueList(sixItems));
          if (p.endsWith('/cat_item_view')) return ok(sixItems.first);
          if (p.endsWith('/cat_item_lookup')) return jsonDecode(r.body)['code'] == 'CC500' ? ok(sixItems.first) : err(404, 'No item has that code.', 'not_found');
          if (p.endsWith('/cat_item_save')) return ok(item('n1', 'Oat', 'OAT1', 4500));
          return err(404, 'nope');
        });

    testWidgets('the list view shows counts, chips, rows with price and stock, and the pager', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api));
      expect(find.text('Catalogue'), findsWidgets);   // the page title, and the banner's until the outlet is known
      expect(find.text('142 items'), findsOneWidget);
      // no count cards on Products (stock numbers live in Item → Stock)
      for (final k in ['Active Items', 'Out of Stock', 'Inactive Items', 'Combos', 'Drafts', 'Food products']) {
        expect(find.text(k), findsNothing, reason: k);
      }
      for (final c in ['All', 'Beverages', 'Dairy', 'Snacks', 'Staples']) {
        expect(find.text(c), findsOneWidget);
      }
      expect(find.text('Coca-Cola 500ml'), findsOneWidget);
      expect(find.text('CC500 · Lts'), findsOneWidget);
      expect(find.text('₹40/L'), findsOneWidget);
      expect(find.text('84 L'), findsOneWidget);
      expect(find.text('₹0.56/g'), findsOneWidget);
      expect(find.text('42000 g'), findsOneWidget);
      expect(find.text('₹72/Dz'), findsOneWidget);
      expect(find.text('Available · QR ✓'), findsNWidgets(6));
      await t.scrollUntilVisible(find.text('Showing 1–6 of 142 items'), 300, scrollable: find.byType(Scrollable).first); // the pager scrolls with the list
      expect(find.text('Showing 1–6 of 142 items'), findsOneWidget);
      expect(find.text('POS Items'), findsOneWidget);
      expect(find.text('A simpler receipt preview'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('the grid view is a two column card layout; a category chip filters on the server; search is debounced', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api), height: 4200);
      await t.tap(find.byKey(const ValueKey('cat-view-grid')));
      await t.pumpAndSettle();
      expect(find.text('QR ✓'), findsNWidgets(6));
      expect(find.text('Available'), findsNWidgets(6));
      await t.tap(find.text('Dairy'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['category'], 'Dairy');
      expect(jsonDecode(s.requests.last.body)['page'], 1);
      await t.enterText(find.byType(TextField), 'salt');
      await t.pump(const Duration(milliseconds: 350));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['q'], 'salt');
    });

    testWidgets('the next page asks the server for page 2', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api));
      await t.scrollUntilVisible(find.byTooltip('Next page'), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['page'], 2);
    });

    testWidgets('a failed load shows the message and a retry', (t) async {
      final s = Fake((_) => err(500, 'Something went wrong. Please try again.'));
      await phone(t, CatalogueScreen(api: s.api));
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the kebab opens the action sheet; Copy SKU puts the SKU on the clipboard', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final s = server();
      await phone(t, CatalogueScreen(api: s.api));
      await t.tap(find.byTooltip('Actions for Coca-Cola 500ml'));
      await t.pumpAndSettle();
      expect(find.text('CC500 · ₹40 · Item actions'), findsOneWidget);
      for (final x in ['View product details', 'Open the catalogue record', 'Quick edit', 'Update existing product information', 'View product image', 'Open the image viewer', 'Copy System Code', 'Cancel']) {
        expect(find.text(x), findsOneWidget);
      }
      await t.tap(find.text('Copy System Code'));
      await t.pumpAndSettle();
      expect(copied, ['CC500']);
      expect(toast('System Code CC500 copied.'), findsOneWidget);
    });

    testWidgets('tapping an item shows "About this product", then the detail drawer with the catalogue record', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api), height: 3000);
      await t.tap(find.text('Coca-Cola 500ml'));
      await t.pumpAndSettle();
      expect(find.text('About this product'), findsOneWidget);
      expect(find.text('Check the pack and System Code before selecting.'), findsOneWidget);   // its own hint line under the facts
      expect(find.text('System Code CC500'), findsOneWidget);
      expect(find.text('Selling price'), findsOneWidget);
      expect(find.text('500ml bottle'), findsOneWidget);
      await t.tap(find.text('View product details'));
      await t.pumpAndSettle();
      expect(find.text('CATALOGUE RECORD'), findsOneWidget);
      expect(find.text('RECORD INFORMATION'), findsOneWidget);
      expect(find.text('INR'), findsOneWidget);
      expect(find.text('Product'), findsOneWidget);
      expect(find.text('84 L'), findsWidgets);
      expect(find.text('Edit catalogue details'), findsOneWidget);
      expect(find.text('Product image'), findsOneWidget);
    });

    testWidgets('Quick add opens the one Quick Add screen straight away; the price is needed; the System Code comes from the name', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api), height: 3000);
      expect(find.text('Quick add'), findsOneWidget); // the button on the first screen
      await t.tap(find.byKey(const ValueKey('cat-add')));
      await t.pumpAndSettle();
      expect(find.byType(QuickAddScreen), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('quick-name')), 'Oat Crunch');
      await t.pump();
      expect(find.textContaining('System Code'), findsNothing); // the SKU is never made from the name
      await pickSku(t);
      await t.ensureVisible(find.byKey(const ValueKey('quick-save')));
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pump();
      expect(find.text('Enter the selling price.'), findsOneWidget);
      expect(s.where('POST', '/cat_item_save'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('quick-price')), '45');
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pumpAndSettle();
      final post = s.where('POST', '/cat_item_save').single;
      final b = s.body(post);
      expect(b, allOf(containsPair('mode', 'quick'), containsPair('name', 'Oat Crunch'), containsPair('price_minor', 4500), containsPair('selling_unit', 'pc')));
      expect(b['sku_parts'], {'sub': 'SNK', 'slot3': 'LSE', 'size': 'PK'});
      expect(post.headers['Idempotency-Key'], startsWith('cat-'));
      expect(toast('Oat added.'), findsOneWidget);
    });

    testWidgets('the header is compact: title, search and Add, and the chips all sit above the first product', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api), height: 3000);
      expect(s.body(s.where('POST', '/cat_item_list').last).containsKey('status'), isFalse);
      final title = t.getRect(find.text('Catalogue').last), add = t.getRect(find.byKey(const ValueKey('cat-add')));
      final chip = t.getRect(find.text('Beverages').first), first = t.getRect(find.text('Coca-Cola 500ml'));
      expect(add.top, greaterThan(title.bottom));
      expect(chip.top, greaterThan(add.bottom));
      expect(first.top, greaterThan(chip.bottom));
      expect(chip.bottom - title.top, lessThan(130)); // three short lines, not a page of cards
      expect(find.byTooltip('Import'), findsOneWidget);
      expect(find.byTooltip('Sample template'), findsOneWidget);
    });

    testWidgets('New category chip: name it, add its first product, and that category is shown', (t) async {
      final s = Fake((r) => r.url.path.endsWith('/cat_item_save') ? ok(item('n1', 'Shampoo', 'SH1', 9900, category: 'Personal care')) : ok(catalogueList(sixItems)));
      await phone(t, CatalogueScreen(api: s.api), height: 3000);
      await t.ensureVisible(find.byKey(const ValueKey('cat-new-category')));
      await t.tap(find.byKey(const ValueKey('cat-new-category')));
      await t.pumpAndSettle();
      await t.tap(find.text('Personal care'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('new-category-next')));
      await t.pumpAndSettle();
      expect(find.text('Category: Personal care'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('quick-name')), 'Shampoo');
      await t.enterText(find.byKey(const ValueKey('quick-price')), '99');
      await pickSku(t);
      await t.ensureVisible(find.byKey(const ValueKey('quick-save')));
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pumpAndSettle();
      expect(s.body(s.where('POST', '/cat_item_save').single)['category'], 'Personal care');
      expect(s.body(s.where('POST', '/cat_item_list').last)['category'], 'Personal care');
      expect(toast('Category Personal care is ready with Shampoo.'), findsOneWidget);
    });

    testWidgets('Quick Add opened for a category says so and saves the product into it', (t) async {
      final s = Fake((_) => ok(item('n1', 'Chips', 'CH1', 2000)));
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showQuickAdd(c, s.api, photos: _FakePhotos(), category: 'Snacks'), child: const Text('go')))), height: 3000);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Category: Snacks'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('quick-name')), 'Chips');
      await t.enterText(find.byKey(const ValueKey('quick-price')), '20');
      await pickSku(t);
      await t.ensureVisible(find.byKey(const ValueKey('quick-save')));
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pumpAndSettle();
      final save = s.body(s.requests.firstWhere((r) => r.url.path.endsWith('/cat_item_save')));
      expect(save, allOf(containsPair('name', 'Chips'), containsPair('price_minor', 2000), containsPair('category', 'Snacks')));
    });

    testWidgets('Quick Add takes an optional photo, which goes on the product once it is added', (t) async {
      final s = Fake((_) => ok(item('n1', 'Oat', 'OAT1', 4500)));
      final photos = _FakePhotos();
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showQuickAdd(c, s.api, photos: photos), child: const Text('go')))), height: 3000);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Tap to add photo'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('quick-photo-add')));
      await t.pumpAndSettle();
      expect(find.text('Tap to add photo'), findsNothing);
      expect(find.byKey(const ValueKey('quick-photo-replace')), findsOneWidget); // tap the photo to change it
      await t.enterText(find.byKey(const ValueKey('quick-name')), 'Oat');
      await t.enterText(find.byKey(const ValueKey('quick-price')), '45');
      await pickSku(t);
      await t.ensureVisible(find.byKey(const ValueKey('quick-save')));
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pumpAndSettle();
      expect(photos.attached, ['n1']);
      expect(find.byType(QuickAddScreen), findsNothing);
    });

    testWidgets('Quick Add shows the database refusal and stays open', (t) async {
      final s = Fake((r) => r.url.path.endsWith('/cat_item_save') ? err(409, 'Another item already uses System Code OAT1.', 'duplicate') : ok(catalogueList(sixItems)));
      await phone(t, CatalogueScreen(api: s.api), height: 3000);
      await t.tap(find.byKey(const ValueKey('cat-add')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('quick-name')), 'Oat');
      await t.enterText(find.byKey(const ValueKey('quick-price')), '45');
      await pickSku(t);
      await t.ensureVisible(find.byKey(const ValueKey('quick-save')));
      await t.tap(find.byKey(const ValueKey('quick-save')));
      await t.pumpAndSettle();
      expect(find.text('Another item already uses System Code OAT1.'), findsOneWidget);
      expect(find.byType(QuickAddScreen), findsOneWidget);
    });

    testWidgets('Scan barcode: the search bar\'s barcode button reads with the camera and opens the product at once', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api, scan: (_) async => 'CC500'), height: 3000);
      await t.tap(find.byTooltip('Scan a barcode'));
      await t.pumpAndSettle();
      expect(s.body(s.where('POST', '/cat_item_lookup').single)['code'], 'CC500');
      expect(find.text('Scan barcode'), findsNothing);
      expect(find.text('About this product'), findsOneWidget);
    });

    testWidgets('Scan barcode: a code with no product offers to create one; "Type a different code" opens the sheet with it', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api, scan: (_) async => 'NOPE'), height: 3000);
      await t.tap(find.byTooltip('Scan a barcode'));
      await t.pumpAndSettle();
      expect(find.text('New barcode'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('unknown-type')));
      await t.pumpAndSettle();
      expect(find.text('Scan barcode'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'NOPE'), findsOneWidget);
      expect(find.text('No item has that code.'), findsOneWidget);
    });

    testWidgets('Unknown product: "Create product" opens Quick Add with the scanned barcode filled in', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api, scan: (_) async => '8901234567890'), height: 3000);
      await t.tap(find.byTooltip('Scan a barcode'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('unknown-create')));
      await t.pumpAndSettle();
      expect(find.byType(QuickAddScreen), findsOneWidget);
      expect(find.widgetWithText(TextField, '8901234567890'), findsOneWidget);
    });

    testWidgets('Scan barcode: closing the camera does nothing', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api, scan: (_) async => null), height: 3000);
      final before = s.requests.length;
      await t.tap(find.byTooltip('Scan a barcode'));
      await t.pumpAndSettle();
      expect(s.requests.length, before);
      expect(find.text('Scan barcode'), findsNothing);
    });

    testWidgets('Scan barcode: "Type the code instead" opens the sheet; type a barcode, Find product opens the item; an unknown code shows the message', (t) async {
      final s = server();
      await phone(t, CatalogueScreen(api: s.api, scan: (_) async => ''), height: 3000);
      await t.tap(find.byTooltip('Scan a barcode'));
      await t.pumpAndSettle();
      expect(find.text('Scan barcode'), findsOneWidget);
      expect(find.descendant(of: find.byType(Dialog), matching: find.textContaining('QR')), findsNothing);
      expect(find.text('Tap to scan with camera'), findsOneWidget);
      expect(find.text('Barcode or System Code'), findsOneWidget);
      await t.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'NOPE');
      await t.pump();
      await t.tap(find.text('Find product'));
      await t.pumpAndSettle();
      expect(find.text('No item has that code.'), findsOneWidget);
      await t.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'CC500');
      await t.pump();
      await t.tap(find.text('Find product'));
      await t.pumpAndSettle();
      expect(find.text('About this product'), findsOneWidget);
    });

    testWidgets('Scan barcode: tapping the viewfinder scans with the camera and looks the code up straight away', (t) async {
      final s = server();
      CatItem? found;
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () async => found = await showScanSheet(c, s.api, scan: (_) async => 'CC500'), child: const Text('go')))), height: 3000);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('scan-camera')));
      await t.pumpAndSettle();
      expect(s.body(s.where('POST', '/cat_item_lookup').single)['code'], 'CC500');
      expect(found?.sku, 'CC500');
      expect(find.text('Scan barcode'), findsNothing);
    });

    test('installRoutes plugs the catalogue and the GRN queue into the control centre', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.items, isNotNull);
      expect(HomeNav.grn, isNotNull);
    });
  });

  group('Item creation', () {
    testWidgets('a full save without tax shows the database message as a red banner and keeps the form', (t) async {
      final s = Fake((r) => err(422, 'Complete the HSN and GST rate to save the item, or save it as a draft.', 'tax_required'));
      await phone(t, ItemFormScreen(api: s.api), height: 6400);
      expect(find.text('Item Creation'), findsOneWidget);
      expect(find.text('Prepare a new catalogue item without changing live stock.'), findsOneWidget);
      for (final x in ['Item identity', 'Units & storage', 'Tax & pricing', 'Save checklist', 'Save item', 'Save draft only']) {
        expect(find.text(x), findsOneWidget);
      }
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'Oat Crunch Cookies 200g');
      await pickSku(t);
      await t.enterText(find.widgetWithText(TextField, '').at(0), 'Oat Crunch Cookies 200g');
      // price field is the one with the ₹40.00 hint
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '₹40.00'), '40');
      await t.ensureVisible(find.text('Save item'));
      await t.tap(find.text('Save item'));
      await t.pumpAndSettle();
      final sent = jsonDecode(s.requests.single.body) as Map<String, dynamic>;
      expect(sent['mode'], 'full');
      expect(sent['draft'], false);
      expect(sent['price_minor'], 4000);
      expect(sent['sku_parts'], allOf(containsPair('sub', 'SNK'), containsPair('slot3', 'LSE'))); // the database makes the SKU
      expect(sent.containsKey('version'), false);
      expect(find.text('Complete tax details to save item'), findsOneWidget);
      expect(find.text('Complete the HSN and GST rate to save the item, or save it as a draft.'), findsOneWidget);
      expect(find.byType(ItemFormScreen), findsOneWidget);
    });

    testWidgets('missing name, SKU or price is caught before any request', (t) async {
      final s = Fake((_) => ok(item('n', 'x', 'x', 1)));
      await phone(t, ItemFormScreen(api: s.api), height: 6400);
      await t.ensureVisible(find.text('Save draft only'));
      await t.tap(find.text('Save draft only'));
      await t.pump();
      expect(toast('Enter the product name.'), findsOneWidget);
      expect(s.requests, isEmpty);
    });

    testWidgets('Save draft only sends draft true and closes with a toast', (t) async {
      final s = Fake((_) => ok(item('n1', 'Oat', 'OAT1', 4000, status: 'draft')));
      var closed = false;
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () async { closed = (await Navigator.of(c).push<bool>(MaterialPageRoute(builder: (_) => ItemFormScreen(api: s.api))))!; }, child: const Text('go')))), height: 6400);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'Oat');
      await pickSku(t);
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '₹40.00'), '40');
      await t.ensureVisible(find.text('Save draft only'));
      await t.tap(find.text('Save draft only'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.single.body)['draft'], true);
      expect(closed, true);
    });

    testWidgets('a product photo can be added, have its background removed, and goes on the item once it is saved', (t) async {
      final s = Fake((_) => ok(item('n1', 'Oat', 'OAT1', 4000)));
      final photos = _FakePhotos();
      await phone(t, ItemFormScreen(api: s.api, photos: photos), height: 6400);
      expect(find.text('Tap to add photo'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('item-photo-add')));
      await t.pumpAndSettle();
      expect(find.text('Tap to add photo'), findsNothing);
      await t.tap(find.byKey(const ValueKey('item-photo-bg')));
      await t.pumpAndSettle();
      expect(find.text('Background removed'), findsOneWidget);
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), 'Oat');
      await pickSku(t);
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '₹40.00'), '40');
      await t.tap(find.text('Save draft only'));
      await t.pumpAndSettle();
      expect(photos.attached, ['n1 bg']);
    });

    testWidgets('the step chips follow the scroll, and a tap jumps to its section', (t) async {
      await phone(t, ItemFormScreen(api: Fake((_) => ok({})).api), height: 1704);   // an 852-point phone
      bool current(String label) => (t.widget<Semantics>(find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.selected != null)).first)).properties.selected == true;
      expect(current('Product'), isTrue);
      // scroll until the Tax & pricing section reaches the top
      await t.dragUntilVisible(find.text('Tax & pricing'), find.byType(SingleChildScrollView).last, const Offset(0, -200));
      await t.drag(find.byType(SingleChildScrollView).last, const Offset(0, -250));
      await t.pumpAndSettle();
      expect(current('Product'), isFalse);
      expect(current('Tax & price') || current('Review'), isTrue);
      await t.tap(find.text('Units'));
      await t.pumpAndSettle();
      expect(current('Units'), isTrue);
      expect(current('Tax & price'), isFalse);
    });

    testWidgets('the barcode field has a scan button: the code the camera reads is filled in', (t) async {
      final s = Fake((_) => ok({}));
      var opened = 0;
      await phone(t, ItemFormScreen(api: s.api, scan: (_) async { opened++; return '8901234567890'; }), height: 6400);
      await t.tap(find.byKey(const ValueKey('item-barcode-scan')));
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(find.widgetWithText(TextField, '8901234567890'), findsOneWidget);
      expect(toast('Barcode 8901234567890 added.'), findsOneWidget);
    });

    testWidgets('editing an item shows its saved photo; Remove photo takes it off when the item is saved', (t) async {
      final it = CatItem({...item('i1', 'Coca-Cola 500ml', 'CC500', 4000, version: 3), 'image_url': 'http://img.test/cc.png'});
      final s = Fake((_) => ok(item('i1', 'Coca-Cola 500ml', 'CC500', 4000, version: 4)));
      final photos = _FakePhotos();
      await phone(t, ItemFormScreen(api: s.api, item: it, photos: photos), height: 6400);
      expect(find.byKey(const ValueKey('item-photo-saved')), findsOneWidget);
      expect(find.text('Tap to add photo'), findsNothing);
      await t.tap(find.byKey(const ValueKey('item-photo-remove')));
      await t.pumpAndSettle();
      expect(find.text('Tap to add photo'), findsOneWidget);
      await t.ensureVisible(find.text('Save item'));
      await t.tap(find.text('Save item'));
      await t.pumpAndSettle();
      expect(photos.removed, ['i1']);
      expect(photos.attached, isEmpty);
    });

    test('a saved photo goes to storage through the server: slot, upload, confirm', () async {
      final seen = <String>[];
      final client = MockClient((r) async {
        seen.add('${r.method} ${r.url.host}${r.url.path}');
        if (r.url.path.endsWith('/cat_item_photo_slot')) {
          expect(jsonDecode(r.body), {'item_id': 'i1', 'content_type': 'image/png', 'size': 4});
          return ok({'path': 'org/items/i1/a.png', 'upload_url': 'http://storage.test/upload/a.png'});
        }
        if (r.url.host == 'storage.test') {
          expect(r.headers['Content-Type'], startsWith('image/png'));
          expect(r.bodyBytes, [0x89, 0x50, 0x4E, 0x47]);
          return http.Response('{}', 200);
        }
        expect(jsonDecode(r.body)['path'], 'org/items/i1/a.png');
        return ok({'id': 'i1', 'image_url': 'http://img.test/a.png'});
      });
      final photos = DeviceItemPhotos(rpc: RpcClient(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: client), client: client);
      await photos.attach('i1', ItemPhoto(bytes: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]), contentType: 'image/png'));
      expect(seen, ['POST pos.test/rpc/cat_item_photo_slot', 'PUT storage.test/upload/a.png', 'POST pos.test/rpc/cat_item_photo_attach']);
    });

    test('a refused photo save says why', () async {
      final client = MockClient((r) async => err(403, 'Your role cannot change catalogue items.', 'forbidden'));
      final photos = DeviceItemPhotos(rpc: RpcClient(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: client), client: client);
      expect(() => photos.remove('i1'), throwsA(isA<ItemPhotoUnavailable>().having((e) => e.message, 'message', 'Your role cannot change catalogue items.')));
    });

    testWidgets('editing an item pre-fills it and sends its version; a stale save says so', (t) async {
      final it = CatItem(item('i1', 'Coca-Cola 500ml', 'CC500', 4000, version: 3));
      final s = Fake((_) => err(409, 'This item was changed on another device.', 'version_conflict'));
      await phone(t, ItemFormScreen(api: s.api, item: it), height: 6400);
      expect(find.text('Edit Item'), findsOneWidget);
      expect(find.text('COCA-COLA 500ML'), findsWidgets); // the name box is in capitals
      await t.ensureVisible(find.text('Save item'));
      await t.tap(find.text('Save item'));
      await t.pumpAndSettle();
      final r = s.requests.single;
      expect(r.url.path, endsWith('/cat_item_save'));
      expect(jsonDecode(r.body)['id'], 'i1');
      expect(jsonDecode(r.body)['version'], 3);
      expect(find.text('This item changed on another device'), findsOneWidget);
    });
  });

  group('GRN Dashboard', () {
    testWidgets('shows the GRN, the invoice against physical receiving, the resolution form, posting preview and checklist', (t) async {
      final s = Fake((_) => ok(grnView()));
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      expect(s.requests.first.url.path, '/rpc/grn_open');
      expect(find.text('Match bill'), findsOneWidget); // the title; the step strip says Bill
      // one page: no tab strip, no separate matching screen
      for (final gone in ['Purchase dashboard', 'Putaway', 'Shelf Labels', 'Match against the invoice']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.text('GRN-105'), findsOneWidget);
      expect(find.text('RCV-105 / PO-105 / INV-5512'), findsOneWidget);
      expect(find.text('Coca-Cola Bottling'), findsOneWidget);
      expect(find.text('Rohan Shah · Owner'), findsOneWidget);
      expect(find.text('Not posted'), findsOneWidget);
      expect(find.text('Review'), findsNWidgets(2)); // the status chip and the resolve card chip
      expect(find.text('Open the count'), findsOneWidget);
      expect(find.text('Invoice vs counted · 0 match · 1 differs'), findsOneWidget);
      // the items as one table: billed, received, rate, amount, GST; the bill's totals under it
      expect(find.byKey(const ValueKey('check-header')), findsOneWidget); // the green purchase card
      for (final x in ['Bill', 'Rcvd', 'Rate', 'Amount', '₹30', '₹720']) {
        expect(find.text(x), findsWidgets, reason: x);
      }
      expect(find.textContaining('GST 18%'), findsOneWidget);
      expect(find.text('₹129.60'), findsOneWidget); // GST: 18% of ₹720
      expect(find.text('₹849.60'), findsOneWidget); // bill total
      expect(find.text('₹778.80'), findsOneWidget); // received: ₹660 + 18%
      // each item can be ticked as it is checked
      expect(find.text('0 / 1 checked'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('check-tick-i1')));
      await t.pump();
      expect(find.text('1 / 1 checked'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('check-tick-i1')));
      await t.pump();
      expect(find.text('0 / 1 checked'), findsOneWidget);
      // a row opens its full comparison
      await t.tap(find.byKey(const ValueKey('check-row-i1')));
      await t.pumpAndSettle();
      expect(find.text('24 / 24 units'), findsOneWidget);
      expect(find.text('22 / 2 units'), findsOneWidget);
      expect(find.text('24 × ₹30.00 = ₹720.00'), findsOneWidget);
      expect(find.text('22 × ₹30.00 = ₹660.00'), findsOneWidget);
      expect(find.text('2 × ₹30.00 = ₹60.00'), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      expect(find.text('Resolve exceptions'), findsOneWidget);
      expect(find.text('Accept 22 · Claim credit for 2'), findsOneWidget);
      expect(find.text('Posting preview'), findsOneWidget);
      expect(find.text('84 → 106 unit'), findsOneWidget);
      expect(find.text('Confirm Receiving & Approval'), findsOneWidget);
      expect(find.text('Physical count verified by Niraj'), findsOneWidget);
      expect(find.text('Lot and expiry captured · CC-C / 2027-11-15'), findsOneWidget);
      expect(find.text('Owner approval pending • nothing posted'), findsOneWidget);
      expect(find.byKey(const ValueKey('purchase-steps-3')), findsOneWidget);
      // one button finishes: a claim needs its reference and evidence first, so nothing is sent yet
      expect(find.text('Send to owner for approval'), findsOneWidget); // this person may not approve
      await t.ensureVisible(find.byKey(const ValueKey('check-finish')));
      await t.tap(find.byKey(const ValueKey('check-finish')));
      await t.pumpAndSettle();
      expect(s.requests.where((r) => r.url.path.endsWith('/grn_resolve') || r.url.path.endsWith('/grn_request_approval')), isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('one tap settles the claim and sends the match to the owner', (t) async {
      var view = grnView();
      final s = Fake((r) {
        if (r.url.path.endsWith('/grn_resolve')) view = grnView(valid: true, blockers: const [], version: 5);
        if (r.url.path.endsWith('/grn_request_approval')) view = grnView(status: 'approval_due', valid: true, blockers: const [], version: 6, actions: {'can_resolve': false, 'can_request': false, 'can_approve': false, 'can_reject': false});
        return ok(view);
      });
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'CLM-105'), 'CLM-105');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Seal inspection · 2 photos'), 'Seal inspection, 2 photos');
      await t.ensureVisible(find.text('Send to owner for approval'));
      await t.tap(find.text('Send to owner for approval'));
      await t.pumpAndSettle();
      final res = s.requests.firstWhere((r) => r.url.path.endsWith('/grn_resolve'));
      expect(jsonDecode(res.body), {'receipt_document_id': 'r1', 'version': 4, 'resolution': 'accept_claim_credit', 'claim_ref': 'CLM-105', 'evidence': 'Seal inspection, 2 photos'});
      final req = s.requests.firstWhere((r) => r.url.path.endsWith('/grn_request_approval'));
      expect(jsonDecode(req.body), {'receipt_document_id': 'r1', 'version': 5});
      expect(find.text('Approval due'), findsOneWidget);
      expect(find.text('Waiting for owner approval'), findsOneWidget);
    });

    testWidgets('the owner matches the bill and adds the stock in one tap (accepting differences as delivered)', (t) async {
      final owner = {'can_resolve': true, 'can_request': false, 'can_approve': false, 'can_reject': false, 'self_approve': true};
      var view = grnView(actions: owner);
      final s = Fake((r) {
        final p = r.url.path;
        if (p.endsWith('/grn_resolve')) view = grnView(valid: true, blockers: const [], version: 5, actions: owner);
        if (p.endsWith('/grn_request_approval')) view = grnView(status: 'approval_due', valid: true, blockers: const [], version: 6, actions: owner);
        if (p.endsWith('/grn_decide')) view = grnView(status: 'approved', valid: true, blockers: const [], version: 7, actions: owner);
        return ok(view);
      });
      HomeNav.stockPage = (c, page, {itemId}) {};
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      // choose "accept as received" for the 2 short units
      await t.tap(find.text('Accept 22 · Claim credit for 2'));
      await t.pumpAndSettle();
      await t.tap(find.text('Accept 22 as received').last);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Match bill & add stock'));
      await t.tap(find.text('Match bill & add stock'));
      await t.pumpAndSettle();
      final paths = s.requests.map((r) => r.url.path.split('/').last).where((p) => p != 'grn_open' && p != 'grn_view').toList();
      expect(paths, ['grn_resolve', 'grn_request_approval', 'grn_decide']);
      expect(jsonDecode(s.requests.firstWhere((r) => r.url.path.endsWith('/grn_resolve')).body)['note'], 'Accepted as delivered');
      expect(find.text('Print labels for this lot?'), findsOneWidget); // step 3 done: labels offered
    });

    testWidgets('an approver sees Approve and post stock and Send back; send back needs a reason', (t) async {
      var view = grnView(status: 'approval_due', valid: true, blockers: const [], version: 6, actions: {'can_resolve': false, 'can_request': false, 'can_approve': true, 'can_reject': true});
      final s = Fake((r) {
        if (r.url.path.endsWith('/grn_decide')) {
          final b = jsonDecode(r.body) as Map<String, dynamic>;
          view = b['decision'] == 'approve' ? grnView(status: 'approved', valid: true, blockers: const [], version: 7, actions: {'can_resolve': false, 'can_request': false, 'can_approve': false, 'can_reject': false}) : grnView(valid: true, blockers: const [], version: 7, decisionNote: b['note'] as String?);
        }
        return ok(view);
      });
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      expect(find.text('Approve and post stock'), findsOneWidget);
      await t.ensureVisible(find.text('Send back'));
      await t.tap(find.text('Send back'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Send back'));
      await t.pumpAndSettle();
      expect(s.requests.where((r) => r.url.path.endsWith('/grn_decide')), isEmpty); // empty reason: nothing sent
      await t.enterText(find.byType(TextField).last, 'Attach the credit note');
      await t.tap(find.widgetWithText(TextButton, 'Send back'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body), {'receipt_document_id': 'r1', 'version': 6, 'decision': 'reject', 'note': 'Attach the credit note'});
      expect(find.text('Sent back: Attach the credit note'), findsOneWidget);
    });

    testWidgets('approving posts and shows Approved', (t) async {
      var view = grnView(status: 'approval_due', valid: true, blockers: const [], version: 6, actions: {'can_resolve': false, 'can_request': false, 'can_approve': true, 'can_reject': true});
      final s = Fake((r) {
        if (r.url.path.endsWith('/grn_decide')) view = grnView(status: 'approved', valid: true, blockers: const [], version: 7, actions: {'can_resolve': false, 'can_request': false, 'can_approve': false, 'can_reject': false});
        return ok(view);
      });
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      // approving leads straight on to the whole lot's labels (founder, 26 Oct 2026)
      final opened = <String>[];
      HomeNav.stockPage = (c, page, {itemId}) => opened.add(itemId == null ? page : '$page:$itemId');
      await t.ensureVisible(find.text('Approve and post stock'));
      await t.tap(find.text('Approve and post stock'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body), {'receipt_document_id': 'r1', 'version': 6, 'decision': 'approve'});
      // the voucher is matched: a question, not the labels straight away
      expect(opened, isEmpty);
      expect(find.text('Print labels for this lot?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('labels-offer-yes')));
      await t.pumpAndSettle();
      expect(opened, ['lot_labels:r1']);
      expect(find.text('Approved · stock posted'), findsOneWidget);
      expect(find.text('Posted'), findsOneWidget);
      expect(find.text('Owner approved · stock posted'), findsOneWidget);
      // the optional next steps appear as two buttons, and open the stock pages for this delivery
      await t.ensureVisible(find.byKey(const ValueKey('check-putaway')));
      await t.tap(find.byKey(const ValueKey('check-putaway')));
      await t.tap(find.byKey(const ValueKey('check-labels')));
      expect(opened, ['lot_labels:r1', 'putaway:r1', 'lot_labels:r1']);
    });

    testWidgets('every line is listed, the differences first, and matching lines too', (t) async {
      final s = Fake((_) => ok(grnView(rows: [
            row('matched', invoice: {'name': 'Matched item', 'qty': 5, 'unit': 'units', 'unit_price_minor': 1000, 'amount_minor': 5000}, received: {'line_id': 'l2', 'name': 'Matched item', 'qty': 5, 'rejected_qty': 0, 'unit': 'unit', 'unit_cost_minor': 1000}, accepted: 5),
            colaRow(),
          ])));
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      expect(find.text('Invoice vs counted · 1 match · 1 differs'), findsOneWidget);
      expect(t.getTopLeft(find.text('Coca-Cola 500ml').first).dy, lessThan(t.getTopLeft(find.text('Matched item')).dy));
    });

    testWidgets('a database refusal is shown as a message; a stale version reloads', (t) async {
      var n = 0;
      final s = Fake((r) {
        if (r.url.path.endsWith('/grn_request_approval')) return err(409, 'This GRN was changed on another device.', 'version_conflict');
        n++;
        return ok(grnView(valid: true, blockers: const []));
      });
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      await t.ensureVisible(find.text('Send to owner for approval'));
      await t.tap(find.text('Send to owner for approval'));
      await t.pumpAndSettle();
      expect(toast('This GRN was changed on another device.'), findsOneWidget);
      expect(n, greaterThan(1)); // reloaded
    });

    testWidgets('an invoiced line that never arrived adds no empty row to the posting preview', (t) async {
      final view = grnView();
      view['preview'] = [
        ...(view['preview'] as List),
        {'name': null, 'unit': null, 'item_id': null, 'stock_now': null, 'accepted_qty': 0, 'rejected_qty': null},
      ];
      final s = Fake((_) => ok(view));
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      expect(find.text('Posting preview'), findsOneWidget);
      expect(find.text('null'), findsNothing);
      expect(find.text('+0 '), findsNothing);
    });

    testWidgets('no bill yet: the counted items are listed with estimates; the bill is entered here, prefilled from the count', (t) async {
      final counted = row('not_on_invoice', received: {'line_id': 'l1', 'name': 'Surf Excel 1kg', 'qty': 12, 'rejected_qty': 2, 'unit': 'pack'}, accepted: 10)
        ..addAll({'item_id': 'i9', 'gst_pct': 18, 'ref_unit_minor': 11200});
      Map<String, dynamic>? sent;
      final s = Fake((r) {
        if (r.url.path.endsWith('/grn_invoice_save')) sent = jsonDecode(r.body) as Map<String, dynamic>;
        return ok(grnView(hasInvoice: false, rows: [counted], blockers: const ['Enter the supplier invoice first.'])
          ..['totals'] = {'invoice_amount_minor': 0, 'accepted_value_minor': 0, 'claim_minor': 0, 'exceptions': 0});
      });
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4000);
      expect(find.text('Surf Excel 1kg'), findsOneWidget);
      expect(find.textContaining('2 damaged'), findsOneWidget);
      expect(find.text('No supplier bill yet: rates are from the order or the product cost.'), findsOneWidget);
      expect(find.text('₹112'), findsOneWidget); // the order's rate
      expect(find.text('₹1,120'), findsOneWidget); // 10 good × ₹112
      expect(find.text('₹1,321.60'), findsOneWidget); // estimated total with 18% GST
      expect(find.text('Resolve exceptions'), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('check-enter-bill')));
      await t.tap(find.byKey(const ValueKey('check-enter-bill')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(find.byKey(const ValueKey('bill-qty-i9'))).controller!.text, '12');
      expect(t.widget<TextField>(find.byKey(const ValueKey('bill-rate-i9'))).controller!.text, '112');
      expect(find.text('₹1,344.00'), findsOneWidget); // 12 × ₹112
      await t.enterText(find.byKey(const ValueKey('bill-number')), '');
      await t.tap(find.byKey(const ValueKey('bill-save')));
      await t.pump();
      expect(find.text('Enter the bill number.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('bill-number')), 'LFA-9001');
      await t.tap(find.byKey(const ValueKey('bill-save')));
      await t.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!['invoice_no'], 'LFA-9001');
      expect(sent!['supplier_name'], 'Coca-Cola Bottling');
      expect(sent!['lines'], [{'inventory_item_id': 'i9', 'product_name': 'Surf Excel 1kg', 'qty': 12, 'unit_price_minor': 11200}]);
    });

    testWidgets('a role that may only read opens the existing GRN (open refused with 403)', (t) async {
      final s = Fake((r) => r.url.path.endsWith('/grn_open') ? err(403, 'Your role cannot review receipts.', 'forbidden') : ok(grnView(actions: {'can_resolve': false, 'can_request': false, 'can_approve': false, 'can_reject': false})));
      await phone(t, GrnDashboardScreen(receiptId: 'r1', api: s.api), height: 4600);
      expect(find.text('GRN-105'), findsOneWidget);
    });
  });

  group('GRN queue', () {
    testWidgets('lists receipts with a status and opens the dashboard', (t) async {
      final s = Fake((r) => r.url.path.endsWith('/grn_list')
          ? ok({
              'items': [
                {'receipt_document_id': 'r1', 'doc_no': 'RCV-105', 'doc_status': 'review', 'grn_no': 'GRN-105', 'review_status': 'matching', 'supplier_name': 'Coca-Cola Bottling', 'invoice_no': 'INV-5512', 'has_invoice': true, 'exceptions': 1},
                {'receipt_document_id': 'r2', 'doc_no': 'RCV-106', 'doc_status': 'review', 'grn_no': null, 'review_status': null, 'supplier_name': 'Metro', 'invoice_no': null, 'has_invoice': false, 'exceptions': null},
              ]
            })
          : ok(grnView()));
      await phone(t, GrnQueueScreen(api: s.api));
      expect(find.text('Deliveries to check'), findsOneWidget);
      expect(find.text('Putaway'), findsNothing); // no tab strip
      expect(find.text('GRN-105'), findsOneWidget);
      expect(find.text('RCV-105 / INV-5512'), findsOneWidget);
      expect(find.text('Coca-Cola Bottling'), findsOneWidget);
      expect(find.text('1 to review'), findsOneWidget);
      expect(find.text('RCV-106'), findsOneWidget);
      expect(find.text('Not opened'), findsOneWidget);
      expect(find.text('Needs review'), findsOneWidget);
      expect(find.text('No deliveries to check'), findsNothing);
      await t.tap(find.text('GRN-105'));
      await t.pumpAndSettle();
      expect(find.text('Match bill'), findsOneWidget); // the title; the step strip says Bill
    });

    testWidgets('no receipts: explains the flow and Receive stock opens Receiving', (t) async {
      final s = Fake((r) => ok({'items': []}));
      var received = 0;
      await phone(t, GrnQueueScreen(api: s.api, onReceive: (_) => received++));
      expect(find.text('No deliveries to check'), findsOneWidget);
      expect(find.text('Count the delivery in Receiving'), findsOneWidget);
      await t.tap(find.text('Receive stock'));
      await t.pump();
      expect(received, 1);
    });
  });
}

/// Photo tools without a file dialog or an image service: a fixed picture, a background removal that marks it, attach records.
class _FakePhotos extends ItemPhotoService {
  final attached = <String>[];
  @override
  Future<ItemPhoto?> pick() async => ItemPhoto(bytes: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]), contentType: 'image/png');
  // no camera in tests: the camera screen has its own tests (photo_capture_test.dart)
  @override
  Future<ItemPhoto?> capture(BuildContext context) => pick();
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto p, {String? bgColor}) async => ItemPhoto(bytes: p.bytes, contentType: 'image/png', backgroundRemoved: true);
  @override
  Future<void> attach(String itemId, ItemPhoto p) async => attached.add('$itemId${p.backgroundRemoved ? ' bg' : ''}');
  final removed = <String>[];
  @override
  Future<void> remove(String itemId) async => removed.add(itemId);
}
