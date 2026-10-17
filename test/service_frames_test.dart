// Exports every built section I screen as a phone frame PNG (405 pt wide, 2x, real Inter and Lucide fonts), named like the founder's
// Figma exports in assets/figma_ref_i, for side-by-side review. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/service_frames_test.dart   -> test/frames_i/*.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/service/availability_screen.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/history_screen.dart';
import 'package:vinii_pos/service/plans_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/service/staff_screen.dart';
import 'package:vinii_pos/service/visit_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'service_screens_test.dart' as fx;

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  final checks = [
    {'label': 'Inspect cooling and drain line', 'done': true},
    {'label': 'Clean indoor filters and coils', 'done': true},
    {'label': 'Flush drain and replace connector', 'done': true},
    {'label': 'Wash outdoor unit · Add-on', 'done': true},
    {'label': 'Final cooling test · Record outlet temperature', 'done': false},
  ];
  final api = fx.FakeRpc({
    'svc_service_list': (_) => fx.serviceList(),
    'svc_service_detail': (_) => fx.serviceDetail(),
    'svc_plan_list': (b) => b['kind'] == 'membership' ? fx.memberships() : fx.packages(),
    'svc_staff_list': (_) => fx.staff(),
    'svc_schedule': (_) => fx.schedule(),
    'svc_history': (_) => fx.history(),
    'svc_appointment_view': (b) => switch (b['id']) {
          'exec' => fx.appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], checklist: checks),
          'bill' => fx.appointment(fulfilment: 'on_location', status: 'in_service', actions: ['update', 'bill'], due: 516, paid: 900),
          _ => fx.appointment(),
        },
  }).api;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1800}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_i/$file.png'));
  }

  const b = 'Sharma Services · Bengaluru';
  testWidgets('83', (t) => frame(t, '83 — Service Catalogue', ServiceCatalogueScreen(api: api, business: b), height: 1700), skip: !on);
  testWidgets('84', (t) => frame(t, '84 — Service Detail', ServiceDetailScreen(api: api, id: 's1', business: b), height: 1700), skip: !on);
  testWidgets('85', (t) => frame(t, '85 — Packages', PlansScreen(api: api, kind: 'package', business: b), height: 1600), skip: !on);
  testWidgets('86', (t) => frame(t, '86 — Memberships', PlansScreen(api: api, kind: 'membership', business: b), height: 1650), skip: !on);
  testWidgets('87', (t) => frame(t, '87 — Staff & Service Providers', StaffScreen(api: api, business: b), height: 1500), skip: !on);
  testWidgets('89', (t) => frame(t, '89 — Availability & Scheduling', AvailabilityScreen(api: api, business: b), height: 2000), skip: !on);
  testWidgets('92', (t) => frame(t, '92 — Appointment Detail', AppointmentDetailScreen(api: api, id: 'ap1', business: b), height: 2100), skip: !on);
  testWidgets('103', (t) => frame(t, '103 — Service Check-In', ServiceCheckInScreen(api: api, appointment: AppointmentView(fx.appointment(fulfilment: 'on_location')), business: b, now: DateTime(2026, 10, 8, 14, 56)), height: 1400), skip: !on);
  testWidgets('104', (t) => frame(t, '104 — Service Execution', ServiceExecutionScreen(api: api, id: 'exec', business: b), height: 2100), skip: !on);
  testWidgets('105', (t) => frame(t, '105 — Service Billing', ServiceBillingScreen(api: api, id: 'bill', business: b), height: 1600), skip: !on);
  testWidgets('108', (t) => frame(t, '108 — Service History', ServiceHistoryScreen(api: api, business: b), height: 1500), skip: !on);
}
