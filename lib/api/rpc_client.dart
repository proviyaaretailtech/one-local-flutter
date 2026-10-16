import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';

/// The one door to the POS server: `POST {PARTNER_API_BASE_URL}/rpc/<name>` with the JSON arguments as the body and the Supabase
/// session token as the bearer. The server runs the named database function as the signed-in person, so the database decides
/// what they may see or change. No key other than the person's own session token ever leaves this app.
/// Base URL from --dart-define=PARTNER_API_BASE_URL (names only in code).
class RpcClient {
  RpcClient({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  /// Calls [fn] with [args]; returns the decoded JSON answer (a map, a list or null). [idempotencyKey] makes a retry safe for
  /// functions that take one. Throws [PartnerApiException] with the server's sentence on any non-2xx answer.
  Future<dynamic> call(String fn, [Map<String, dynamic> args = const {}, String? idempotencyKey]) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final res = await _http
        .post(
          Uri.parse('$_base/rpc/$fn'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey},
          body: jsonEncode(args),
        )
        .timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail'] as String? : null;
      throw RpcException(res.statusCode, detail ?? 'Something went wrong. Please try again.', decoded is Map ? decoded['code'] as String? : null);
    }
    return decoded;
  }

  /// Like [call] for functions that answer with an object.
  Future<Map<String, dynamic>> callMap(String fn, [Map<String, dynamic> args = const {}, String? idempotencyKey]) async {
    final r = await call(fn, args, idempotencyKey);
    return r is Map ? r.cast<String, dynamic>() : <String, dynamic>{};
  }
}

/// A [PartnerApiException] that also keeps the server's machine-readable `code` (for example `version_conflict`), so a screen can react to it.
class RpcException extends PartnerApiException {
  const RpcException(super.status, super.message, this.code);
  final String? code;
}
