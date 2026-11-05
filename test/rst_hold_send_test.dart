// A takeaway or delivery order held on the floor is found under Orders and sent to the kitchen (0643). The Orders answer is what the database
// gave on the local test database (server/scripts/rst-hold-send-e2e.mjs with FIXTURES=…): a held takeaway P-00001 and a held delivery P-00002.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/orders/orders_board_screen.dart';

import 'helpers.dart';
import 'orders_board_test.dart' show board, tapChip;
import 'orders_test.dart' show FakeServer, ok, err, showTall;

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_hold_send_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> sources() => jsonDecode(jsonEncode(fx['channel_orders'])) as Map<String, dynamic>;

FakeServer server({int status = 200, String? refusal}) => FakeServer((r) {
      final p = r.url.path;
      if (p.endsWith('/rpc/rst_channel_orders')) return ok(sources());
      if (p.endsWith('/rpc/pos_orders_board')) return ok(board());
      if (p.endsWith('/rpc/rst_hold_send')) {
        return refusal != null
            ? err(status, refusal)
            : ok({'order_id': 'x', 'display_no': 'P-00001', 'kot': {'ticket_id': 'k7', 'kot_no': 7, 'dishes': 2}, 'status': 'sent_to_kitchen', 'replayed': false});
      }
      // 0658: the KOT just sent prints on the kitchen printer (none set up here)
      if (p.endsWith('/rpc/pos_print_targets')) return ok({'printers': [], 'stations': [], 'business': {}});
      if (p.endsWith('/rpc/pos_kot_print')) {
        return ok({'ticket_id': 'k7', 'kot_no': 7, 'order_id': 'x', 'display_no': 'P-00001', 'channel': 'pickup', 'reprint': false, 'groups': [
          {'printer_id': null, 'station': 'Main Kitchen', 'items': [{'name': 'Masala Dosa', 'qty': 2}]},
        ]});
      }
      if (p.endsWith('/rpc/pos_print_log')) return ok({'logged': true});
      return err(404, 'not in this fake: $p');
    });

void main() {
  testWidgets('Orders has a Takeaway card; a held takeaway says it is held and sends to the kitchen with a key', (t) async {
    final s = server();
    await showTall(t, OrdersBoardScreen(api: s.api, initialTab: 'live', poll: Duration.zero));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('channel-card-takeaway')), findsOneWidget);
    expect(find.byKey(const ValueKey('channel-timer-takeaway')), findsNothing, reason: 'a held order is not waiting to be accepted');
    await tapChip(t, 'channel-card-takeaway');
    await t.pumpAndSettle();
    expect(find.text('Held · not sent to the kitchen'), findsOneWidget);
    expect(find.byKey(const ValueKey('channel-accept-P-00001')), findsNothing, reason: 'nothing to accept: the restaurant held it itself');
    await tapChip(t, 'channel-send-P-00001');
    await t.pumpAndSettle();
    final sent = s.where('POST', '/rpc/rst_hold_send').single;
    expect(jsonDecode(sent.body), containsPair('order_id', (sources()['orders'] as List).firstWhere((o) => o['display_no'] == 'P-00001')['id']));
    expect(jsonDecode(sent.body)['idempotency_key'], isNotEmpty);
    expect(toast('#P-00001 sent to the kitchen · KOT 7. No kitchen printer set up. Add one in Settings → Devices.'), findsOneWidget,
        reason: 'the send, then what the kitchen printer did with it');
    expect(jsonDecode(s.where('POST', '/rpc/pos_kot_print').single.body), {'order_id': 'x', 'ticket_id': 'k7'});
  });

  testWidgets('a held delivery under On call delivery also offers Send to kitchen, not Accept', (t) async {
    final s = server();
    await showTall(t, OrdersBoardScreen(api: s.api, initialTab: 'live', poll: Duration.zero));
    await t.pumpAndSettle();
    await tapChip(t, 'channel-card-on_call');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('channel-send-P-00002')), findsOneWidget);
    expect(find.byKey(const ValueKey('channel-accept-P-00002')), findsNothing);
  });

  testWidgets('a refusal says why', (t) async {
    final s = server(status: 409, refusal: 'this order is already with the kitchen');
    await showTall(t, OrdersBoardScreen(api: s.api, initialTab: 'live', poll: Duration.zero));
    await t.pumpAndSettle();
    await tapChip(t, 'channel-card-takeaway');
    await t.pumpAndSettle();
    await tapChip(t, 'channel-send-P-00001');
    await t.pumpAndSettle();
    expect(toast('this order is already with the kitchen'), findsOneWidget);
  });
}
