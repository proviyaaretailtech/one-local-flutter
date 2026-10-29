import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/orders/online_locked.dart';
import 'package:vinii_pos/settings/settings_api.dart';

import 'helpers.dart';

class _Support extends SettingsApi {
  final sent = <String>[];
  @override
  Future<Map<String, dynamic>> supportCreate({required String message, String kind = 'support', String? topic, String? attachmentPath, required String idempotencyKey}) async {
    sent.add('$topic: $message');
    return {'reference': 'SR-1042'};
  }
}

void main() {
  tearDown(StorePlan.reset);

  testWidgets('POS only: Online orders shows "Start selling on OneLocal" instead of the orders', (t) async {
    StorePlan.set('pos_only');
    await show(t, const OnlineOrdersGate(child: Text('the orders')));
    await t.pumpAndSettle();
    expect(find.text('Start selling on OneLocal'), findsOneWidget);
    expect(find.text('the orders'), findsNothing);
  });

  testWidgets('with OneLocal selling (or no plan on record) the orders show as before', (t) async {
    for (final plan in ['pos_and_onelocal', null]) {
      StorePlan.set(plan);
      await show(t, OnlineOrdersGate(key: ValueKey(plan), child: const Text('the orders')));
      await t.pumpAndSettle();
      expect(find.text('the orders'), findsOneWidget);
    }
  });

  testWidgets('the ₹799 plan: pick 12 months, Continue sends the request with the price', (t) async {
    final api = _Support();
    await show(t, OnlineLockedScreen(api: api));
    expect(find.text('Continue with 6 months · ₹4,794'), findsOneWidget);
    await t.ensureVisible(find.byKey(const ValueKey('cycle-12')));
    await t.tap(find.byKey(const ValueKey('cycle-12')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('continue-pos_and_onelocal')));
    await t.pumpAndSettle();
    expect(api.sent.single, startsWith('account: Subscription request: Sell on OneLocal and Purchase POS, 12 months, ₹7,990 (2 months free). Moving from Purchase POS.'));
    expect(find.byKey(const ValueKey('plan-request-sent')), findsOneWidget);
    expect(find.textContaining('SR-1042'), findsOneWidget);
  });
}
