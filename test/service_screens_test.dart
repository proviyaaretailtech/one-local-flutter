import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/service/availability_screen.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/history_screen.dart';
import 'package:vinii_pos/service/plans_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/service/service_widgets.dart';
import 'package:vinii_pos/service/staff_screen.dart';
import 'package:vinii_pos/service/visit_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

/// Fake /rpc server: answers by function name, records every call.
class FakeRpc {
  FakeRpc(this.answers);
  final Map<String, Object Function(Map<String, dynamic> body)> answers;
  final calls = <(String fn, Map<String, dynamic> body, String? key)>[];
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body, r.headers['Idempotency-Key']));
      final a = answers[fn];
      if (a == null) return http.Response(jsonEncode({'detail': 'no fake for $fn'}), 404, headers: _json);
      final v = a(body);
      if (v is http.Response) return v;
      return http.Response(jsonEncode(v), 200, headers: _json);
    }),
  );
  List<(String, Map<String, dynamic>, String?)> of(String fn) => calls.where((c) => c.$1 == fn).toList();
}

http.Response refuse(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: _json);

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 5200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

// ---- fixtures: the words and numbers of Figma frames 83-108 (assets/figma_ref_i)
Map<String, dynamic> serviceList() => {
      'total': 18,
      'shown': 6,
      'categories': ['Grooming', 'Home care', 'Learning', 'Wellness'],
      'counts': {'active': 16, 'paused': 2, 'draft': 0},
      'services': [
        {'id': 's1', 'name': 'Precision haircut', 'type': 'appointment', 'status': 'active', 'status_label': 'Active', 'type_label': 'Appointment', 'price_label': '₹600', 'length_label': '45 min', 'subtitle': 'APT-01 · Grooming'},
        {'id': 's2', 'name': 'AC maintenance', 'type': 'on_location', 'status': 'active', 'status_label': 'Active', 'type_label': 'On-location', 'price_label': '₹800', 'length_label': '1 hour', 'subtitle': 'LOC-01 · Home care'},
        {'id': 'p1', 'name': 'Grooming essentials', 'type': 'package', 'status': 'active', 'status_label': 'Active', 'type_label': 'Package', 'price_label': '₹1,350', 'length_label': '90 days', 'subtitle': 'PKG-01 · 3 services'},
        {'id': 'm1', 'name': 'Care Plus', 'type': 'membership', 'status': 'active', 'status_label': 'Active', 'type_label': 'Membership', 'price_label': '₹999/mo', 'length_label': '30 days', 'subtitle': 'MEM-01 · Monthly'},
      ],
    };

Map<String, dynamic> serviceDetail({bool canEdit = true}) => {
      'id': 's1', 'name': 'Precision haircut', 'price': 600, 'description': 'Consultation, wash, precision cut and styling for a fresh everyday look.', 'code': 'APT-01', 'category': 'Grooming',
      'kind': 'service', 'fulfilment': 'appointment', 'duration_min': 45, 'buffer_min': 15, 'capacity': 1, 'staff_required': '1 certified hair stylist', 'min_notice_min': 120, 'grace_min': 10,
      'checklist': [], 'status': 'active', 'updated_label': '7 Oct', 'gst_pct': 18, 'prices_include_tax': false, 'deposit': 200, 'free_cancel_hours': 12, 'locations': ['Indiranagar Studio'],
      'staff': [
        {'staff_id': 'st1', 'name': 'Neha Rao'},
        {'staff_id': 'st2', 'name': 'Kavya Nair'}
      ],
      'addons': [
        {'id': 'a1', 'name': 'Hair spa', 'price': 200, 'duration_min': 20},
        {'id': 'a2', 'name': 'Beard shaping', 'price': 150, 'duration_min': 15}
      ],
      'can_edit': canEdit,
    };

