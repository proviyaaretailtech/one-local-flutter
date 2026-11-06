import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/front_desk_screen.dart';
import 'package:vinii_pos/service/service_api.dart';

import 'helpers.dart';

// The Bill tab (5 Nov 2026): today's bookings in a tab per listing type, with check-in on the row, and the bills in the last tab.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _row(String id, String customer, String status, {String category = 'service', String fulfilment = 'appointment', List<String> actions = const [], num amount = 500, num paid = 0, String? unit, int? people, String kind = 'booking'}) => {
      'id': id, 'kind': kind, 'job_id': 'job-$id', 'display_no': 'APT-$id', 'status': status, 'version': 3, 'status_label': status == 'checked_in' ? 'Checked in' : status == 'completed' ? 'Completed' : 'Confirmed', 'tone': 'good',
      'time_label': '10:00 – 11:00 AM', 'title': 'Listing $id', 'category': category, 'fulfilment': fulfilment, 'customer': customer, 'customer_phone': '98765000$id', 'provider': 'Meera',
      'unit': unit, 'part': null, 'people': people, 'amount': amount, 'paid': paid, 'actions': actions,
    };

class _Fake {
  _Fake(this.rows, {this.kinds = const ['play', 'service']});
  List<Map<String, dynamic>> rows;
  final List<String> kinds;
  final calls = <(String, Map<String, dynamic>)>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body));
      final answer = switch (fn) {
        'svc_front_desk' => day(),
        'svc_session_count' => count(body),
        'svc_appointment_admit' => admit(body),
        'svc_appointment_act' => {'id': body['id'], 'status': 'checked_in', 'version': 4},
        'svc_bill_list' => {'counts': {'all': 1, 'due': 1, 'paid': 0}, 'due_amount': 500, 'paid_this_month': 0, 'bills': []},
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(answer), 200, headers: _json);
    }),
  );
  int walkIns = 2;
  int capacity = 6;
  Map<String, dynamic> day() {
    final booked = rows.where((r) => r['session_key'] == 'yoga|1').fold<int>(0, (n, r) => n + (r['places'] as int));
    final inNow = rows.where((r) => r['session_key'] == 'yoga|1').fold<int>(0, (n, r) => n + (r['admitted'] as int));
    return {
      'date_label': 'Thu, 5 Nov', 'business': 'Demo', 'kinds': kinds, 'appointments': rows,
      'courts': courts,
      'group_listings': [{'service_id': 'yoga', 'name': 'Yoga workshop', 'category': 'events'}, {'service_id': 'pottery', 'name': 'Pottery', 'category': 'activities'}],
      'sessions': hasSession ? [{'key': 'yoga|1', 'service_id': 'yoga', 'starts_at': '2026-11-05T12:30:00+00:00', 'title': 'Yoga workshop', 'time_label': '6:00 – 7:30 PM', 'category': 'events',
        'capacity': capacity, 'walk_ins': walkIns, 'booked': booked, 'booked_in': inNow, 'admitted': walkIns + inNow, 'to_come': booked - inNow, 'free': capacity - walkIns - booked}] : [],
    };
  }

  bool hasSession = true;
  List<Map<String, dynamic>> courts = [];
  Map<String, dynamic> count(Map<String, dynamic> b) {
    hasSession = true;
    walkIns += b['delta'] as int;
    return day();
  }

  Map<String, dynamic> admit(Map<String, dynamic> b) {
    final r = rows.firstWhere((x) => x['id'] == b['id']);
    r['admitted'] = b['admitted'];
    r['version'] = (r['version'] as int) + 1;
    return day();
  }

  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => HomeNav.storeName = 'Demo');
  tearDown(HomeNav.reset);

  final rows = [
    _row('01', 'Riya', 'confirmed', actions: ['check_in'], paid: 200),
    _row('02', 'Sam', 'checked_in', actions: ['start']),
    _row('03', 'Court player', 'confirmed', category: 'play', actions: ['check_in'], unit: 'Court A', people: 2),
    _row('04', 'Done person', 'completed', amount: 300, paid: 300),
  ];

  testWidgets('only the types this business offers show, with today\'s count, and Bills last', (t) async {
    await show(t, FrontDeskScreen(api: _Fake(rows).api));
    await t.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Thu, 5 Nov · 4 bookings'), findsOneWidget);
    for (final s in ['all', 'play', 'service', 'bills']) {
      expect(find.byKey(ValueKey('desk-tab-$s')), findsOneWidget, reason: s);
    }
    for (final s in ['events', 'activities', 'stay']) {
      expect(find.byKey(ValueKey('desk-tab-$s')), findsNothing, reason: s);
    }
    expect(find.text('Waiting · 3'), findsOneWidget);
    expect(find.text('Done · 1'), findsOneWidget);
    expect(find.text('Due ₹300'), findsOneWidget, reason: 'what is due sits on the row');
  });

  testWidgets('a type\'s tab shows only its bookings; a court shows its court and people', (t) async {
    await show(t, FrontDeskScreen(api: _Fake(rows).api));
    await t.pumpAndSettle();
    await _tap(t, 'desk-tab-play');
    expect(find.text('Court player'), findsOneWidget);
    expect(find.text('Riya'), findsNothing);
    expect(find.text('Court A · 2 people'), findsOneWidget);
  });

  testWidgets('a court already named in the title is not said twice', (t) async {
    final row = {..._row('05', 'Asha', 'confirmed', category: 'play', actions: ['check_in'], unit: 'Court A', people: 2), 'title': 'Badminton · Court A'};
    await show(t, FrontDeskScreen(api: _Fake([row]).api));
    await t.pumpAndSettle();
    expect(find.text('2 people'), findsOneWidget);
  });

  testWidgets('check in and start are one tap on the row, with the row\'s version, and the day reloads', (t) async {
    final f = _Fake(rows);
    await show(t, FrontDeskScreen(api: f.api));
    await t.pumpAndSettle();
    expect(f.of('svc_front_desk'), hasLength(1));
    await _tap(t, 'desk-act-01');
    expect(f.of('svc_appointment_act').last, containsPair('action', 'check_in'));
    expect(f.of('svc_appointment_act').last, containsPair('expected_version', 3));
    await _tap(t, 'desk-act-02');
    expect(f.of('svc_appointment_act').last, containsPair('action', 'start'));
    expect(f.of('svc_front_desk'), hasLength(3));
  });

  testWidgets('search finds a person by name or phone', (t) async {
    await show(t, FrontDeskScreen(api: _Fake(rows).api));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('desk-search')), '9876500002');
    await t.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Riya'), findsNothing);
  });

  testWidgets('the Bills tab keeps New bill and the piles', (t) async {
    final f = _Fake(rows);
    await show(t, FrontDeskScreen(api: f.api));
    await t.pumpAndSettle();
    expect(f.of('svc_bill_list'), isEmpty, reason: 'bills load when their tab is opened');
    await _tap(t, 'desk-tab-bills');
    expect(find.byKey(const ValueKey('new-bill')), findsOneWidget);
    expect(find.byKey(const ValueKey('pile-due')), findsOneWidget);
    expect(find.text('Every bill, from bookings, jobs and made here'), findsNothing, reason: 'one page, one heading');
  });

  group('Events and activities', () {
    Map<String, dynamic> guest(String id, String who, int places, {int admitted = 0}) => {
          ..._row(id, who, admitted > 0 ? 'checked_in' : 'confirmed', category: 'events', actions: [admitted > 0 ? 'start' : 'check_in']),
          'session_key': 'yoga|1', 'places': places, 'admitted': admitted,
        };

    testWidgets('the count: who is in, walk-ins, booked to come and free; +1 and -1 send one person', (t) async {
      final f = _Fake([guest('11', 'Riya', 3)], kinds: const ['events', 'service']);
      await show(t, FrontDeskScreen(api: f.api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');
      expect(find.text('2 of 6 admitted'), findsOneWidget);
      expect(find.text('2 walk-ins · 3 booked to come · 1 free'), findsOneWidget);

      await _tap(t, 'desk-plus-yoga|1');
      expect(f.of('svc_session_count').last, containsPair('delta', 1));
      expect(f.of('svc_session_count').last, containsPair('starts_at', '2026-11-05T12:30:00+00:00'));
      expect(find.text('3 of 6 admitted'), findsOneWidget);

      await _tap(t, 'desk-minus-yoga|1');
      expect(f.of('svc_session_count').last, containsPair('delta', -1));
      expect(find.text('2 of 6 admitted'), findsOneWidget);
    });

    testWidgets('+1 stops at capacity; -1 stops at no walk-ins', (t) async {
      final f = _Fake([guest('11', 'Riya', 3)], kinds: const ['events'])..walkIns = 3;
      await show(t, FrontDeskScreen(api: f.api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');
      expect(find.textContaining('Full'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('desk-plus-yoga|1')));
      await t.pumpAndSettle();
      expect(f.of('svc_session_count'), isEmpty, reason: 'no one more fits');

      f.rows = [];
      f.walkIns = 0;
      await show(t, FrontDeskScreen(key: UniqueKey(), api: f.api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');
      await t.tap(find.byKey(const ValueKey('desk-minus-yoga|1')));
      await t.pumpAndSettle();
      expect(f.of('svc_session_count'), isEmpty, reason: 'nothing to take off');
    });

    testWidgets('a group comes in parts: + adds one with the row version, All takes them all; one person is Admit and Undo', (t) async {
      final f = _Fake([guest('11', 'Riya', 3), guest('12', 'Sam', 3), guest('13', 'Solo', 1)], kinds: const ['events'])..capacity = 20;
      await show(t, FrontDeskScreen(api: f.api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');

      final plusAt = t.getCenter(find.byKey(const ValueKey('desk-more-11')));
      await _tap(t, 'desk-more-11');
      expect(f.of('svc_appointment_admit').last, {'id': '11', 'admitted': 1, 'expected_version': 3});
      expect(find.text('1 of 3'), findsOneWidget);
      expect(t.getCenter(find.byKey(const ValueKey('desk-more-11'))), plusAt, reason: 'the button stays under the finger');
      await _tap(t, 'desk-more-11');
      expect(f.of('svc_appointment_admit').last, {'id': '11', 'admitted': 2, 'expected_version': 4});

      await _tap(t, 'desk-all-12');
      expect(f.of('svc_appointment_admit').last, containsPair('admitted', 3));

      await _tap(t, 'desk-admit-13');
      expect(f.of('svc_appointment_admit').last, containsPair('admitted', 1));
      await _tap(t, 'desk-undo-13');
      expect(f.of('svc_appointment_admit').last, containsPair('admitted', 0));
    });

    testWidgets('no one booked: start a count for a listing of this type only', (t) async {
      final f = _Fake([], kinds: const ['events', 'activities'])..hasSession = false;
      await show(t, FrontDeskScreen(api: f.api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');
      expect(find.byKey(const ValueKey('desk-start-pottery')), findsNothing);
      await _tap(t, 'desk-start-yoga');
      expect(f.of('svc_session_count').single, containsPair('delta', 0));
      expect(f.of('svc_session_count').single['service_id'], 'yoga');
      expect(find.byKey(const ValueKey('desk-plus-yoga|1')), findsOneWidget);
    });

    testWidgets('a 375 px phone holds the count and a group row', (t) async {
      t.view.physicalSize = const Size(375, 812);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await show(t, FrontDeskScreen(api: _Fake([guest('11', 'A very long customer name that keeps going and going', 12)], kinds: const ['events']).api));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-events');
      expect(t.takeException(), isNull);
    });
  });

  group('Play', () {
    final now = DateTime(2026, 11, 6, 17, 0);
    String at(int h, int m) => DateTime(2026, 11, 6, h, m).toUtc().toIso8601String();
    Map<String, dynamic> play(String id, String who, String status, String unit, int fromH, int fromM, int toH, int toM, {String? part, int? people, List<String> actions = const [], num amount = 500, num paid = 500}) => {
          ..._row(id, who, status, category: 'play', actions: actions, unit: unit, people: people, amount: amount, paid: paid),
          'service_id': 'court', 'part': part, 'starts_at': at(fromH, fromM), 'ends_at': at(toH, toM), 'status_label': status,
        };
    final listing = {
      'service_id': 'court', 'title': 'Badminton', 'unit_word': 'Court',
      'units': [{'name': 'Court A', 'surface': 'Wooden'}, {'name': 'Court B'}, {'name': 'Court C'}],
    };
    Future<_Fake> open(WidgetTester t, List<Map<String, dynamic>> rows, {DateTime? clock}) async {
      final f = _Fake(rows)..courts = [listing];
      await show(t, FrontDeskScreen(key: UniqueKey(), api: f.api, now: () => clock ?? now));
      await t.pumpAndSettle();
      await _tap(t, 'desk-tab-play');
      return f;
    }

    String state(String key) => (find.descendant(of: find.byKey(ValueKey('desk-state-court|$key')), matching: find.byType(Text)).evaluate().single.widget as Text).data!;

    testWidgets('every court shows: playing with the time left and who is next, waiting, and free', (t) async {
      await open(t, [
        play('21', 'Riya', 'in_service', 'Court A', 16, 35, 17, 25, people: 2, actions: ['finish']),
        play('22', 'Sam', 'confirmed', 'Court A', 18, 0, 19, 0, actions: ['check_in']),
        play('23', 'Arjun', 'checked_in', 'Court B', 17, 0, 18, 0, people: 4, actions: ['start'], paid: 200),
      ]);
      expect(state('Court A'), 'Playing');
      expect(find.text('Riya · 2 people'), findsOneWidget);
      expect(find.text('25 min left'), findsOneWidget);
      expect(find.text('Next: Sam at 6:00 PM'), findsOneWidget);
      expect(find.byKey(const ValueKey('desk-act-21')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('desk-act-21')), matching: find.text('Finish')), findsOneWidget);
      expect(state('Court B'), 'Waiting');
      expect(find.descendant(of: find.byKey(const ValueKey('desk-act-23')), matching: find.text('Start')), findsOneWidget);
      expect(find.text('Due ₹300'), findsOneWidget);
      expect(state('Court C'), 'Free now');
      expect(find.text('Nothing more booked today'), findsOneWidget);
    });

    testWidgets('running over and arriving late are said; a free court shows who is next with Check in', (t) async {
      await open(t, [
        play('21', 'Riya', 'in_service', 'Court A', 16, 0, 16, 50, actions: ['finish']),
        play('22', 'Sam', 'confirmed', 'Court B', 16, 50, 17, 50, actions: ['check_in']),
        play('23', 'Asha', 'confirmed', 'Court C', 19, 0, 20, 0, actions: ['check_in']),
      ]);
      expect(find.text('10 min over'), findsOneWidget);
      expect(state('Court B'), 'Waiting');
      expect(find.text('10 min late'), findsOneWidget);
      expect(state('Court C'), 'Free now');
      expect(find.text('Next: Asha'), findsOneWidget);
      expect(find.text('at 7:00 PM'), findsOneWidget);
    });

    testWidgets('someone whose time passed does not hold the court; done ones are counted', (t) async {
      await open(t, [
        play('21', 'Gone', 'confirmed', 'Court A', 14, 0, 15, 0, actions: ['check_in']),
        play('22', 'Past', 'completed', 'Court A', 15, 0, 16, 0),
        play('23', 'Off', 'cancelled', 'Court B', 17, 0, 18, 0),
      ]);
      expect(state('Court A'), 'Free now');
      expect(find.text('Did not come: Gone at 2:00 PM'), findsOneWidget);
      expect(find.text('1 done today'), findsOneWidget);
      expect(state('Court B'), 'Free now');
      expect(find.textContaining('Off'), findsNothing);
    });

    testWidgets('a court booked in parts shows each part', (t) async {
      await open(t, [
        play('21', 'North team', 'in_service', 'Court A', 16, 30, 17, 30, part: 'North half', actions: ['finish']),
        play('22', 'South team', 'checked_in', 'Court A', 17, 0, 18, 0, part: 'South half', actions: ['start']),
      ]);
      expect(find.text('North half'), findsOneWidget);
      expect(find.text('South half'), findsOneWidget);
      expect(state('Court A|North half'), 'Playing');
      expect(state('Court A|South half'), 'Waiting');
    });

    testWidgets('Check in and Start act from the court; a booking with no court still shows; search narrows; a phone fits', (t) async {
      t.view.physicalSize = const Size(375, 812);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final f = await open(t, [
        play('22', 'A very long customer name that keeps going and going', 'confirmed', 'Court B', 17, 0, 18, 0, people: 12, actions: ['check_in']),
        {...play('24', 'No court', 'confirmed', '', 19, 0, 20, 0, actions: ['check_in']), 'unit': null, 'service_id': 'other'},
      ]);
      expect(t.takeException(), isNull);
      await _tap(t, 'desk-act-22');
      expect(f.of('svc_appointment_act').last, containsPair('action', 'check_in'));
      expect(find.text('Other bookings · 1'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('desk-search')), 'No court');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('desk-court-court|Court B')), findsNothing);
      expect(find.byKey(const ValueKey('desk-row-24')), findsOneWidget);
    });
  });

  testWidgets('an empty day says so; a long row fits a 375 px phone', (t) async {
    await show(t, FrontDeskScreen(api: _Fake([]).api));
    await t.pumpAndSettle();
    expect(find.text('No bookings here today.'), findsOneWidget);

    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final long = _row('09', 'A very long customer name that keeps going and going', 'confirmed', actions: ['check_in'], unit: 'A very long court name indeed', people: 12);
    await show(t, FrontDeskScreen(api: _Fake([long], kinds: const ['events', 'activities', 'play', 'service', 'stay']).api));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
