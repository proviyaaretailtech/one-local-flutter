import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/settings/returns_api.dart';
import 'package:vinii_pos/settings/returns_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

// Settings → Returns & refunds (founder's spec, 29 Oct 2026, Phase 1 "Policy foundation"): a OneLocal policy per category, chosen
// once, read and agreed to, versioned; "always covered" claims; the handover photo and the bulk-order checklist.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

Map<String, dynamic> _tpl(String id, String name, {bool change = true, int min = 24, int max = 168, int def = 72, List<String> remedies = const ['refund', 'replacement', 'exchange'], List<String> defRem = const ['refund', 'replacement'], bool defChange = true, bool sealed = true}) => {
      'id': id, 'name': name, 'blurb': '$name blurb', 'change_of_mind_allowed': change, 'min_hours': min, 'max_hours': max, 'default_hours': def,
      'remedies': remedies, 'default_remedies': defRem, 'default_change_of_mind': defChange && change, 'default_sealed_only': sealed, 'default_inspection': false,
    };

final _templates = [
  _tpl('fresh', 'Fresh food & perishables', change: false, min: 2, max: 48, def: 24, remedies: ['refund', 'replacement'], sealed: false),
  _tpl('packaged', 'Packaged grocery & daily needs'),
  _tpl('electronics', 'Electronics & appliances', max: 240, def: 168, remedies: ['refund', 'replacement', 'exchange', 'repair'], sealed: false),
];

Map<String, dynamic> _policy(String cat, {int version = 1}) => {
      'id': 'p-$cat', 'category_id': cat, 'category_name': 'Snacks', 'template_id': 'packaged', 'version': version, 'change_of_mind': true,
      'window_hours': 72, 'remedies': ['refund', 'replacement'], 'sealed_only': true, 'inspection': false,
      'label': 'Returns within 3 days · sealed items only', 'status': 'active', 'effective_from': '2026-10-29T10:00:00Z',
      'consent': {'name': 'Raj', 'at': '2026-10-29T10:00:00Z'},
    };

Map<String, dynamic> _home({bool canEdit = true}) => {
      'can_edit': canEdit,
      'templates': _templates,
      'default': null,
      'categories': [
        {'id': 'c-dairy', 'name': 'Dairy', 'items': 2, 'suggested': 'fresh', 'policy': null, 'versions': 0},
        {'id': 'c-snacks', 'name': 'Snacks', 'items': 3, 'suggested': 'packaged', 'policy': _policy('c-snacks', version: 2), 'versions': 2},
        {'id': 'c-oils', 'name': 'Oils', 'items': 1, 'suggested': 'packaged', 'policy': null, 'versions': 0},
      ],
      'uncategorised_items': 0,
      'dispatch_photo': true,
      'bulk_items': 10,
    };

