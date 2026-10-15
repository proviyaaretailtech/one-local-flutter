// Exports every built section E screen as a phone frame PNG (405 pt wide, 2x, real Inter and Lucide fonts), named like the
// founder's Figma exports in assets/figma_ref_e, for side-by-side review. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/orders_frames_test.dart   -> test/frames_e/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'order_fixtures.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

OrdersApi _api(String stage) => OrdersApi(
      baseUrl: 'http://frames.local',
      accessToken: () => 'frames',
      client: MockClient((r) async {
        final p = r.url.path;
        final Object body = p.endsWith('/pos-orders')
            ? {
                'orders': [
                  {...card('a', 'completed', 'Completed'), 'display_no': 'P-01090', 'customer': 'Ananya Shah', 'channel_label': 'Online Order', 'total': 1240, 'items': '4 lines · 6 units', 'payment_status': 'Paid', 'payment_mode': 'UPI', 'delivery_status': 'Delivered · 6 of 6 units', 'delivery_time': '09 Oct · 6:18 PM'},
                  {...card('b', 'pending', 'Pending'), 'display_no': 'P-01089'},
                  {...card('c', 'cancelled', 'Cancelled'), 'display_no': 'P-01088', 'customer': 'Priya Nair', 'total': 620, 'payment_status': 'Not captured', 'delivery_status': 'Cancelled · not dispatched'},
                  {...card('d', 'completed', 'Completed'), 'display_no': 'P-01086', 'customer': 'Vikram Patel', 'total': 1560, 'items': '5 lines · 8 units', 'payment_status': 'Paid', 'payment_mode': 'Card', 'delivery_status': 'Delivered · 8 of 8 units', 'delivery_time': '08 Oct · 4:05 PM', 'refund_damages': '1 missing unit'},
                ],
              }
            : p.endsWith('/quote')
                ? {
                    'subtotal': 1600, 'gst_pct': 5, 'gst_amount': 80, 'service_charge': 160, 'discount': 0, 'round_off': 0, 'total': 1840,
                    'lines': [for (final i in view('pending')['items'] as List) {'menu_item_id': i['menu_item_id'], 'amount': i['amount']}],
                  }
                : view(stage);
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );

List<CartLine> _lines() => [for (final i in view('pending')['items'] as List) CartLine(menuItemId: i['menu_item_id'] as String, name: i['name'] as String, qty: i['qty'] as int)];

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1355, Future<void> Function()? then}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    if (then != null) await then();
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_e/$file.png'));
  }

  testWidgets('Orders History', (t) => frame(t, 'Orders History', OrdersHome(api: _api('pending')), height: 1418), skip: !on);
  testWidgets('Cart', (t) => frame(t, 'Cart', CartScreen(api: _api('pending'), initialLines: _lines())), skip: !on);
  testWidgets('Checkout', (t) => frame(t, 'Checkout', CartScreen(api: _api('pending'), initialLines: _lines()), then: () async {
        await t.tap(find.textContaining('Proceed to Checkout'));
        await t.pumpAndSettle();
        await t.tap(find.text('₹2,000'));
      }), skip: !on);
  for (final (stage, name) in const [
    ('checkout', 'Held Bill'),
    ('pending', 'Order Confirmation'),
    ('preparing', 'Order Preparing'),
    ('picked', 'Order Picked'),
    ('ready', 'Order Ready'),
    ('in_transit', 'Order In Transit'),
    ('exception', 'Order Exception'),
    ('cancelled', 'Order Cancelled'),
    ('completed', 'Order Completed'),
  ]) {
    testWidgets(name, (t) => frame(t, name, OrderScreen(api: _api(stage), orderId: orderId)), skip: !on);
  }
}
