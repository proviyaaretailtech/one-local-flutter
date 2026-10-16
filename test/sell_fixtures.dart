import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/sell/sell_api.dart';
import 'package:vinii_pos/sell/sell_carts.dart';
import 'package:vinii_pos/sell/sell_env.dart';
import 'package:vinii_pos/sell/sell_widgets.dart' show SellNavigate;

import 'order_fixtures.dart';

// Shared by sell_test.dart and sell_frames_test.dart: a fake POS server for the till screens and the server-shaped rows it answers with.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});

const sellItems = [
  {'id': 'm1', 'name': 'Coca-Cola 500ml', 'sku': 'CC500', 'price': 40, 'category': 'Beverages', 'available': true, 'image_url': null},
  {'id': 'm2', 'name': 'Amul Butter 500g', 'sku': 'AB500', 'price': 280, 'category': 'Dairy', 'available': true, 'image_url': null},
  {'id': 'm3', 'name': 'Cadbury Dairy Milk', 'sku': 'CDM50', 'price': 10, 'category': 'Snacks', 'available': false, 'image_url': null},
];

Map<String, dynamic> receipt(String id, String no, String name, num total, {String status = 'paid', String label = 'Paid · UPI', num paid = -1, num refunded = 0, List<Map<String, dynamic>>? items, String? coupon, num discount = 0}) => {
      'id': id, 'display_no': no, 'customer': name, 'customer_phone': null, 'created_at': '2026-10-09T12:53:00Z', 'when': '9 Oct 2026 · 6:23 PM',
      'paid_at_label': status == 'paid' ? 'Paid at 6:23 PM' : null, 'status': status, 'status_label': label, 'payment_mode': 'UPI', 'channel': 'pickup',
      'total': total, 'paid': paid < 0 ? total : paid, 'refunded': refunded, 'balance_due': status == 'unpaid' ? total : 0, 'units': 3, 'lines': 2, 'counts': '2 lines · 3 units',
      'items': items ?? [{'order_item_id': 'i1', 'name': 'Amul Butter 500g', 'qty': 2, 'amount': 560}, {'order_item_id': 'i2', 'name': 'Coca-Cola 500ml', 'qty': 1, 'amount': 40}],
      'subtotal': 600, 'discount': discount, 'coupon_code': coupon, 'gst_pct': 5, 'gst_amount': 30, 'service_charge': 0, 'round_off': 0, 'tax_and_charges': 30,
      'kind_label': 'Sales receipt', 'receipt_text': 'Receipt $no\nTotal ₹$total',
    };

Map<String, dynamic> retRow(String id, String no, String status, {num amount = 320}) => {
      'id': id, 'return_no': no, 'status': status, 'status_label': {'requested': 'Requested', 'approved': 'Approved', 'rejected': 'Rejected', 'refunded': 'Refunded'}[status],
      'date': '9 Oct 2026', 'customer': 'Rahul Patil', 'order_no': 'P-00087', 'order_id': orderId, 'reason': 'Damaged seal', 'note': 'Seal broken',
      'status_note': status == 'requested' ? 'Awaiting a manager' : 'Approved · refund not issued', 'amount': amount, 'lines': [{'name': 'Horlicks 500g', 'qty': 1, 'amount': amount}],
    };

/// A fake POS server for the till screens: answers section E's and section F's routes and records every request.
class Till {
  final calls = <http.Request>[];
  http.Response? Function(http.Request r)? override;
  List<Map<String, dynamic>> receipts = [receipt('r1', 'P-00087', 'Rahul Patil', 630), receipt('r2', 'P-00086', 'Priya Shah', 920, label: 'Paid · Card')];
  List<Map<String, dynamic>> returns = [retRow('t1', 'RET-0001', 'requested')];

