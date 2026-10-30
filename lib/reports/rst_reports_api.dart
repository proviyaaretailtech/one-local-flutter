import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../tables/tables_api.dart' show TablesApiException;

/// The restaurant reports (migration 0636) through the one generic door, `POST /rpc/<rst_report_*>`. The database works out every figure
/// for the caller's business and outlets only; the app only draws the answers.
class RstReportsApi {
  RstReportsApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Facts> _call(String fn, Map<String, Object?> args) async {
    try {
      return Facts(await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null)));
    } on RpcException catch (e) {
      throw TablesApiException(e.status, e.message, e.code);
    }
  }

  static String day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// [kind]: sales, items, categories, payments, cashiers, discounts or audit. [from]/[to] are days in the business's time zone.
  Future<Facts> report(String kind, {required DateTime from, required DateTime to, String? locationId, String? menuItemId}) =>
      _call('rst_report_$kind', {'from': day(from), 'to': day(to), 'location_id': locationId, 'menu_item_id': menuItemId});
}
