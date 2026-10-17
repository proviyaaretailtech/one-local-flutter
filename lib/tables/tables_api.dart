import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
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
      if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
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

  /// "Confirm Reservation". [scheduledAt] is sent in UTC; [key] makes a retry of the same tap return the same booking.
  Future<Facts> reserve({
    required String tableId,
    required String guestName,
    required String phone,
    required int guests,
    required DateTime scheduledAt,
    String notes = '',
    required String key,
  }) async =>
      Facts(await _call('tbl_reserve', {
        'table_id': tableId,
        'guest_name': guestName.trim(),
        'phone': phone.trim(),
        'guests': guests,
        'scheduled_at': scheduledAt.toUtc().toIso8601String(),
        'notes': notes.trim(),
        'idempotency_key': key,
      }, key: key));

  Future<Facts> cancelReservation(String reservationId) async => Facts(await _call('tbl_reserve_cancel', {'id': reservationId}));

  /// "Confirm Transfer": the open orders and the guests' session move to [toTableId].
  Future<Facts> transfer(String fromTableId, String toTableId) async => Facts(await _call('tbl_transfer', {'from_table_id': fromTableId, 'to_table_id': toTableId}));

  /// "Join Tables".
  Future<Facts> merge(List<String> tableIds) async => Facts(await _call('tbl_merge', {'table_ids': tableIds}));

  /// "Split Existing Merges": by the joined group or by one of its tables.
  Future<Facts> split({String? mergeId, String? tableId}) async => Facts(await _call('tbl_split', {'merge_id': mergeId, 'table_id': tableId}));

  /// Send KOT / Generate Bill: the existing order status move (`pos_set_order_status`); the database checks the transition and the role.
  Future<void> setOrderStatus(String orderId, String to, {String? expectedUpdatedAt}) async {
    await _call('pos_set_order_status', {'order_id': orderId, 'to': to, 'expected_updated_at': expectedUpdatedAt});
  }
}

class TablesApiException extends PartnerApiException {
  const TablesApiException(super.status, super.message, this.code);
  final String? code;
}
