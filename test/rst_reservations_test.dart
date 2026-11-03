// Manage reservations (0642). The answers are what the database gave on the local test database (server/scripts/rst-reservations-e2e.mjs
// with FIXTURES=…): Asha Rao, 3 guests at R1 with "Window seat"; later a seated, a cancelled ("Guest called to cancel") and a no-show booking.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/tables/floor_screen.dart';
import 'package:vinii_pos/tables/reservations_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';

import 'helpers.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/rst_reservations_server.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> copy(Object? o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail) => http.Response(jsonEncode({'detail': detail, 'code': 'conflict'}), status, headers: {'content-type': 'application/json; charset=utf-8'});

class Fake {
  Fake({Map<String, dynamic>? list, this.on = const {}}) : list = list ?? copy(fx['upcoming']);
  Map<String, dynamic> list;
  final Map<String, http.Response Function(Map<String, dynamic> body)> on;
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> of(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];

  late final api = TablesApi(
    baseUrl: 'http://tbl.test',
    accessToken: () => 't',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final b = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, b));
      final h = on[fn];
      if (h != null) return h(b);
      return switch (fn) {
        'tbl_reservations_list' => ok(b['status'] == 'all' ? fx['all'] : list),
        'tbl_reserve_seat' => ok(fx['seated']),
        'tbl_reserve_cancel' => ok(fx['no_show']),
        'tbl_view' => ok(fx['view_reserved']),
        _ => err(404, 'Not found'),
      };
    }),
  );
  late final env = TablesEnv(api: api);
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

String get asha => (fx['upcoming']['reservations'] as List).first['id'] as String;
final today = DateTime(2026, 11, 3);

void main() {
  testWidgets('the day\'s bookings: time, guest, party, table, phone, notes; counts on the filters', (t) async {
    final f = Fake();
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    expect(find.text('Reservations'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('11:50 AM'), findsOneWidget);
    expect(find.text('3 guests · Table R1 · +91 98765 43210'), findsOneWidget);
    expect(find.text('“Window seat”'), findsOneWidget);
    expect(find.text('Upcoming 1'), findsOneWidget);
    expect(find.byKey(ValueKey('rsv-seat-$asha')), findsOneWidget);
    expect(find.byKey(ValueKey('rsv-cancel-$asha')), findsOneWidget);
    expect(find.byKey(ValueKey('rsv-noshow-$asha')), findsNothing, reason: 'not before its time');
    expect(f.of('tbl_reservations_list').single, {'status': 'upcoming'});
  });

  testWidgets('Seat: are you sure (No does nothing), at the booked table, then take the order later', (t) async {
    final f = Fake();
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    await tapKey(t, 'rsv-seat-$asha');
    expect(find.text('Seat Asha Rao (3)?'), findsOneWidget);
    await tapKey(t, 'rsv-seat-no');
    expect(f.of('tbl_reserve_seat'), isEmpty);

    await tapKey(t, 'rsv-seat-$asha');
    expect(find.text('Yes, at R1'), findsOneWidget);
    await tapKey(t, 'rsv-seat-yes');
    expect(f.of('tbl_reserve_seat').single, {'id': asha});
    expect(find.text('Asha Rao seated at R1'), findsOneWidget);
    expect(find.text('Take their order now?'), findsOneWidget);
    await tapKey(t, 'rsv-order-later');
    expect(f.of('tbl_reservations_list').length, 2, reason: 'the list reads again');
  });

  testWidgets('Seat refused by the server says why', (t) async {
    final f = Fake(on: {'tbl_reserve_seat': (_) => err(409, 'table R1 still has guests with an open bill; seat them at another table')});
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    await tapKey(t, 'rsv-seat-$asha');
    await tapKey(t, 'rsv-seat-yes');
    expect(toast('table R1 still has guests with an open bill; seat them at another table'), findsOneWidget);
  });

  testWidgets('Cancel: are you sure, with an optional reason', (t) async {
    final f = Fake(on: {'tbl_reserve_cancel': (_) => ok({'reservation': {}})});
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    await tapKey(t, 'rsv-cancel-$asha');
    expect(find.text('Cancel the booking of Asha Rao (3)?'), findsOneWidget);
    await tapKey(t, 'rsv-no');
    expect(f.of('tbl_reserve_cancel'), isEmpty, reason: 'No keeps the booking');

    await tapKey(t, 'rsv-cancel-$asha');
    await t.enterText(find.byKey(const ValueKey('rsv-reason')), 'Guest called to cancel');
    await tapKey(t, 'rsv-yes');
    expect(f.of('tbl_reserve_cancel').single, {'id': asha, 'reason': 'Guest called to cancel'});
    expect(toast('Booking of Asha Rao (3) cancelled.'), findsOneWidget);
  });

  testWidgets('a late booking: marked Late, counted, and offered as a no-show', (t) async {
    final late = copy(fx['upcoming']);
    final r = (late['reservations'] as List).first as Map<String, dynamic>;
    r['late'] = true;
    r['can'] = {'seat': true, 'cancel': true, 'no_show': true};
    (late['counts'] as Map)['late'] = 1;
    final f = Fake(list: late);
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    expect(find.text('Late'), findsOneWidget);
    expect(find.text('1 late: seat them, or mark a no-show.'), findsOneWidget);
    await tapKey(t, 'rsv-noshow-$asha');
    expect(find.text('Mark Asha Rao (3) as a no-show?'), findsOneWidget);
    await tapKey(t, 'rsv-yes');
    expect(f.of('tbl_reserve_cancel').single, {'id': asha, 'outcome': 'no_show'});
    expect(toast('Asha Rao (3) marked as a no-show.'), findsOneWidget);
  });

  testWidgets('All: seated, cancelled with its reason, no-show; nothing left to do on them', (t) async {
    final f = Fake();
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    await tapKey(t, 'rsv-filter-all');
    expect(f.of('tbl_reservations_list').last['status'], 'all');
    expect(find.text('Seated'), findsWidgets);
    expect(find.text('Cancelled'), findsWidgets);
    expect(find.text('No-show'), findsWidgets);
    expect(find.text('Guest called to cancel'), findsOneWidget);
    expect(find.text('Seat'), findsNothing);
  });

  testWidgets('another day: forward a day asks for that date', (t) async {
    final f = Fake();
    await show(t, ReservationsScreen(env: f.env, today: today));
    await t.pumpAndSettle();
    await tapKey(t, 'rsv-next');
    expect(f.of('tbl_reservations_list').last['date'], '2026-11-04');
  });

  testWidgets('a reserved table\'s sheet shows its booking with Seat and Cancel', (t) async {
    final f = Fake();
    final table = Facts({'id': (fx['view_reserved'] as Map)['table']['id'], 'label': 'R1', 'status': 'reserved', 'seats': 4});
    await show(t, Builder(builder: (c) => Scaffold(body: TextButton(key: const ValueKey('open'), onPressed: () => showTableSheet(c, f.env, table), child: const Text('open')))));
    await tapKey(t, 'open');
    expect(find.text('Asha Rao'), findsOneWidget);
    expect(find.text('3 guests · +91 98765 43210'), findsOneWidget, reason: 'the table is the one on the sheet');
    expect(find.byKey(ValueKey('rsv-seat-$asha')), findsOneWidget);
    await tapKey(t, 'rsv-seat-$asha');
    await tapKey(t, 'rsv-seat-yes');
    expect(f.of('tbl_reserve_seat').single, {'id': asha});
  });
}
