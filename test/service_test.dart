import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/booking_screen.dart';
import 'package:vinii_pos/service/calendar_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'home_test.dart' show FakeHome;

const _json = {'content-type': 'application/json; charset=utf-8'};

/// Fake server: records each request and answers from [handler].
class FakeServer {
  FakeServer(this.handler);
  final http.Response Function(http.Request r) handler;
  final requests = <http.Request>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      return handler(r);
    }),
  );
  Iterable<http.Request> where(String method, String pathEnd) => requests.where((r) => r.method == method && r.url.path.endsWith(pathEnd));
}

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: _json);

// ---- fixtures: the numbers and words of Figma frames 90 and 91 (assets/figma_ref_i)
Map<String, dynamic> appt(String time, String title, String status, String label, String tone, String customer, String provider, {String? resource}) =>
    {'id': 'a-$time', 'display_no': 'APT-1', 'status': status, 'status_label': label, 'tone': tone, 'time_label': time, 'title': title, 'customer': customer, 'provider': provider, 'resource': resource, 'version': 1};

Map<String, dynamic> calendar({List<Map<String, dynamic>>? items}) => {
      'date': '2026-10-08',
      'view': 'day',
      'date_label': 'Thursday, 8 October 2026',
      'business': 'Sharma Services',
      'location': {'id': 'l1', 'name': 'Indiranagar Studio', 'city': 'Bengaluru'},
      'week': [
        for (final (i, d) in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexed) {'date': '2026-10-${(5 + i).toString().padLeft(2, '0')}', 'weekday': d, 'day': 5 + i, 'selected': i == 3, 'count': 0},
      ],
      'counts': {'appointments': 8, 'available_slots': 6, 'providers': 2},
      'providers': [
        {'staff_id': 's1', 'name': 'Neha Rao', 'title': 'Senior stylist'},
        {'staff_id': 's2', 'name': 'Kavya Nair', 'title': 'Stylist'},
      ],
      'appointments': items ??
          [
            appt('10:00 – 10:45 AM', 'Precision haircut', 'completed', 'Completed', 'good', 'Amit Shah', 'Kavya Nair'),
            appt('10:00 – 11:05 AM', 'Haircut + spa', 'confirmed', 'Confirmed', 'good', 'Riya Sharma', 'Neha Rao', resource: 'Chair 2'),
            appt('3:30 – 4:15 PM', 'Precision haircut', 'deposit_pending', 'Deposit pending', 'warn', 'Vikram Patel', 'Kavya Nair'),
          ],
    };

Map<String, dynamic> catalogue() => {
      'settings': {'deposit_amount': 200, 'free_cancel_hours': 12, 'slot_minutes': 15},
      'services': [
        {
          'id': 'sv1',
          'name': 'Precision haircut',
          'price': 600,
          'duration_min': 45,
          'buffer_min': 15,
          'category': 'Hair',
          'addons': [
            {'id': 'ad1', 'name': 'Hair spa', 'price': 200, 'duration_min': 20}
          ],
          'staff_ids': ['s1'],
        },
      ],
      'providers': [
        {'staff_id': 's1', 'name': 'Neha Rao', 'title': 'Senior stylist', 'location_id': 'l1'},
        {'staff_id': 's2', 'name': 'Kavya Nair', 'title': 'Stylist', 'location_id': 'l1'},
      ],
      'resources': [
        {'id': 'r2', 'name': 'Chair 2', 'kind': 'chair', 'location_id': 'l1'}
      ],
    };

