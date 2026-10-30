import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../orders/orders_api.dart';

/// One sellable item as the search route describes it (`GET /api/partner/sell/catalog`).
class SellItem {
  const SellItem({required this.id, required this.name, required this.sku, required this.price, required this.category, required this.available, this.imageUrl, this.loose = false, this.plu, this.barcode});
  final String id, name, sku, category;
  final num price;
  final bool available;
  final String? imageUrl;

  /// Sold loose, by weight (30 Oct 2026): [price] is per kg and each pack is weighed; [plu] is its number on weigh labels.
  final bool loose;
  final int? plu;
  final String? barcode;

  factory SellItem.fromJson(Map<String, dynamic> j) => SellItem(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        sku: (j['sku'] ?? '') as String,
        price: (j['price'] ?? 0) as num,
        category: (j['category'] ?? '') as String,
        available: j['available'] != false,
        imageUrl: j['image_url'] as String?,
        loose: j['loose'] == true,
        plu: (j['plu'] as num?)?.toInt(),
        barcode: j['barcode'] as String?,
      );
}

class SellCatalog {
  const SellCatalog(this.items, this.categories);
  final List<SellItem> items;
  final List<String> categories;
}

/// What the till's catalogue does not carry about an item (Figma "444 Discount"): the MRP to strike through and the stock behind it.
/// From the catalogue list (MRP, stock count) and the stock list (low / out status, daily sales); any part may be missing.
class SellFacts {
  const SellFacts({this.mrp, this.stockQty, this.stockKnown = false, this.status, this.perDay});
  final num? mrp, stockQty;
  final bool stockKnown;

  /// healthy / low / critical / out / near_expiry, from the stock list; null when this person cannot see stock.
  final String? status;

  /// Units sold per day, from the stock list (available ÷ days of stock); null when there are no recent sales.
  final double? perDay;

