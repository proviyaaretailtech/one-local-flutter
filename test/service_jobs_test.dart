import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/bookings_screen.dart';
import 'package:vinii_pos/service/job_screens.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

// Jobs (New job, 2 Nov 2026): several services, a team, a time or "schedule later", arrival window, repeating visits, the job's bill.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _job({String status = 'scheduled', List<String> visitStatus = const ['scheduled', 'scheduled'], List<String> actions = const ['close', 'cancel'],
        bool billNow = false, int cancelled = 0}) =>
    {
      'id': 'j1', 'display_no': 'J-0001', 'title': 'AC + plumbing', 'instructions': 'Call before coming', 'status': status,
      'status_label': {'scheduled': 'Scheduled', 'in_progress': 'In progress', 'completed': 'Completed', 'cancelled': 'Cancelled'}[status], 'tone': 'info',
      'customer': 'Job Cust', 'customer_phone': '9000000398', 'address': 'Flat 2, Pune', 'repeat_label': 'Every week', 'remind_invoice': true,
      'team': [{'staff_id': 's2', 'name': 'Arjun Kumar'}],
      'visits': [
        for (var i = 0; i < visitStatus.length; i++)
          {
            'id': 'v${i + 1}', 'no': i + 1, 'status': visitStatus[i], 'status_label': visitStatus[i] == 'in_progress' ? 'In progress' : 'Scheduled',
            'date_label': 'Tue, 10 Nov 2026', 'time_label': '1:00 – 3:00 PM', 'arrival_label': 'Arrive 1:00 – 2:00 PM',
            'actions': visitStatus[i] == 'scheduled' ? ['start'] : visitStatus[i] == 'in_progress' ? ['complete'] : [],
          }
      ],
      'bill': {
        'id': 'o1', 'display_no': 'P-00039', 'status': 'due', 'status_label': 'Due', 'tone': 'warn', 'source': 'job', 'job': {'id': 'j1', 'display_no': 'J-0001'},
        'customer': 'Job Cust', 'lines': [{'name': 'AC service', 'qty': 1, 'amount': 800}, {'name': 'Plumber visit', 'qty': 2, 'amount': 600}],
        'subtotal': 1400, 'discount': 0, 'gst_pct': 0, 'gst_amount': 0, 'round_off': 0, 'total': 1400, 'paid': 0, 'due': 1400, 'payments': [], 'can_collect': true,
      },
      'actions': actions, 'bill_now': billNow, 'visits_cancelled': cancelled,
    };

class _Fake {
  _Fake(this.answers);
  final Map<String, Object Function(Map<String, dynamic>)> answers;
  final calls = <(String, Map<String, dynamic>, String?)>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body, r.headers['Idempotency-Key']));
      final a = answers[fn];
      if (a == null) return http.Response(jsonEncode({'detail': 'no fake for $fn'}), 404, headers: _json);
      return http.Response(jsonEncode(a(body)), 200, headers: _json);
    }),
  );
  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

Map<String, dynamic> _catalogue(Map<String, dynamic> _) => {
      'services': [
        {'id': 'ac', 'name': 'AC service', 'price': 800, 'duration_min': 60},
        {'id': 'pl', 'name': 'Plumber visit', 'price': 300, 'duration_min': 45},
      ],
      'providers': [
        {'staff_id': 's1', 'name': 'Neha Patil'},
        {'staff_id': 's2', 'name': 'Arjun Kumar'},
      ],
    };

