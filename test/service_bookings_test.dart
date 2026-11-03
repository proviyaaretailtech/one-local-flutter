import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/bookings_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/motion.dart' show Entrance;
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

// The Bookings tab (founder's sketch, 2 Nov 2026): Calendar day / week / month with Today, List, Board, Map, and the day's bookings.

const _json = {'content-type': 'application/json; charset=utf-8'};
final _now = DateTime(2026, 11, 2, 15, 20); // Monday

Map<String, dynamic> _appt(String id, String date, String hm, int mins, String title, String status, String tone, String label,
        {String fulfilment = 'appointment', String customer = 'Riya Sharma', String phone = '9000000301', String staff = 'Neha Patil', String? address, num amount = 600, num paid = 200,
        String source = 'pos'}) {
  final start = DateTime.parse('${date}T$hm:00');
  final end = start.add(Duration(minutes: mins));
  String c(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  return {
    'id': id, 'display_no': id.toUpperCase(), 'status': status, 'status_label': label, 'tone': tone, 'version': 1,
    'starts_at': start.toIso8601String(), 'ends_at': end.toIso8601String(), 'date': date, 'duration_min': mins, 'time_label': '${c(start)} – ${c(end)}',
    'title': title, 'fulfilment': fulfilment, 'customer': customer, 'customer_phone': phone, 'provider': staff, 'staff_id': 's1',
    'service_address': address, 'amount': amount, 'paid': paid, 'source': source,
  };
}

final _today = [
  _appt('a1', '2026-11-02', '10:15', 45, 'Haircut (women)', 'completed', 'good', 'Completed', paid: 600),
  _appt('a2', '2026-11-02', '15:15', 60, 'AC service', 'in_service', 'info', 'In service', fulfilment: 'on_location', customer: 'Deepak Verma', phone: '9000000316',
      staff: 'Arjun Kumar', address: 'Flat 12, Sunrise Society, Karve Nagar, Pune 411052', amount: 800),
  _appt('a3', '2026-11-02', '15:15', 30, 'Haircut (men)', 'checked_in', 'good', 'Checked in', customer: 'Farhan Khan', staff: 'Ravi Shinde', amount: 300, source: 'app'),
  _appt('a4', '2026-11-02', '16:00', 15, 'Beard trim', 'deposit_pending', 'warn', 'Advance due', customer: 'Nikhil Jain', staff: 'Ravi Shinde', amount: 150, paid: 0),
  _appt('a5', '2026-11-02', '17:00', 45, 'Haircut (women)', 'cancelled', 'bad', 'Cancelled', customer: 'Karan Singh'),
];
final _tomorrow = [_appt('b1', '2026-11-03', '10:30', 90, 'Hair colour', 'confirmed', 'good', 'Confirmed', customer: 'Sneha Kulkarni', amount: 1800)];

Map<String, dynamic> _calendar(Map<String, dynamic> body) {
  final view = body['view'] ?? 'day';
  final date = '${body['date']}';
  final items = switch (view) {
    'day' => date == '2026-11-03' ? _tomorrow : date == '2026-11-02' ? _today : <Map<String, dynamic>>[],
    _ => [..._today, ..._tomorrow],
  };
  final d = DateTime.parse(date);
  final monday = d.subtract(Duration(days: d.weekday - 1));
  return {
    'date': date, 'view': view, 'date_label': 'Day $date', 'month_label': 'November 2026', 'business': 'Demo Services',
    'location': {'name': 'Main', 'city': 'Pune'}, 'closed': null,
    'week': [
      for (var i = 0; i < 7; i++)
        {
          'date': monday.add(Duration(days: i)).toIso8601String().substring(0, 10),
          'weekday': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
          'day': monday.add(Duration(days: i)).day,
          'count': monday.add(Duration(days: i)).day == 2 ? 4 : monday.add(Duration(days: i)).day == 3 ? 1 : 0,
        }
    ],
    'month': view == 'month'
        ? [for (var i = 1; i <= 30; i++) {'date': '2026-11-${i.toString().padLeft(2, '0')}', 'day': i, 'isodow': ((i + 5) % 7) + 1, 'today': i == 2, 'count': i == 2 ? 4 : i == 3 ? 1 : 0}]
        : null,
    'counts': {'appointments': 4, 'available_slots': 12, 'providers': 3, 'offline': 3, 'online': 1},
    'providers': [
      {'staff_id': 's1', 'name': 'Neha Patil', 'title': 'Senior stylist'},
      {'staff_id': 's2', 'name': 'Arjun Kumar', 'title': 'Technician'},
    ],
    'appointments': items,
  };
}

class _Fake {
  final calls = <Map<String, dynamic>>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token',
    client: MockClient((r) async {
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add(body);
      return http.Response(jsonEncode(_calendar(body)), 200, headers: _json);
    }),
  );
}

