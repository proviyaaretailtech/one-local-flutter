import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/auth/partner_api.dart';

void main() {
  const base = 'http://api.test';

  test('sends the session token as Bearer and reads person + restaurant', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({
          'person': {'name': 'Phase A Tester', 'email': 'a@b.c'},
          'restaurant': {'name': 'Sim Kitchen'},
        }),
        200,
      );
    });
    final api = PartnerApi(client: client, baseUrl: '$base/', accessToken: () => 'tok123');
    final me = await api.me();
    expect(seen.url.toString(), '$base/api/partner/me');
    expect(seen.headers['Authorization'], 'Bearer tok123');
    expect(me.name, 'Phase A Tester');
    expect(me.email, 'a@b.c');
    expect(me.outlet, 'Sim Kitchen');
  });

  test('no session means 401 without calling the server', () async {
    var called = false;
    final api = PartnerApi(
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
      baseUrl: base,
      accessToken: () => null,
    );
    await expectLater(api.me(), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 401)));
    expect(called, isFalse);
  });

  test('server detail message is surfaced (403 not staff)', () async {
    final api = PartnerApi(
      client: MockClient((_) async => http.Response(
            jsonEncode({'detail': 'You are not a staff member of any restaurant on One Local.'}),
            403,
          )),
      baseUrl: base,
      accessToken: () => 'tok',
    );
    await expectLater(
      api.me(),
      throwsA(isA<PartnerApiException>()
          .having((e) => e.status, 'status', 403)
          .having((e) => e.message, 'message', 'You are not a staff member of any restaurant on One Local.')),
    );
  });
}
