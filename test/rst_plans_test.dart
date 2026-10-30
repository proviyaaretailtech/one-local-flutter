// Subscription plans in the restaurant POS: the store's prices (₹599 / ₹799 a month; 6 months, or 12 with 2 free), the current plan marked,
// and Continue sending a request to the OneLocal team (no payment in the app).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/restaurant/rst_plans_screen.dart';
import 'package:vinii_pos/settings/settings_api.dart';
import 'package:vinii_pos/ui/theme.dart';

void main() {
  late List<(String, Map<String, dynamic>)> calls;
  RpcClient rpc() {
    calls = [];
    return RpcClient(
      client: MockClient((r) async {
        final fn = r.url.pathSegments.last;
        calls.add((fn, (jsonDecode(r.body) as Map).cast<String, dynamic>()));
        final body = switch (fn) {
          'org_sell_plan' => {'plan': 'pos_and_onelocal'},
          'pos_support_create' => {'id': 's1', 'reference': 'SUP-0042', 'status': 'open'},
          _ => <String, dynamic>{},
        };
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      }),
      baseUrl: 'http://pos.test',
      accessToken: () => 't',
    );
  }

  Future<void> show(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(800, 1720);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
    await t.pumpAndSettle();
  }

  String text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('the business\'s plan opens first and says Current plan; POS + OneLocal is ₹799, ₹7,990 for 12 months with 2 free, ₹4,794 for 6', (t) async {
    final r = rpc();
    await show(t, RstPlansScreen(rpc: r, settings: SettingsApi(rpc: r)));
    expect(calls.first.$1, 'org_sell_plan');
    expect(find.byKey(const ValueKey('plan-current')), findsOneWidget);
    expect(text(t, 'plan-per-month'), '₹799');
    expect(text(t, 'plan-total-12'), '₹7,990 total');
    expect(text(t, 'plan-total-6'), '₹4,794 total');
    expect(find.text('₹666/month (approx.)'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Everything in Purchase POS, plus'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Everything in Purchase POS, plus'), findsOneWidget);
    expect(find.text('Continue with 12 months · ₹7,990'), findsOneWidget);
  });

  testWidgets('Purchase POS: ₹599, ₹3,594 for 6 months, ₹5,990 for 12 (≈₹499), save ₹1,198; the online features are not included', (t) async {
    final r = rpc();
    await show(t, RstPlansScreen(rpc: r, settings: SettingsApi(rpc: r), current: 'pos_and_onelocal'));
    await t.tap(find.byKey(const ValueKey('plan-tab-pos_only')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-current')), findsNothing);
    expect(text(t, 'plan-per-month'), '₹599');
    expect(text(t, 'plan-total-6'), '₹3,594 total');
    expect(text(t, 'plan-total-12'), '₹5,990 total');
    expect(find.text('₹499/month (approx.)'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('plan-cycle-6')));
    await t.pumpAndSettle();
    expect(find.textContaining('Save ₹1,198 with 12 months', findRichText: true), findsOneWidget);
    await t.scrollUntilVisible(find.text('Not included in this plan'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Not included in this plan'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Delivery & pickup'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Online orders'), findsOneWidget);
    expect(find.text('Continue with 6 months · ₹3,594'), findsOneWidget);
  });

  testWidgets('Continue sends one request to the OneLocal team with the plan, months and price, then says it was sent', (t) async {
    final r = rpc();
    await show(t, RstPlansScreen(rpc: r, settings: SettingsApi(rpc: r), current: 'pos_and_onelocal'));
    await t.tap(find.byKey(const ValueKey('plan-tab-pos_only')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('plan-continue')));
    await t.pumpAndSettle();
    final sent = calls.where((c) => c.$1 == 'pos_support_create').single.$2;
    expect(sent['topic'], 'account');
    expect(sent['message'], contains('Purchase POS, 12 months, ₹5,990 (2 months free)'));
    expect(sent['message'], contains('Moving from POS + OneLocal'));
    expect(find.byKey(const ValueKey('plan-sent')), findsOneWidget);
    expect(find.textContaining('SUP-0042'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-continue')), findsNothing, reason: 'not sent twice');
  });
}
