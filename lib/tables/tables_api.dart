import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../outlets/outlet_scope.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;

/// Tables-and-floor calls through the one generic door, `POST /rpc/<tbl_function>` ([RpcClient]); the database functions of migration 0404
/// do the work and check the business, the store, the role and every rule (state, capacity, overlap, merge). The app only draws the answers.
/// Reserving carries an Idempotency-Key so a retried tap never books twice.
class TablesApi {
  TablesApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The store the screens look at; null lets the database pick the person's main store.
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'tbl-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{
      // the outlet chosen in the header's switcher when the screen names none (specs/outlets-multi)
      if (OutletScope.pick(locationId) != null) 'location_id': OutletScope.pick(locationId),
      ...args,
    }..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw TablesApiException(e.status, e.message, e.code);
    }
  }

  /// The grid: every table with its state and time, plus the counts for the filter chips. [status] is all / available / occupied / reserved / cleaning.
  Future<Facts> floor({String status = 'all', String? areaId}) async => Facts(await _call('tbl_floor', {'status': status, 'area_id': areaId}));

  /// One table for the bottom sheet and the actions screen (state, bill, guests, waiter, what may be done).
  Future<Facts> view(String tableId) async => Facts(await _call('tbl_view', {'table_id': tableId}));

  /// "Table T12 Order": items, kitchen status, timeline, subtotal and which buttons are allowed.
  Future<Facts> orderView(String tableId) async => Facts(await _call('tbl_order_view', {'table_id': tableId}));

  Future<List<Facts>> history(String tableId, {int limit = 20}) async => Facts(await _call('tbl_history', {'table_id': tableId, 'limit': limit})).l('entries');

  /// "Confirm Reservation". The date and time are the STORE's wall clock ([localDate] yyyy-MM-dd, [localTime] HH:mm); the database reads them in the
  /// store's time zone and checks the store's hours. [key] makes a retry of the same tap return the same booking.
  Future<Facts> reserve({
    required String tableId,
    required String guestName,
    required String phone,
    required int guests,
    required String localDate,
    required String localTime,
    String notes = '',
    required String key,
  }) async =>
      Facts(await _call('tbl_reserve', {
        'table_id': tableId,
        'guest_name': guestName.trim(),
        'phone': phone.trim(),
        'guests': guests,
        'local_date': localDate,
        'local_time': localTime,
        'notes': notes.trim(),
        'idempotency_key': key,
      }, key: key));

  /// [outcome] is cancelled, or no_show once the booking time has passed.
  Future<Facts> cancelReservation(String reservationId, {String outcome = 'cancelled'}) async =>
      Facts(await _call('tbl_reserve_cancel', {'id': reservationId, if (outcome != 'cancelled') 'outcome': outcome}));

  /// "Confirm Transfer": the open orders and the guests' session move to [toTableId].
  Future<Facts> transfer(String fromTableId, String toTableId) async => Facts(await _call('tbl_transfer', {'from_table_id': fromTableId, 'to_table_id': toTableId}));

  /// "Join Tables".
  Future<Facts> merge(List<String> tableIds) async => Facts(await _call('tbl_merge', {'table_ids': tableIds}));

  /// "Split Existing Merges": by the joined group or by one of its tables.
  Future<Facts> split({String? mergeId, String? tableId}) async => Facts(await _call('tbl_split', {'merge_id': mergeId, 'table_id': tableId}));

  // ---- take an order at a table (migration 0485)

  /// The dishes and their categories (the till's catalogue read, `pos_sell_catalog`); only dishes on sale.
  Future<Facts> menu() async => Facts(await _call('pos_sell_catalog', {'available': true}));

  /// Add dishes to the table: [send] true fires a KOT for every dish not yet sent ("Send to kitchen"), false holds them ("Save and hold").
  /// [key] is one per tap: a retry sends the same key and gets the same answer.
  Future<Facts> addDishes(String tableId, List<Map<String, Object?>> lines, {required bool send, required String key, int? guests}) async =>
      Facts(await _call('tbl_order_add', {'table_id': tableId, 'lines': lines, 'send': send, 'guest_count': guests}, key: key));

  /// Send the held dishes of the table's order as a new KOT.
  Future<Facts> sendHeld(String tableId, {required String key}) async => Facts(await _call('tbl_kot_send', {'table_id': tableId}, key: key));

  /// Ready to serve: the store's table dishes in the kitchen or ready.
  Future<Facts> readyList() async => Facts(await _call('tbl_ready_list', {}));

  /// Mark dishes as served. Safe to repeat: dishes already served are counted, not refused.
  Future<Facts> markServed(List<String> itemIds) async => Facts(await _call('tbl_mark_served', {'item_ids': itemIds}));

  /// Send KOT / Generate Bill: the existing order status move (`pos_set_order_status`); the database checks the transition and the role.
  Future<void> setOrderStatus(String orderId, String to, {String? expectedUpdatedAt}) async {
    await _call('pos_set_order_status', {'order_id': orderId, 'to': to, 'expected_updated_at': expectedUpdatedAt});
  }
}

class TablesApiException extends PartnerApiException {
  const TablesApiException(super.status, super.message, this.code);
  final String? code;
}
