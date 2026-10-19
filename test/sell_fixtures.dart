import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/sell/sell_api.dart';
import 'package:vinii_pos/sell/sell_carts.dart';
import 'package:vinii_pos/sell/sell_env.dart';
import 'package:vinii_pos/sell/sell_widgets.dart' show SellNavigate;
import 'package:vinii_pos/shift/shift_api.dart';

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
      // a row of pos_receipt_list as the database returns it
      'id': id, 'display_no': no, 'customer_name': name, 'customer_phone': null, 'created_at': '2026-10-09T12:53:00Z', 'paid_at': status == 'paid' ? '2026-10-09T12:53:00Z' : null,
      'order_status': status == 'paid' ? 'paid' : 'awaiting_payment', 'status': status, 'channel': 'pickup', 'total': total, 'paid': paid < 0 ? total : paid, 'refunded': refunded,
      'methods': status == 'unpaid' ? [] : [label.contains('Card') ? 'card' : 'upi'], 'units': 3, 'lines': 2,
      'items': items ?? [{'order_item_id': 'i1', 'name': 'Amul Butter 500g', 'qty': 2, 'amount': 560}, {'order_item_id': 'i2', 'name': 'Coca-Cola 500ml', 'qty': 1, 'amount': 40}],
      'subtotal': 600, 'discount': discount, 'coupon_code': coupon, 'gst_pct': 5, 'gst_amount': 30, 'service_charge': 0, 'round_off': 0,
    };

Map<String, dynamic> retRow(String id, String no, String status, {num amount = 320}) => {
      // a row of pos_return_list as the database returns it
      'id': id, 'return_no': no, 'status': status, 'reason': 'Damaged seal', 'note': 'Seal broken', 'amount': amount, 'created_at': '2026-10-09T09:00:00Z', 'decided_at': null,
      'decision_note': null, 'order_id': orderId, 'order_no': 'P-00087', 'customer_name': 'Rahul Patil', 'refund_method': null,
      'lines': [{'name': 'Horlicks 500g', 'qty': 1, 'amount': amount}],
    };

Map<String, dynamic> shiftRow({String status = 'open', num expected = 1310, num? counted, num? variance, String? reason}) => {
      // a shift as pos_till_shift_json describes it
      'id': 's1', 'shift_no': 'SH-0003', 'status': status, 'version': status == 'open' ? 1 : 2, 'location_name': 'Latur Main Branch', 'opening_float': 1000,
      'opened_at': '2026-10-20T03:30:00Z', 'closed_at': status == 'open' ? null : '2026-10-20T15:30:00Z', 'expected_cash': status == 'open' ? null : expected,
      'counted_cash': counted, 'variance': variance, 'variance_reason': reason, 'approval_note': null,
      'totals': {'opening_float': 1000, 'cash_sales': 210, 'sales_by_method': {'cash': 210, 'upi': 420}, 'bills': 3, 'cash_refunds': 0, 'refunds': 0, 'cash_in': 200, 'cash_out': 100, 'expected_cash': expected},
      'cash_moves': [{'id': 'm1', 'kind': 'in', 'amount': 200, 'reason': 'Change from bank', 'created_at': '2026-10-20T04:00:00Z'}, {'id': 'm2', 'kind': 'out', 'amount': 100, 'reason': 'Milk for tea', 'created_at': '2026-10-20T05:00:00Z'}],
    };

Map<String, dynamic> shiftCurrent({Map<String, dynamic>? shift, bool require = false, bool canApprove = false, List<Map<String, dynamic>> pending = const []}) => {
      'location_id': 'l1', 'location_name': 'Latur Main Branch', 'policy': {'require_open_shift': require, 'variance_limit': 500, 'return_days': 7},
      'shift': shift, 'must_open': shift == null && require, 'can_approve': canApprove, 'pending_approval': pending,
    };

Map<String, dynamic> intentRow({String status = 'pending', String method = 'upi', bool stale = false, Map<String, dynamic>? attempt}) => {
      'id': 'pi1', 'order_id': orderId, 'display_no': 'P-01087', 'method': method, 'amount': 630, 'status': status, 'reference': status == 'succeeded' ? 'UPI98765' : null,
      'created_at': '2026-10-20T06:00:00Z', 'resolved_at': null, 'age_seconds': stale ? 1000 : 42, 'stale': stale, 'order_status': status == 'succeeded' ? 'paid' : 'awaiting_payment',
      'total': 630, 'paid': status == 'succeeded' ? 630 : 0, 'due': status == 'succeeded' ? 0 : 630, 'attempt': attempt,
    };