/// A tall screen: the job form and page are long, and a list only builds what is on screen.
Future<void> _show(WidgetTester t, Widget screen) async {
  await show(t, screen);
  t.view.physicalSize = const Size(900, 9000);
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

/// New job is in steps (4 Nov 2026): a step bar segment jumps straight to step [n] (0 Customer, 1 Services, 2 Schedule, 3 Team and billing).
Future<void> _step(WidgetTester t, int n) => _tap(t, ValueKey('job-seg-$n'));

Future<void> _saveJob(WidgetTester t) async {
  // the last toast floats over the bottom bar, where Save now is
  t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
  await t.pumpAndSettle();
  await t.ensureVisible(find.text('Save job'));
  await t.tap(find.text('Save job'));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  testWidgets('new job: customer, services, team, day and time, arrival window, every week for 5 visits; one call with a key', (t) async {
    final f = _Fake({'svc_catalogue': _catalogue, 'svc_job_save': (_) => _job()});
    JobView? made;
    await _show(t, Builder(builder: (c) => TextButton(
        onPressed: () async => made = await Navigator.of(c).push<JobView>(MaterialPageRoute(builder: (_) => NewJobScreen(api: f.api, date: DateTime(2026, 11, 3), today: () => DateTime(2026, 11, 2, 15)))),
        child: const Text('open'))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    for (final s in ['New job', 'Customer', 'Job', 'Step 1 of 4']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.text('Save job'), findsNothing, reason: 'save is on the last step');
    await t.enterText(find.byKey(const ValueKey('job-name')), 'Job Cust');
    await t.enterText(find.byKey(const ValueKey('job-phone')), '9000000398');
    await t.enterText(find.byKey(const ValueKey('job-address')), 'Flat 2, Pune');
    await t.enterText(find.byKey(const ValueKey('job-title')), 'AC + plumbing');
    await _step(t, 1);
    await _tap(t, const ValueKey('jmore-ac'));
    await _tap(t, const ValueKey('jmore-pl'));
    await _tap(t, const ValueKey('jmore-pl'));
    expect(find.text('₹1,400'), findsWidgets);
    await _step(t, 2);
    for (final s in ['Schedule', 'Tue, 3 Nov 2026', '10:00 AM', '11:00 AM', 'Arrival window', 'Repeating']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('window-60'));
    await _tap(t, const ValueKey('repeat-weekly'));
    await _tap(t, const ValueKey('visits-more'));
    await _step(t, 3);
    for (final s in ['Team', 'Billing', 'Remind me to bill when I close the job']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('team-s2'));
    await _tap(t, const ValueKey('job-remind'));
    await _saveJob(t);
    final call = f.calls.singleWhere((c) => c.$1 == 'svc_job_save');
    expect(call.$2, {
      'customer_name': 'Job Cust', 'customer_phone': '9000000398', 'address': 'Flat 2, Pune', 'title': 'AC + plumbing',
      'lines': [{'menu_item_id': 'ac', 'qty': 1}, {'menu_item_id': 'pl', 'qty': 2}], 'team': ['s2'],
      'date': '2026-11-03', 'start': '10:00', 'end': '11:00', 'arrival_window_min': 60, 'repeat': 'weekly', 'repeat_count': 5, 'remind_invoice': false,
    });
    expect(call.$3, startsWith('svc-'));
    expect(made!.displayNo, 'J-0001');
  });

  testWidgets('schedule later: no date or time is sent; nothing is sent without a service', (t) async {
    final f = _Fake({'svc_catalogue': _catalogue, 'svc_job_save': (_) => _job(status: 'unscheduled', visitStatus: [])});
    await _show(t, NewJobScreen(api: f.api, today: () => DateTime(2026, 11, 2, 15)));
    await t.enterText(find.byKey(const ValueKey('job-name')), 'Z');
    await _step(t, 2);
    await _tap(t, const ValueKey('job-later'));
    expect(find.text('Arrival window'), findsNothing);
    await _step(t, 3);
    await _saveJob(t);
    expect(find.text('Add at least one service.'), findsOneWidget);
    expect(find.text('Step 2 of 4'), findsOneWidget, reason: 'back on Services, where the service is missing');
    expect(f.of('svc_job_save'), isEmpty);
    await _tap(t, const ValueKey('jmore-pl'));
    await _step(t, 3);
    await _saveJob(t);
    expect(f.of('svc_job_save').single, {'customer_name': 'Z', 'lines': [{'menu_item_id': 'pl', 'qty': 1}], 'team': [], 'schedule_later': true, 'remind_invoice': true});
  });

  testWidgets('new job steps: Step 1 of 4, Next moves on, Back goes back; no name sends you to Customer', (t) async {
    final f = _Fake({'svc_catalogue': _catalogue});
    await _show(t, NewJobScreen(api: f.api, today: () => DateTime(2026, 11, 2, 15)));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Next: Services'), findsWidgets);
    expect(find.byKey(const ValueKey('job-back')), findsNothing);
    await _tap(t, const ValueKey('job-next'));
    expect(find.text('Step 2 of 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('jmore-ac')), findsOneWidget);
    await _tap(t, const ValueKey('job-next'));
    expect(find.text('Step 3 of 4'), findsOneWidget);
    await _tap(t, const ValueKey('job-back'));
    expect(find.text('Step 2 of 4'), findsOneWidget);
    await _step(t, 3);
    expect(find.text('Step 4 of 4'), findsOneWidget);
    expect(find.text('Last step: save the job'), findsOneWidget);
    expect(find.byKey(const ValueKey('job-next')), findsNothing);
    await _saveJob(t);
    expect(find.text('Enter the customer\'s name.'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('job-name')), findsOneWidget);
  });

  testWidgets('new job on a phone (375 x 812): every step fits', (t) async {
    final f = _Fake({'svc_catalogue': _catalogue});
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: NewJobScreen(api: f.api, today: () => DateTime(2026, 11, 2, 15))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    for (var i = 1; i < 4; i++) {
      await t.tap(find.byKey(const ValueKey('job-next')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'step ${i + 1}');
      expect(find.text('Step ${i + 1} of 4'), findsOneWidget);
    }
    expect(find.text('Save job'), findsOneWidget);
  });

  testWidgets('job page: who, where, team, every visit with Start; Close asks to bill now and opens the bill', (t) async {
    var state = _job();
    final f = _Fake({
      'svc_job_view': (_) => state,
      'svc_job_act': (b) => state = switch (b['action']) {
            'start' => _job(status: 'in_progress', visitStatus: ['in_progress', 'scheduled'], actions: ['cancel']),
            'close' => _job(status: 'completed', visitStatus: ['completed', 'cancelled'], actions: [], billNow: true, cancelled: 1),
            _ => state,
          },
      'svc_bill_view': (_) => (_job()['bill'] as Map<String, dynamic>),
    });
    await _show(t, JobDetailScreen(api: f.api, id: 'j1'));
    for (final s in ['Job J-0001', 'Every week · 2 visits', 'AC + plumbing', 'Job Cust · +91 90000 00398', 'Flat 2, Pune', 'Call before coming', 'Arjun Kumar',
      'Visit 1 · Tue, 10 Nov 2026', '1:00 – 3:00 PM', 'Arrive 1:00 – 2:00 PM', 'Bill P-00039', '₹1,400', 'Close job', 'Cancel job']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('start-v1'));
    expect(f.of('svc_job_act').last, {'id': 'j1', 'action': 'start', 'visit_id': 'v1'});
    expect(find.text('Complete visit'), findsOneWidget);
    expect(find.text('Close job'), findsNothing, reason: 'a visit is in progress');
    state = _job(status: 'in_progress', visitStatus: ['completed', 'scheduled']);
    await t.pumpWidget(const SizedBox());
    await _show(t, JobDetailScreen(api: f.api, id: 'j1'));
    await t.ensureVisible(find.text('Close job'));
    await t.tap(find.text('Close job'));
    await t.pumpAndSettle();
    expect(f.of('svc_job_act').last, {'id': 'j1', 'action': 'close'});
    expect(find.text('Bill Job Cust now?'), findsOneWidget);
    expect(find.text('₹1,400 is due on this job.'), findsOneWidget);
    await t.tap(find.text('Open the bill'));
    await t.pumpAndSettle();
    expect(f.of('svc_bill_view').single, {'order_id': 'o1'});
    expect(find.text('Open job J-0001'), findsOneWidget);
  });

  testWidgets('cancel asks first; Keep it sends nothing', (t) async {
    final f = _Fake({'svc_job_view': (_) => _job(), 'svc_job_act': (_) => _job(status: 'cancelled', actions: [])});
    await _show(t, JobDetailScreen(api: f.api, id: 'j1'));
    await _tap(t, const ValueKey('cancel-job'));
    await t.tap(find.text('Keep it'));
    await t.pumpAndSettle();
    expect(f.of('svc_job_act'), isEmpty);
    await _tap(t, const ValueKey('cancel-job'));
    await t.tap(find.text('Cancel job').last);
    await t.pumpAndSettle();
    expect(f.of('svc_job_act').single, {'id': 'j1', 'action': 'cancel'});
  });

  testWidgets('bookings: a job visit opens its job; + New job is there', (t) async {
    final f = _Fake({
      'svc_calendar': (_) => {
            'date': '2026-11-02', 'date_label': 'Monday', 'month_label': 'November 2026', 'business': 'Demo', 'location': {'name': 'Main'},
            'week': [], 'counts': {'available_slots': 0, 'providers': 1}, 'providers': [],
            'appointments': [
              {'id': 'v1', 'kind': 'job', 'job_id': 'j1', 'display_no': 'J-0001 · visit 1', 'status': 'confirmed', 'status_label': 'Scheduled', 'tone': 'good',
               'starts_at': '2026-11-02T13:00:00', 'date': '2026-11-02', 'duration_min': 120, 'time_label': '1:00 – 3:00 PM', 'title': 'AC + plumbing',
               'customer': 'Job Cust', 'provider': 'Arjun Kumar', 'amount': 1400, 'paid': 0},
            ],
          },
      'svc_job_view': (_) => _job(),
    });
    await _show(t, BookingsScreen(api: f.api, now: () => DateTime(2026, 11, 2, 9)));
    expect(find.byKey(const ValueKey('new-job')), findsOneWidget);
    await _tap(t, const ValueKey('booking-v1'));
    expect(f.of('svc_job_view').single, {'id': 'j1'});
    expect(find.text('Job J-0001'), findsOneWidget);
  });
}
