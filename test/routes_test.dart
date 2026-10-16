import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/setup/setup_api.dart';
import 'package:vinii_pos/setup/setup_flow.dart';

import 'helpers.dart';
import 'setup_test.dart' show sampleSetup;

const _json = {'content-type': 'application/json; charset=utf-8'};

SetupApi _setup(http.Response Function() answer) =>
    SetupApi(client: MockClient((_) async => answer()), baseUrl: 'http://x', accessToken: () => 't');

Future<void> _open(WidgetTester t, SetupApi api) async {
  await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => openWorkspace(c, setupApi: api), child: const Text('go')))));
  await t.tap(find.text('go'));
  await t.pump();
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  tearDown(HomeNav.reset);

  test('installRoutes plugs setup, home, orders and the bill into the control centre', () {
    HomeNav.reset();
    installRoutes();
    expect([HomeNav.home, HomeNav.setup, HomeNav.orders, HomeNav.orderHistory, HomeNav.bill], everyElement(isNotNull));
    expect(HomeNav.items, isNotNull); // section G
    expect(HomeNav.stock, isNull); // later phases still say "later release"
  });

  group('Continue to store', () {
    testWidgets('an owner with setup still open goes to workspace setup', (t) async {
      await _open(t, _setup(() => http.Response(jsonEncode(sampleSetup().raw), 200, headers: _json)));
      expect(find.byType(SetupEntry), findsOneWidget);
      expect(find.byType(ControlCentreScreen), findsNothing);
    });
    testWidgets('setup finished: the control centre', (t) async {
      await _open(t, _setup(() => http.Response(jsonEncode(sampleSetup(completed: true).raw), 200, headers: _json)));
      expect(find.byType(ControlCentreScreen), findsOneWidget);
    });
    testWidgets('the server refuses setup (staff, not approved): the control centre', (t) async {
      await _open(t, _setup(() => http.Response(jsonEncode({'detail': 'Only the owner can set up the workspace.'}), 403, headers: _json)));
      expect(find.byType(ControlCentreScreen), findsOneWidget);
      expect(find.byType(SetupEntry), findsNothing);
    });
  });
}
