import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/service/plans_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'service_screens_test.dart' show FakeRpc, show;

// PlanEditScreen in steps like every Service POS form (founder, 4 Nov 2026).
const _services = [
  SvcData({'id': 's1', 'name': 'Full grooming with nail trim and ear cleaning', 'price': 1200}),
  SvcData({'id': 's2', 'name': 'Bath', 'price': 450}),
];

String _text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  testWidgets('step bar: Step 1 of 3, Next blocked without name and price, forward and back', (t) async {
    final s = FakeRpc({'svc_plan_save': (b) => {'id': 'p1', ...b}});
    await show(t, PlanEditScreen(api: s.api, kind: 'package', services: _services));
    expect(_text(t, 'plan-step-count'), 'Step 1 of 3');
    expect(find.byKey(const ValueKey('plan-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-save')), findsNothing, reason: 'Save only on the last step');

    await t.tap(find.byKey(const ValueKey('plan-next')));
    await t.pumpAndSettle();
    expect(_text(t, 'plan-step-count'), 'Step 1 of 3', reason: 'name and price are required');
    expect(find.text('Enter the name and the price.'), findsOneWidget);
    await t.pump(const Duration(seconds: 4)); // the toast floats over Next until it goes
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const ValueKey('plan-Name')), 'Grooming essentials');
    await t.enterText(find.byKey(const ValueKey('plan-Price (₹, before GST)')), '2500');
    await t.tap(find.byKey(const ValueKey('plan-next')));
    await t.pumpAndSettle();
    expect(_text(t, 'plan-step-count'), 'Step 2 of 3');
    await t.tap(find.byKey(const ValueKey('plan-back')));
    await t.pumpAndSettle();
    expect(_text(t, 'plan-step-count'), 'Step 1 of 3');
    expect(find.byKey(const ValueKey('plan-Name')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('plan-seg-1')));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('One more Bath'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('plan-seg-2')));
    await t.pumpAndSettle();
    expect(_text(t, 'plan-step-count'), 'Step 3 of 3');
    await t.enterText(find.byKey(const ValueKey('plan-Usage limit')), '3 visits');
    await t.tap(find.byKey(const ValueKey('plan-save')));
    await t.pumpAndSettle();
    final body = s.of('svc_plan_save').single.$2;
    expect(body['name'], 'Grooming essentials');
    expect(body['price'], 2500);
    expect(body['usage_note'], '3 visits');
    expect(body['items'], [{'service_id': 's2', 'qty': 1}]);
  });

  testWidgets('membership at 375x812: Next through every step without overflow', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = FakeRpc({});
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: PlanEditScreen(api: s.api, kind: 'membership', services: _services)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(_text(t, 'plan-step-count'), 'Step 1 of 4');
    await t.enterText(find.byKey(const ValueKey('plan-Name')), 'Care club');
    await t.enterText(find.byKey(const ValueKey('plan-Price (₹, before GST)')), '999');
    for (var i = 2; i <= 4; i++) {
      await t.tap(find.byKey(const ValueKey('plan-next')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(_text(t, 'plan-step-count'), 'Step $i of 4');
    }
    expect(find.byKey(const ValueKey('plan-Renewal')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-save')), findsOneWidget);
  });
}
