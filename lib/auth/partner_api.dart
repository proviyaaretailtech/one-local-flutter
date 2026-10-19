import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

/// Who the signed-in person is, through the one `/rpc/<name>` door ([RpcClient]). The server looks up the membership from the token.
class PartnerApi {
  PartnerApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// `me`. Throws [PartnerApiException] with the server's message.
  Future<PartnerMe> me() async => PartnerMe.fromJson(await _rpc.callMap('me'));
}

class PartnerMe {
  PartnerMe({required this.name, required this.email, required this.outlet, this.kind = 'store'});
  final String name;

  /// store | restaurant | service, from the server.
  final String kind;
  final String email;
  final String outlet;

  factory PartnerMe.fromJson(Map<String, dynamic> j) {
    final person = (j['person'] as Map?) ?? {};
    final outlet = (j['restaurant'] as Map?) ?? {};
    return PartnerMe(
      name: (person['name'] ?? '') as String,
      email: (person['email'] ?? '') as String,
      outlet: (outlet['name'] ?? '') as String,
      kind: (j['business_kind'] ?? 'store') as String,
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
