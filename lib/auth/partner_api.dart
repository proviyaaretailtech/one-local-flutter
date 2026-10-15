import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Calls One Local's server (`/api/partner/*`). The session token from Supabase
/// Auth is the only credential; the server looks up the membership.
/// Base URL from --dart-define=PARTNER_API_BASE_URL (names only in code).
class PartnerApi {
  PartnerApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL'))
            .replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  /// GET /api/partner/me. Throws [PartnerApiException] with the server's message.
  Future<PartnerMe> me() async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final res = await _http.get(
      Uri.parse('$_base/api/partner/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw PartnerApiException(res.statusCode, (body['detail'] ?? 'Request failed.') as String);
    }
    return PartnerMe.fromJson(body);
  }
}

class PartnerMe {
  PartnerMe({required this.name, required this.email, required this.outlet});
  final String name;
  final String email;
  final String outlet;

  factory PartnerMe.fromJson(Map<String, dynamic> j) {
    final person = (j['person'] as Map?) ?? {};
    final outlet = (j['restaurant'] as Map?) ?? {};
    return PartnerMe(
      name: (person['name'] ?? '') as String,
      email: (person['email'] ?? '') as String,
      outlet: (outlet['name'] ?? '') as String,
    );
  }
}

class PartnerApiException implements Exception {
  const PartnerApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}
