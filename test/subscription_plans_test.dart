import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/plans/subscription_plans.dart';
import 'package:vinii_pos/settings/settings_api.dart';

import 'helpers.dart';

class _Support extends SettingsApi {
  final sent = <String>[];
  @override
  Future<Map<String, dynamic>> supportCreate({required String message, String kind = 'support', String? topic, String? attachmentPath, required String idempotencyKey}) async {
    sent.add(message);
    return {'reference': 'SUP-7'};
  }
}

void main() {
  test('prices: ₹599 and ₹799 a month; 6 months full price, 12 months with 2 free; no monthly', () {
    final pos = planByCode('pos_only')!, both = planByCode('pos_and_onelocal')!;
    expect(pos.price(BillingCycle.sixMonths), 3594);
    expect(pos.price(BillingCycle.twelveMonths), 5990);
    expect(pos.saving(BillingCycle.twelveMonths), 1198);
    expect(both.price(BillingCycle.sixMonths), 4794);
    expect(both.price(BillingCycle.twelveMonths), 7990);
    expect(both.effectivePerMonth(BillingCycle.twelveMonths), 666);
    expect(BillingCycle.values.map((c) => c.months), [6, 12]);
    expect(rupees(179700), '₹1,79,700');
  });

  testWidgets('two tabs; the store\'s plan opens first and is marked; the other tab shows its plan', (t) async {
    final api = _Support();
    await show(t, SubscriptionPlansScreen(current: 'pos_only', api: api));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-pos_only')), findsOneWidget);
    expect(find.text('Current plan'), findsOneWidget);
    expect(find.text('Not included in this plan'), findsOneWidget);
    expect(find.text('Continue with 6 months · ₹3,594'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tab-pos_and_onelocal')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-pos_and_onelocal')), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
    expect(find.text('Everything in Purchase POS, plus'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('cycle-12')));
    await t.pumpAndSettle();
    expect(find.text('Continue with 12 months · ₹7,990'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('continue-pos_and_onelocal')));
    await t.pumpAndSettle();
    expect(api.sent.single, contains('Sell on OneLocal and Purchase POS, 12 months, ₹7,990'));
    expect(find.byKey(const ValueKey('plan-request-sent')), findsOneWidget);
  });
}
