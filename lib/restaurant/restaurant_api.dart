import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

Map<String, dynamic> _map(Object? v) =>
    (v as Map?)?.cast<String, dynamic>() ?? const {};
num _n(Object? v) => v is num ? v : (num.tryParse('${v ?? 0}') ?? 0);

/// A block of the restaurant dashboard. `null` means the server could not supply it (the role may not read it): the screen says "Not reported".
class RstBlock {
  const RstBlock(this.raw);
  final Map<String, dynamic> raw;
  int i(String k) => _n(raw[k]).toInt();
  num n(String k) => _n(raw[k]);
  String s(String k) => (raw[k] ?? '').toString();
}

/// The restaurant home screen (`rst_dashboard`). Every number is the server's; a missing block is drawn as "Not reported", never as zero.
class RestaurantDashboardData {
  const RestaurantDashboardData(this.raw);
  final Map<String, dynamic> raw;
  String get business => (raw['business'] ?? '').toString();
  String get locationId => (_map(raw['location'])['id'] ?? '').toString();
  String get locationName => (_map(raw['location'])['name'] ?? '').toString();
  String get dateLabel => (raw['date_label'] ?? '').toString();
  List<Map<String, dynamic>> get outlets =>
      ((raw['outlets'] as List?) ?? const [])
          .whereType<Map>()
          .map(_map)
          .toList();
  RstBlock get orders => RstBlock(_map(raw['orders']));
  RstBlock get sales => RstBlock(_map(raw['sales']));
  RstBlock? _opt(String k) => raw[k] is Map ? RstBlock(_map(raw[k])) : null;
  RstBlock? get kot => _opt('kot');
  RstBlock? get tables => _opt('tables');
  RstBlock? get ingredientsLow => _opt('ingredients_low');
  RstBlock? get onelocal => _opt('onelocal');
  /// 0570: the 7 days before [last7] ({sales, orders}); null from an older server.
  RstBlock? get prev7 => _opt('prev7');
  /// 0570: outlets taking One Local orders ({open_outlets, outlets}); null from an older server.
  RstBlock? get channel => _opt('channel');
  /// 0570: up to three low-stock rows; null when the role cannot read stock (or an older server).
  List<Map<String, dynamic>>? get ingredientRows =>
      raw['ingredients_items'] is List ? (raw['ingredients_items'] as List).whereType<Map>().map(_map).toList() : null;
  List<Map<String, dynamic>> get last7 =>
      ((raw['last7'] as List?) ?? const []).whereType<Map>().map(_map).toList();
  List<String> get notReported =>
      ((raw['not_reported'] as List?) ?? const []).map((e) => '$e').toList();
}

class RestaurantApiException extends PartnerApiException {
  const RestaurantApiException(super.status, super.message);
}

class RestaurantApi {
  RestaurantApi({
    http.Client? client,
    String? baseUrl,
    String? Function()? accessToken,
    RpcClient? rpc,
  }) : _rpc =
           rpc ??
           RpcClient(
             client: client,
             baseUrl: baseUrl,
             accessToken: accessToken,
           );
  final RpcClient _rpc;

  /// One outlet, or (no [locationId]) all outlets the person may see, summed by the server (0524 `rst_dashboard_scope`).
  Future<RestaurantDashboardData> dashboard({String? locationId}) async {
    try {
      return RestaurantDashboardData(
        await _rpc.callMap('rst_dashboard_scope', {'location_id': locationId ?? 'all'}),
      );
    } on RpcException catch (e) {
      throw RestaurantApiException(e.status, e.message);
    }
  }
}
