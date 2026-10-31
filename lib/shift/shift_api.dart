import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../orders/orders_api.dart';

num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => v is List ? v.map(_m).toList() : const [];

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A database timestamp read as India time, worded "20 Oct, 9:05 AM".
String shiftWhen(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.parse(iso).toUtc().add(const Duration(hours: 5, minutes: 30));
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.day} ${_months[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// One cash shift as the database describes it (`till_shifts` + its totals). While it is open the totals are read live from the
/// payments and refunds of the store; once closed they are the figures frozen at the close. Nothing here is computed on the phone.
class TillShift {
  TillShift(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id'] ?? ''}';
  String get shiftNo => '${raw['shift_no'] ?? ''}';
  String get status => '${raw['status'] ?? ''}';
  bool get isOpen => status == 'open';
  bool get pendingApproval => status == 'pending_approval';
  int get version => _n(raw['version']).toInt();
  String get locationName => '${raw['location_name'] ?? ''}';
  String get openedAt => shiftWhen(raw['opened_at'] as String?);
  String get closedAt => shiftWhen(raw['closed_at'] as String?);
  Map<String, dynamic> get totals => _m(raw['totals']);
  num get openingFloat => _n(raw['opening_float']);
  num get cashSales => _n(totals['cash_sales']);
  num get cashIn => _n(totals['cash_in']);
  num get cashOut => _n(totals['cash_out']);
  num get cashRefunds => _n(totals['cash_refunds']);
  int get bills => _n(totals['bills']).toInt();
  Map<String, num> get salesByMethod => _m(totals['sales_by_method']).map((k, v) => MapEntry(k, _n(v)));
  num get expectedCash => isOpen ? _n(totals['expected_cash']) : _n(raw['expected_cash']);
  num? get countedCash => raw['counted_cash'] == null ? null : _n(raw['counted_cash']);
  num? get variance => raw['variance'] == null ? null : _n(raw['variance']);
  String? get varianceReason => raw['variance_reason'] as String?;
  String? get approvalNote => raw['approval_note'] as String?;
  List<Map<String, dynamic>> get cashMoves => _l(raw['cash_moves']);
  String get statusLabel => switch (status) { 'open' => 'Open', 'pending_approval' => 'Waiting for a manager', 'closed' => 'Closed', _ => status };
}

/// The drawer of one store right now (`pos_shift_current`).
class ShiftState {
  ShiftState(this.raw);
  final Map<String, dynamic> raw;
  String get locationId => '${raw['location_id'] ?? ''}';
  String get locationName => '${raw['location_name'] ?? ''}';
  Map<String, dynamic> get policy => _m(raw['policy']);
  bool get requireOpenShift => policy['require_open_shift'] == true;
  num get varianceLimit => _n(policy['variance_limit']);
  TillShift? get shift => raw['shift'] is Map ? TillShift(_m(raw['shift'])) : null;
  bool get mustOpen => raw['must_open'] == true;
  bool get canApprove => raw['can_approve'] == true;
  List<TillShift> get pendingApproval => _l(raw['pending_approval']).map(TillShift.new).toList();
}

/// A UPI or card payment waiting for confirmation (`sell_payment_intents`). The bill is not paid while [status] is 'pending'.
class PaymentIntent {
  PaymentIntent(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id'] ?? ''}';
  String get orderId => '${raw['order_id'] ?? ''}';
  String get displayNo => '${raw['display_no'] ?? ''}';
  String get method => '${raw['method'] ?? ''}';
  String get methodLabel => method == 'upi' ? 'UPI' : method == 'card' ? 'Card' : method;
  num get amount => _n(raw['amount']);
  String get status => '${raw['status'] ?? ''}';
  bool get pending => status == 'pending';
  bool get succeeded => status == 'succeeded';
  bool get stale => raw['stale'] == true;
  int get ageSeconds => _n(raw['age_seconds']).toInt();
  String? get reference => raw['reference'] as String?;
  String get orderStatus => '${raw['order_status'] ?? ''}';
  num get due => _n(raw['due']);
  Map<String, dynamic>? get attempt => raw['attempt'] is Map ? _m(raw['attempt']) : null;
  String get age {
    final m = ageSeconds ~/ 60, s = ageSeconds % 60;
    return m == 0 ? '$s s' : '$m min ${s.toString().padLeft(2, '0')} s';
  }
}

/// Why a refund or a return may not be given (`pos_refund_check`). Every reason and its sentence is the database's.
class RefundCheck {
  RefundCheck(this.raw);
  final Map<String, dynamic> raw;
  bool get allowed => raw['allowed'] == true;
  String get purpose => '${raw['purpose'] ?? 'refund'}';
  String get displayNo => '${raw['display_no'] ?? ''}';
  List<(String, String)> get reasons => [for (final r in _l(raw['reasons'])) ('${r['code'] ?? ''}', '${r['message'] ?? ''}')];
  num get total => _n(raw['total']);
  num get taken => _n(raw['taken']);
  num get refunded => _n(raw['refunded']);
  num get refundableLeft => _n(raw['refundable_left']);
  int get returnDays => _n(raw['return_days']).toInt();
  int get daysSincePaid => _n(raw['days_since_paid']).toInt();
  bool get isManager => raw['is_manager'] == true;
}

/// Calls the cash shift, payment pending and refund check functions (migrations 0500-0502) through the POS server's one generic endpoint
/// (`POST /rpc/<function>`). Same credentials and error shape as the till; every rule is a database function.
class ShiftApi {
  ShiftApi({http.Client? client, String? baseUrl, String? Function()? accessToken}) : _rpc = RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args, [String? key]) async {
    try {
      return await _rpc.callMap(fn, args, key);
    } on RpcException catch (e) {
      throw OrdersApiException(e.status, e.message, e.code);
    }
  }

  /// Any function through the same door (the business day, day_api.dart).
  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> args, [String? key]) => _call(fn, args, key);

  Future<List<Object?>> callList(String fn, Map<String, dynamic> args) async {
    try {
      final r = await _rpc.call(fn, args);
      return r is List ? r : const [];
    } on RpcException catch (e) {
      throw OrdersApiException(e.status, e.message, e.code);
    }
  }

  Future<ShiftState> current({String? locationId}) async => ShiftState(await _call('pos_shift_current', {'location_id': ?locationId}));

  Future<List<TillShift>> history({String? locationId, int limit = 10}) async {
    try {
      final r = await _rpc.call('pos_shift_list', {'location_id': ?locationId, 'limit': limit});
      return _l(r).map(TillShift.new).toList();
    } on RpcException catch (e) {
      throw OrdersApiException(e.status, e.message, e.code);
    }
  }

  Future<TillShift> open({required num openingFloat, required String key, String? locationId}) async =>
      TillShift(await _call('pos_shift_open', {'opening_float': openingFloat, 'location_id': ?locationId}, key));

  Future<TillShift> cashMove(String shiftId, {required String kind, required num amount, required String reason, required String key}) async =>
      TillShift(await _call('pos_shift_cash_move', {'shift_id': shiftId, 'kind': kind, 'amount': amount, 'reason': reason}, key));

  Future<TillShift> close(String shiftId, {required num counted, String? reason, required String key, int? version}) async => TillShift(await _call('pos_shift_close', {
        'shift_id': shiftId,
        'counted_cash': counted,
        if (reason != null && reason.trim().isNotEmpty) 'variance_reason': reason.trim(),
        'expected_version': ?version,
      }, key));

  Future<TillShift> approve(String shiftId, {required String note}) async => TillShift(await _call('pos_shift_approve', {'shift_id': shiftId, 'note': note}));

  Future<PaymentIntent> startPayment(String orderId, {required String method, required String key}) async =>
      PaymentIntent(await _call('pos_payment_start', {'order_id': orderId, 'method': method}, key));

  Future<PaymentIntent> confirmPayment(String intentId, {required String reference}) async =>
      PaymentIntent(await _call('pos_payment_confirm', {'intent_id': intentId, 'reference': reference.trim()}));

  Future<PaymentIntent> failPayment(String intentId, {String status = 'failed', String message = ''}) async =>
      PaymentIntent(await _call('pos_payment_fail', {'intent_id': intentId, 'status': status, if (message.isNotEmpty) 'message': message}));

  Future<PaymentIntent> paymentStatus({String? intentId, String? orderId}) async =>
      PaymentIntent(await _call('pos_payment_status', {'intent_id': ?intentId, 'order_id': ?orderId}));

  Future<RefundCheck> refundCheck(String orderId, {String purpose = 'refund', num? amount}) async =>
      RefundCheck(await _call('pos_refund_check', {'order_id': orderId, 'purpose': purpose, 'amount': ?amount}));
}
