import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/service/booking_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/theme.dart';

// A listing booked by the court (founder, 5 Nov 2026): no provider to pick, full court or a part, times under the time bands, then the free courts.
void main() {
  const json = {'content-type': 'application/json; charset=utf-8'};
  http.Response ok(Object? b) => http.Response(jsonEncode(b), 200, headers: json);
  const courts = {
    'id': 'sv1', 'name': 'Badminton', 'price': 500, 'duration_min': 60, 'addons': [], 'staff_ids': [], 'unit_word': 'Court',
    'units': [{'name': 'Court A', 'surface': 'Wooden'}, {'name': 'Court B', 'surface': 'Synthetic'}],
    'parts': [{'name': 'North half', 'price': 300}],
  };
  const morning = {'starts_at': '2026-10-08T04:30:00+00:00', 'label': '10:00 AM', 'range_label': '10:00 – 11:00 AM', 'band': 'Morning', 'units': ['Court B']};
  const evening = {'starts_at': '2026-10-08T12:30:00+00:00', 'label': '6:00 PM', 'range_label': '6:00 – 7:00 PM', 'band': 'Evening', 'units': ['Court A', 'Court B']};

  Future<List<http.Request>> open(WidgetTester t) async {
    final calls = <http.Request>[];
    final api = ServiceApi(baseUrl: 'http://pos.test', accessToken: () => 'token-123', client: MockClient((r) async {
      calls.add(r);
      final p = r.url.path;
      if (p.endsWith('/svc_catalogue')) return ok({'services': [courts], 'providers': [], 'resources': [], 'settings': {}});
      if (p.endsWith('/svc_quote')) {
        final part = jsonDecode(r.body)['part'];
        final total = part == null ? 500 : 300;
        return ok({'subtotal': total, 'gst_pct': 0, 'gst_amount': 0, 'round_off': 0, 'total': total, 'deposit': 0, 'due_at_studio': total, 'duration_min': 60, 'buffer_min': 0, 'free_cancel_hours': 12, 'lines': []});
      }
      if (p.endsWith('/svc_slots')) return ok({'providers': [{'staff_id': null, 'name': '', 'slots': [morning, evening]}]});
      if (p.endsWith('/svc_book')) return ok({'id': 'a1', 'display_no': 'APT-0001', 'status': 'confirmed', 'customer': 'Riya'});
      return http.Response('{}', 404, headers: json);
    }));
    t.view.physicalSize = const Size(800, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: ServiceBookingScreen(api: api, date: DateTime(2026, 10, 8))));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('field-customer')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('customer-name')), 'Riya');
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('book-seg-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('field-service')));
    await t.pumpAndSettle();
    await t.tap(find.text('Badminton'));
    await t.pumpAndSettle();
    return calls;
  }

  Map<String, dynamic> lastBody(List<http.Request> calls, String fn) => jsonDecode(calls.lastWhere((r) => r.url.path.endsWith(fn)).body) as Map<String, dynamic>;

  testWidgets('full court or a part on the Service step; the part is priced by the server', (t) async {
    final calls = await open(t);
    expect(find.text('Full court · ₹500'), findsOneWidget);
    expect(find.text('North half · ₹300'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('book-part-North half')));
    await t.pumpAndSettle();
    expect(lastBody(calls, '/svc_quote')['part'], 'North half');
    expect(find.byKey(const ValueKey('book-total')).evaluate().isNotEmpty, isTrue);
  });

  testWidgets('no provider to pick; times sit under their bands; only the free courts show, and the booking sends the court', (t) async {
    final calls = await open(t);
    await t.tap(find.byKey(const ValueKey('book-seg-2')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('field-provider')), findsNothing);
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('Evening'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('unit-time-10:00 AM')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('unit-Court A')), findsNothing, reason: 'Court A is taken at 10');
    expect(find.byKey(const ValueKey('unit-Court B')), findsOneWidget);
    expect(find.text('Synthetic'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('unit-time-6:00 PM')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('unit-Court A')));
    await t.pumpAndSettle();
    expect(lastBody(calls, '/svc_quote')['unit'], 'Court A');

    await t.tap(find.byKey(const ValueKey('book-seg-3')));
    await t.pumpAndSettle();
    expect(find.text('Court A'), findsOneWidget, reason: 'the review says which court');
    await t.tap(find.byKey(const ValueKey('book-confirm')));
    await t.pumpAndSettle();
    final sent = lastBody(calls, '/svc_book');
    expect(sent['unit'], 'Court A');
    expect(sent['staff_id'], isNull);
    expect(sent.containsKey('part'), isFalse);
  });

  testWidgets('Next waits for a time on the Time step', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('book-seg-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('book-next')));
    await t.pump();
    expect(find.text('Choose a date and time.'), findsOneWidget);
  });
}