Map<String, dynamic> packages() => {
      'plans': [
        {
          'id': 'p1', 'name': 'Grooming essentials', 'price': 1350, 'kind': 'package', 'status': 'active', 'status_label': 'Active', 'validity_days': 90, 'usage_note': '3 visits · 1 credit per service',
          'exclusions': '', 'benefits': '', 'discount_pct': 0, 'credit_rules': '', 'renewal_note': '', 'savings': 250, 'list_price': 1600,
          'items': [
            {'service_id': 's1', 'name': 'Precision haircut', 'qty': 1, 'amount': 600},
            {'service_id': 'a1', 'name': 'Hair spa', 'qty': 2, 'amount': 1000}
          ],
        },
        {
          'id': 'p2', 'name': 'Home care duo', 'price': 1450, 'kind': 'package', 'status': 'active', 'status_label': 'Active', 'validity_days': 180, 'usage_note': '2 jobs · Same customer address',
          'exclusions': 'Travel, materials and GST extra', 'benefits': '', 'discount_pct': 0, 'credit_rules': '', 'renewal_note': '', 'savings': 150, 'list_price': 1600,
          'items': [
            {'service_id': 's2', 'name': 'AC maintenance', 'qty': 2, 'amount': 1600}
          ],
        },
      ],
      'counts': {'all': 2, 'active': 2, 'draft': 0, 'paused': 0},
      'active_members': 0, 'joined_this_month': 0, 'monthly_recurring': 0,
      'services': [
        {'id': 's1', 'name': 'Precision haircut', 'price': 600},
        {'id': 'a1', 'name': 'Hair spa', 'price': 500}
      ],
      'can_edit': true,
    };

Map<String, dynamic> memberships() => {
      'plans': [
        {
          'id': 'm1', 'name': 'Care Plus', 'price': 999, 'kind': 'membership', 'status': 'active', 'status_label': 'Active', 'validity_days': 30, 'period': 'month', 'usage_note': '', 'exclusions': '',
          'benefits': 'Priority appointment slots', 'discount_pct': 10, 'discount_category': 'Additional grooming', 'credit_rules': 'No rollover · Member only', 'renewal_note': 'Monthly · Cancel before renewal',
          'savings': 0, 'items': [
            {'service_id': 's1', 'name': 'Haircut', 'qty': 1, 'amount': 600},
            {'service_id': 'a1', 'name': 'Hair spa', 'qty': 1, 'amount': 500}
          ],
        },
      ],
      'counts': {'all': 1, 'active': 1, 'draft': 0, 'paused': 0},
      'active_members': 64, 'joined_this_month': 8, 'monthly_recurring': 63936, 'services': [], 'can_edit': true,
    };

Map<String, dynamic> staff() => {
      'counts': {'all': 8, 'available': 5, 'on_job': 2, 'off_duty': 1},
      'providers': [
        {'staff_id': 'st1', 'name': 'Neha Rao', 'title': 'Senior stylist', 'state': 'available', 'state_label': 'Available', 'tone': 'good', 'skills': 'Hair cutting · Styling', 'certification': 'NVQ Hairdressing Level 3',
          'services': 'Precision haircut · Hair spa', 'service_area': 'Indiranagar Studio only', 'availability': 'Thu–Sat · 10 AM–7 PM', 'service_ids': ['s1'], 'is_bookable': true},
        {'staff_id': 'st3', 'name': 'Arjun Kumar', 'title': 'AC technician', 'state': 'on_job', 'state_label': 'On job', 'tone': 'warn', 'skills': 'AC cleaning · Diagnostics', 'certification': 'ITI Refrigeration · Verified',
          'services': 'AC maintenance · Repairs', 'service_area': 'Indiranagar · Domlur · 5 km', 'availability': 'Today · Next slot 4 PM', 'service_ids': ['s2'], 'is_bookable': true},
      ],
      'candidates': [
        {'staff_id': 'st9', 'name': 'Meera Iyer'}
      ],
      'services': [
        {'id': 's1', 'name': 'Precision haircut'},
        {'id': 's2', 'name': 'AC maintenance'}
      ],
      'locations': [], 'can_edit': true,
    };

Map<String, dynamic> schedule() => {
      'location': {'id': 'l1', 'name': 'Indiranagar Studio'},
      'locations': [
        {'id': 'l1', 'name': 'Indiranagar Studio'}
      ],
      'hours': [
        for (var d = 1; d <= 7; d++) {'weekday': d, 'open': '10:00', 'close': d == 7 ? '14:00' : '19:00', 'break_start': '13:00', 'break_end': d == 7 ? '14:00' : '14:00'}
      ],
      'hours_rows': [
        {'label': 'Mon–Sat', 'value': '10:00 AM – 7:00 PM'},
        {'label': 'Sunday', 'value': '10:00 AM – 2:00 PM'},
        {'label': 'Lunch break', 'value': '1:00 PM – 2:00 PM'}
      ],
      'providers': [
        {'staff_id': 'st1', 'name': 'Neha Rao', 'label': 'Thu–Sat · 10 AM–7 PM', 'hours': [], 'available_today': true},
        {'staff_id': 'st2', 'name': 'Kavya Nair', 'label': 'Mon–Sat · 10 AM–6 PM', 'hours': [], 'available_today': true}
      ],
      'available_today': 2,
      'slot': {'slot_minutes': 15, 'service': 'Precision haircut', 'duration_min': 45, 'capacity': 1, 'buffer_before': 0, 'buffer_after': 15},
      'exceptions': [
        {'kind': 'blocked', 'id': 'x1', 'date_label': 'Friday, 9 October', 'time_label': '3:00 – 4:00 PM', 'provider': 'Neha Rao', 'staff_id': 'st1', 'reason': 'Team training'},
        {'kind': 'holiday', 'id': 'x2', 'date_label': 'Tuesday, 20 October', 'reason': 'Dasara · Studio closed all day'}
      ],
      'can_edit': true,
    };

