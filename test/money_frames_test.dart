// Exports the built section K (Money) screens as phone frame PNGs (405 pt wide, 2x, real Inter and Lucide fonts) for side-by-side review
// with assets/figma_ref_k. Uses the answers captured from the real database (test/fixtures/money_server.json). Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/money_frames_test.dart   -> test/frames_k/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/money/money_api.dart';
import 'package:vinii_pos/money/money_env.dart';
import 'package:vinii_pos/money/money_home.dart';
import 'package:vinii_pos/money/money_screens_c.dart';
import 'package:vinii_pos/ui/theme.dart';

final Map<String, dynamic> _fx = jsonDecode(File('test/fixtures/money_server.json').readAsStringSync()) as Map<String, dynamic>;

const _answers = {
  'money_options': 'options_owner', 'money_overview': 'overview', 'money_payments_list': 'payments', 'money_transactions_list': 'transactions', 'money_invoices_list': 'invoices',
  'money_cashbook': 'cashbook', 'money_expenses_list': 'expenses', 'money_refunds_list': 'refunds', 'money_settlements_list': 'settlements',
  'money_settlement_detail': 'settlement_detail', 'money_payouts_list': 'payouts', 'money_reports': 'reports', 'money_report_rows': 'report_rows',
};

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

MoneyEnv _env() {
  final env = MoneyEnv(
    api: MoneyApi(
      baseUrl: 'http://frames.local',
      accessToken: () => 'frames',
      client: MockClient((r) async {
        final k = _answers[r.url.path.split('/').last];
        return http.Response(jsonEncode(k == null ? {'detail': 'not found'} : _fx[k]), k == null ? 404 : 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    ),
    onNavigate: (_) {},
  );
  env.screenFor = moneyScreenFor;
  env.allowed = [for (final s in (_fx['options_owner'] as Map)['screens'] as List) s.toString()];
  return env;
}

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1600}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(RepaintBoundary(key: const ValueKey('frame'), child: MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen)));
    await t.pumpAndSettle();
    await expectLater(find.byKey(const ValueKey('frame')), matchesGoldenFile('frames_k/$file.png'));
  }

  testWidgets('frames', (t) async {
    for (final k in ['overview', 'payments', 'transactions', 'invoices', 'cashbook', 'expenses', 'settlements', 'payouts', 'refunds', 'reports']) {
      final env = _env();
      await frame(t, k, moneyScreenFor(env, k));
    }
    final env = _env();
    final id = (((_fx['settlements'] as Map)['rows'] as List).first as Map)['id'].toString();
    await frame(t, 'settlement_detail', SettlementDetailScreen(env: env, id: id));
  }, skip: !on);
}