/// A fake POS server for the till screens: answers section E's and section F's routes and records every request.
class Till {
  Map<String, dynamic> shift = shiftCurrent(shift: shiftRow());
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
    if (p.endsWith('/rpc/pos_sell_catalog')) {
      final b = body();
      final q = '${b['q'] ?? ''}'.toLowerCase(), cat = '${b['category'] ?? ''}';
      var list = [...sellItems];
      if (q.isNotEmpty) list = list.where((i) => '${i['name']}'.toLowerCase().contains(q) || '${i['sku']}'.toLowerCase().contains(q)).toList();
      if (cat.isNotEmpty) list = list.where((i) => i['category'] == cat).toList();
      if (b['available'] == true) list = list.where((i) => i['available'] == true).toList();
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
    if (p.endsWith('/rpc/pos_split_pay')) return ok({'order_id': orderId, 'replayed': false, 'parts': 2});
    if (p.endsWith('/pos-orders/' + orderId + '/pay')) return ok(view('pending'));
    if (p.endsWith('/cancel')) return ok(view('cancelled'));
    if (p.endsWith('/rpc/pos_payment_attempt_record')) {
      final b = body();
      return ok({'order_id': orderId, 'display_no': 'P-01087', 'method': b['method'], 'status': b['status'], 'code': b['code'], 'message': b['message'], 'amount_due': 630, 'charged': false});
    }
    if (p.endsWith('/rpc/pos_online_checkout')) return err(503, 'Online payment is not switched on for this shop yet.', 'provider_not_configured');
    if (p.endsWith('/rpc/pos_receipt_list')) {
      final status = body()['status'] ?? 'all';
      return ok(receipts.where((x) => status == 'all' || x['status'] == status).toList());
    }
    if (p.endsWith('/rpc/pos_return_list')) return ok(returns);
    if (p.endsWith('/rpc/pos_return_create')) return ok({'return_id': 't9', 'return_no': 'RET-0009', 'amount': 269.5, 'status': 'requested'});
    if (p.endsWith('/rpc/pos_return_decide')) return ok({'return_id': 't1', 'status': body()['decision'] == 'approve' ? 'approved' : 'rejected'});
    if (p.endsWith('/rpc/pos_return_issue_refund')) return ok({'return_id': 't1', 'status': 'refunded'});
    if (p.endsWith('/rpc/pos_refund')) return ok({'refund_id': 'f1', 'order_id': orderId, 'amount': 50});
    // cash shift, payment pending, refund check (0500-0502)
    if (p.endsWith('/rpc/pos_shift_current')) return ok(shift);
    if (p.endsWith('/rpc/pos_shift_list')) return ok([]);
    if (p.endsWith('/rpc/pos_shift_open')) return ok(shiftRow());
    if (p.endsWith('/rpc/pos_payment_start') || p.endsWith('/rpc/pos_payment_status')) return ok(intentRow(method: '${body()['method'] ?? 'upi'}'));
    if (p.endsWith('/rpc/pos_payment_confirm')) return ok(intentRow(status: 'succeeded'));
    if (p.endsWith('/rpc/pos_payment_fail')) {
      final st = '${body()['status'] ?? 'failed'}';
      return ok(intentRow(status: st == 'cancelled' ? 'cancelled' : 'failed', attempt: {'status': st, 'code': '', 'message': 'Not received'}));
    }
    if (p.endsWith('/rpc/pos_refund_check')) return ok({'allowed': true, 'purpose': body()['purpose'] ?? 'refund', 'reasons': [], 'display_no': 'P-00087', 'total': 630, 'taken': 630, 'refunded': 0, 'refundable_left': 630, 'return_days': 7, 'days_since_paid': 0});
    if (p.contains('/pos-orders/') && m == 'GET') return ok(view('checkout'));
    return err(404, 'unexpected ${r.method} $p');
  });

  Iterable<http.Request> where(String method, String end) => calls.where((r) => r.method == method && r.url.path.endsWith(end));

  SellEnv env({SellCarts? carts, SellNavigate? onTab, List<Uri>? opened}) => SellEnv(
        sell: SellApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: client),
        orders: OrdersApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: client),
        shift: ShiftApi(baseUrl: 'http://pos.test', accessToken: () => 'tok', client: client),
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

