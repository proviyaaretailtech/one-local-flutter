import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/manage_screen.dart';
import 'package:vinii_pos/service/service_api.dart';

import 'helpers.dart';

// The Manage tab, Service management (founder's sketch, 2 Nov 2026): a weekday's slot table worked out from the hours, the slot length,
// opening hours, the people at work, and the word for them from the kind of service.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _table(int weekday, {int slotMinutes = 60, bool canEdit = true}) {
  final open = weekday != 7;
  return {
    'location': {'id': 'loc1', 'name': 'Demo Services - Main'},
    'business': 'Demo Services',
    'weekday': weekday,
    'worker_word': {'one': 'Technician', 'many': 'Technicians'},
    'slot_minutes': slotMinutes,
    'slot_choices': [15, 30, 60, 90, 120, 180, 240],
    'closed': !open,
    'hours': open ? {'open': '10:00', 'close': '14:00', 'label': '10:00 AM – 2:00 PM', 'break_start': '12:00', 'break_end': '13:00', 'break_label': '12:00 PM – 1:00 PM'} : null,
    'days': [
      for (var d = 1; d <= 7; d++)
        {
          'weekday': d, 'label': const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d - 1], 'selected': d == weekday, 'open': d != 7,
          'open_time': d == 7 ? null : '10:00', 'close_time': d == 7 ? null : '14:00', 'break_start': d == 7 ? null : '12:00', 'break_end': d == 7 ? null : '13:00',
        }
    ],
    'slots': open
        ? [
            {'no': 1, 'start': '10:00', 'end': '11:00', 'time_label': '10:00 AM – 11:00 AM', 'length_min': 60, 'workers': 2, 'names': ['Arjun Kumar', 'Meera Iyer']},
            {'no': 2, 'start': '11:00', 'end': '12:00', 'time_label': '11:00 AM – 12:00 PM', 'length_min': 60, 'workers': 1, 'names': ['Arjun Kumar']},
            {'no': 3, 'start': '13:00', 'end': '14:00', 'time_label': '1:00 PM – 2:00 PM', 'length_min': 60, 'workers': 0, 'names': []},
          ]
        : [],
    'staff': [
      {'staff_id': 's1', 'name': 'Arjun Kumar', 'title': 'Technician', 'hours': '10:00 AM – 2:00 PM'},
      {'staff_id': 's2', 'name': 'Meera Iyer', 'title': 'Consultant', 'hours': null},
    ],
    'can_edit': canEdit,
  };
}

class _Fake {
  _Fake({this.canEdit = true});
  final bool canEdit;
  final calls = <(String, Map<String, dynamic>, String?)>[];
  int slotMinutes = 60;
  late final api = ServiceApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body, r.headers['Idempotency-Key']));
      if (fn == 'svc_schedule_save') {
        if (body['slot_minutes'] != null) slotMinutes = body['slot_minutes'] as int;
        return http.Response(jsonEncode({'location': {'id': 'loc1'}}), 200, headers: _json);
      }
      return http.Response(jsonEncode(_table((body['weekday'] as int?) ?? 1, slotMinutes: slotMinutes, canEdit: canEdit)), 200, headers: _json);
    }),
  );
  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

Future<_Fake> _show(WidgetTester t, {bool canEdit = true}) async {
  final f = _Fake(canEdit: canEdit);
  await show(t, ManageScreen(api: f.api));
  await t.pumpAndSettle(); // the sections build in and the figures count up (the store's motion)
  return f;
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  testWidgets('compact (2 Nov 2026): a week of round letters, hours and slot length in one card, the slots as tiles with who works them', (t) async {
    final f = await _show(t);
    expect(f.of('svc_slot_table').single, isEmpty, reason: 'today, chosen by the server');
    for (final s in ['Service management', 'Monday', 'Edit hours', '10:00 AM – 2:00 PM', 'Break 12:00 PM – 1:00 PM', 'Slot length', 'Slots on Monday', '3 slots',
      '10:00 AM', 'to 11:00 AM · 1 hr', '2 Technicians', '1 Technician', '0 Technicians', '1 with nobody (in red). Tap a slot to see who works it.',
      'Technicians on Monday', 'Arjun Kumar', 'Off', 'M', 'S', 'Closed']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('slot-row-1'));
    expect(find.text('Slot 1 · 10:00 AM – 11:00 AM'), findsOneWidget);
    expect(find.text('Meera Iyer'), findsWidgets);
  });

  testWidgets('a weekday shows its own slots; a closed day says so', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('weekday-7'));
    expect(f.of('svc_slot_table').last, {'weekday': 7});
    expect(find.text('Closed on this day.'), findsOneWidget);
    expect(find.text('Closed on this day, so there are no slots.'), findsOneWidget);
  });

  testWidgets('slot length: one tap saves it with a key, then the table reloads', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('slot-120'));
    final save = f.calls.singleWhere((c) => c.$1 == 'svc_schedule_save');
    expect(save.$2, {'location_id': 'loc1', 'slot_minutes': 120});
    expect(save.$3, startsWith('svc-'));
    expect(f.of('svc_slot_table').length, 2);
    expect(find.text('Slots are now 2 hr.'), findsOneWidget);
  });

  testWidgets('closing a day sends the whole week without it', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('edit-hours'));
    expect(find.text('Hours on Monday'), findsOneWidget);
    await _tap(t, const ValueKey('day-open'));
    await t.tap(find.text('Save hours'));
    await t.pumpAndSettle();
    final hours = (f.of('svc_schedule_save').single['hours'] as List).cast<Map>();
    expect(hours.map((h) => h['weekday']), [2, 3, 4, 5, 6], reason: 'Monday closed, Sunday was already closed');
    expect(hours.first, {'weekday': 2, 'open': '10:00', 'close': '14:00', 'break_start': '12:00', 'break_end': '13:00'});
  });

  testWidgets('removing the break keeps the day open, without a break', (t) async {
    final f = await _show(t);
    await _tap(t, const ValueKey('edit-hours'));
    await _tap(t, const ValueKey('day-break'));
    await t.tap(find.text('Save hours'));
    await t.pumpAndSettle();
    final hours = (f.of('svc_schedule_save').single['hours'] as List).cast<Map>();
    expect(hours.first, {'weekday': 1, 'open': '10:00', 'close': '14:00'});
    expect(hours.length, 6);
  });

  testWidgets('without the manager role: no Edit and the slot length does not change', (t) async {
    final f = await _show(t, canEdit: false);
    expect(find.byKey(const ValueKey('edit-hours')), findsNothing);
    expect(find.byKey(const ValueKey('edit-staff-hours')), findsNothing);
    await _tap(t, const ValueKey('slot-120'));
    expect(f.of('svc_schedule_save'), isEmpty);
  });
}