  late final client = MockClient((r) async {
    calls.add(r);
    final o = override?.call(r);
    if (o != null) return o;
    final p = r.url.path, m = r.method;
    Map<String, dynamic> body() => r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
    if (p.endsWith('/sell/catalog')) {
      final q = (r.url.queryParameters['q'] ?? '').toLowerCase(), cat = r.url.queryParameters['category'] ?? '';
      var list = [...sellItems];
      if (q.isNotEmpty) list = list.where((i) => '${i['name']}'.toLowerCase().contains(q) || '${i['sku']}'.toLowerCase().contains(q)).toList();
      if (cat.isNotEmpty) list = list.where((i) => i['category'] == cat).toList();
      if (r.url.queryParameters['available'] == '1') list = list.where((i) => i['available'] == true).toList();
      return ok({'items': list, 'categories': ['Beverages', 'Dairy', 'Snacks']});
    }
    if (p.endsWith('/pos-orders/quote')) {
      final b = body();
      final sub = (b['lines'] as List).fold<num>(0, (n, l) => n + (l['qty'] as num) * (l['menu_item_id'] == 'm2' ? 280 : 40));
      final code = b['coupon_code'];
      if (code == 'NOPE') return err(422, 'This coupon code is not valid.', 'coupon_unknown');
      final disc = code == 'WELCOME10' ? 50 : 0;
      final gst = ((sub - disc) * 0.05);
      return ok({'subtotal': sub, 'gst_pct': 5, 'gst_amount': gst, 'service_charge': 0, 'discount': disc, 'round_off': 0, 'total': sub - disc + gst,
        'lines': [for (final l in b['lines']) {'menu_item_id': l['menu_item_id'], 'qty': l['qty'], 'amount': (l['qty'] as num) * (l['menu_item_id'] == 'm2' ? 280 : 40)}]});
    }
    if (p.endsWith('/pos-orders/checkout')) return ok(view('pending'));
    if (p.endsWith('/pos-orders/hold')) return ok(view('checkout'));
    if (p.endsWith('/split-pay')) return ok(view('pending'));
    if (p.endsWith('/pay')) return ok(view('pending'));
    if (p.endsWith('/cancel')) return ok(view('cancelled'));
    if (p.endsWith('/attempts')) {
      final b = body();
      return ok({'order_id': orderId, 'display_no': 'P-01087', 'method': b['method'], 'status': b['status'], 'code': b['code'], 'message': b['message'],
        'headline': b['method'] == 'card' ? 'Card payment declined' : 'Online payment failed', 'detail': 'This payment was ${b['status']}. Your cart is still saved.', 'amount_due': 630, 'charged': false});
    }
    if (p.endsWith('/online-checkout')) return err(503, 'Online payment is not switched on for this shop yet.', 'provider_not_configured');
    if (p.endsWith('/sell/receipts')) {
      final status = r.url.queryParameters['status'] ?? 'all';
      return ok({'receipts': receipts.where((x) => status == 'all' || x['status'] == status).toList()});
    }
    if (p.endsWith('/sell/returns') && m == 'GET') return ok({'returns': returns});
    if (p.endsWith('/sell/returns') && m == 'POST') return ok({'return_id': 't9', 'return_no': 'RET-0009', 'amount': 269.5, 'status': 'requested'});
    if (p.endsWith('/decide')) return ok({'return_id': 't1', 'status': body()['decision'] == 'approve' ? 'approved' : 'rejected'});
    if (p.endsWith('/refund') && p.contains('/returns/')) return ok({'return_id': 't1', 'status': 'refunded'});
    if (p.endsWith('/refund')) return ok(view('completed'));
    if (p.contains('/pos-orders/') && m == 'GET') return ok(view('checkout'));
    return err(404, 'unexpected ${r.method} $p');
  });

  Iterable<http.Request> where(String method, String end) => calls.where((r) => r.method == method && r.url.path.endsWith(end));

  SellEnv env({SellCarts? carts, SellNavigate? onTab, List<Uri>? opened}) => SellEnv(
        sell: SellApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: client),
        orders: OrdersApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: client),
        carts: carts ?? SellCarts(),
        onTab: onTab,
        branchName: 'Latur Main Branch',
        openUrl: (u) async {
          opened?.add(u);
          return true;
        },
      );
}

SellCart cartWith(SellCarts carts, {int butter = 2, int cola = 1}) {
  final c = carts.active;
  for (var i = 0; i < butter; i++) {
    c.add(SellItem.fromJson(sellItems[1]));
  }
  for (var i = 0; i < cola; i++) {
    c.add(SellItem.fromJson(sellItems[0]));
  }
  return c;
}