Map<String, dynamic> quote({bool addon = false}) => addon
    ? {
        'subtotal': 800, 'gst_pct': 18, 'gst_amount': 144, 'round_off': 0, 'total': 944, 'deposit': 200, 'due_at_studio': 744, 'duration_min': 65, 'buffer_min': 15, 'free_cancel_hours': 12,
        'lines': [
          {'menu_item_id': 'sv1', 'name': 'Precision haircut', 'qty': 1, 'amount': 600},
          {'menu_item_id': 'ad1', 'name': 'Hair spa', 'qty': 1, 'amount': 200},
        ],
      }
    : {
        'subtotal': 600, 'gst_pct': 18, 'gst_amount': 108, 'round_off': 0, 'total': 708, 'deposit': 200, 'due_at_studio': 508, 'duration_min': 45, 'buffer_min': 15, 'free_cancel_hours': 12,
        'lines': [
          {'menu_item_id': 'sv1', 'name': 'Precision haircut', 'qty': 1, 'amount': 600},
        ],
      };

Map<String, dynamic> bookedView() => {
      'id': 'ap1', 'display_no': 'APT-0001', 'status': 'confirmed', 'status_label': 'Confirmed', 'tone': 'good', 'version': 1, 'time_label': '10:00 – 11:05 AM', 'title': 'Precision haircut + Hair spa',
      'customer': {'name': 'Riya Sharma'}, 'provider': {'name': 'Neha Rao'}, 'bill': {'total': 944, 'paid': 200, 'due': 744}, 'actions': ['check_in', 'reschedule', 'cancel', 'no_show'],
    };

