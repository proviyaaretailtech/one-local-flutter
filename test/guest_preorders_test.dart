// Pre-orders from the guest page (database 0654) wait in the same Guest orders inbox as table orders: no table, a pickup time, the
// guest's name and phone. Accept and Decline are the same guest_request_decide.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/tables/guest_orders.dart';
import 'package:vinii_pos/tables/table_qr_api.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  /// Shaped like guest__staff_request_json (0654): a pre-order has kind 'preorder', a null table, pickup_at and guest_phone.
  Map<String, dynamic> listJson() => {
        'can_decide': true,
        'waiting': 3,
        'requests': [
          {'id': 'r1', 'status': 'waiting', 'kind': 'table', 'table': {'id': 't1', 'label': 'T1'}, 'guest_name': 'Ravi', 'minutes_waiting': 2, 'estimated_total': 240, 'pickup_at': null, 'guest_phone': null,
           'lines': [{'name': 'Masala Dosa', 'qty': 2, 'notes': null}]},
          {'id': 'r2', 'status': 'waiting', 'kind': 'preorder', 'table': null, 'guest_name': 'Asha', 'minutes_waiting': 3, 'estimated_total': 520, 'pickup_at': '2026-11-05T10:30:00', 'guest_phone': '9876543210',
           'note': 'pack separately', 'lines': [{'name': 'Cinnamon Scroll', 'qty': 2, 'notes': null}]},
          // an older answer without the new fields, and no table either: still shows, does not crash
          {'id': 'r3', 'status': 'waiting', 'table': null, 'guest_name': null, 'minutes_waiting': 0, 'estimated_total': 100, 'lines': []},
        ],
      };

  testWidgets('a pre-order shows its pickup time, name and phone instead of a table; Accept is the same decide', (t) async {
    ignoreOverflow();
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final calls = <http.Request>[];
    final client = MockClient((r) async {
      calls.add(r);
      final fn = r.url.path.split('/').last;
      return switch (fn) {
        'guest_requests_list' => ok(listJson()),
        'guest_request_decide' => ok({'id': 'r2', 'status': 'accepted', 'kind': 'preorder', 'order': {'display_no': 'P-00008'}}),
        _ => http.Response(jsonEncode({'detail': 'not found'}), 404),
      };
    });
    final rpc = RpcClient(baseUrl: 'https://pos.test', accessToken: () => 'tok', client: client);
    final env = TablesEnv(api: TablesApi(rpc: rpc, locationId: 'loc1'), qrApi: TableQrApi(rpc: rpc));
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: SingleChildScrollView(child: GuestOrdersPanel(env: env)))));
    await t.pumpAndSettle();

    expect(find.text('3 guest orders waiting'), findsOneWidget);
    expect(find.text('Table T1 · Ravi · 2 min ago'), findsOneWidget);
    expect(find.byKey(const ValueKey('guest-preorder-r2')), findsOneWidget);
    expect(find.text('Pre-order · pickup Thu 10:30'), findsOneWidget, reason: '5 Nov 2026 is a Thursday');
    expect(find.text('Asha · 98765 43210 · 3 min ago'), findsOneWidget);
    expect(find.text('Note: pack separately'), findsOneWidget);
    expect(find.text('Table — · 0 min ago'), findsOneWidget);
    expect(find.byKey(const ValueKey('guest-preorder-r1')), findsNothing);

    await t.tap(find.byKey(const ValueKey('guest-accept-r2')));
    await t.pumpAndSettle();
    final decide = calls.where((c) => c.url.path.endsWith('/guest_request_decide')).single;
    expect(jsonDecode(decide.body), {'location_id': 'loc1', 'id': 'r2', 'action': 'accept'});
    expect(find.text('Sent to the kitchen as P-00008.'), findsOneWidget);
  });

  test('pickup label and phone text', () {
    expect(pickupLabel(DateTime(2026, 11, 5, 10, 30)), 'Thu 10:30');
    expect(pickupLabel(DateTime(2026, 11, 8, 9, 5)), 'Sun 09:05');
    expect(pickupLabel(null), 'time not set');
    expect(phoneText('9876543210'), '98765 43210');
    expect(phoneText('+91 98765'), '+91 98765');
  });
}