Map<String, dynamic> appointment({String status = 'confirmed', List<String>? actions, String fulfilment = 'appointment', List<Map<String, dynamic>>? checklist, num due = 744, num paid = 200}) => {
      'id': 'ap1', 'display_no': fulfilment == 'on_location' ? 'JOB-1048' : 'APT-1042', 'status': status, 'version': 3, 'fulfilment': fulfilment,
      'status_label': switch (status) { 'in_service' => 'In service', 'completed' => 'Completed', _ => 'Confirmed' }, 'tone': 'good',
      'starts_at': '2026-10-08T04:30:00Z', 'ends_at': '2026-10-08T05:35:00Z', 'started_at': '2026-10-08T09:30:00Z', 'checked_in_at': '2026-10-08T09:27:00Z', 'arrival_verified_by': 'otp',
      'date_label': '8 Oct 2026', 'time_label': '10:00 – 11:05 AM', 'duration_min': 65, 'buffer_min': 15,
      'title': fulfilment == 'on_location' ? 'AC maintenance' : 'Precision haircut + Hair spa',
      'customer': {'name': 'Riya Sharma', 'phone': '9876543210'}, 'provider': {'staff_id': 'st1', 'name': fulfilment == 'on_location' ? 'Arjun Kumar' : 'Neha Rao'}, 'resource': {'name': 'Chair 2'},
      'location': {'name': 'Indiranagar Studio'}, 'service_address': 'A-304, Lakeview Apartments, Domlur 560071', 'access_note': 'Gate 2 · Lift available',
      'notes': 'Keep shoulder-length layers. Sensitive scalp; use a mild shampoo.', 'provider_notes': 'Drain fixed; cooling improved to 17°C.',
      'lines': [
        {'menu_item_id': 's1', 'name': fulfilment == 'on_location' ? 'AC maintenance' : 'Precision haircut', 'kind': 'service', 'qty': 1, 'amount': fulfilment == 'on_location' ? 800 : 600, 'covered': false},
        {'menu_item_id': 'a1', 'name': fulfilment == 'on_location' ? 'Outdoor unit wash' : 'Hair spa', 'kind': 'addon', 'qty': 1, 'amount': fulfilment == 'on_location' ? 150 : 200, 'covered': false},
      ],
      'extras': fulfilment == 'on_location'
          ? [
              {'id': 'e1', 'kind': 'material', 'name': 'Drain connector', 'qty': 1, 'amount': 150, 'approved_at': '2026-10-08T09:45:00Z'},
              {'id': 'e2', 'kind': 'material', 'name': 'Coil cleaning solution', 'qty': 1, 'amount': 100, 'approved_at': '2026-10-08T09:45:00Z'},
            ]
          : [],
      'checklist': checklist ?? [],
      'credits': [],
      'order': {'id': 'o1', 'display_no': 'INV-1048', 'status': 'awaiting_payment'},
      'bill': {'subtotal': 800, 'discount': 0, 'gst_pct': 18, 'gst_amount': 144, 'cgst': 72, 'sgst': 72, 'taxable': 800, 'gstin': '29ABCDE1234F1Z5', 'total': 944, 'deposit': 200, 'paid': paid, 'refunded': 0, 'due': due},
      'payments': [
        {'method': 'upi', 'amount': 200, 'at': '2026-10-07T12:45:00Z'}
      ],
      'events': [
        {'kind': 'placed', 'message': 'P-1 placed', 'at': '2026-10-07T12:42:00Z'},
        {'kind': 'appointment_booked', 'message': 'booked', 'at': '2026-10-07T12:42:00Z', 'actor': 'Riya Sharma'},
        {'kind': 'part_paid', 'message': 'paid', 'at': '2026-10-07T12:45:00Z'},
      ],
      'actions': actions ?? ['check_in', 'reschedule', 'cancel'],
    };

