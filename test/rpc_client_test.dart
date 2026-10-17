import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/onboarding/onboarding_api.dart';

void main() {
  const base = 'http://api.test';

  test('posts the arguments to /rpc/<name> with the bearer token and the idempotency key', () async {
    late http.Request seen;
    final rpc = RpcClient(
      client: MockClient((r) async {
        seen = r;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
      baseUrl: '$base//',
      accessToken: () => 'tok',
    );
    final out = await rpc.call('pos_checkout', {'method': 'cash'}, 'key-12345678');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), '$base/rpc/pos_checkout');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['Idempotency-Key'], 'key-12345678');
    expect(jsonDecode(seen.body), {'method': 'cash'});
    expect(out, {'ok': true});
  });

  test('no session: 401 and no call', () async {
    final rpc = RpcClient(client: MockClient((_) async => fail('must not call')), baseUrl: base, accessToken: () => null);
    await expectLater(rpc.call('me'), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 401)));
  });

  test('the server sentence is the message; a body without one gets a plain sentence', () async {
    final a = RpcClient(client: MockClient((_) async => http.Response(jsonEncode({'detail': 'Nope.', 'code': 'x'}), 409)), baseUrl: base, accessToken: () => 't');
    await expectLater(a.call('f'), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 409).having((e) => e.message, 'message', 'Nope.')));
    final b = RpcClient(client: MockClient((_) async => http.Response('', 500)), baseUrl: base, accessToken: () => 't');
    await expectLater(b.call('f'), throwsA(isA<PartnerApiException>().having((e) => e.message, 'message', 'Something went wrong. Please try again.')));
  });

  test('a null answer is fine (callMap gives an empty map)', () async {
    final rpc = RpcClient(client: MockClient((_) async => http.Response('null', 200)), baseUrl: base, accessToken: () => 't');
    expect(await rpc.call('f'), isNull);
    expect(await rpc.callMap('f'), isEmpty);
  });

  test('onboarding calls go to the right names', () async {
    final seen = <String>[];
    final api = OnboardingApi(
      client: MockClient((r) async {
        seen.add('${r.url.path} ${r.body}');
        return http.Response(jsonEncode({'exists': true}), 200);
      }),
      baseUrl: base,
      accessToken: () => 't',
    );
    await api.get();
    await api.choosePlan('onelocal_app');
    await api.acceptAgreement('v1');
    await api.taxonomy();
    expect(seen, [
      '/rpc/partner_app_get {}',
      '/rpc/partner_app_choose_plan {"plan":"onelocal_app"}',
      '/rpc/partner_app_accept_agreement {"version":"v1","acknowledged":true}',
      '/rpc/static_taxonomy {}',
    ]);
  });
}
