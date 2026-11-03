import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';

import 'home_test.dart' show FakeHome, summaryJson, showTall;
import 'service_screens_test.dart' show FakeRpc, appointment, refuse;

Map<String, dynamic> dashboard({String? closed, List<Map<String, dynamic>>? next}) => {
      'business': 'Sharma Services',
      'location': {'id': 'l1', 'name': 'Indiranagar Studio'},
      'date_label': 'Thursday, 8 October 2026',
      'closed': closed,
      'today': {'visits': 8, 'upcoming': 3, 'in_progress': 1, 'completed': 4, 'no_show': 0, 'cancelled': 1},
      'money': {'today': 4150, 'month': 63936},
      'available_slots': 6,
      'free_now': ['Neha Rao', 'Arjun Kumar', 'Meera Iyer'],
      'today_sources': {'offline': 7, 'online': 1},
      'providers': {'all': 8, 'available': 5, 'on_job': 2, 'off_duty': 1},
      'attention': {'advances_waiting': 2, 'to_bill': 1, 'no_show_to_decide': 0},
      'next_up': next ??
          [
            {'id': 'ap1', 'display_no': 'APT-1042', 'status': 'confirmed', 'status_label': 'Confirmed', 'tone': 'good', 'version': 3, 'time_label': '10:00 – 11:05 AM', 'title': 'Precision haircut + Hair spa', 'customer': 'Riya Sharma', 'provider': 'Neha Rao'},
          ],
      'month': {'completed': 41, 'no_show': 2, 'cancelled': 5},
      'plans': {'packages_active': 12, 'members': 64, 'sold_this_month': 9},
      'top_services': [
        {'name': 'Precision haircut', 'count': 22, 'revenue': 13200}
      ],
    };

Future<FakeRpc> showService(WidgetTester t, {Map<String, dynamic>? dash, Object? fail}) async {
  final rpc = FakeRpc({'svc_dashboard': (_) => fail != null ? refuse(500, 'Could not load.') : (dash ?? dashboard()), 'svc_appointment_view': (_) => appointment()});
  await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson(kind: 'service')), serviceApi: rpc.api, now: () => DateTime.utc(2026, 10, 8, 10)));
  return rpc;
}

void main() {
  setUp(() {
    HomeNav.reset();
    OutletScope.reset(); // the header's outlet switcher is app-wide
  });

  group('Service dashboard (home of a service business)', () {
    testWidgets('a service business gets its own dashboard, not the store one', (t) async {
      final rpc = await showService(t);
      expect(rpc.of('svc_dashboard'), hasLength(1));
      for (final text in ['Dashboard', 'Visits today', '8', '7 offline · 1 online', 'Money today', '₹4,150', '₹63,936 this month', 'Free slots', '6', 'Neha, Arjun +1 free now', 'Open today',
        'Thursday, 8 October 2026 · Indiranagar Studio', 'Needs attention', 'Advances waiting: 2', 'Visits to bill: 1', 'Next visits', '10:00 – 11:05 AM · Precision haircut + Hair spa',
        'Riya Sharma · Neha Rao', 'Providers', 'Available', 'On a job', 'Off duty', 'This month', '41 completed', 'TOP SERVICES · MONTH', 'Active packages', 'Members', 'Sold this month']) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      expect(find.text('Stock health'), findsNothing, reason: 'the store cards are not drawn for a service business');
      expect(find.text('Active orders'), findsNothing);
    });

    testWidgets('the bar has Home first, and Bill opens the appointment calendar', (t) async {
      HomeNav.service = (c) => HomeNav.partnerType = 'calendar-opened';
      await showService(t);
      expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-Money')), findsNothing);
      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pumpAndSettle();
      expect(HomeNav.partnerType, 'calendar-opened');
    });

    testWidgets('the three figures open what they count: visits as a list, money taken today, who is free and their free slots (2 Nov 2026)', (t) async {
      final rpc = FakeRpc({
        'svc_dashboard': (_) => dashboard(),
        'svc_calendar': (_) => {'date': '2026-10-08', 'date_label': 'Thursday', 'location': {'name': 'Main'}, 'week': [], 'counts': {'available_slots': 6, 'providers': 5}, 'providers': [], 'appointments': []},
        'svc_bill_list': (_) => {'counts': {'today': 2}, 'paid_today': 4150, 'due_amount': 0, 'paid_this_month': 63936, 'bills': []},
        'svc_free_slots': (_) => {'date_label': 'Thursday, 8 October', 'slot_minutes': 30, 'total': 6, 'free_now': ['Neha Rao'], 'people': [
              {'staff_id': 's1', 'name': 'Neha Rao', 'title': 'Stylist', 'state': 'free_now', 'count': 2, 'slots': [{'time': '11:00', 'label': '11:00 AM'}, {'time': '11:30', 'label': '11:30 AM'}]},
            ]},
      });
      await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson(kind: 'service')), serviceApi: rpc.api, now: () => DateTime.utc(2026, 10, 8, 10)));
      Future<void> open(String key) async {
        await t.tap(find.byKey(ValueKey(key)));
        await t.pumpAndSettle();
      }

      await open('tile-visits');
      expect(find.text('Bookings'), findsWidgets);
      expect(rpc.of('svc_calendar').last.$2['view'], 'day');
      expect(find.text('No bookings on this day. Tap New booking to add one.'), findsOneWidget, reason: 'the List view');
      await t.pageBack();
      await t.pumpAndSettle();

      await open('tile-money');
      expect(rpc.of('svc_bill_list').last.$2, {'filter': 'today'});
      expect(find.text('Taken today'), findsOneWidget);
      expect(find.text('2 bills · ₹4,150 taken'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();

      await open('tile-slots');
      // which slots and who is free (founder, 2 Nov 2026)
      expect(rpc.of('svc_free_slots'), hasLength(1));
      for (final s in ['Free slots', 'Who is free', 'Neha Rao', 'Free now', '11:00 AM', '11:30 AM']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
    });

    testWidgets('a visit opens its detail', (t) async {
      await showService(t);
      await t.ensureVisible(find.textContaining('Precision haircut + Hair spa').first);
      await t.tap(find.textContaining('Precision haircut + Hair spa').first);
      await t.pumpAndSettle();
      expect(find.text('Appointment Detail'), findsOneWidget);
    });

    testWidgets('a closed day says so; an empty day is honest', (t) async {
      await showService(t, dash: dashboard(closed: 'Dasara · Studio closed all day', next: []));
      expect(find.text('Closed today'), findsOneWidget);
      expect(find.textContaining('Dasara · Studio closed all day'), findsWidgets);
      expect(find.text('No visits waiting. Tap Calendar to book one.'), findsOneWidget);
    });

    testWidgets('a failed load shows the message and a retry that asks again', (t) async {
      final rpc = await showService(t, fail: true);
      expect(find.text('Could not load.'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(rpc.of('svc_dashboard'), hasLength(2));
    });
  });

  group('Home tab', () {
    testWidgets('on the dashboard itself, Home does nothing and Money is gone', (t) async {
      var home = 0;
      HomeNav.home = (_) => home++;
      await showTall(t, ControlCentreScreen(api: FakeHome(summary: summaryJson()), now: () => DateTime.utc(2026, 10, 5, 10, 30)));
      await t.tap(find.byKey(const ValueKey('tab-Home')));
      await t.pumpAndSettle();
      expect(home, 0, reason: 'already on the dashboard');
      expect(find.byKey(const ValueKey('tab-Money')), findsNothing);
    });
  });
}