Map<String, dynamic> history() => {
      'total': 24,
      'month_label': 'October 2026',
      'providers': [
        {'staff_id': 'st1', 'name': 'Neha Rao'}
      ],
      'appointments': [
        {'id': 'j1', 'display_no': 'JOB-1048', 'title': 'AC maintenance', 'status': 'completed', 'status_label': 'Completed', 'money_label': 'Paid', 'tone': 'good', 'fulfilment': 'on_location',
          'customer': 'Riya Sharma', 'provider': 'Arjun Kumar', 'date_label': '8 Oct', 'time_label': '3:00 – 4:00 PM', 'total': 1416, 'paid': 1416, 'refunded': 0, 'order_no': 'P-00012', 'version': 6},
        {'id': 't1', 'display_no': 'TKT-2074', 'title': 'Clay & Chai', 'status': 'cancelled', 'status_label': 'Cancelled', 'money_label': 'Refunded', 'tone': 'bad', 'fulfilment': 'event',
          'customer': 'Priya Menon', 'provider': 'Meera Iyer', 'date_label': '11 Oct', 'time_label': '10:00 AM – 12:00 PM', 'total': 1062, 'paid': 1062, 'refunded': 1062, 'refunded_at': '2026-10-07T06:00:00Z', 'version': 3},
      ],
    };