  bool get outOfStock => stockKnown && (stockQty ?? 0) <= 0;
  bool get lowInventory => status == 'low' || status == 'critical' || status == 'out';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _methodNames = {'cash': 'Cash', 'upi': 'UPI', 'card': 'Card', 'split': 'Split', 'wallet': 'Wallet', 'online': 'Online', 'other': 'Other', 'due': 'Due'};

/// A database timestamp read as India time (the shops are in India; the database keeps UTC).
DateTime _ist(String iso) => DateTime.parse(iso).toUtc().add(const Duration(hours: 5, minutes: 30));
String _day(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
String _clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String _plural(num n, String one) => '$n ${n == 1 ? one : '${one}s'}';

/// One bill as `pos_receipt_list` describes it. The money, the lines and the status are the database's; this class only words them.
class Receipt {
  Receipt(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  num _n(String k) => (raw[k] ?? 0) as num;
  String get id => _s('id');
  String get displayNo => _s('display_no');
  String get customer => (raw['customer_name'] as String?)?.isNotEmpty == true ? raw['customer_name'] as String : 'Guest';
  String? get customerPhone => raw['customer_phone'] as String?;
  String get createdAt => _s('created_at');
  String get when => '${_day(_ist(createdAt))} · ${_clock(_ist(createdAt))}';
  String? get paidAtLabel => status == 'paid' && raw['paid_at'] != null ? 'Paid at ${_clock(_ist(_s('paid_at')))}' : null;
  String get status => _s('status');
  List<String> get methods => ((raw['methods'] as List?) ?? const []).map((e) => e.toString()).toList();
  String get paymentMode => methods.length > 1 ? 'Split' : methods.length == 1 ? (_methodNames[methods[0]] ?? methods[0]) : 'Not chosen';
  String get statusLabel => switch (status) {
        'paid' => 'Paid · $paymentMode',
        'refunded' => 'Refunded · ${rupees(refunded)}',
        'part_paid' => 'Partially paid',
        'unpaid' => 'Unpaid',
        'cancelled' => 'Cancelled',
        _ => status,
      };
  String get kindLabel => status == 'paid' ? 'Sales receipt' : 'Sales invoice';
  String get counts => '${_plural(_n('lines'), 'line')} · ${_plural(units, 'unit')}';
  String? get couponCode => raw['coupon_code'] as String?;
  num get total => _n('total');
  num get paid => _n('paid');
  num get refunded => _n('refunded');
  num get balanceDue => status == 'part_paid' || status == 'unpaid' ? ((total - paid) < 0 ? 0 : (total - paid)) : 0;
  num get subtotal => _n('subtotal');
  num get discount => _n('discount');
  num get serviceCharge => _n('service_charge');
  num get gstAmount => _n('gst_amount');
  num get taxAndCharges => ((gstAmount + serviceCharge) * 100).round() / 100;
  num get gstPct => _n('gst_pct');
  num get units => _n('units');
  List<Map<String, dynamic>> get items => ((raw['items'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  /// Plain-text receipt (what Print / Download copies).
  String get receiptText {
    final out = <String>['Receipt $displayNo', when, ''];
    for (final i in items) {
      out.add('${i['qty']} x ${i['name']}  ${rupees((i['amount'] ?? 0) as num)}');
    }
    out.addAll(['', 'Subtotal ${rupees(subtotal)}']);
    if (gstAmount != 0) out.add('GST (${gstPct == gstPct.roundToDouble() ? gstPct.toInt() : gstPct}%) ${rupees(gstAmount)}');
    if (serviceCharge != 0) out.add('Service charge ${rupees(serviceCharge)}');
    if (discount != 0) out.add('Discount${couponCode == null ? '' : ' $couponCode'} -${rupees(discount)}');
    if (_n('round_off') != 0) out.add('Round off ${rupees(_n('round_off'))}');
    out.add('Total ${rupees(total)}');
    out.add(paid > 0 ? 'Paid ${rupees(paid)} ($paymentMode)' : 'Not paid');
    if (refunded > 0) out.add('Refunded ${rupees(refunded)}');
    return out.join('\n');
  }
}

/// A customer return as `pos_return_list` describes it.
class ReturnRecord {
  ReturnRecord(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('id');
  String get returnNo => _s('return_no');
  String get status => _s('status');
  String get statusLabel => const {'requested': 'Requested', 'approved': 'Approved', 'rejected': 'Rejected', 'refunded': 'Refunded'}[status] ?? status;
  String get date => _day(_ist(_s('created_at')));
  String get customer => (raw['customer_name'] as String?)?.isNotEmpty == true ? raw['customer_name'] as String : 'Guest';
  String get orderNo => _s('order_no');
  String get reason => _s('reason');
  String? get note => (raw['note'] as String?)?.isEmpty == true ? null : raw['note'] as String?;
  String get statusNote {
    final m = raw['refund_method'] as String?;
    final d = raw['decision_note'] as String?;
    return switch (status) {
      'refunded' => m == null ? 'Refund issued' : 'Refund issued · ${_methodNames[m] ?? m}',
      'rejected' => d == null || d.isEmpty ? 'Rejected' : 'Rejected · $d',
      'approved' => 'Approved · refund not issued',
      _ => 'Awaiting a manager',
    };
  }

  num get amount => (raw['amount'] ?? 0) as num;
  List<Map<String, dynamic>> get lines => ((raw['lines'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// What the "Transaction failed" screen shows (built from the logged attempt). [charged] is always false: a failed attempt never writes a payment.
class PaymentFailure {
  PaymentFailure(this.raw);
  final Map<String, dynamic> raw;
  String get orderId => (raw['order_id'] ?? '').toString();
  String get displayNo => (raw['display_no'] ?? '').toString();
  String get method => (raw['method'] ?? '').toString();
  String get status => (raw['status'] ?? '').toString();
  String get code => (raw['code'] ?? '').toString();
  String get message => (raw['message'] ?? '').toString();
  String get headline {
    final name = method == 'online' ? 'Online payment' : '${_methodNames[method] ?? method} payment';
    return '$name ${status == 'cancelled' ? 'cancelled' : status == 'declined' ? 'declined' : 'failed'}';
  }

  String get detail => 'This payment was $status. Your cart is still saved.';
  num get amountDue => (raw['amount_due'] ?? 0) as num;
  bool get charged => raw['charged'] == true;
}

/// Calls the till's database functions through the POS server's one generic endpoint (`POST /rpc/<function>`). Same credentials and the
/// same error shape as [OrdersApi]; every rule is a database function, so a manager-only action simply comes back 403 for anyone else.
class SellApi {
  SellApi({http.Client? client, String? baseUrl, String? Function()? accessToken, OrdersApi? orders})
      : _rpc = RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken),
        _orders = orders ?? OrdersApi(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;
  final OrdersApi _orders;

  /// The gateway's refusal as the exception the till screens already handle.
  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args, [String? key]) async {
    try {
      return await _rpc.callMap(fn, args, key);
    } on RpcException catch (e) {
      throw OrdersApiException(e.status, e.message, e.code);
    }
  }

  /// MRP and stock for each sellable item, keyed by its catalogue id (the same id the till sells). The catalogue list gives MRP and the
  /// stock count; the stock list (when this person may see stock) adds the low/out status and daily sales. Never throws: an empty map
  /// only means the cards show the price alone and the stock tabs stay hidden.
  Future<Map<String, SellFacts>> facts() async {
    final cat = <Map<String, dynamic>>[];
    try {
      for (var page = 1; page <= 5; page++) {
        final r = await _call('cat_item_list', {'page': page, 'page_size': 100});
        final items = ((r['items'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        cat.addAll(items);
        if (items.length < 100) break;
      }
    } catch (_) {
      return const {};
    }
    final stock = <String, Map<String, dynamic>>{};
    try {
      for (var page = 1; page <= 10; page++) {
        final r = await _call('inv_stock_list', {'filter': 'all', 'page': page, 'page_size': 50});
        final items = ((r['items'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        for (final s in items) {
          stock[s['id'].toString()] = s;
        }
        if (items.length < 50) break;
      }
    } catch (_) {
      // no stock permission: MRP and the stock count still show
    }
    return {
      for (final c in cat)
        c['id'].toString(): () {
          final s = stock[c['inventory_item_id']?.toString()];
          final available = s?['available'] as num?, days = s?['stock_days'] as num?;
          return SellFacts(
            mrp: (c['mrp_minor'] as num?) == null ? null : (c['mrp_minor'] as num) / 100,
            stockQty: c['stock_qty'] as num?,
            stockKnown: c['stock_known'] == true,
            status: s?['status'] as String?,
            perDay: available != null && days != null && available > 0 && days > 0 ? available / days : null,
          );
        }(),
    };
  }

  /// Bought together (market basket analysis on the server, 27 Oct 2026): product ids ranked by how often they were on the same bill
  /// as [inCart], best first; with an empty cart, the best sellers.
  Future<List<String>> boughtWith(List<String> inCart) async {
    final r = await _call('pos_basket_suggest', {'item_ids': inCart, 'limit': 12});
    return [for (final i in (r['items'] as List?) ?? const []) '${(i as Map)['menu_item_id']}'];
  }

  Future<SellCatalog> catalog({String q = '', String? category, bool availableOnly = false, String sort = 'name'}) async {
    final r = await _call('pos_sell_catalog', {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (category != null && category.isNotEmpty) 'category': category,
      if (availableOnly) 'available': true,
      'sort': sort,
    });
    return SellCatalog(
      ((r['items'] as List?) ?? const []).map((e) => SellItem.fromJson((e as Map).cast<String, dynamic>())).toList(),
      ((r['categories'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }

  /// Pay a bill with 2 to 4 tenders at once; the parts must add up to what is due (the database checks).
  Future<OrderView> splitPay(String orderId, List<Map<String, dynamic>> parts, {Object? version, required String key}) async {
    await _call('pos_split_pay', {'order_id': orderId, 'payments': parts, if (version is String && version.isNotEmpty) 'expected_updated_at': version}, key);
    return _orders.get(orderId);
  }

  Future<OrderView> refundOrder(String orderId, {required num amount, required String method, String kind = 'goodwill', required String reason, required String key}) async {
    await _call('pos_refund', {'order_id': orderId, 'amount': amount, 'method': method, 'kind': kind, 'reason': reason}, key);
    return _orders.get(orderId);
  }

  Future<PaymentFailure> recordAttempt(String orderId, {required String method, String status = 'declined', String code = '', String message = ''}) async =>
      PaymentFailure(await _call('pos_payment_attempt_record', {'order_id': orderId, 'method': method, 'status': status, 'code': code, 'message': message}));

  /// The hosted online checkout. Answers 503 `provider_not_configured` until a payment provider is set up.
  Future<Map<String, dynamic>> onlineCheckout(String orderId) => _call('pos_online_checkout', {'order_id': orderId});

  Future<List<Receipt>> receipts({String q = '', String status = 'all', String? from, String? to}) async {
    final r = await _rpc.call('pos_receipt_list', {if (q.trim().isNotEmpty) 'q': q.trim(), 'status': status, 'from': ?from, 'to': ?to}).catchError(_refuse);
    return ((r as List?) ?? const []).map((e) => Receipt((e as Map).cast<String, dynamic>())).toList();
  }

  Future<List<ReturnRecord>> returns({String status = 'all', String q = ''}) async {
    final r = await _rpc.call('pos_return_list', {'status': status, if (q.trim().isNotEmpty) 'q': q.trim()}).catchError(_refuse);
    return ((r as List?) ?? const []).map((e) => ReturnRecord((e as Map).cast<String, dynamic>())).toList();
  }

  Future<Map<String, dynamic>> createReturn({required String orderId, required List<Map<String, dynamic>> lines, required String reason, String note = '', required String key}) =>
      _call('pos_return_create', {'order_id': orderId, 'lines': lines, 'reason': reason, 'note': note}, key);

  Future<Map<String, dynamic>> decideReturn(String id, {required bool approve, String note = ''}) =>
      _call('pos_return_decide', {'return_id': id, 'decision': approve ? 'approve' : 'reject', 'note': note});

  Future<Map<String, dynamic>> refundReturn(String id, {required String method, required String key}) => _call('pos_return_issue_refund', {'return_id': id, 'method': method}, key);

  static Never _refuse(Object e) {
    if (e is RpcException) throw OrdersApiException(e.status, e.message, e.code);
    throw e;
  }
}
