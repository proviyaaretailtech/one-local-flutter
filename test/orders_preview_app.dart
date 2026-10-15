// Visual preview of the section E screens with fixture data (no sign-in, no server), to compare against assets/figma_ref_e.
// Build: flutter build web -t test/orders_preview_app.dart -o build/orders_preview ; open ?screen=history|cart|<stage>.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'order_fixtures.dart';

void main() {
  final screen = Uri.base.queryParameters['screen'] ?? 'history';
  final api = OrdersApi(
    baseUrl: 'http://preview.local',
    accessToken: () => 'preview',
    client: MockClient((r) async {
      final p = r.url.path;
      Object body;
      if (p.endsWith('/pos-orders')) {
        body = {
          'orders': [
            {...card('a', 'completed', 'Completed'), 'display_no': 'P-01090', 'customer': 'Ananya Shah', 'channel_label': 'Online Order', 'total': 1240, 'items': '4 lines · 6 units', 'payment_status': 'Paid', 'payment_mode': 'UPI', 'delivery_status': 'Delivered · 6 of 6 units', 'delivery_time': '09 Oct · 6:18 PM'},
            {...card('b', 'pending', 'Pending'), 'display_no': 'P-01089'},
            {...card('c', 'cancelled', 'Cancelled'), 'display_no': 'P-01088', 'customer': 'Priya Nair', 'total': 620, 'payment_status': 'Not captured', 'delivery_status': 'Cancelled · not dispatched'},
          ],
        };
      } else if (p.endsWith('/quote')) {
        body = {
          'subtotal': 1600, 'gst_pct': 5, 'gst_amount': 80, 'service_charge': 160, 'discount': 0, 'round_off': 0, 'total': 1840,
          'lines': [for (final i in view('pending')['items'] as List) {'menu_item_id': i['menu_item_id'], 'amount': i['amount']}],
        };
      } else {
        body = view(screen);
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
  final lines = [for (final i in view('pending')['items'] as List) CartLine(menuItemId: i['menu_item_id'] as String, name: i['name'] as String, qty: i['qty'] as int)];
  final Widget home = switch (screen) {
    'history' => OrdersHome(api: api),
    'cart' => CartScreen(api: api, initialLines: lines),
    _ => OrderScreen(api: api, orderId: orderId),
  };
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: posTheme(),
    builder: (context, child) => ColoredBox(
      color: const Color(0xFF1B1F1C),
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 405), child: child)),
    ),
    home: home,
  ));
}
