import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

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

/// One row of the Low Stock list (`GET /api/partner/backoffice/low-stock`). Levels, cover and shortfalls are decided by the server.
class LowStockItem {
  LowStockItem(Map<String, dynamic> j)
      : id = '${j['id'] ?? ''}',
        name = '${j['name'] ?? ''}',
        unit = _str(j['unit']) ?? 'units',
        available = _num(j['available']) ?? 0,
        level = '${j['level'] ?? 'low'}',
        reorderLevel = _num(j['reorder_level']),
        quantityShort = _num(j['quantity_short']),
        daysCover = _num(j['days_cover']),
        inboundQty = _num(j['inbound_qty']),
        inboundEta = DateTime.tryParse('${j['inbound_eta'] ?? ''}'),
        supplierName = _str(j['supplier_name']),
        lastPurchasePrice = _num(j['last_purchase_price']);
  final String id, name, unit, level;
  final num available;
  final num? reorderLevel, quantityShort, daysCover, inboundQty, lastPurchasePrice;
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

/// One open purchase suggestion (`GET /api/partner/backoffice/purchase-suggestions`). `suggestedQty` is what was recorded, not a calculation.
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

/// A line the person ticked for the purchase order (draft on the phone until sent).
class PoLine {
  const PoLine(this.suggestionId, this.qty);
  final String suggestionId;
  final num qty;
  Map<String, dynamic> toJson() => {'suggestion_id': suggestionId, 'qty': qty};
}

/// Calls One Local's server (`/api/partner/backoffice/*`, contract in specs/pos-section-j/spec.md). The Supabase session token is the only
/// credential; the database checks the business, the location and the role again. Writes carry an Idempotency-Key.
class BackofficeApi {
  BackofficeApi({http.Client? client, String? baseUrl, String? Function()? accessToken, this.locationId})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  /// The location to look at; null = every location the person may see.
  final String? locationId;

  static final _rand = Random.secure();
  static String newKey() => 'bo-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final q = {'location_id': ?locationId, ...?query};
    var uri = Uri.parse('$_base/api/partner/backoffice$path');
    if (q.isNotEmpty) uri = uri.replace(queryParameters: q);
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
      throw BackofficeApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  Future<LowStockView> lowStock({String filter = 'all', String q = ''}) async =>
      LowStockView(await _send('GET', '/low-stock', query: {'filter': filter, if (q.trim().isNotEmpty) 'q': q.trim()}));

  /// Records suggestions for the items low now, then answers the open suggestions.
  Future<SuggestionsView> refreshSuggestions({required String key}) async => SuggestionsView(await _send('POST', '/purchase-suggestions/refresh', key: key, body: const {}));

  Future<SuggestionsView> suggestions() async => SuggestionsView(await _send('GET', '/purchase-suggestions'));

  /// Drafts a purchase order from the ticked suggestions. Answers the purchase order reference.
  Future<String> createPurchaseOrder(List<PoLine> lines, {required String key}) async {
    final r = await _send('POST', '/purchase-suggestions/create-po', key: key, body: {'lines': lines.map((l) => l.toJson()).toList()});
    return '${r['purchase_order_ref'] ?? ''}';
  }
}

class BackofficeApiException extends PartnerApiException {
  const BackofficeApiException(super.status, super.message, this.code);
  final String? code;
}
