import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/auth/partner_api.dart' show PartnerApiException;
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/sell/carts_screen.dart';
import 'package:vinii_pos/sell/history_screen.dart';
import 'package:vinii_pos/sell/pay_screen.dart';
import 'package:vinii_pos/sell/razorpay_screen.dart';
import 'package:vinii_pos/sell/receipts_screen.dart';
import 'package:vinii_pos/sell/result_screens.dart';
import 'package:vinii_pos/sell/returns_screen.dart';
import 'package:vinii_pos/sell/search_screen.dart';
import 'package:vinii_pos/sell/sell_api.dart';
import 'package:vinii_pos/sell/sell_carts.dart';
import 'package:vinii_pos/sell/sell_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'order_fixtures.dart';
import 'sell_fixtures.dart';

Future<void> tall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4800);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('SellApi', () {
    test('catalog sends the filters and reads sku, category and availability', () async {
      final t = Till();
      final c = await t.env().sell.catalog(q: 'butter', category: 'Dairy', availableOnly: true, sort: 'price_desc');
      final r = t.calls.single;
      expect(r.url.path, '/rpc/pos_sell_catalog');
      expect(jsonDecode(r.body), {'q': 'butter', 'category': 'Dairy', 'available': true, 'sort': 'price_desc'});
      expect(r.headers['Authorization'], 'Bearer tok');
      expect(c.items.first.sku, 'AB500');
      expect(c.categories, ['Beverages', 'Dairy', 'Snacks']);
    });

    test('split pay sends the key, the version and the parts as given', () async {
      final t = Till();
      await t.env().sell.splitPay('o1', [{'method': 'cash', 'amount': 300, 'tendered': 500}, {'method': 'upi', 'amount': 330}], version: 'v1', key: 'pos-key-1');
      final r = t.calls.first;
      expect(r.url.path, '/rpc/pos_split_pay');
      expect(r.headers['Idempotency-Key'], 'pos-key-1');
      expect(jsonDecode(r.body), {'order_id': 'o1', 'payments': [{'method': 'cash', 'amount': 300, 'tendered': 500}, {'method': 'upi', 'amount': 330}], 'expected_updated_at': 'v1'});
      expect(t.calls.last.url.path, '/api/partner/pos-orders/o1'); // the shaped order comes back through section E's read
    });

    test('a refusal keeps its message and code (manager only, too much refunded)', () async {
      final t = Till()..override = (_) => err(403, 'Only a manager can give a refund.', 'forbidden');
      await expectLater(t.env().sell.refundOrder('o1', amount: 10, method: 'cash', reason: 'Goodwill', key: 'k'),
          throwsA(isA<OrdersApiException>().having((e) => e.code, 'code', 'forbidden').having((e) => e.message, 'message', 'Only a manager can give a refund.')));
    });

    test('no session: nothing is sent', () async {
      final t = Till();
      final api = SellApi(baseUrl: 'http://pos.test', accessToken: () => null, client: t.client);
      await expectLater(api.catalog(), throwsA(isA<PartnerApiException>()));
      expect(t.calls, isEmpty);
    });
  });

  group('SellCarts', () {
    test('lines add up, quantities change, a finished cart leaves, one cart always remains', () {
      final carts = SellCarts();
      final c = cartWith(carts);
      expect(c.units, 3);
      expect(c.lines.length, 2);
      c.setQty(c.lines.first, 0);
      expect(c.lines.length, 1);
      final second = carts.newCart();
      expect(carts.active, second);
      carts.finish(second);
      carts.finish(c);
      expect(carts.carts.length, 1);
      expect(carts.active.isEmpty, isTrue);
    });
  });

  group('Sell screen', () {
    testWidgets('the till pages are shortcuts on the screen (☰ is only the side menu); Open carts opens the carts', (t) async {
      final env = Till().env();
      await tall(t, SellScreen(env: env));
      for (final s in ['Open carts', 'History', 'Returns', 'Invoices', 'Cash shift']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('Bill'), findsWidgets);
      await t.tap(find.text('Open carts'));
      await t.pumpAndSettle();
      expect(find.byType(CartsScreen), findsOneWidget);
    });

    testWidgets('+ New category: name it (or tap one), add its first product, and the category opens', (t) async {
      final till = Till();
      final asked = <String>[];
      final env = till.env(addFirstItem: (_, c) async {
        asked.add(c);
        return true;
      });
      await tall(t, SellScreen(env: env));
      // pinned at the top of the category column, above All items, so it is never scrolled out of sight
      expect(t.getRect(find.byKey(const ValueKey('sell-new-category'))).top, lessThan(t.getRect(find.text('All items').first).top));
      final loads = till.calls.where((r) => r.url.path.endsWith('/rpc/pos_sell_catalog')).length;
      await t.tap(find.byKey(const ValueKey('sell-new-category')));
      await t.pumpAndSettle();
      expect(find.text('New category'), findsWidgets);
      expect(find.text('Snacks'), findsWidgets); // already a category: not offered as an idea
      expect(find.text('Personal care'), findsOneWidget);
      await t.tap(find.text('Personal care'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('new-category-next')));
      await t.pumpAndSettle();
      expect(asked, ['Personal care']);
      expect(till.calls.where((r) => r.url.path.endsWith('/rpc/pos_sell_catalog')).length, greaterThan(loads));
      expect(toast('Category Personal care is ready with its first product.'), findsOneWidget);
    });

    testWidgets('+ New category: an existing name adds to that category; Cancel does nothing', (t) async {
      final till = Till();
      final asked = <String>[];
      await tall(t, SellScreen(env: till.env(addFirstItem: (_, c) async {
        asked.add(c);
        return true;
      })));
      await t.tap(find.byKey(const ValueKey('sell-new-category')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(asked, isEmpty);
      await t.tap(find.byKey(const ValueKey('sell-new-category')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('new-category-name')), 'dairy');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('new-category-next')));
      await t.pumpAndSettle();
      expect(asked, ['Dairy']);
      expect(toast('Product added to Dairy.'), findsOneWidget);
    });

    testWidgets('shows the catalogue; an unavailable item cannot be added; ADD fills the cart and PAY shows the server total', (t) async {
      final till = Till();
      final env = till.env();
      await tall(t, SellScreen(env: env));
      expect(find.text('Coca-Cola 500ml'), findsOneWidget);
      expect(find.text('Out of Stock'), findsOneWidget);
      expect(find.text('PAY'), findsOneWidget);
      await t.tap(find.text('ADD').first);
      await t.pumpAndSettle();
      expect(find.text('×1'), findsOneWidget);
      await t.tap(find.text('ADD').first);
      await t.pumpAndSettle();
      expect(env.carts.active.units, 2);
      expect(find.text('PAY ₹84'), findsOneWidget); // 2 x ₹40 + 5% GST, as the server quoted it
      final q = jsonDecode(till.where('POST', '/quote').last.body);
      expect(q['lines'], [{'menu_item_id': 'm1', 'qty': 2}]);
    });

    group('444 Discount', () {
      Till stocked() => Till()
        ..catalogueFacts = [
          {'id': 'm1', 'inventory_item_id': 'i1', 'mrp_minor': 5000, 'stock_qty': 84, 'stock_known': true}, // ₹50 MRP, sold at ₹40
          {'id': 'm2', 'inventory_item_id': 'i2', 'mrp_minor': 28000, 'stock_qty': 0, 'stock_known': true}, // MRP equals the price; none left
          {'id': 'm3', 'inventory_item_id': 'i3', 'mrp_minor': null, 'stock_qty': 3, 'stock_known': true},
        ]
        ..stockFacts = [
          {'id': 'i1', 'status': 'healthy', 'available': 84, 'stock_days': 6},
          {'id': 'i2', 'status': 'out', 'available': 0, 'stock_days': null},
          {'id': 'i3', 'status': 'low', 'available': 3, 'stock_days': 1.5},
        ];

      testWidgets('MRP is struck through when the price is lower; stock says Available or Out of Stock and an empty item cannot be added', (t) async {
        final env = stocked().env();
        await tall(t, SellScreen(env: env));
        final mrp = t.widget<Text>(find.text('₹50'));
        expect(mrp.style?.decoration, TextDecoration.lineThrough);
        expect(find.text('₹280'), findsOneWidget); // no MRP above the price: nothing struck through
        expect(find.text('Available'), findsOneWidget); // Coca-Cola
        expect(find.text('Out of Stock'), findsNWidgets(2)); // butter (stock 0) and the item not on sale
        await t.tap(find.text('ADD').at(1)); // butter
        await t.pumpAndSettle();
        expect(env.carts.active.isEmpty, isTrue);
      });

      testWidgets('tabs: In Stock, Fast Moving (most sold per day first) and Low Inventory', (t) async {
        final env = stocked().env();
        await tall(t, SellScreen(env: env));
        for (final l in ['All Items', 'In Stock', 'Fast Moving', 'Low Inventory']) {
          expect(find.text(l), findsOneWidget, reason: l);
        }
        await t.tap(find.text('In Stock'));
        await t.pumpAndSettle();
        expect(find.text('Coca-Cola 500ml'), findsOneWidget);
        expect(find.text('Amul Butter 500g'), findsNothing);
        await t.tap(find.text('Fast Moving'));
        await t.pumpAndSettle();
        // Coca-Cola sells 14/day, the chocolate 2/day; butter has no recent sales
        expect(t.getTopLeft(find.text('Coca-Cola 500ml')).dy, lessThanOrEqualTo(t.getTopLeft(find.text('Cadbury Dairy Milk')).dy));
        expect(find.text('Amul Butter 500g'), findsNothing);
        await t.ensureVisible(find.text('Low Inventory')); // the tab row scrolls sideways on a phone
        await t.pumpAndSettle();
        await t.tap(find.text('Low Inventory'));
        await t.pumpAndSettle();
        expect(find.text('Amul Butter 500g'), findsOneWidget);
        expect(find.text('Cadbury Dairy Milk'), findsOneWidget);
        expect(find.text('Coca-Cola 500ml'), findsNothing);
      });

      testWidgets('the cart shows what each line saves against MRP', (t) async {
        final env = stocked().env();
        await tall(t, SellScreen(env: env));
        await t.tap(find.text('ADD').first); // Coca-Cola, ₹10 under MRP
        await t.pumpAndSettle();
        await t.tap(find.text('ADD').first);
        await t.pumpAndSettle();
        expect(find.text('Coca-Cola 500ml: ₹20 off MRP'), findsOneWidget);
      });

      testWidgets('a person who may not see the catalogue or stock gets the plain till: no tabs, no MRP', (t) async {
        final env = Till().env();
        await tall(t, SellScreen(env: env));
        expect(find.text('In Stock'), findsNothing);
        expect(find.text('Fast Moving'), findsNothing);
        expect(find.textContaining('off MRP'), findsNothing);
      });
    });

    testWidgets('a category narrows the grid', (t) async {
      final env = Till().env();
      await tall(t, SellScreen(env: env));
      await t.tap(find.text('Dairy'));
      await t.pumpAndSettle();
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      expect(find.text('Coca-Cola 500ml'), findsNothing);
    });

    testWidgets('Hold saves the bill and empties the cart', (t) async {
      final till = Till();
      final env = till.env();
      cartWith(env.carts);
      await tall(t, SellScreen(env: env));
      await t.tap(find.text('Hold'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/hold').single;
      expect(r.headers['Idempotency-Key'], startsWith('pos-'));
      expect(env.carts.active.isEmpty, isTrue);
    });

    testWidgets('the catalogue failing says so and Retry asks again', (t) async {
      final till = Till();
      var fail = true;
      till.override = (r) => r.url.path.endsWith('/pos_sell_catalog') && fail ? err(500, 'Something went wrong. Please try again.') : null;
      await tall(t, SellScreen(env: till.env()));
      expect(find.text('Items could not load'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();
      expect(find.text('Coca-Cola 500ml'), findsOneWidget);
    });
  });

  group('Search', () {
    testWidgets('landing offers suggestions, categories, search and scan', (t) async {
      await tall(t, SearchScreen(env: Till().env()));
      expect(find.text('Find a product'), findsOneWidget);
      expect(find.text('Try a search'), findsOneWidget);
      expect(find.text('Browse categories'), findsOneWidget);
      expect(find.text('Dairy'), findsOneWidget);
      expect(find.text('Search catalogue'), findsOneWidget);
      expect(find.text('Scan barcode'), findsOneWidget);
    });

    testWidgets('a search lists matches by name or SKU and adding reports the item to the cart', (t) async {
      final added = <SellItem>[];
      await tall(t, SearchScreen(env: Till().env(), onAdd: added.add));
      await t.enterText(find.byType(TextField).first, 'butter');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(find.text('1 matching product'), findsOneWidget);
      await t.tap(find.byIcon(LucideIcons.plus).first);
      await t.pumpAndSettle();
      expect(added.single.sku, 'AB500');
    });

    testWidgets('no result: "No products found" with Clear search', (t) async {
      await tall(t, SearchScreen(env: Till().env(), initialQuery: 'oat milk'));
      expect(find.text('No products found'), findsOneWidget);
      await t.tap(find.text('Clear search'));
      await t.pumpAndSettle();
      expect(find.text('Find a product'), findsOneWidget);
    });

    testWidgets('a failed request keeps the query and Retry works', (t) async {
      final till = Till();
      var fail = true;
      till.override = (r) => r.url.path.endsWith('/pos_sell_catalog') && jsonDecode(r.body).containsKey('q') && fail ? err(503, 'The server is busy.') : null;
      await tall(t, SearchScreen(env: till.env(), initialQuery: '500'));
      expect(find.text('Search couldn\'t load'), findsOneWidget);
      expect((t.widget(find.byType(TextField).first) as TextField).controller!.text, '500');
      fail = false;
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();
      expect(find.text('Search couldn\'t load'), findsNothing);
    });

    testWidgets('filters: available only narrows, the pill counts it, Clear filters restores', (t) async {
      final till = Till();
      await tall(t, SearchScreen(env: till.env(), initialQuery: 'a'));
      expect(find.text('Cadbury Dairy Milk'), findsOneWidget);
      await t.tap(find.text('Filters'));
      await t.pumpAndSettle();
      expect(find.text('Filter products'), findsOneWidget);
      await t.tap(find.widgetWithText(ChoiceChip, 'Available'));
      await t.tap(find.text('Apply filters'));
      await t.pumpAndSettle();
      expect(find.text('Filters · 1'), findsOneWidget);
      expect(jsonDecode(till.calls.last.body)['available'], true);
      expect(find.text('Cadbury Dairy Milk'), findsNothing);
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      await t.tap(find.text('Clear filters').last);
      await t.pumpAndSettle();
      expect(find.text('Filters · 1'), findsNothing);
    });

    testWidgets('filters with no match: "No matching results"', (t) async {
      final till = Till();
      await tall(t, SearchScreen(env: till.env(), initialQuery: 'cadbury'));
      await t.tap(find.text('Filters'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ChoiceChip, 'Available'));
      await t.tap(find.text('Apply filters'));
      await t.pumpAndSettle();
      expect(find.text('No matching results'), findsWidgets);
    });
  });

  group('Payment', () {
    testWidgets('cash: short tender is refused on the phone, the right tender checks out once and shows the success screen', (t) async {
      final till = Till();
      final env = till.env();
      final cart = cartWith(env.carts);
      cart.customerName = 'Riya Patel';
      cart.customerPhone = '9876543210';
      await tall(t, PayScreen(env: env, cart: cart));
      expect(find.text('SELECT PAYMENT METHOD'), findsOneWidget);
      expect(find.text('Pay ₹630'), findsOneWidget);
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(find.text('Enter the cash received.'), findsOneWidget);
      expect(till.where('POST', '/checkout'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('tender-field')), '500');
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/checkout'), isEmpty); // 500 < 630
      await t.enterText(find.byKey(const ValueKey('tender-field')), '1000');
      await t.pumpAndSettle();
      expect(find.text('₹370'), findsWidgets); // change due
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/checkout').single;
      final b = jsonDecode(r.body);
      expect(b['method'], 'cash');
      expect(b['tendered'], 1000);
      expect(b['customer_name'], 'Riya Patel');
      expect(b['customer_phone'], '9876543210');
      expect(b['lines'], [{'menu_item_id': 'm2', 'qty': 2}, {'menu_item_id': 'm1', 'qty': 1}]);
      expect(r.headers['Idempotency-Key'], startsWith('pos-'));
      expect(find.text('Transaction Successful'), findsOneWidget);
      expect(find.text('P-01087'), findsOneWidget);
      expect(find.text('New Order'), findsOneWidget);
      expect(env.carts.active.isEmpty, isTrue); // the paid cart left
    });

    testWidgets('a coupon is priced by the server and shown as a discount chip; a refused code is dropped with the server\'s sentence', (t) async {
      final till = Till();
      final env = till.env();
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('Apply coupon'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Coupon code'), 'welcome10');
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(find.text('WELCOME10'), findsWidgets);
      expect(find.text('−₹50'), findsOneWidget);
      expect(find.text('Pay ₹577.50'), findsOneWidget);
      expect(jsonDecode(till.where('POST', '/quote').last.body)['coupon_code'], 'WELCOME10'); // the phone sends the code in capitals; the server prices it
      await t.tap(find.text('Coupon WELCOME10'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Coupon code'), 'NOPE');
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(find.text('This coupon code is not valid.'), findsOneWidget);
      expect(cart.couponCode, 'WELCOME10'); // the code that worked stays
    });

    testWidgets('UPI is never paid on the tap: the bill is held unpaid and waits for confirmation (S5.14)', (t) async {
      final till = Till();
      final env = till.env();
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('UPI / QR'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/checkout'), isEmpty); // nothing is recorded as paid
      expect(till.where('POST', '/hold'), hasLength(1));
      final start = till.where('POST', '/pos_payment_start').single;
      expect(jsonDecode(start.body), {'order_id': orderId, 'method': 'upi'});
      expect(start.headers['Idempotency-Key'], isNotEmpty);
      expect(find.text('Payment pending'), findsOneWidget);
      expect(find.text('Not paid yet · P-01087'), findsOneWidget);
    });

    testWidgets('split: parts that do not add up are refused on the phone; correct parts hold the bill then split-pay it once', (t) async {
      final till = Till();
      final env = till.env();
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('Split Pay'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('split-amount-0')), '300');
      await t.enterText(find.byKey(const ValueKey('split-amount-1')), '400');
      await t.pumpAndSettle();
      expect(find.text('₹70 too much'), findsOneWidget);
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/pos_split_pay'), isEmpty);
      expect(till.where('POST', '/hold'), isEmpty);
      await t.enterText(find.byKey(const ValueKey('split-amount-1')), '330');
      await t.pumpAndSettle();
      expect(find.text('Adds up'), findsOneWidget);
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/hold'), hasLength(1));
      final r = till.where('POST', '/pos_split_pay').single;
      expect(jsonDecode(r.body)['order_id'], orderId);
      expect(jsonDecode(r.body)['payments'], [{'method': 'cash', 'amount': 300}, {'method': 'upi', 'amount': 330}]);
      expect(find.text('Transaction Successful'), findsOneWidget);
    });

    testWidgets('a split the database refuses shows its sentence and keeps the same key for the retry', (t) async {
      final till = Till();
      var refuse = true;
      till.override = (r) => r.url.path.endsWith('/pos_split_pay') && refuse ? err(400, 'The parts add up to 600 but 630 is due.', 'bad_request') : null;
      final env = till.env();
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('Split Pay'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('split-amount-0')), '300');
      await t.enterText(find.byKey(const ValueKey('split-amount-1')), '330');
      await t.tap(find.text('Pay ₹630'));
      await t.pumpAndSettle();
      expect(find.text('The parts add up to 600 but 630 is due.'), findsOneWidget);
      refuse = false;
      await t.tap(find.text('Pay ₹1,840')); // the bill is saved now, so the button shows the held bill's total
      await t.pumpAndSettle();
      final keys = till.where('POST', '/pos_split_pay').map((r) => r.headers['Idempotency-Key']).toSet();
      expect(keys, hasLength(1));
      expect(till.where('POST', '/hold'), hasLength(1)); // the bill was saved once, not twice
    });

    testWidgets('card declined: the bill is held, the attempt is logged, nothing is charged, and the failure screen offers a retry on the same bill', (t) async {
      final till = Till();
      final env = till.env();
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('Card'));
      await t.pumpAndSettle();
      await t.tap(find.text('Payment did not go through'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_payment_attempt_record').single.body), {'order_id': orderId, 'method': 'card', 'status': 'declined', 'code': 'declined', 'message': 'Declined at the terminal'});
      expect(find.text('Transaction Failed'), findsOneWidget);
      expect(find.text('Card payment declined'), findsOneWidget);
      expect(find.text('Declined · Not charged'), findsOneWidget);
      expect(find.text('₹630'), findsOneWidget);
      expect(till.where('POST', '/checkout'), isEmpty);
      await t.tap(find.text('Retry Payment'));
      await t.pumpAndSettle();
      expect(find.text('SELECT PAYMENT METHOD'), findsOneWidget);
      expect(find.text('Pay ₹1,840'), findsOneWidget); // the held bill's own total
      await t.tap(find.text('Pay ₹1,840'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/pay'), isEmpty); // a card retry waits for confirmation on the same held bill (S5.14)
      expect(jsonDecode(till.where('POST', '/pos_payment_start').single.body), {'order_id': orderId, 'method': 'card'});
      expect(find.text('Payment pending'), findsOneWidget);
    });

    testWidgets('cancel from the failure screen cancels the held bill', (t) async {
      final till = Till();
      await tall(t, FailedScreen(env: till.env(), failure: PaymentFailure({'order_id': orderId, 'display_no': 'P-01087', 'method': 'card', 'status': 'declined', 'code': 'S1', 'message': 'Insufficient funds', 'headline': 'Card payment declined', 'detail': 'This payment was declined. Your cart is still saved.', 'amount_due': 1302, 'charged': false})));
      expect(find.text('S1 · Insufficient funds'), findsOneWidget);
      await t.tap(find.text('Cancel transaction · No payment was collected'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/cancel').single.body)['reason'], 'Payment not collected');
    });

    testWidgets('WhatsApp needs a mobile number; with one it opens wa.me', (t) async {
      final till = Till();
      final opened = <Uri>[];
      final env = till.env(opened: opened);
      final cart = cartWith(env.carts);
      await tall(t, PayScreen(env: env, cart: cart));
      await t.tap(find.text('Send by WhatsApp'));
      await t.pumpAndSettle();
      expect(find.text('Ask for a mobile number before sharing.'), findsWidgets);
      expect(opened, isEmpty);
      cart.customerPhone = '9876543210';
      await t.tap(find.text('Send by WhatsApp'));
      await t.pumpAndSettle();
      expect(opened.single.host, 'wa.me');
      expect(opened.single.path, '/919876543210');
    });

    testWidgets('Razorpay checkout: the server says no provider is set up, the attempt is logged and the failure screen opens', (t) async {
      final till = Till();
      final env = till.env();
      await tall(t, RazorpayScreen(env: env, order: OrderView(view('checkout'))));
      expect(find.text('Checkout P-01087'), findsOneWidget);
      expect(find.text('Choose payment method'), findsOneWidget);
      await t.tap(find.text('Pay ₹1,840.00'));
      await t.pumpAndSettle();
      expect(find.text('Enter a UPI ID like name@bank.'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'customer@okaxis'), 'customer@okaxis');
      await t.tap(find.text('Pay ₹1,840.00'));
      await t.pumpAndSettle();
      expect(till.where('POST', '/pos_online_checkout'), hasLength(1));
      final a = jsonDecode(till.where('POST', '/pos_payment_attempt_record').single.body);
      expect(a['method'], 'online');
      expect(a['code'], 'provider_not_configured');
      expect(find.text('Transaction Failed'), findsOneWidget);
      expect(find.text('Online payment failed'), findsOneWidget);
    });
  });

  group('Carts', () {
    testWidgets('the active cart shows items and quantities; + / − re-quote; a second cart waits; held bills are listed with Pay', (t) async {
      final till = Till();
      till.receipts = [receipt('h1', 'P-00090', 'Neha Shah', 420, status: 'unpaid', label: 'Unpaid', paid: 0)];
      final env = till.env();
      cartWith(env.carts);
      await tall(t, CartsScreen(env: env));
      expect(find.text('Cart'), findsOneWidget);
      expect(find.text('1 open · 1 on hold'), findsOneWidget);
      expect(find.text('Cart #1'), findsWidgets);
      expect(find.text('Amul Butter 500g'), findsWidgets);
      await t.tap(find.bySemanticsLabel('One more Coca-Cola 500ml'), warnIfMissed: false);
      await t.tap(find.byIcon(LucideIcons.plus).first);
      await t.tap(find.text('+ New cart'));
      await t.pumpAndSettle();
      expect(env.carts.carts.length, 2);
      expect(find.text('Cart #1'), findsWidgets);
      expect(find.text('P-00090'), findsOneWidget);
      expect(find.text('On hold'), findsOneWidget);
      await t.tap(find.text('Show items').first);
      await t.pumpAndSettle();
      expect(find.text('Hide items'), findsWidgets);
    });

    testWidgets('a held bill can be cancelled', (t) async {
      final till = Till();
      till.receipts = [receipt('h1', 'P-00090', 'Neha Shah', 420, status: 'unpaid', label: 'Unpaid', paid: 0)];
      await tall(t, CartsScreen(env: till.env()));
      await t.tap(find.text('Cancel this held bill'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/cancel').single.body)['reason'], 'Held bill cancelled');
    });
  });

  group('Transaction history', () {
    testWidgets('lists bills that took money; View card opens the lines and the sum', (t) async {
      final till = Till();
      till.receipts = [receipt('r1', 'P-00087', 'Rahul Patil', 1740, coupon: 'WELCOME10', discount: 100), receipt('r3', 'P-00089', 'Held one', 100, status: 'unpaid', label: 'Unpaid', paid: 0)];
      await tall(t, HistoryScreen(env: till.env()));
      expect(find.text('Transaction History'), findsOneWidget);
      expect(find.text('1 transaction'), findsOneWidget); // the unpaid bill took no money
      expect(find.text('Rahul Patil'), findsOneWidget);
      expect(find.text('Order P-00087'), findsOneWidget);
      expect(find.text('Paid at 6:23 PM'), findsOneWidget);
      await t.tap(find.text('View card'));
      await t.pumpAndSettle();
      expect(find.text('Amul Butter 500g'), findsOneWidget);
      expect(find.text('2×'), findsOneWidget);
      expect(find.text('Discount · WELCOME10'), findsOneWidget);
      expect(find.text('Total Amount'), findsOneWidget);
      final q = jsonDecode(till.where('POST', '/pos_receipt_list').single.body);
      expect(q['from'], q['to']);
    });

    testWidgets('refund: the server\'s refusal is shown (manager only); a good refund asks with a key and reloads', (t) async {
      final till = Till();
      var allow = false;
      till.override = (r) => r.url.path.endsWith('/pos_refund') ? (allow ? ok(view('completed')) : err(403, 'Only a manager can give a refund.', 'forbidden')) : null;
      await tall(t, HistoryScreen(env: till.env()));
      await t.tap(find.text('View card').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Refund this bill').first);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Amount to refund'), '50');
      await t.enterText(find.widgetWithText(TextField, 'Reason'), 'Goodwill');
      await t.tap(find.text('Give refund'));
      await t.pumpAndSettle();
      expect(find.text('Only a manager can give a refund.'), findsOneWidget);
      allow = true;
      await t.pumpAndSettle(const Duration(seconds: 5));
      await t.tap(find.text('Refund this bill').first);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Amount to refund'), '50');
      await t.enterText(find.widgetWithText(TextField, 'Reason'), 'Goodwill');
      await t.tap(find.text('Give refund'));
      await t.pumpAndSettle();
      final last = till.where('POST', '/pos_refund').last;
      expect(last.headers['Idempotency-Key'], startsWith('pos-'));
      expect(jsonDecode(last.body), {'order_id': 'r1', 'amount': 50, 'method': 'cash', 'kind': 'goodwill', 'reason': 'Goodwill'});
    });

    testWidgets('nothing that day: a plain message; a failure has Retry', (t) async {
      final till = Till()..receipts = [];
      await tall(t, HistoryScreen(env: till.env()));
      expect(find.text('No transactions'), findsOneWidget);
      till.override = (_) => err(500, 'Something went wrong. Please try again.');
      await t.tap(find.byTooltip('Previous day'));
      await t.pumpAndSettle();
      expect(find.text('History could not load'), findsOneWidget);
    });
  });

  group('Invoices & receipts', () {
    testWidgets('lists the bills with their status words and balance due', (t) async {
      final till = Till();
      till.receipts = [receipt('r1', 'P-00087', 'Rahul Patil', 1740), receipt('r2', 'P-00088', 'Neha Kulkarni', 1200, status: 'part_paid', label: 'Partially paid', paid: 600)];
      await tall(t, ReceiptsScreen(env: till.env()));
      expect(find.text('Invoices & Receipts'), findsOneWidget);
      expect(find.text('0 selected · 2 records'), findsOneWidget);
      expect(find.text('Partially paid'), findsOneWidget);
      expect(find.text('Paid · UPI'), findsOneWidget);
    });

    testWidgets('selecting makes Download Selected work', (t) async {
      final till = Till();
      till.receipts = [receipt('r1', 'P-00087', 'Rahul Patil', 1740), receipt('r2', 'P-00088', 'Neha Kulkarni', 1200)];
      String? clip;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') clip = (c.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tall(t, ReceiptsScreen(env: till.env()));
      final boxes = find.byWidgetPredicate((w) => w is Semantics && w.properties.label != null && w.properties.label!.startsWith('Select '));
      expect(boxes, findsNWidgets(2));
      await t.tap(boxes.at(0));
      await t.tap(boxes.at(1));
      await t.pumpAndSettle();
      expect(find.text('2 selected · 2 records'), findsOneWidget);
      await t.tap(find.text('Download Selected (2)'));
      await t.pumpAndSettle();
      expect(clip, contains('Receipt P-00087'));
      expect(clip, contains('Receipt P-00088'));
    });

    testWidgets('the status filter and the Purchases tab', (t) async {
      final till = Till();
      await tall(t, ReceiptsScreen(env: till.env()));
      await t.tap(find.text('All statuses'));
      await t.pumpAndSettle();
      await t.tap(find.text('Refunded'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_receipt_list').last.body)['status'], 'refunded');
      await t.tap(find.text('Purchases'));
      await t.pumpAndSettle();
      expect(find.text('No purchase invoices here yet'), findsOneWidget);
    });
  });

  group('Returns & refunds', () {
    testWidgets('a request shows its lines and amount; a manager approves; Customer / Supplier tabs', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      expect(find.text('Returns & Refunds'), findsOneWidget);
      expect(find.text('#RET-0001'), findsOneWidget);
      expect(find.text('Rahul Patil'), findsOneWidget);
      expect(find.text('Reason: Damaged seal'), findsOneWidget);
      expect(find.text('₹320'), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
      await t.tap(find.text('View details'));
      await t.pumpAndSettle();
      await t.tap(find.text('Approve'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_return_decide').single.body), {'return_id': 't1', 'decision': 'approve', 'note': ''});
      await t.tap(find.text('Supplier Returns'));
      await t.pumpAndSettle();
      expect(find.text('Supplier returns come later'), findsOneWidget);
      expect(find.text('#RET-0001'), findsNothing);
    });

    testWidgets('an approved return is refunded with a key; the database\'s refusal is shown', (t) async {
      final till = Till()..returns = [retRow('t1', 'RET-0001', 'approved')];
      till.override = (r) => r.url.path.endsWith('/pos_return_issue_refund') ? err(403, 'Only a manager can give a refund.', 'forbidden') : null;
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('View details'));
      await t.pumpAndSettle();
      await t.tap(find.text('Issue refund ₹320'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cash'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/pos_return_issue_refund').single;
      expect(r.url.path, '/rpc/pos_return_issue_refund');
      expect(r.headers['Idempotency-Key'], startsWith('pos-'));
      expect(jsonDecode(r.body), {'return_id': 't1', 'method': 'cash'});
      expect(find.text('Only a manager can give a refund.'), findsOneWidget);
    });

    testWidgets('rejecting needs words and sends them', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('View details'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reject'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Why is it rejected?'), 'Not eligible');
      await t.tap(find.text('Reject return'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_return_decide').single.body), {'return_id': 't1', 'decision': 'reject', 'note': 'Not eligible'});
    });

    testWidgets('a new return: choose the bill, the quantity, the reason; the server\'s amount comes back', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('+ Return'));
      await t.pumpAndSettle();
      await t.tap(find.text('P-00087 · Rahul Patil'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('One more Amul Butter 500g'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record return'));
      await t.pumpAndSettle();
      final r = till.where('POST', '/pos_return_create').single;
      expect(r.headers['Idempotency-Key'], startsWith('pos-'));
      expect(jsonDecode(r.body), {'order_id': 'r1', 'lines': [{'order_item_id': 'i1', 'qty': 1}], 'reason': 'Damaged seal', 'note': ''});
      expect(find.text('Return recorded. A manager approves it next.'), findsOneWidget);
    });

    testWidgets('a damaged item is refunded but marked not to go back on the shelf', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('+ Return'));
      await t.pumpAndSettle();
      await t.tap(find.text('P-00087 · Rahul Patil'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('One more Amul Butter 500g'));
      await t.pumpAndSettle();
      await t.tap(find.text('Damaged'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record return'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_return_create').single.body)['lines'], [{'order_item_id': 'i1', 'qty': 1, 'restock': false}]);
    });

    testWidgets('the Damaged mark appears only once an item is chosen, and can be switched off again', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('+ Return'));
      await t.pumpAndSettle();
      await t.tap(find.text('P-00087 · Rahul Patil'));
      await t.pumpAndSettle();
      expect(find.text('Damaged'), findsNothing);
      await t.tap(find.byTooltip('One more Amul Butter 500g'));
      await t.pumpAndSettle();
      await t.tap(find.text('Damaged'));
      await t.pumpAndSettle();
      await t.tap(find.text('Damaged'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record return'));
      await t.pumpAndSettle();
      expect(jsonDecode(till.where('POST', '/pos_return_create').single.body)['lines'], [{'order_item_id': 'i1', 'qty': 1}]); // back on the shelf is the default: no flag sent
    });

    testWidgets('a return whose item was marked damaged says so in its details', (t) async {
      final till = Till();
      till.returns = [
        {...retRow('t1', 'RET-0001', 'approved'), 'lines': [{'name': 'Horlicks 500g', 'qty': 1, 'amount': 320, 'restock': false}, {'name': 'Parle-G', 'qty': 2, 'amount': 20, 'restock': true}]},
      ];
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('View details'));
      await t.pumpAndSettle();
      expect(find.text('1 × Horlicks 500g · damaged'), findsOneWidget);
      expect(find.text('2 × Parle-G'), findsOneWidget);
    });

    testWidgets('no item chosen: no request', (t) async {
      final till = Till();
      await tall(t, ReturnsScreen(env: till.env()));
      await t.tap(find.text('+ Return'));
      await t.pumpAndSettle();
      await t.tap(find.text('P-00087 · Rahul Patil'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record return'));
      await t.pumpAndSettle();
      expect(find.text('Choose the items being returned.'), findsOneWidget);
      expect(till.where('POST', '/pos_return_create'), isEmpty);
    });
  });

  testWidgets('installRoutes puts the till on the Bill tab', (t) async {
    HomeNav.reset();
    installRoutes();
    expect(HomeNav.bill, isNotNull);
    final till = Till();
    ignoreOverflow();
    t.view.physicalSize = const Size(780, 4800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SellScreen(env: till.env()))), child: const Text('go'))))));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Current Cart'), findsOneWidget);
  });
}
