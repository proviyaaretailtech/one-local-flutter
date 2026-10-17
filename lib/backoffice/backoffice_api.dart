import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

num? _num(Object? v) => v == null ? null : (v is num ? v : num.tryParse('$v'));
String? _str(Object? v) => v == null || '$v'.isEmpty ? null : '$v';

/// Snapshot facts shared by both back-office screens.
class Snapshot {
  Snapshot(Map<String, dynamic> j)
      : at = DateTime.tryParse('${j['snapshot_at'] ?? ''}')?.toLocal(),
        locationName = _str(j['location_name']),
        viewerName = _str(j['viewer_name']);
  final DateTime? at;
  final String? locationName, viewerName;
}

/// One row of the Low Stock list (`backoffice_low_stock`). Levels, cover and shortfalls are decided by the server.
class LowStockItem {
  LowStockItem(Map<String, dynamic> j)
      : id = '${j['id'] ?? ''}',
        name = '${j['name'] ?? ''}',
        unit = _str(j['unit']) ?? 'units',
        available = _num(j['available']) ?? 0,
        level = '${j['level'] ?? 'low'}',
        reorderLevel = _num(j['reorder_level']),
        quantityShort = _num(j['quantity_short']),
        suggestedQty = _num(j['suggested_qty']),
        daysCover = _num(j['days_cover']),
        inboundQty = _num(j['inbound_qty']),
        inboundEta = DateTime.tryParse('${j['inbound_eta'] ?? ''}'),
        supplierName = _str(j['supplier_name']),
        lastPurchasePrice = _num(j['last_purchase_price']);
  final String id, name, unit, level;
  final num available;
  final num? reorderLevel, quantityShort, suggestedQty, daysCover, inboundQty, lastPurchasePrice;
  final DateTime? inboundEta;
  final String? supplierName;
  bool get critical => level == 'critical';
}

class LowStockView {
  LowStockView(Map<String, dynamic> j)
      : snapshot = Snapshot(j),
        low = (_num((j['counts'] as Map?)?['low']) ?? 0).toInt(),
        critical = (_num((j['counts'] as Map?)?['critical']) ?? 0).toInt(),
        missingLevels = j['missing_levels'] == true,
        items = ((j['items'] as List?) ?? const []).map((e) => LowStockItem((e as Map).cast<String, dynamic>())).toList();
  final Snapshot snapshot;
  final int low, critical;
  final bool missingLevels;
  final List<LowStockItem> items;
}

/// One open purchase suggestion (`purchase_suggestions_list`). `suggestedQty` is what was recorded, not a calculation.
class Suggestion {
  Suggestion(Map<String, dynamic> j)
      : id = '${j['id'] ?? ''}',
        itemId = '${j['item_id'] ?? ''}',
        name = '${j['name'] ?? ''}',
        unit = _str(j['unit']) ?? 'units',
        available = _num(j['available']) ?? 0,
        level = _str(j['level']),
        reason = '${j['reason'] ?? 'low_stock'}',
        daysCover = _num(j['days_cover']),
        suggestedQty = _num(j['suggested_qty']),
        inboundQty = _num(j['inbound_qty']),
        inboundEta = DateTime.tryParse('${j['inbound_eta'] ?? ''}'),
        supplierName = _str(j['supplier_name']),
        estimatedUnitCost = _num(j['estimated_unit_cost']),
        deliveryDays = _num(j['delivery_days']);
  final String id, itemId, name, unit, reason;
  final String? level, supplierName;
  final num available;
  final num? daysCover, suggestedQty, inboundQty, estimatedUnitCost, deliveryDays;
  final DateTime? inboundEta;
  bool get urgent => reason == 'urgent';
}

class SuggestionsView {
  SuggestionsView(Map<String, dynamic> j)
      : snapshot = Snapshot(j),
        suggestions = ((j['suggestions'] as List?) ?? const []).map((e) => Suggestion((e as Map).cast<String, dynamic>())).toList();
  final Snapshot snapshot;
  final List<Suggestion> suggestions;
}

/// Back office calls through the one generic door, `POST /rpc/<function>` ([RpcClient]); the database functions of migration 0420 do the
/// work on section H's stock numbers and check the business, the store, the role and every rule. The Supabase session token is the only
/// credential. Writes carry an Idempotency-Key so a retried tap never doubles.
class BackofficeApi {
  BackofficeApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The store to look at; null = the whole business. Only a business-wide person may see the whole business: for someone who works at
  /// some stores the database answers 403 `store_scope`, and the client then switches to the person's own store (from `inv_options`)
  /// and asks again. Any other refusal is passed on as it is.
  String? locationId;

  static final _rand = Random.secure();
  static String newKey() => 'bo-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    Map<String, dynamic> body() => <String, dynamic>{
          if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
          ...args,
        }..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body(), key);
    } on RpcException catch (e) {
      if (e.code != 'store_scope' || (locationId != null && locationId!.isNotEmpty)) throw _wrap(e);
      final own = await _ownStore();
      if (own == null) throw _wrap(e);
      locationId = own;
      try {
        return await _rpc.callMap(fn, body(), key);
      } on RpcException catch (e2) {
        throw _wrap(e2);
      }
    }
  }

  Future<String?> _ownStore() async {
    try {
      final o = await _rpc.callMap('inv_options');
      final id = (o['location'] as Map?)?['id'];
      return id == null || '$id'.isEmpty ? null : '$id';
    } on PartnerApiException {
      return null;
    }
  }

  static BackofficeApiException _wrap(RpcException e) => BackofficeApiException(e.status, e.message, e.code);

  Future<LowStockView> lowStock({String filter = 'all', String q = ''}) async =>
      LowStockView(await _call('backoffice_low_stock', {'filter': filter, if (q.trim().isNotEmpty) 'q': q.trim()}));

  /// Records suggestions for the items low now (nothing for goods already on the way), then answers the open suggestions.
  Future<SuggestionsView> refreshSuggestions({required String key}) async {
    await _call('purchase_suggestions_refresh', const {}, key: key);
    return suggestions();
  }

  Future<SuggestionsView> suggestions() async => SuggestionsView(await _call('purchase_suggestions_list', const {}));

  /// Marks the ticked suggestions as ordered under the person's own purchase order reference (free text: there is no purchase-order
  /// record in One Local yet). [quantities] maps suggestion id -> quantity ordered. Answers how many were closed.
  Future<int> markOrdered(Map<String, num> quantities, {required String reference, required String key}) async {
    final r = await _call('purchase_suggestions_close',
        {'ids': quantities.keys.toList(), 'outcome': 'ordered', 'purchase_order_ref': reference.trim(), 'quantities': quantities}, key: key);
    return (r['closed'] as num?)?.toInt() ?? 0;
  }

  /// Dismisses suggestions (not needed). Answers how many were closed.
  Future<int> dismiss(List<String> ids, {required String key}) async {
    final r = await _call('purchase_suggestions_close', {'ids': ids, 'outcome': 'dismissed'}, key: key);
    return (r['closed'] as num?)?.toInt() ?? 0;
  }
}

class BackofficeApiException extends PartnerApiException {
  const BackofficeApiException(super.status, super.message, this.code);
  final String? code;
}
