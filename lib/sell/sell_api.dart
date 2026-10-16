import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/orders_api.dart';

/// One sellable item as the search route describes it (`GET /api/partner/sell/catalog`).
class SellItem {
  const SellItem({required this.id, required this.name, required this.sku, required this.price, required this.category, required this.available, this.imageUrl});
  final String id, name, sku, category;
  final num price;
  final bool available;
  final String? imageUrl;

  factory SellItem.fromJson(Map<String, dynamic> j) => SellItem(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        sku: (j['sku'] ?? '') as String,
        price: (j['price'] ?? 0) as num,
        category: (j['category'] ?? '') as String,
        available: j['available'] != false,
        imageUrl: j['image_url'] as String?,
      );
}

class SellCatalog {
  const SellCatalog(this.items, this.categories);
  final List<SellItem> items;
  final List<String> categories;
}

/// One bill as the receipt list describes it: the money, the lines and the words are all the server's.
class Receipt {
  Receipt(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  num _n(String k) => (raw[k] ?? 0) as num;
  String get id => _s('id');
  String get displayNo => _s('display_no');
  String get customer => _s('customer');
  String? get customerPhone => raw['customer_phone'] as String?;
  String get when => _s('when');
  String? get paidAtLabel => raw['paid_at_label'] as String?;
  String get status => _s('status');
  String get statusLabel => _s('status_label');
  String get paymentMode => _s('payment_mode');
  String get kindLabel => _s('kind_label');
  String get counts => _s('counts');
  String get receiptText => _s('receipt_text');
  String? get couponCode => raw['coupon_code'] as String?;
  num get total => _n('total');
  num get paid => _n('paid');
  num get refunded => _n('refunded');
  num get balanceDue => _n('balance_due');
  num get subtotal => _n('subtotal');
  num get discount => _n('discount');
  num get taxAndCharges => _n('tax_and_charges');
  num get gstPct => _n('gst_pct');
  num get units => _n('units');
  String get createdAt => _s('created_at');
  List<Map<String, dynamic>> get items => ((raw['items'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// A customer return (`GET /api/partner/sell/returns`).
class ReturnRecord {
  ReturnRecord(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('id');
  String get returnNo => _s('return_no');
  String get status => _s('status');
  String get statusLabel => _s('status_label');
  String get date => _s('date');
  String get customer => _s('customer');
  String get orderNo => _s('order_no');
  String get reason => _s('reason');
  String? get note => raw['note'] as String?;
  String get statusNote => _s('status_note');
  num get amount => (raw['amount'] ?? 0) as num;
  List<Map<String, dynamic>> get lines => ((raw['lines'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// What the "Transaction failed" screen shows. [charged] is always false: a failed attempt never writes a payment.
class PaymentFailure {
  PaymentFailure(this.raw);
  final Map<String, dynamic> raw;
  String get orderId => (raw['order_id'] ?? '').toString();
  String get displayNo => (raw['display_no'] ?? '').toString();
  String get method => (raw['method'] ?? '').toString();
  String get status => (raw['status'] ?? '').toString();
  String get code => (raw['code'] ?? '').toString();
  String get message => (raw['message'] ?? '').toString();
  String get headline => (raw['headline'] ?? 'Payment failed').toString();
  String get detail => (raw['detail'] ?? '').toString();
  num get amountDue => (raw['amount_due'] ?? 0) as num;
  bool get charged => raw['charged'] == true;
}

/// Calls the POS server's section F routes (`/api/partner/sell/*`). Same credentials and the same error shape as [OrdersApi]; every rule is
/// a database function, so a manager-only action simply comes back 403 for anyone else.
class SellApi {
  SellApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const OrdersApiException(401, 'Sign in to continue.', null);
    var uri = Uri.parse('$_base/api/partner/sell$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final headers = {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json', 'Idempotency-Key': ?key};
    final res = await (method == 'GET' ? _http.get(uri, headers: headers) : _http.post(uri, headers: headers, body: jsonEncode(body ?? {}))).timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OrdersApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  Future<SellCatalog> catalog({String q = '', String? category, bool availableOnly = false, String sort = 'name'}) async {
    final r = await _send('GET', '/catalog', query: {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (category != null && category.isNotEmpty) 'category': category,
      if (availableOnly) 'available': '1',
      'sort': sort,
    });
    return SellCatalog(
      ((r['items'] as List?) ?? const []).map((e) => SellItem.fromJson((e as Map).cast<String, dynamic>())).toList(),
      ((r['categories'] as List?) ?? const []).map((e) => e.toString()).toList(),
    );
  }

  /// Pay a bill with 2 to 4 tenders at once; the parts must add up to what is due (the database checks).
  Future<OrderView> splitPay(String orderId, List<Map<String, dynamic>> parts, {Object? version, required String key}) async =>
      OrderView(await _send('POST', '/orders/$orderId/split-pay', key: key, body: {'payments': parts, 'version': version}));

  Future<OrderView> refundOrder(String orderId, {required num amount, required String method, String kind = 'goodwill', required String reason, required String key}) async =>
      OrderView(await _send('POST', '/orders/$orderId/refund', key: key, body: {'amount': amount, 'method': method, 'kind': kind, 'reason': reason}));

  Future<PaymentFailure> recordAttempt(String orderId, {required String method, String status = 'declined', String code = '', String message = ''}) async =>
      PaymentFailure(await _send('POST', '/orders/$orderId/attempts', body: {'method': method, 'status': status, 'code': code, 'message': message}));

  /// The hosted online checkout. Answers 503 `provider_not_configured` until a provider is set up on the server.
  Future<Map<String, dynamic>> onlineCheckout(String orderId) => _send('POST', '/orders/$orderId/online-checkout', body: {});

  Future<List<Receipt>> receipts({String q = '', String status = 'all', String? from, String? to}) async {
    final r = await _send('GET', '/receipts', query: {if (q.trim().isNotEmpty) 'q': q.trim(), 'status': status, 'from': ?from, 'to': ?to});
    return ((r['receipts'] as List?) ?? const []).map((e) => Receipt((e as Map).cast<String, dynamic>())).toList();
  }

  Future<List<ReturnRecord>> returns({String status = 'all', String q = ''}) async {
    final r = await _send('GET', '/returns', query: {'status': status, if (q.trim().isNotEmpty) 'q': q.trim()});
    return ((r['returns'] as List?) ?? const []).map((e) => ReturnRecord((e as Map).cast<String, dynamic>())).toList();
  }

  Future<Map<String, dynamic>> createReturn({required String orderId, required List<Map<String, dynamic>> lines, required String reason, String note = '', required String key}) =>
      _send('POST', '/returns', key: key, body: {'order_id': orderId, 'lines': lines, 'reason': reason, 'note': note});

  Future<Map<String, dynamic>> decideReturn(String id, {required bool approve, String note = ''}) =>
      _send('POST', '/returns/$id/decide', body: {'decision': approve ? 'approve' : 'reject', 'note': note});

  Future<Map<String, dynamic>> refundReturn(String id, {required String method, required String key}) => _send('POST', '/returns/$id/refund', key: key, body: {'method': method});
}