void main() {
  group('data classes', () {
    test('appointment facts read as typed fields; actions decide the buttons', () {
      final a = AppointmentView(appointment(fulfilment: 'on_location', checklist: [
        {'label': 'Inspect', 'done': true},
        {'label': 'Final cooling test', 'done': false}
      ]));
      expect(a.onLocation, isTrue);
      expect(a.displayNo, 'JOB-1048');
      expect(a.customerPhone, '9876543210');
      expect(a.checklist.where((c) => c.b('done')).length, 1);
      expect(a.extras.length, 2);
      expect(a.billData.n('due'), 744);
      expect(a.can('check_in'), isTrue);
      expect(a.can('bill'), isFalse);
      expect(a.version, 3);
    });

    test('list data: counts and rows from the server', () {
      expect(ServiceListData(serviceList()).count('active'), 16);
      expect(StaffData(staff()).count('on_job'), 2);
      expect(ScheduleData(schedule()).exceptions.length, 2);
      expect(PlanListData(memberships()).monthlyRecurring, 63936);
      expect(HistoryData(history()).items.first.fulfilment, 'on_location');
      expect(svcRupees(63936), '₹63,936');
      expect(svcRupees(1350), '₹1,350');
      expect(svcRupees(125000), '₹1,25,000');
      expect(svcPhone('9876543210'), '+91 98765 43210');
    });
  });

  group('ServiceApi on the /rpc gateway', () {
    test('every call is POST /rpc/<function> with the token; writes carry a key', () async {
      final s = FakeRpc({'svc_job_update': (_) => appointment(status: 'in_service'), 'svc_entitlement_sell': (_) => {'id': 'e1', 'name': 'Grooming essentials', 'credits': []}});
      await s.api.jobUpdate('ap1', version: 3, key: 'k-1', done: ['Inspect'], extras: [
        {'menu_item_id': 'm9', 'qty': 1, 'approved_by_customer': true}
      ]);
      await s.api.sell(key: 'k-2', planId: 'p1', customerName: 'Riya', customerPhone: '9876543210', method: 'upi');
      expect(s.calls[0].$1, 'svc_job_update');
      expect(s.calls[0].$2, {
        'id': 'ap1',
        'expected_version': 3,
        'done': ['Inspect'],
        'extras': [
          {'menu_item_id': 'm9', 'qty': 1, 'approved_by_customer': true}
        ]
      });
      expect(s.calls[0].$3, 'k-1');
      expect(s.calls[1].$2, {'plan_id': 'p1', 'customer_name': 'Riya', 'customer_phone': '9876543210', 'method': 'upi'});
      expect(s.calls[1].$3, 'k-2');
    });

    test('a refusal keeps the server sentence and code', () async {
      final s = FakeRpc({'svc_bill': (_) => refuse(422, 'This idempotency key was already used for a different request', 'idempotency_mismatch')});
      await expectLater(
          s.api.bill('ap1', version: 1, key: 'k'), throwsA(isA<ServiceApiException>().having((e) => e.code, 'code', 'idempotency_mismatch').having((e) => e.status, 'status', 422)));
    });
  });

  group('Service Catalogue (Figma 83)', () {
    testWidgets('draws counts, filters and rows from the server', (t) async {
      final s = FakeRpc({'svc_service_list': (_) => serviceList()});
      await show(t, ServiceCatalogueScreen(api: s.api, business: 'Sharma Services · Bengaluru'));
      for (final text in ['Service Catalogue', '18 services · All fulfilment models', 'Grooming', 'Instant/On-demand', 'Active 16', 'Paused 2', '6 total', 'Precision haircut', 'APT-01 · Grooming',
        'Active · Appointment', '₹600', '45 min', '₹999/mo', 'Active · Membership', '+ Add service']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });

    testWidgets('filters and search are sent to the server', (t) async {
      final s = FakeRpc({'svc_service_list': (_) => serviceList()});
      await show(t, ServiceCatalogueScreen(api: s.api));
      await t.tap(find.text('On-location').first);
      await t.pumpAndSettle();
      expect(s.of('svc_service_list').last.$2['type'], 'on_location');
      await t.tap(find.text('Paused 2'));
      await t.pumpAndSettle();
      expect(s.of('svc_service_list').last.$2['status'], 'paused');
      await t.enterText(find.byKey(const ValueKey('catalogue-search')), 'LOC');
      await t.pumpAndSettle();
      expect(s.of('svc_service_list').last.$2['q'], 'LOC');
    });

    testWidgets('pausing a service sends the whole service back with is_bookable false and a key', (t) async {
      final s = FakeRpc({'svc_service_list': (_) => serviceList(), 'svc_service_detail': (_) => serviceDetail(), 'svc_service_save': (_) => serviceDetail()});
      await show(t, ServiceCatalogueScreen(api: s.api));
      await t.tap(find.byKey(const ValueKey('more-s1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('toggle-status')));
      await t.pumpAndSettle();
      final save = s.of('svc_service_save').single;
      expect(save.$2['is_bookable'], false);
      expect(save.$2['name'], 'Precision haircut');
      expect(save.$3, startsWith('svc-'));
    });
  });

  group('Service Detail (Figma 84)', () {
    testWidgets('draws the service, delivery, add-ons and booking rules', (t) async {
      final s = FakeRpc({'svc_service_detail': (_) => serviceDetail()});
      await show(t, ServiceDetailScreen(api: s.api, id: 's1'));
      for (final text in ['Service Detail', 'APT-01 · Grooming · Updated 7 Oct', 'Precision haircut', 'Active', '₹600 + 18% GST', '45 minutes', 'Appointment · Customer visits us',
        'Indiranagar Studio', '1 customer per slot', '1 certified hair stylist', 'Neha Rao · Kavya Nair', 'Hair spa · +20 min', '₹200', 'Book at least 2 hours ahead',
        '15 min after each appointment', '₹200 at booking', 'Free until 12 hours before', '10-minute grace period', 'Appointment only', 'Edit service']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });

    testWidgets('no Edit button for a role that cannot edit', (t) async {
      final s = FakeRpc({'svc_service_detail': (_) => serviceDetail(canEdit: false)});
      await show(t, ServiceDetailScreen(api: s.api, id: 's1'));
      expect(find.text('Edit service'), findsNothing);
    });
  });

  group('Packages (Figma 85) and Memberships (Figma 86)', () {
    testWidgets('packages: lines, price, validity, usage, savings, exclusions', (t) async {
      final s = FakeRpc({'svc_plan_list': (_) => packages()});
      await show(t, PlansScreen(api: s.api, kind: 'package'));
      for (final text in ['Packages', 'Bundles with prepaid service usage', 'All packages', 'Grooming essentials', '2×', '₹1,000', 'Package price', '₹1,350', '90 days from purchase',
        '3 visits · 1 credit per service', '₹250 vs individual prices', 'Travel, materials and GST extra', '+ Create package']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(s.of('svc_plan_list').single.$2, {'kind': 'package'});
    });

    testWidgets('memberships: member tiles and plan rules', (t) async {
      final s = FakeRpc({'svc_plan_list': (_) => memberships()});
      await show(t, PlansScreen(api: s.api, kind: 'membership'));
      for (final text in ['Memberships', 'Active members', '64', '+8 this month', 'Monthly recurring', '₹63,936', 'Before GST', 'Care Plus · ₹999 / month', '1 haircut + 1 hair spa / month',
        'Priority appointment slots', '10% off additional grooming', '30-day billing cycle', 'No rollover · Member only', 'Monthly · Cancel before renewal', '+ Create membership']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });

    testWidgets('selling a package: name, phone, payment, one call with a key', (t) async {
      final s = FakeRpc({'svc_plan_list': (_) => packages(), 'svc_entitlement_sell': (_) => {'id': 'e1', 'name': 'Grooming essentials', 'credits': []}});
      await show(t, PlansScreen(api: s.api, kind: 'package'));
      await t.tap(find.text('Grooming essentials'));
      await t.pumpAndSettle();
      await t.tap(find.text('Sell to a customer'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('sell-name')), 'Riya Sharma');
      await t.enterText(find.byKey(const ValueKey('sell-phone')), '+91 98765 43210');
      await t.tap(find.text('Next: payment'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pay-upi')));
      await t.pumpAndSettle();
      final call = s.of('svc_entitlement_sell').single;
      expect(call.$2, {'plan_id': 'p1', 'customer_name': 'Riya Sharma', 'customer_phone': '9876543210', 'method': 'upi'});
      expect(call.$3, startsWith('svc-'));
    });
  });

  group('Staff & Service Providers (Figma 87)', () {
    testWidgets('counts, states and provider facts', (t) async {
      final s = FakeRpc({'svc_staff_list': (_) => staff()});
      await show(t, StaffScreen(api: s.api));
      for (final text in ['Staff & Service Providers', '8 team members · Skills and service eligibility', 'All 8', 'Available 5', 'On job 2', 'Off duty 1', 'Neha Rao · Senior stylist', 'Available',
        'Hair cutting · Styling', 'NVQ Hairdressing Level 3', 'Precision haircut · Hair spa', 'Indiranagar Studio only', 'Thu–Sat · 10 AM–7 PM', 'On job', 'Today · Next slot 4 PM', '+ Add provider']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      await t.tap(find.text('On job 2'));
      await t.pumpAndSettle();
      expect(s.of('svc_staff_list').last.$2['filter'], 'on_job');
    });

    testWidgets('adding a provider sends the chosen staff member and services', (t) async {
      final s = FakeRpc({'svc_staff_list': (_) => staff(), 'svc_provider_save': (_) => staff()});
      await show(t, StaffScreen(api: s.api));
      await t.tap(find.text('+ Add provider'));
      await t.pumpAndSettle();
      await t.tap(find.text('Meera Iyer'));
      await t.tap(find.text('AC maintenance').last);
      await t.pump();
      await t.tap(find.text('Save provider'));
      await t.pumpAndSettle();
      final call = s.of('svc_provider_save').single;
      expect(call.$2['staff_id'], 'st9');
      expect(call.$2['service_ids'], ['s2']);
      expect(call.$3, startsWith('svc-'));
    });
  });

  group('Availability & Scheduling (Figma 89)', () {
    testWidgets('week, providers, slot rules and exceptions', (t) async {
      final s = FakeRpc({'svc_schedule': (_) => schedule()});
      await show(t, AvailabilityScreen(api: s.api));
      for (final text in ['Availability & Scheduling', 'Indiranagar Studio · Appointment availability', 'Working hours', 'Mon–Sat', '10:00 AM – 7:00 PM', 'Lunch break', '1:00 PM – 2:00 PM',
        '2 available today', 'Neha Rao', 'Thu–Sat · 10 AM–7 PM', '15 minutes', '45 min · Precision haircut', '1 customer per provider', '0 minutes', 'Blocked time & holidays', '2 exceptions',
        'Friday, 9 October', 'Blocked', '3:00 – 4:00 PM', 'Neha Rao · Team training', 'Holiday', 'Dasara · Studio closed all day', 'Existing bookings are protected', 'Save schedule']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });

    testWidgets('a holiday added on the page is sent with Save schedule, once, with a key', (t) async {
      final s = FakeRpc({'svc_schedule': (_) => schedule(), 'svc_schedule_save': (_) => schedule()});
      await show(t, AvailabilityScreen(api: s.api));
      await t.tap(find.text('Save schedule'));
      await t.pumpAndSettle();
      expect(s.of('svc_schedule_save'), isEmpty, reason: 'nothing changed yet');
      await t.tap(find.text('Add exception'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('exception-day')), '2026-11-12');
      await t.enterText(find.byKey(const ValueKey('exception-reason')), 'Diwali');
      await t.tap(find.text('Add'));
      await t.pumpAndSettle();
      expect(find.text('3 exceptions'), findsOneWidget);
      await t.tap(find.text('Save schedule'));
      await t.pumpAndSettle();
      final call = s.of('svc_schedule_save').single;
      expect(call.$2['location_id'], 'l1');
      expect(call.$2['closures_add'], [
        {'day': '2026-11-12', 'reason': 'Diwali'}
      ]);
      expect(call.$3, startsWith('svc-'));
    });
  });

  group('Appointment Detail (Figma 92)', () {
    testWidgets('who, when, payment, notes, history and the next step', (t) async {
      final s = FakeRpc({'svc_appointment_view': (_) => appointment()});
      await show(t, AppointmentDetailScreen(api: s.api, id: 'ap1'));
      for (final text in ['Appointment Detail', 'APT-1042 · Customer visits business', 'Riya Sharma · +91 98765 43210', 'Appointment', 'Confirmed', 'Precision haircut + Hair spa', 'Neha Rao · Chair 2',
        '8 Oct 2026 · 10:00 – 11:05 AM', 'Indiranagar Studio', '65 min · 15 min buffer', '₹800', 'GST · 18%', '₹144', 'Booking total', '₹944', 'Customer notes', 'Booking history',
        'Booking created', 'Payment received', 'Customer check-in', 'Reschedule appointment', 'Check in customer', 'Cancel appointment']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(find.textContaining('₹744'), findsOneWidget);
    });

    testWidgets('check-in sends the action with the version', (t) async {
      final s = FakeRpc({'svc_appointment_view': (_) => appointment(), 'svc_appointment_act': (_) => appointment(status: 'checked_in', actions: ['start', 'cancel'])});
      await show(t, AppointmentDetailScreen(api: s.api, id: 'ap1'));
      await t.tap(find.text('Check in customer'));
      await t.pumpAndSettle();
      final call = s.of('svc_appointment_act').single;
      expect(call.$2, {'id': 'ap1', 'action': 'check_in', 'expected_version': 3});
      expect(call.$3, startsWith('svc-'));
      expect(find.text('Start service'), findsOneWidget);
    });

    testWidgets('a stale version reloads and says why', (t) async {
      final s = FakeRpc({'svc_appointment_view': (_) => appointment(), 'svc_appointment_act': (_) => refuse(409, 'This appointment was changed on another device.', 'version_conflict')});
      await show(t, AppointmentDetailScreen(api: s.api, id: 'ap1'));
      await t.tap(find.text('Check in customer'));
      await t.pumpAndSettle();
      expect(find.text('This appointment was changed on another device.'), findsOneWidget);
      expect(s.of('svc_appointment_view').length, 2);
    });
  });

  group('Service Check-In (Figma 103)', () {
    testWidgets('draws the job, the address and the code boxes; verifies with the code then starts', (t) async {
      final s = FakeRpc({
        'svc_appointment_act': (b) => b['action'] == 'check_in' ? (appointment(fulfilment: 'on_location', status: 'checked_in', actions: ['start'])..['version'] = 4) : appointment(fulfilment: 'on_location', status: 'in_service'),
        'svc_appointment_view': (_) => appointment(fulfilment: 'on_location', status: 'in_service'),
      });
      await show(t, ServiceCheckInScreen(api: s.api, appointment: AppointmentView(appointment(fulfilment: 'on_location')), now: DateTime(2026, 10, 8, 14, 56)));
      for (final text in ['Service Check-In', 'Arrival verification · 8 Oct 2026, 2:56 PM', 'JOB-1048 · AC maintenance', 'Arjun Kumar · Riya Sharma', 'On-location', 'Arrived · Verification needed',
        'Customer location', 'A-304, Lakeview Apartments, Domlur 560071', 'Gate 2 · Lift available', 'Customer OTP', 'Customer confirmation', 'Enter the customer’s arrival OTP',
        'Customer confirmation is supported', 'Request customer confirmation', 'Verify arrival & start job']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      await t.enterText(find.byKey(const ValueKey('arrival-code')), '4826');
      await t.pump();
      expect(find.text('4'), findsOneWidget);
      await t.tap(find.text('Verify arrival & start job'));
      await t.pumpAndSettle();
      final acts = s.of('svc_appointment_act');
      expect(acts[0].$2, {'id': 'ap1', 'action': 'check_in', 'expected_version': 3, 'verification': 'otp', 'code': '4826'});
      expect(acts[1].$2, {'id': 'ap1', 'action': 'start', 'expected_version': 4});
      expect(find.text('Service Execution'), findsOneWidget);
    });

    testWidgets('a short code sends nothing', (t) async {
      final s = FakeRpc({});
      await show(t, ServiceCheckInScreen(api: s.api, appointment: AppointmentView(appointment(fulfilment: 'on_location'))));
      await t.tap(find.text('Verify arrival & start job'));
      await t.pumpAndSettle();
      expect(s.calls, isEmpty);
    });
  });

  group('Service Execution (Figma 104)', () {
    final checks = [
      {'label': 'Inspect cooling and drain line', 'done': true},
      {'label': 'Clean indoor filters and coils', 'done': true},
      {'label': 'Final cooling test', 'done': false},
    ];
    testWidgets('checklist, materials, extra charges, notes', (t) async {
      final s = FakeRpc({'svc_appointment_view': (_) => appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], checklist: checks)});
      await show(t, ServiceExecutionScreen(api: s.api, id: 'ap1'));
      for (final text in ['Service Execution', 'AC maintenance', 'On-location', 'In progress', 'Job checklist · 2 of 3 done', 'Inspect cooling and drain line', 'Final cooling test',
        'Before / after photos', 'Materials used', 'Drain connector', 'Coil cleaning solution', 'Extra charges', '₹150 · Selected at booking', 'Labour extras', '₹0 · None added', 'Provider notes',
        'Drain fixed; cooling improved to 17°C.', 'Complete: Final cooling test', 'Review job & complete']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(find.textContaining('₹250 · Approved by Riya'), findsOneWidget);
    });

    testWidgets('ticking an item sends it with the version and a key; billing waits for the checklist', (t) async {
      final s = FakeRpc({
        'svc_appointment_view': (_) => appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], checklist: checks),
        'svc_job_update': (_) => appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], checklist: [for (final c in checks) {...c, 'done': true}]),
      });
      await show(t, ServiceExecutionScreen(api: s.api, id: 'ap1'));
      await t.tap(find.text('Review job & complete'));
      await t.pumpAndSettle();
      expect(find.text('Service Billing'), findsNothing);
      await t.tap(find.byKey(const ValueKey('check-Final cooling test')));
      await t.pumpAndSettle();
      final call = s.of('svc_job_update').single;
      expect(call.$2, {'id': 'ap1', 'expected_version': 3, 'done': ['Final cooling test']});
      expect(call.$3, startsWith('svc-'));
      expect(find.text('Job checklist · 3 of 3 done'), findsOneWidget);
    });
  });

  group('Service Billing (Figma 105)', () {
    testWidgets('charges, final bill, paid, balance, tax split and GSTIN', (t) async {
      final s = FakeRpc({'svc_appointment_view': (_) => appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], due: 516, paid: 900)});
      await show(t, ServiceBillingScreen(api: s.api, id: 'ap1'));
      for (final text in ['Service Billing', 'JOB-1048 · AC maintenance', 'Riya Sharma · Provider: Arjun Kumar', 'Ready for billing', 'Service charges', 'Outdoor unit wash', 'Drain connector',
        'FINAL BILL', 'Charges subtotal', 'GST (18% on ₹800)', 'Final total', '₹944', '₹900', 'FINAL', '₹516', 'Approval & tax details', 'CGST ₹72 + SGST ₹72', '29ABCDE1234F1Z5',
        'Continue to payment · ₹516']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });

    testWidgets('payment: cash with the amount received, one key, the version', (t) async {
      final s = FakeRpc({
        'svc_appointment_view': (_) => appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], due: 516, paid: 900),
        'svc_bill': (_) => appointment(fulfilment: 'on_location', status: 'completed', actions: [], due: 0, paid: 1416),
      });
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => ServiceBillingScreen(api: s.api, id: 'ap1'))), child: const Text('open')))));
      ignoreOverflow();
      t.view.physicalSize = const Size(780, 5200);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Continue to payment · ₹516'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('pay-cash')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('cash-received')), '600');
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      final call = s.of('svc_bill').single;
      expect(call.$2, {'id': 'ap1', 'method': 'cash', 'tendered': 600, 'expected_version': 3});
      expect(call.$3, startsWith('svc-'));
      expect(find.text('open'), findsOneWidget, reason: 'billing closes after the visit is completed');
    });
  });

  group('Service History (Figma 108)', () {
    testWidgets('records with status and money, refunds, filters, export', (t) async {
      final s = FakeRpc({'svc_history': (_) => history()});
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await show(t, ServiceHistoryScreen(api: s.api));
      for (final text in ['Service History', 'All service activity · October 2026', 'All', 'Appointment', 'Event', 'On-location', 'This month', 'All statuses', 'All providers', 'Recent activity',
        '24 records', 'JOB-1048 · AC maintenance', 'Completed · Paid', 'Arjun Kumar', '8 Oct · 3:00 – 4:00 PM', '₹1,416 · On-location', 'TKT-2074 · Clay & Chai', 'Cancelled · Refunded',
        'Host', '₹1,062 · 7 Oct', 'Original session', 'Export service history']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(s.of('svc_history').first.$2, {'filter': 'all', 'period': 'this_month'});
      await t.tap(find.text('On-location'));
      await t.pumpAndSettle();
      expect(s.of('svc_history').last.$2['fulfilment'], 'on_location');
      await t.tap(find.text('Export service history'));
      await t.pumpAndSettle();
      expect(copied, contains('JOB-1048'));
      expect(copied!.split('\n').length, 3);
    });
  });
}
