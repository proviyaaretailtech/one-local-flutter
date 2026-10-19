import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import 'tables_api.dart' show TablesApiException;

/// Table QR codes and guest orders through the one generic door, `POST /rpc/<name>` ([RpcClient]); the database functions of migrations 0560
/// and 0561 check the business, the store and the role. Replacing a code must name the table; accepting a guest order places the real order.
class TableQrApi {
  TableQrApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  /// The printed link of a code: `<guest web base>/t/<code>`. The base is `--dart-define=GUEST_WEB_BASE_URL`, else the POS server the app talks
  /// to (it serves the guest page too).
  static String linkFor(String code, {String? base}) {
    const web = String.fromEnvironment('GUEST_WEB_BASE_URL');
    const api = String.fromEnvironment('PARTNER_API_BASE_URL');
    final b = (base ?? (web.isNotEmpty ? web : api)).replaceAll(RegExp(r'/+$'), '');
    return '$b/t/$code';
  }

  Future<Map<String, dynamic>> _call(String fn, String? locationId, Map<String, Object?> args, [String? key]) async {
    final body = <String, dynamic>{if (locationId != null && locationId.isNotEmpty) 'location_id': locationId, ...args}..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw TablesApiException(e.status, e.message, e.code);
    }
  }

  /// Every table of the store with its code state; `code` is only there for a table manager.
  Future<Facts> list(String? locationId) async => Facts(await _call('tbl_qr_list', locationId, {}));

  /// A table's first code, or a replacement ([confirmLabel] must be the table's name).
  Future<Facts> issue(String? locationId, String tableId, {bool replace = false, String? confirmLabel}) async =>
      Facts(await _call('tbl_qr_issue', locationId, {'table_id': tableId, if (replace) 'replace': true, 'confirm_label': confirmLabel}));

  Future<Facts> setEnabled(String? locationId, String tableId, bool enabled) async =>
      Facts(await _call('tbl_qr_set_enabled', locationId, {'table_id': tableId, 'enabled': enabled}));

  /// Guest orders waiting at the store (or one table).
  Future<Facts> requests(String? locationId, {String? tableId}) async => Facts(await _call('guest_requests_list', locationId, {'table_id': tableId}));

  /// Accept places the order as the signed-in person; decline needs a [reason] the guest will read.
  Future<Facts> decide(String? locationId, String requestId, {required bool accept, String? reason}) async =>
      Facts(await _call('guest_request_decide', locationId, {'id': requestId, 'action': accept ? 'accept' : 'decline', 'reason': reason}));
}