Future<void> showTall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('ServiceApi', () {
    test('calendar sends the token and the date, view and provider filter', () async {
      final s = FakeServer((_) => ok(calendar()));
      final c = await s.api.calendar(date: '2026-10-08', view: 'week', staffId: 's1');
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rpc/svc_calendar');
      expect(jsonDecode(r.body), {'date': '2026-10-08', 'view': 'week', 'staff_id': 's1'});
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(c.appointments, 8);
      expect(c.availableSlots, 6);
      expect(c.items.length, 3);
      expect(c.items[1].resource, 'Chair 2');
    });

    test('book sends only choices and a key; no prices, no totals', () async {
      final s = FakeServer((_) => ok(bookedView()));
      final a = await s.api.book(
        key: 'svc-abc',
        customerName: 'Riya Sharma',
        customerPhone: '9876543210',
        serviceId: 'sv1',
        addonIds: ['ad1'],
        staffId: 's1',
        resourceId: 'r2',
        startsAt: '2026-10-08T04:30:00+00:00',
        depositMethod: 'cash',
        tendered: 500,
      );
      final r = s.requests.single;
      expect(r.url.path, '/rpc/svc_book');
      expect(r.headers['Idempotency-Key'], 'svc-abc');
      expect(jsonDecode(r.body), {
        'customer_name': 'Riya Sharma',
        'customer_phone': '9876543210',
        'service_id': 'sv1',
        'addon_ids': ['ad1'],
        'staff_id': 's1',
        'resource_id': 'r2',
        'starts_at': '2026-10-08T04:30:00+00:00',
        'deposit': {'method': 'cash', 'tendered': 500},
      });
      expect(a.displayNo, 'APT-0001');
      expect(a.actions, contains('check_in'));
    });

    test('act and bill carry the version and an idempotency key', () async {
      final s = FakeServer((_) => ok(bookedView()));
      await s.api.act('ap1', 'cancel', version: 3, extra: {'reason': 'customer asked'});
      await s.api.bill('ap1', method: 'cash', tendered: 800, version: 4, key: 'svc-b1');
      expect(s.requests[0].url.path, '/rpc/svc_appointment_act');
      expect(s.requests[0].headers['Idempotency-Key'], startsWith('svc-'));
      expect(jsonDecode(s.requests[0].body), {'id': 'ap1', 'action': 'cancel', 'expected_version': 3, 'reason': 'customer asked'});
      expect(s.requests[1].url.path, '/rpc/svc_bill');
      expect(s.requests[1].headers['Idempotency-Key'], 'svc-b1');
      expect(jsonDecode(s.requests[1].body), {'id': 'ap1', 'method': 'cash', 'tendered': 800, 'expected_version': 4});
    });

    test('server refusals keep their message and code', () async {
      final s = FakeServer((_) => err(409, 'This appointment was changed on another device.', 'version_conflict'));
      await expectLater(
        s.api.act('ap1', 'check_in', version: 1),
        throwsA(isA<ServiceApiException>().having((e) => e.stale, 'stale', true).having((e) => e.message, 'message', 'This appointment was changed on another device.')),
      );
    });

    test('no session means nothing is sent', () async {
      final api = ServiceApi(baseUrl: 'http://pos.test', accessToken: () => null, client: MockClient((_) async => fail('must not call the server')));
      await expectLater(api.calendar(date: '2026-10-08'), throwsA(isA<Exception>()));
    });

    test('history passes filter and search', () async {
      final s = FakeServer((_) => ok({'appointments': []}));
      await s.api.history(filter: 'completed', q: ' riya ');
      expect(jsonDecode(s.requests.single.body), {'filter': 'completed', 'q': 'riya'});
    });
  });

  group('Appointment Calendar (Figma 90)', () {
    testWidgets('draws the title, strip, counts, cards and the book button', (t) async {
      final s = FakeServer((_) => ok(calendar()));
      await showTall(t, ServiceCalendarScreen(api: s.api));
      expect(find.text('Appointment Calendar'), findsOneWidget);
      expect(find.text('Thursday, 8 October 2026 · Indiranagar Studio'), findsOneWidget);
      expect(find.text('Sharma Services · Bengaluru'), findsNothing, reason: 'first-level screens carry only the shared banner');
      for (final w in ['Day', 'Week', 'All providers', 'Mon', 'Thu', 'Sun']) {
        expect(find.text(w), findsWidgets, reason: w);
      }
      expect(find.text('Appointments'), findsOneWidget);
      expect(find.text('8'), findsWidgets);
      expect(find.text('Available slots'), findsOneWidget);
      expect(find.text('2 providers'), findsOneWidget);
      expect(find.text('Today’s appointments'), findsOneWidget);
      expect(find.text('3 scheduled'), findsOneWidget);
      expect(find.text('10:00 – 11:05 AM · Haircut + spa'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('Deposit pending'), findsOneWidget);
      expect(find.text('Neha Rao · Chair 2'), findsOneWidget);
      expect(find.text('+ Book appointment'), findsOneWidget);
      for (final tab in ['Home', 'Item', 'Bill', 'Online order']) {
        expect(find.text(tab), findsOneWidget, reason: tab);
      }
      expect(find.text('Stock'), findsNothing, reason: 'the fifth slot is kept empty (Stock is a part of Item)');
    });

    testWidgets('tapping a day asks the server for that day', (t) async {
      final s = FakeServer((_) => ok(calendar()));
      await showTall(t, ServiceCalendarScreen(api: s.api, initialDate: DateTime(2026, 10, 8)));
      await t.tap(find.bySemanticsLabel('Fri 9'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['date'], '2026-10-09');
    });

    testWidgets('Week and a chosen provider are sent to the server', (t) async {
      final s = FakeServer((_) => ok(calendar()));
      await showTall(t, ServiceCalendarScreen(api: s.api, initialDate: DateTime(2026, 10, 8)));
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['view'], 'week');
      await t.tap(find.text('All providers'));
      await t.pumpAndSettle();
      await t.tap(find.text('Kavya Nair').last);
      await t.pumpAndSettle();
      expect(jsonDecode(s.requests.last.body)['staff_id'], 's2');
    });

    testWidgets('an empty day says so, an error offers a retry', (t) async {
      var fail = true;
      final s = FakeServer((_) => fail ? err(500, 'Could not load the calendar.') : ok(calendar(items: [])));
      await showTall(t, ServiceCalendarScreen(api: s.api));
      expect(find.text('Could not load the calendar.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.textContaining('No appointments yet'), findsOneWidget);
    });
  });

  group('Appointment Booking (Figma 91)', () {
    http.Response Function(http.Request) router({bool bookFails = false}) => (r) {
          final p = r.url.path;
          if (p.endsWith('/svc_catalogue')) return ok(catalogue());
          if (p.endsWith('/svc_quote')) return ok(quote(addon: (jsonDecode(r.body)['addon_ids'] as List).isNotEmpty));
          if (p.endsWith('/svc_slots')) {
            return ok({'providers': [{'staff_id': 's1', 'name': 'Neha Rao', 'slots': [{'starts_at': '2026-10-08T04:30:00+00:00', 'label': '10:00 AM', 'range_label': '10:00 – 11:05 AM'}]}]});
          }
          if (p.endsWith('/svc_book')) return bookFails ? err(500, 'Network trouble.') : ok(bookedView());
          return err(404, 'not found');
        };

    Future<void> fill(WidgetTester t, FakeServer s, {bool addon = false}) async {
      await showTall(t, ServiceBookingScreen(api: s.api, date: DateTime(2026, 10, 8), business: 'Sharma Services', location: 'Indiranagar Studio'));
      await t.tap(find.byKey(const ValueKey('field-customer')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('customer-name')), 'Riya Sharma');
      await t.enterText(find.byKey(const ValueKey('customer-phone')), '98765 43210');
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('field-service')));
      await t.pumpAndSettle();
      await t.tap(find.text('Precision haircut'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('field-provider')));
      await t.pumpAndSettle();
      await t.tap(find.text('Neha Rao').last);
      await t.pumpAndSettle();
      if (addon) {
        await t.tap(find.text('Hair spa · ₹200 · +20 min'));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const ValueKey('field-time')));
      await t.pumpAndSettle();
      await t.tap(find.text('10:00 AM'));
      await t.pumpAndSettle();
    }

    testWidgets('draws the form, the add-on, the server summary and the policy', (t) async {
      final s = FakeServer(router());
      await fill(t, s, addon: true);
      expect(find.text('Appointment Booking'), findsOneWidget);
      expect(find.text('New appointment · Customer visits the studio'), findsOneWidget);
      for (final w in ['Customer & service', 'Schedule & location', 'Customer', 'Service', 'Provider', 'Date', 'Time', 'Business location']) {
        expect(find.text(w), findsWidgets, reason: w);
      }
      expect(find.text('Riya Sharma · +91 9876543210'), findsOneWidget);
      expect(find.text('Precision haircut · ₹600 · 45 min'), findsOneWidget);
      expect(find.text('Neha Rao · Senior stylist'), findsOneWidget);
      expect(find.text('Thursday, 8 October 2026'), findsOneWidget);
      expect(find.text('10:00 – 11:05 AM'), findsOneWidget);
      expect(find.text('Hair spa · ₹200 · +20 min'), findsOneWidget);
      expect(find.text('65 min + 15 min buffer'), findsOneWidget);
      expect(find.text('Payment summary'), findsOneWidget);
      for (final w in ['₹800', 'GST · 18%', '₹144', 'Advance now', '₹200', 'Due at studio', '₹744', 'Total', '₹944']) {
        expect(find.text(w), findsWidgets, reason: w);
      }
      expect(find.text('Cancellation policy'), findsOneWidget);
      expect(find.text('Free until 12 hours before. Later cancellations forfeit the ₹200 deposit.'), findsOneWidget);
      expect(find.text('Confirm booking · ₹200 advance'), findsOneWidget);
    });

    testWidgets('quote asks the server with choices only; the policy banner can be dismissed', (t) async {
      final s = FakeServer(router());
      await fill(t, s, addon: true);
      expect(jsonDecode(s.where('POST', '/svc_quote').last.body), {'service_id': 'sv1', 'addon_ids': ['ad1'], 'staff_id': 's1'});
      await t.tap(find.byKey(const ValueKey('dismiss-policy')));
      await t.pumpAndSettle();
      expect(find.text('Cancellation policy'), findsNothing);
    });

    testWidgets('confirm takes the advance and books with one key, the chosen time and the add-on', (t) async {
      final s = FakeServer(router());
      await fill(t, s, addon: true);
      await t.tap(find.text('Confirm booking · ₹200 advance'));
      await t.pumpAndSettle();
      expect(find.text('Advance ₹200'), findsOneWidget);
      await t.tap(find.text('Take Cash'));
      await t.pumpAndSettle();
      final r = s.where('POST', '/svc_book').single;
      expect(r.headers['Idempotency-Key'], startsWith('svc-'));
      final body = jsonDecode(r.body) as Map;
      expect(body['customer_name'], 'Riya Sharma');
      expect(body['customer_phone'], '9876543210');
      expect(body['service_id'], 'sv1');
      expect(body['addon_ids'], ['ad1']);
      expect(body['staff_id'], 's1');
      expect(body['starts_at'], '2026-10-08T04:30:00+00:00');
      expect(body['deposit'], {'method': 'cash'});
      expect(body.keys, isNot(contains('total')));
    });

    testWidgets('"collect the advance later" books without a payment; a failed call keeps the key for the retry', (t) async {
      var fail = true;
      final s = FakeServer((r) => r.url.path.endsWith('/svc_book') && fail ? err(500, 'Network trouble.') : router()(r));
      await fill(t, s);
      await t.tap(find.text('Confirm booking · ₹200 advance'));
      await t.pumpAndSettle();
      await t.tap(find.text('Collect the advance later'));
      await t.pumpAndSettle();
      expect(toast('Network trouble.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Confirm booking · ₹200 advance'));
      await t.pumpAndSettle();
      await t.tap(find.text('Collect the advance later'));
      await t.pumpAndSettle();
      final calls = s.where('POST', '/svc_book').toList();
      expect(calls.length, 2);
      expect(calls[0].headers['Idempotency-Key'], calls[1].headers['Idempotency-Key'], reason: 'a retried tap must not book twice');
      expect(jsonDecode(calls[1].body), isNot(contains('deposit')));
    });

    testWidgets('a time taken on another device clears the chosen time and says why', (t) async {
      final s = FakeServer((r) => r.url.path.endsWith('/svc_book') ? err(409, 'That time was just booked on another device.') : router()(r));
      await fill(t, s);
      await t.tap(find.text('Confirm booking · ₹200 advance'));
      await t.pumpAndSettle();
      await t.tap(find.text('Collect the advance later'));
      await t.pumpAndSettle();
      expect(toast('That time was just booked on another device.'), findsOneWidget);
      expect(find.text('Choose a time'), findsOneWidget);
    });

    testWidgets('confirm with the form incomplete says what is missing and sends nothing', (t) async {
      final s = FakeServer(router());
      await showTall(t, ServiceBookingScreen(api: s.api));
      await t.tap(find.text('Confirm booking'));
      await t.pumpAndSettle();
      expect(toast('Add the customer first.'), findsOneWidget);
      expect(s.where('POST', '/svc_book'), isEmpty);
    });
  });

  group('wiring', () {
    test('installRoutes plugs the service calendar in, and only service partners reach it from the control centre', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.service, isNotNull);
      expect(HomeNav.partnerType, isNull);
    });

    testWidgets('the Bill tab opens appointments for a service partner and billing for everyone else', (t) async {
      var service = 0, bill = 0;
      HomeNav.service = (_) => service++;
      HomeNav.bill = (_) => bill++;
      HomeNav.partnerType = 'service';
      await show(t, ControlCentreScreen(api: FakeHome()));
      t.view.physicalSize = const Size(780, 5200);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pumpAndSettle();
      expect([service, bill], [1, 0]);
      HomeNav.partnerType = 'store';
      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pumpAndSettle();
      expect([service, bill], [1, 1]);
    });

    testWidgets('the calendar opens from the hook', (t) async {
      HomeNav.reset();
      installRoutes();
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => HomeNav.service!(c), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(ServiceCalendarScreen), findsOneWidget);
    });
  });
}
