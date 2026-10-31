// Exports every built section F screen as a 390 x 913 pt phone frame PNG (2x, real Inter and Lucide fonts) for side-by-side review
// against assets/figma_ref_f. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/sell_frames_test.dart   -> test/frames_f/*.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

import 'order_fixtures.dart';
import 'sell_fixtures.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 913, Future<void> Function()? then}) async {
    t.view.physicalSize = Size(780, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    if (then != null) await then();
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_f/$file.png'));
  }

  final till = Till()
    ..receipts = [
      receipt('r1', 'STR-1087', 'Rahul Patil', 1740, coupon: 'WELCOME10', discount: 100),
      receipt('r2', 'STR-1086', 'Priya Shah', 920, label: 'Paid · Card'),
      receipt('r3', 'STR-1085', 'Amit Deshmukh', 480, label: 'Paid · Cash'),
    ]
    ..returns = [retRow('t1', 'RET-0142', 'requested'), retRow('t2', 'RET-0141', 'approved', amount: 640)];

  SellCarts carts() {
    final c = SellCarts();
    cartWith(c, butter: 2, cola: 2);
    c.active.customerName = 'Riya Patel';
    c.active.customerPhone = '9876543210';
    return c;
  }

  testWidgets('Sell', (t) => frame(t, 'Sell', SellScreen(env: till.env(carts: carts()))), skip: !on);
  // Figma "444 Discount": MRP struck through, stock on each card, the stock tabs, and the cart's savings against MRP
  final stocked = Till()
    ..catalogueFacts = [
      {'id': 'm1', 'inventory_item_id': 'i1', 'mrp_minor': 5000, 'stock_qty': 84, 'stock_known': true},
      {'id': 'm2', 'inventory_item_id': 'i2', 'mrp_minor': 29000, 'stock_qty': 6, 'stock_known': true},
      {'id': 'm3', 'inventory_item_id': 'i3', 'mrp_minor': 1000, 'stock_qty': 0, 'stock_known': true},
    ]
    ..stockFacts = [
      {'id': 'i1', 'status': 'healthy', 'available': 84, 'stock_days': 6},
      {'id': 'i2', 'status': 'low', 'available': 6, 'stock_days': 3},
      {'id': 'i3', 'status': 'out', 'available': 0, 'stock_days': null},
    ];
  testWidgets('Discount', (t) => frame(t, 'Discount', SellScreen(env: stocked.env(carts: carts()))), skip: !on);
  testWidgets('Search', (t) => frame(t, 'Search', SearchScreen(env: till.env())), skip: !on);
  testWidgets('Search results', (t) => frame(t, 'Search results', SearchScreen(env: till.env(), initialQuery: 'a')), skip: !on);
  testWidgets('Search empty', (t) => frame(t, 'Search empty', SearchScreen(env: till.env(), initialQuery: 'oat milk')), skip: !on);
  testWidgets('Multiple Cart', (t) {
    final c = carts()..newCart();
    c.select(c.carts.first);
    return frame(t, 'Multiple Cart', CartsScreen(env: till.env(carts: c)), height: 1100);
  }, skip: !on);
  testWidgets('Payment', (t) => frame(t, 'Payment', PayScreen(env: till.env(carts: carts()), cart: null, held: OrderView(view('checkout'))), height: 1100), skip: !on);
  testWidgets('Payment split', (t) {
    final e = till.env(carts: carts());
    return frame(t, 'Payment split', PayScreen(env: e, cart: e.carts.active, method: 'split'), height: 1000);
  }, skip: !on);
  testWidgets('Transaction Success', (t) => frame(t, 'Transaction Success', SuccessScreen(env: till.env(), view: OrderView(view('pending')))), skip: !on);
  testWidgets('Transaction Failed', (t) => frame(t, 'Transaction Failed', FailedScreen(env: till.env(), failure: PaymentFailure({'order_id': orderId, 'display_no': 'ORD-2026-9912', 'method': 'card', 'status': 'declined', 'code': 'S1', 'message': 'Insufficient funds', 'headline': 'Card payment declined', 'detail': 'This payment was declined. Your cart is still saved.', 'amount_due': 1302, 'charged': false}))), skip: !on);
  testWidgets('Razorpay checkout', (t) => frame(t, 'Razorpay checkout', RazorpayScreen(env: till.env(), order: OrderView(view('checkout'))), height: 1000), skip: !on);
  testWidgets('Order History', (t) => frame(t, 'Order History', HistoryScreen(env: till.env()), then: () async {
        await t.tap(find.text('View card').first);
      }), skip: !on);
  testWidgets('Invoices & Receipts', (t) => frame(t, 'Invoices & Receipts', ReceiptsScreen(env: till.env())), skip: !on);
  testWidgets('Returns & Refunds', (t) => frame(t, 'Returns & Refunds', ReturnsScreen(env: till.env())), skip: !on);
}