class Fake {
  Fake({this.canEdit = true});
  final bool canEdit;
  final requests = <http.Request>[];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<Map<String, dynamic>> bodies(String fn) => requests.where((r) => fnOf(r) == fn).map((r) => jsonDecode(r.body) as Map<String, dynamic>);
  late final api = ReturnsApi(
    rpc: RpcClient(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
      requests.add(r);
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      return switch (fnOf(r)) {
        'rr_home' => ok(_home(canEdit: canEdit)),
        'rr_policy_save' when b['preview'] == true => ok({'terms': 'Policy for Dairy: Fresh food & perishables.\nChange-of-mind returns are not accepted.', 'label': 'from server', 'categories': 1}),
        'rr_policy_save' => ok({'policies': [], 'label': 'x'}),
        'rr_history' => ok({'versions': [_policy('c-snacks', version: 2), {..._policy('c-snacks'), 'status': 'replaced', 'label': 'Returns within 7 days'}]}),
        'rr_settings_save' => ok({..._home(), 'dispatch_photo': b['dispatch_photo'] ?? true, 'bulk_items': b['bulk_items'] ?? 10}),
        _ => ok({}),
      };
    })),
  );
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(780, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

String text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('Returns & refunds page', () {
    testWidgets('shows always-covered claims, each category with its policy or the suggestion, and the handover rules', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      expect(find.byKey(const ValueKey('rr-always')), findsOneWidget);
      for (final x in kAlwaysCovered) {
        expect(find.text(x), findsOneWidget, reason: x);
      }
      expect(find.byKey(const ValueKey('rr-unset-c-dairy')), findsOneWidget);
      expect(find.textContaining('Suggested: Fresh food & perishables'), findsOneWidget);
      expect(find.text('v2'), findsOneWidget);
      expect(text(t, 'rr-label-c-snacks'), 'Returns within 3 days · sealed items only');
      expect(find.byKey(const ValueKey('rr-cat-default')), findsOneWidget);
      expect(find.text('Photo before handover'), findsOneWidget);
      expect(find.textContaining('10 or more items'), findsOneWidget);
    });

    testWidgets('a category opens on its suggestion; fresh food has no change-of-mind returns and a window in hours', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await tapKey(t, 'rr-cat-c-dairy');
      expect(find.text('Dairy'), findsWidgets);
      expect(find.byKey(const ValueKey('rr-change')), findsNothing);
      expect(find.text('No change-of-mind returns'), findsOneWidget);
      expect(text(t, 'rr-window-value'), '1 day');
      expect(text(t, 'rr-label'), 'No change-of-mind returns · report issues within 1 day');
      await tapKey(t, 'rr-window-minus');
      expect(text(t, 'rr-window-value'), '12 hours');
      expect(text(t, 'rr-label'), 'No change-of-mind returns · report issues within 12 hours');
      await tapKey(t, 'rr-window-plus');
      await tapKey(t, 'rr-window-plus');
      expect(text(t, 'rr-window-value'), '2 days');
      expect(t.widget<InkWell>(find.byKey(const ValueKey('rr-window-plus'))).onTap, isNull); // 48 hours is the most for fresh food
    });

    testWidgets('review shows the server terms; it saves only after "I agree"', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await tapKey(t, 'rr-cat-c-dairy');
      await tapKey(t, 'rr-review');
      final pre = f.body('rr_policy_save');
      expect(pre['preview'], true);
      expect(pre['category_ids'], ['c-dairy']);
      expect(pre['template_id'], 'fresh');
      expect(pre['change_of_mind'], false);
      expect(find.text('Change-of-mind returns are not accepted.'), findsOneWidget);
      expect(t.widget<InkWell>(find.descendant(of: find.byKey(const ValueKey('rr-confirm')), matching: find.byType(InkWell))).onTap, isNull);
      await tapKey(t, 'rr-confirm'); // nothing happens before the tick
      expect(f.bodies('rr_policy_save').where((b) => b['agree'] == true), isEmpty);
      await tapKey(t, 'rr-agree');
      await tapKey(t, 'rr-confirm');
      final saved = f.body('rr_policy_save');
      expect(saved['agree'], true);
      expect(saved.containsKey('preview'), isFalse);
      expect(saved['window_hours'], 24);
      expect(saved['remedies'], ['refund', 'replacement']);
      expect(find.byType(PolicyEditScreen), findsNothing); // back on the page
      expect(f.requests.where((r) => fnOf(r) == 'rr_home').length, 2); // reloaded
    });

    testWidgets('switching the policy resets the choices; remedies and change-of-mind go in the save', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await tapKey(t, 'rr-cat-c-oils');
      await tapKey(t, 'rr-tpl-electronics');
      expect(text(t, 'rr-window-value'), '7 days');
      expect(find.byKey(const ValueKey('rr-remedy-repair')), findsOneWidget);
      await tapKey(t, 'rr-remedy-repair');
      await tapKey(t, 'rr-sealed');
      expect(text(t, 'rr-label'), 'Returns within 7 days · sealed items only');
      await tapKey(t, 'rr-change');
      expect(find.byKey(const ValueKey('rr-sealed')), findsNothing);
      await tapKey(t, 'rr-review');
      final pre = f.body('rr_policy_save');
      expect(pre['template_id'], 'electronics');
      expect(pre['change_of_mind'], false);
      expect(pre['sealed_only'], false);
      expect(pre['remedies'], ['refund', 'replacement', 'repair']);
    });

    testWidgets('a set category opens on its saved policy and shows who agreed to each version', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await tapKey(t, 'rr-cat-c-snacks');
      expect(text(t, 'rr-label'), 'Returns within 3 days · sealed items only');
      await tapKey(t, 'rr-history');
      expect(f.body('rr_history')['category_id'], 'c-snacks');
      expect(find.byKey(const ValueKey('rr-v-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('rr-v-1')), findsOneWidget);
      expect(find.text('In use'), findsOneWidget);
      expect(find.text('Replaced'), findsOneWidget);
      expect(find.textContaining('Agreed by Raj'), findsNWidgets(2));
    });

    testWidgets('several categories at once get the same policy in one save', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await tapKey(t, 'rr-multi');
      await tapKey(t, 'rr-cat-c-dairy');
      await tapKey(t, 'rr-cat-c-oils');
      await tapKey(t, 'rr-cat-default');
      expect(find.text('Set policy for 3 categories'), findsOneWidget);
      await tapKey(t, 'rr-pick-go');
      expect(find.text('3 categories'), findsWidgets);
      await tapKey(t, 'rr-review');
      expect(f.body('rr_policy_save')['category_ids'], ['c-dairy', 'c-oils', null]);
    });

    testWidgets('the handover photo switch and the bulk-order count save', (t) async {
      final f = Fake();
      await show(t, ReturnsHomeScreen(api: f.api));
      await t.tap(find.byKey(const ValueKey('rr-dispatch-photo')));
      await t.pumpAndSettle();
      expect(f.body('rr_settings_save'), {'dispatch_photo': false});
      await tapKey(t, 'rr-bulk-edit');
      expect(text(t, 'rr-bulk-value'), '10 items');
      await tapKey(t, 'rr-bulk-plus');
      expect(text(t, 'rr-bulk-value'), '15 items');
      await tapKey(t, 'rr-bulk-save');
      expect(f.body('rr_settings_save'), {'bulk_items': 15});
    });

    testWidgets('someone who may not change it sees the page read-only', (t) async {
      final f = Fake(canEdit: false);
      await show(t, ReturnsHomeScreen(api: f.api));
      expect(find.byKey(const ValueKey('rr-readonly')), findsOneWidget);
      expect(find.byKey(const ValueKey('rr-multi')), findsNothing);
      expect(find.byKey(const ValueKey('rr-bulk-edit')), findsNothing);
      await tapKey(t, 'rr-cat-c-dairy');
      expect(find.byKey(const ValueKey('rr-review')), findsNothing);
    });
  });

  test('windows: a few hours, then whole days, inside the template limits', () {
    expect(RrTemplate(_templates[0]).windows, [2, 4, 6, 12, 24, 48]);
    expect(RrTemplate(_templates[1]).windows, [24, 48, 72, 96, 120, 144, 168]);
    expect(windowWords(24), '1 day');
    expect(windowWords(12), '12 hours');
  });
}