Future<_Fake> _show(WidgetTester t, {Future<bool> Function(Uri)? openUrl}) async {
  final f = _Fake();
  await show(t, BookingsScreen(api: f.api, now: () => _now, openUrl: openUrl));
  t.view.physicalSize = const Size(900, 6000);
  t.view.devicePixelRatio = 2;
  await t.pumpAndSettle();
  return f;
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  test('lengths and kinds in plain words', () {
    expect([bookingLength(15), bookingLength(60), bookingLength(90), bookingLength(180)], ['15 min', '1 hr', '1 hr 30 min', '3 hr']);
    expect([bookingKind('on_location'), bookingKind('appointment'), bookingKind('event'), bookingKind('on_demand')],
        ['At customer\'s place', 'At the shop', 'Group session', 'Online']);
  });

  testWidgets('opens on the planner (2 Nov 2026): one call for the month; no Day / Week / Month chips; today\'s bookings in the sheet', (t) async {
    final f = await _show(t);
    expect(f.calls.single, {'date': '2026-11-02', 'view': 'month', 'with_cancelled': true});
    for (final s in ['Bookings', 'Calendar', 'List', 'Board', 'Map', 'All staff', '+ New booking', 'November 2026', 'Upcoming today', '5 bookings']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    for (final k in ['range-day', 'range-week', 'range-month', 'today']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: '$k: gone (Today shows only away from today)');
    }
    expect(find.byKey(const ValueKey('booking-a2')), findsOneWidget);
    // a white calendar (founder: "make it white")
    final card = t.widget<Container>(find.descendant(of: find.byKey(const ValueKey('planner')), matching: find.byType(Container)).first);
    expect((card.decoration as BoxDecoration).color, Colors.white);
    // the store's motion: the day's cards cascade in; a new month slides in
    expect(find.ancestor(of: find.byKey(const ValueKey('booking-a2')), matching: find.byWidgetPredicate((w) => w is Entrance && '${w.key}'.contains('in-2026-11-02-a2'))), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('month-next')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 120));
    expect(find.descendant(of: find.byKey(const ValueKey('planner')), matching: find.byType(SlideTransition)), findsWidgets, reason: 'mid-slide');
    await t.pumpAndSettle();
  });

  testWidgets('month: the grid with counts; a day shows its bookings below without another call; arrows change the month', (t) async {
    final f = await _show(t);
    expect(find.text('November 2026'), findsWidgets);
    expect(find.byKey(const ValueKey('planner')), findsOneWidget, reason: 'the month card with the sheet under it');
    expect(find.text('Upcoming today'), findsOneWidget);
    expect(find.byKey(const ValueKey('booking-a1')), findsOneWidget);
    final calls = f.calls.length;
    await _tap(t, const ValueKey('mday-2026-11-03'));
    expect(f.calls.length, calls, reason: 'the month answer already has that day');
    expect(find.text('On Tue, 3 Nov'), findsOneWidget);
    expect(find.byKey(const ValueKey('booking-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('booking-a1')), findsNothing);
    await _tap(t, const ValueKey('month-next'));
    expect(f.calls.last, {'date': '2026-12-01', 'view': 'month', 'with_cancelled': true});
    await _tap(t, const ValueKey('today'));
    expect(f.calls.last['date'], '2026-11-02');
  });

  testWidgets('planner (2 Nov 2026): pastel cards; pulling the handle up folds the month into the chosen week with the day by the hour, down opens it', (t) async {
    final f = await _show(t);
    final calls = f.calls.length;
    expect(find.byKey(const ValueKey('mday-2026-11-30')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-cards')), findsOneWidget);
    // a booking's pastel: a completed booking is blue (coming up yellow, waiting for the advance pink, happening now green)
    final card = t.widget<Material>(find.ancestor(of: find.byKey(const ValueKey('booking-a1')), matching: find.byType(Material)).first);
    expect(card.color, const Color(0xFFCFE0F7));

    await t.drag(find.byKey(const ValueKey('planner-handle')), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('planner-hours')), findsOneWidget);
    expect(find.text('Today, by the hour'), findsOneWidget);
    expect(find.byKey(const ValueKey('mday-2026-11-02')), findsOneWidget, reason: 'the chosen week stays');
    expect(find.byKey(const ValueKey('mday-2026-11-08')), findsOneWidget);
    expect(find.byKey(const ValueKey('mday-2026-11-30')), findsNothing, reason: 'the rest of the month folds away');
    expect(find.byKey(const ValueKey('block-a1')), findsOneWidget);
    expect(find.byKey(const ValueKey('now-line')), findsOneWidget);

    await t.drag(find.byKey(const ValueKey('planner-handle')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('mday-2026-11-30')), findsOneWidget);
    await _tap(t, const ValueKey('planner-handle'));
    expect(find.byKey(const ValueKey('planner-hours')), findsOneWidget, reason: 'a tap on the handle folds it too');
    expect(f.calls.length, calls, reason: 'folding needs no call');
  });

  testWidgets('month at phone width (2 Nov 2026): each day\'s circle and count fit inside its cell (no overflow stripes)', (t) async {
    await _show(t);
    t.view.physicalSize = const Size(720, 4000); // 360 wide, a narrow phone
    await t.pumpAndSettle();
    for (final day in ['2026-11-02', '2026-11-03', '2026-11-30']) {
      final cell = t.getRect(find.byKey(ValueKey('mday-$day')));
      expect(cell.height, greaterThanOrEqualTo(50), reason: 'room for the circle and the count under it');
      final inside = find.descendant(of: find.byKey(ValueKey('mday-$day')), matching: find.byType(Text));
      for (final e in inside.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget).first);
        expect(r.bottom, lessThanOrEqualTo(cell.bottom + 0.5), reason: '$day: ${(e.widget as Text).data} inside its cell');
      }
    }
  });

  testWidgets('list: each booking with length, kind, customer and phone, staff, address and money', (t) async {
    await _show(t);
    await _tap(t, const ValueKey('mode-list'));
    for (final s in ['10:15 AM – 11:00 AM · Haircut (women)', '45 min', 'At the shop', 'Riya Sharma · +91 90000 00301', '₹600 · paid',
      '3:15 PM – 4:15 PM · AC service', 'At customer\'s place', 'Flat 12, Sunrise Society, Karve Nagar, Pune 411052', '₹800 · ₹200 paid', 'Advance due', 'Cancelled']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
  });

  testWidgets('list: the week strip and arrows change the day', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('mode-list'));
    await _tap(t, const ValueKey('day-2026-11-03'));
    expect(f.calls.last, {'date': '2026-11-03', 'view': 'day', 'with_cancelled': true});
    expect(find.byKey(const ValueKey('booking-b1')), findsOneWidget);
    await _tap(t, const ValueKey('week-next'));
    expect(f.calls.last['date'], '2026-11-10');
    expect(find.text('No bookings on this day. Tap New booking to add one.'), findsOneWidget);
  });

  testWidgets('board: one column per state with its bookings', (t) async {
    await _show(t);
    await _tap(t, const ValueKey('mode-board'));
    Finder inCol(String col, String key) => find.descendant(of: find.byKey(ValueKey('column-$col')), matching: find.byKey(ValueKey(key)));
    expect(inCol('Upcoming', 'block-a4'), findsOneWidget);
    expect(inCol('Checked in', 'block-a3'), findsOneWidget);
    expect(inCol('In progress', 'block-a2'), findsOneWidget);
    expect(inCol('Done', 'block-a1'), findsOneWidget);
    expect(inCol('Cancelled', 'block-a5'), findsOneWidget);
  });

  testWidgets('map: the day\'s jobs at a customer\'s place, each opens in Maps', (t) async {
    Uri? opened;
    await _show(t, openUrl: (u) async {
      opened = u;
      return true;
    });
    // the example map pulses for ever, so this view is stepped through in time instead of waiting for it to settle
    await t.tap(find.byKey(const ValueKey('mode-map')));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.byKey(const ValueKey('map-preview')), findsOneWidget);
    expect(find.text('Example map'), findsOneWidget);
    expect(find.text('3:15 PM – 4:15 PM · AC service'), findsOneWidget);
    expect(find.text('10:15 AM – 11:00 AM · Haircut (women)'), findsNothing, reason: 'only jobs at a customer\'s place');
    await t.tap(find.byKey(const ValueKey('maps-a2')));
    await t.pump(const Duration(milliseconds: 200));
    expect(opened.toString(), 'https://www.google.com/maps/search/?api=1&query=Flat%2012%2C%20Sunrise%20Society%2C%20Karve%20Nagar%2C%20Pune%20411052');
  });

  testWidgets('offline and online (2 Nov 2026): All · Offline · Online with counts; each booking tagged where it came from', (t) async {
    final f = await _show(t);
    for (final s in ['All 4', 'Offline 3', 'Online 1']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Online'), findsWidgets, reason: 'the short tag on the online booking\'s block');
    await _tap(t, const ValueKey('mode-list'));
    expect(find.descendant(of: find.byKey(const ValueKey('booking-a3')), matching: find.text('Booked online')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('booking-a1')), matching: find.text('Booked offline')), findsOneWidget);
    await _tap(t, const ValueKey('source-app'));
    expect(f.calls.last, {'date': '2026-11-02', 'view': 'day', 'with_cancelled': true, 'source': 'app'});
    await _tap(t, const ValueKey('source-all'));
    expect(f.calls.last.containsKey('source'), isFalse);
  });

  testWidgets('staff filter: the chosen person goes to the server', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('staff-filter'));
    await t.tap(find.text('Arjun Kumar').last);
    await t.pumpAndSettle();
    expect(f.calls.last['staff_id'], 's2');
    expect(find.text('Arjun Kumar'), findsWidgets);
    expect(posTheme(), isNotNull);
  });
}
