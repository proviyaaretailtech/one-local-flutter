import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;

/// Kitchen stations and the Kitchen Display System through the one generic door, `POST /rpc/<function>` ([RpcClient]); the database functions of
/// migrations 0480-0481 do the work and check the business, the location, the role and every rule. Writes carry an Idempotency-Key so a retried tap
/// never doubles; ticket actions carry the `updated_at` the person saw so a screen that is out of date is refused.
class KitchenApi {
  KitchenApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;
  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'kit-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{...args}..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw KitchenApiException(e.status, e.message, e.code);
    }
  }

  /// Stations, kitchen printers and preparation areas, and whether the person may change them.
  Future<Facts> config() async => Facts(await _call('kitchen_config', {}));

  Future<Facts> station(String id) async => Facts(await _call('kitchen_station_view', {'id': id}));

  /// Creates a station. (Changing one sends `id` and the `version` seen, plus only the fields to change; no screen does that yet.)
  Future<Facts> saveStation({required String name, String? kdsGroupId, String? printerId, String? prepAreaId, String? key}) async =>
      Facts(await _call('kitchen_station_save', {'name': name, 'kds_group_id': kdsGroupId, 'printer_id': printerId, 'prep_area_id': prepAreaId}, key: key ?? newKey()));

  /// The display: counters, status chips and ticket cards. [status] is all | new | in_progress | ready | served; [station] a station key.
  Future<Facts> queue({String? station, String status = 'all', String q = ''}) async =>
      Facts(await _call('kds_queue', {'station': station, 'status': status, 'q': q.trim().isEmpty ? null : q.trim()}));

  /// Each dish's photo and category (the till's menu read, `pos_sell_catalog`), for the KDS board's pictures and its Category list.
  Future<Map<String, ({String? image, String category})>> dishes() async {
    final r = await _call('pos_sell_catalog', {});
    return {
      for (final i in (r['items'] as List?) ?? const [])
        if (i is Map) '${i['name']}': (image: (i['image_url'] as String?)?.trim().isEmpty ?? true ? null : i['image_url'] as String, category: '${i['category'] ?? ''}'),
    };
  }

  /// The KOT view (0609 `rst_kot_orders`): today's orders that went to the kitchen, each with its KOTs, stations and ready count.
  Future<Facts> kotOrders({String status = 'all'}) async => Facts(await _call('rst_kot_orders', {'status': status}));

  /// Serve the ready dishes of an order (the floor's `tbl_mark_served`); safe to repeat.
  Future<Facts> serve(List<String> itemIds) async => Facts(await _call('tbl_mark_served', {'item_ids': itemIds}));

  /// start / item_done / item_undo / ready / serve / print on ONE card: [station] is the card's station key (a ticket with items for several stations
  /// is acted on one station at a time) and [version] the card's `version` the person saw. Answers the card as it is now.
  Future<Facts> act(String ticketId, String action, {String? station, String? itemId, String? version, String? key}) async =>
      Facts(await _call('kds_ticket_act', {'ticket_id': ticketId, 'action': action, 'station': station, 'item_id': itemId, 'expected_version': version}, key: key ?? newKey()));
}

class KitchenApiException extends PartnerApiException {
  const KitchenApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}
