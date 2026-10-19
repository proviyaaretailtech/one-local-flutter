import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';
import '../api/app_env.dart';

/// One order as the server describes it (`GET /api/partner/pos-orders/:id`). Read-only: the stage, every label, the bill,
/// the payment record and the actions allowed right now all come from the server; the app only draws them.
class OrderView {
  OrderView(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  String _s(String k) => (raw[k] ?? '').toString();

  String get id => _s('id');
  String get displayNo => _s('display_no');
  String get stage => _s('stage');
  String get title => _s('title');
  bool get danger => raw['danger'] == true;
  bool get online => raw['online'] == true;
  String get channelLabel => _s('channel_label');
  String? get placeLabel => raw['place_label'] as String?;
  String get customer => _s('customer');
  String get placedAt => _s('placed_at');
  String get orderStatus => _s('order_status');
  String get fulfilment => _s('fulfilment');
  String get paymentChip => _s('payment_chip');
  String get summary => _s('summary');
  String get adjustments => _s('adjustments');
  String get receiptText => _s('receipt_text');
  String? get cancelReason => raw['cancel_reason'] as String?;

  /// Fulfilment moves send an integer version; a held bill (pay, cancel) sends the order's timestamp. Passed back as given.
  Object? get version => raw['version'];

  Map<String, dynamic> get note => _m('note');
  Map<String, dynamic> get bill => _m('bill');
  Map<String, dynamic> get payment => _m('payment');
  Map<String, dynamic>? get paymentRecord => (payment['record'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get delivery => (raw['delivery'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get exception => (raw['exception'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> _list(String k) => ((raw[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  List<Map<String, dynamic>> get items => _list('items');
  List<Map<String, dynamic>> get actions => _list('actions');
  List<Map<String, dynamic>> get events => _list('events');

  Map<String, dynamic>? action(String style) {
    for (final a in actions) {
      if (a['style'] == style) return a;
    }
    return null;
  }

  List<Map<String, dynamic>> actionsOf(String style) => actions.where((a) => a['style'] == style).toList();
}

/// One row of the history list (`GET /api/partner/pos-orders`).
class OrderCard {
  OrderCard(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('id');
  String get displayNo => _s('display_no');
  String get channelLabel => _s('channel_label');
  String get customer => _s('customer');
  String get placedAt => _s('placed_at');
  String get status => _s('status');
  String get statusLabel => _s('status_label');
  num get total => (raw['total'] ?? 0) as num;
  String get items => _s('items');
  String get paymentStatus => _s('payment_status');
  String get paymentMode => _s('payment_mode');
  String get deliveryStatus => _s('delivery_status');
  String get deliveryTime => _s('delivery_time');
  String get refundDamages => _s('refund_damages');
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
num _num(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;

/// One card of the Live orders board (`pos_orders_board`). Status, minutes and "delayed" are the database's; the app only prints them.
class LiveOrder {
  LiveOrder(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('order_id');
  String get displayNo => _s('display_no');
  DateTime? get placedAt => DateTime.tryParse(_s('placed_at'))?.toLocal();
  String get customer => _s('customer');
  String get items => _s('items');
  String? get note => (raw['note'] as String?)?.trim().isEmpty ?? true ? null : raw['note'] as String;
  String get channel => _s('channel');
  String? get channelTag => raw['channel_tag'] as String?;
  String? get externalId => raw['external_id'] as String?;
  String? get table => raw['table'] as String?;
  String get status => _s('status');
  int get minutes => _int(raw['minutes']);
  bool get delayed => raw['delayed'] == true;
  num get total => _num(raw['total']);
}

/// One aggregator channel's state as the database reports it (never invented: no connection = offline).
class ChannelState {
  ChannelState(this.raw);
  final Map<String, dynamic> raw;
  String get channel => '${raw['channel'] ?? ''}';
  String get name => '${raw['name'] ?? ''}';
  bool get online => raw['state'] == 'online';
  String? get reason => raw['reason'] as String?;
}

class OrdersBoard {
  OrdersBoard(this.raw);
  final Map<String, dynamic> raw;
  Map<String, dynamic> get _header => (raw['header'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get business => '${_header['business'] ?? ''}';
  String? get outlet => _header['outlet'] as String?;
  /// One Local switch: true online, false offline, null when the business is not on One Local.
  bool? get accepting => _header['accepting'] as bool?;
  int count(String status) => _int(((raw['counts'] as Map?) ?? const {})[status]);
  int live(String channel) => _int(((raw['channels'] as List?) ?? const []).cast<Map>().where((c) => c['key'] == channel).firstOrNull?['live']);
  List<LiveOrder> get orders => ((raw['orders'] as List?) ?? const []).map((e) => LiveOrder((e as Map).cast<String, dynamic>())).toList();
  ChannelState? integration(String channel) =>
      ((raw['integrations'] as List?) ?? const []).map((e) => ChannelState((e as Map).cast<String, dynamic>())).where((c) => c.channel == channel).firstOrNull;
}

/// One open held bill (`pos_hold_list`).
class HeldBill {
  HeldBill(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('order_id');
  String get displayNo => _s('display_no');
  String get channel => _s('channel');
  String get source => _s('source');
  String get customer => _s('customer');
  String? get reason => (raw['reason'] as String?)?.trim().isEmpty ?? true ? null : raw['reason'] as String;
  String get items => _s('items');
  String? get note => (raw['note'] as String?)?.trim().isEmpty ?? true ? null : raw['note'] as String;
  num get total => _num(raw['total']);
  int get minutes => _int(raw['minutes']);
  bool get delayed => raw['delayed'] == true;
  bool get hasCoupon => raw['has_coupon'] == true;
  /// The bill's version (its updated_at), sent back on resume and cancel.
  Object? get version => raw['version'];
}

class HoldList {
  HoldList(this.raw);
  final Map<String, dynamic> raw;
  int get delayedAfter => _int(raw['delayed_after_minutes']);
  List<HeldBill> get holds => ((raw['holds'] as List?) ?? const []).map((e) => HeldBill((e as Map).cast<String, dynamic>())).toList();
  Map<String, dynamic>? get oldest => (raw['oldest'] as Map?)?.cast<String, dynamic>();
}

/// Server totals for a cart that is not placed yet (`POST /quote`).
class Quote {
  Quote(this.raw);
  final Map<String, dynamic> raw;
  num _n(String k) => num.tryParse('${raw[k] ?? 0}') ?? 0;
  num get subtotal => _n('subtotal');
  num get gstPct => _n('gst_pct');
  num get gst => _n('gst_amount');
  num get serviceCharge => _n('service_charge');
  num get discount => _n('discount');
  num get roundOff => _n('round_off');
  num get total => _n('total');
  List<Map<String, dynamic>> get lines => ((raw['lines'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

class CatalogItem {
  const CatalogItem({required this.id, required this.name, required this.price});
  final String id, name;
  final num price;
}

/// A line the person is building (not placed). Only the item and the quantity go to the server; it sets the price.
class CartLine {
  CartLine({required this.menuItemId, required this.name, this.qty = 1});
  final String menuItemId, name;
  int qty;
  Map<String, dynamic> toJson() => {'menu_item_id': menuItemId, 'qty': qty};
}

/// Calls One Local's server (`/api/partner/pos-orders/*`). The Supabase session token is the only credential; the server and the
/// database check the business, the role and every rule again. Writes carry an Idempotency-Key so a retried tap never doubles.
class OrdersApi {
  OrdersApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? AppEnv.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'pos-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    var uri = Uri.parse('$_base/api/partner/pos-orders$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final headers = {
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
      'Idempotency-Key': ?key,
    };
    final res = await (method == 'GET' ? _http.get(uri, headers: headers) : _http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)))
        .timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OrdersApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  Future<List<OrderCard>> history({String filter = 'all', String q = ''}) async {
    final r = await _send('GET', '', query: {'filter': filter, if (q.trim().isNotEmpty) 'q': q.trim()});
    return ((r['orders'] as List?) ?? const []).map((e) => OrderCard((e as Map).cast<String, dynamic>())).toList();
  }

  Future<List<CatalogItem>> catalog({String q = ''}) async {
    final r = await _send('GET', '/catalog', query: {if (q.trim().isNotEmpty) 'q': q.trim()});
    return ((r['items'] as List?) ?? const [])
        .map((e) => CatalogItem(id: e['id'] as String, name: e['name'] as String, price: (e['price'] ?? 0) as num))
        .toList();
  }

  Future<Quote> quote(List<CartLine> lines, {String? coupon}) async =>
      Quote(await _send('POST', '/quote', body: {'lines': lines.map((l) => l.toJson()).toList(), 'coupon_code': ?coupon}));

  // customerName / customerPhone / couponCode (section F): who the bill is for and the coupon; the server prices the coupon.
  Future<OrderView> checkout({required List<CartLine> lines, required String method, num? tendered, String? reference, required String key, String? customerName, String? customerPhone, String? couponCode}) async =>
      OrderView(await _send('POST', '/checkout', key: key, body: {
        'lines': lines.map((l) => l.toJson()).toList(),
        'method': method,
        'tendered': ?tendered,
        if (reference != null && reference.isNotEmpty) 'reference': reference,
        if (customerName != null && customerName.isNotEmpty) 'customer_name': customerName,
        if (customerPhone != null && customerPhone.isNotEmpty) 'customer_phone': customerPhone,
        if (couponCode != null && couponCode.isNotEmpty) 'coupon_code': couponCode,
      }));

  Future<OrderView> hold({required List<CartLine> lines, required String key, String? reason, String? customerName, String? customerPhone, String? couponCode}) async =>
      OrderView(await _send('POST', '/hold', key: key, body: {
        'lines': lines.map((l) => l.toJson()).toList(),
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        if (customerName != null && customerName.isNotEmpty) 'customer_name': customerName,
        if (customerPhone != null && customerPhone.isNotEmpty) 'customer_phone': customerPhone,
        if (couponCode != null && couponCode.isNotEmpty) 'coupon_code': couponCode,
      }));

  Future<OrderView> get(String id) async => OrderView(await _send('GET', '/$id'));

  /// The generic gateway door (`POST /rpc/<fn>`, allowlist in server/src/rpc-manifest.ts), used by the Orders tab (migrations 0530-0531).
  Future<Map<String, dynamic>> _rpc(String fn, Map<String, dynamic> args, {String? key}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final res = await _http
        .post(Uri.parse('$_base/rpc/$fn'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Idempotency-Key': ?key}, body: jsonEncode(args))
        .timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OrdersApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  /// Live orders: counts per status, channel totals, Zomato / Swiggy state and the cards of one channel and status (`pos_orders_board`).
  Future<OrdersBoard> board({String channel = 'all', String status = 'new', String q = '', String? locationId}) async => OrdersBoard(await _rpc('pos_orders_board', {
        'channel': channel,
        'status': status,
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'location_id': ?locationId,
      }));

  /// Hold orders: open held bills with their age and reason, and the oldest one (`pos_hold_list`).
  Future<HoldList> holds({String channel = 'all', String q = '', String? locationId}) async => HoldList(await _rpc('pos_hold_list', {
        'channel': channel,
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'location_id': ?locationId,
      }));

  /// Resume POS: rewrites the held bill's lines (and/or reason) ON THE SAME ORDER; answers the bill's new version (`pos_hold_update`).
  /// The same [key] again is a replay. Pay afterwards with [pay] and that version.
  Future<String> updateHold(String orderId, {List<CartLine>? lines, String? reason, required Object? version, required String key}) async {
    final r = await _rpc('pos_hold_update', {
      'order_id': orderId,
      'expected_updated_at': '$version',
      'lines': ?lines?.map((l) => l.toJson()).toList(),
      'reason': ?reason,
      'idempotency_key': key,
    }, key: key);
    return '${r['updated_at'] ?? version}';
  }

  Future<OrderView> pay(String id, {required String method, num? tendered, String? reference, Object? version, required String key}) async =>
      OrderView(await _send('POST', '/$id/pay', key: key, body: {
        'method': method,
        'tendered': ?tendered,
        if (reference != null && reference.isNotEmpty) 'reference': reference,
        'version': version,
      }));

  Future<OrderView> cancel(String id, {required String reason, Object? version}) async =>
      OrderView(await _send('POST', '/$id/cancel', body: {'reason': reason, 'version': version}));

  Future<OrderView> act(String id, String action, {Object? version, List<Map<String, dynamic>>? lines, Map<String, String>? delivery, String? note, String? reason, String? key}) async =>
      OrderView(await _send('POST', '/$id/act', key: key ?? newKey(), body: {
        'action': action,
        'version': version,
        'lines': ?lines,
        'delivery': ?delivery,
        'note': ?note,
        'reason': ?reason,
      }));
}

class OrdersApiException extends PartnerApiException {
  const OrdersApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}

/// ₹1,740 / ₹1,740.50 — display only; every amount comes from the server.
String rupees(num v) {
  final neg = v < 0;
  final a = v.abs();
  final whole = a.truncate();
  final paise = ((a - whole) * 100).round();
  final s = whole.toString();
  String grouped;
  if (s.length <= 3) {
    grouped = s;
  } else {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  return '${neg ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}
