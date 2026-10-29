// Count stock (closing stock check): the counted quantity is typed or stepped in the item's unit, saved with the count, and a finished count
// can be opened again to change its quantities before the difference is fixed.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/stock_count_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

Map<String, dynamic> doc({String status = 'draft', num? counted, int version = 1}) => {
      'id': 'doc1', 'doc_type': 'audit', 'doc_no': 'AUD-0007', 'status': status, 'version': version, 'allowed_actions': [],
      'lines': [
        {
          'id': 'l1', 'system_qty': 2.5, 'counted_qty': counted,
          'item': {'id': 'i-bp', 'name': 'Baking powder', 'sku': 'ING-BAK-13', 'unit': 'kg'},
        },
      ],
    };

void main() {
  late List<(String, Map<String, dynamic>)> calls;
  late Map<String, dynamic> current;

  StockEnv env() {
    calls = [];
    current = doc();
    final client = MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body));
      final answer = switch (fn) {
        'inv_document_list' => {'documents': [{'id': 'doc1', 'doc_no': 'AUD-0007', 'status': current['status']}]},
        'inv_document_save' => current = doc(status: 'draft', counted: (body['lines'] as List).first['counted_qty'] as num?, version: (current['version'] as int) + 1),
        'inv_document_act' => current = doc(
            status: body['action'] == 'submit' ? 'review' : 'draft', counted: (current['lines'] as List).first['counted_qty'] as num?, version: (current['version'] as int) + 1),
        'inv_document_view' => current,
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
    });
    final rpc = RpcClient(client: client, baseUrl: 'http://t.test', accessToken: () => 't');
    return StockEnv(inv: InvEnv(api: InventoryApi(rpc: rpc)), catalogue: CatalogueApi(rpc: rpc), rpc: rpc);
  }

  Future<void> show(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(800, 1720);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
    await t.pumpAndSettle();
  }

  String boxText(WidgetTester t) => t.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('count-qty-l1')), matching: find.byType(TextField))).controller!.text;

  Future<void> tap(WidgetTester t, String key) async {
    await t.ensureVisible(find.byKey(ValueKey(key)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(key)));
    await t.pumpAndSettle();
  }

  testWidgets('the counted quantity is typed or stepped in the item\'s unit (a tenth of a kg) and saved with the count', (t) async {
    await show(t, StockCountScreen(env: env()));
    await tap(t, 'count-doc1');
    expect(find.byKey(const ValueKey('count-unit-l1')), findsOneWidget, reason: 'the unit shows in the box');
    expect(find.text('2.5 kg'), findsOneWidget);
    await tap(t, 'count-plus-l1');
    expect(boxText(t), '2.6', reason: 'the first step starts from what the app has: 2.5 + 0.1');
    await tap(t, 'count-minus-l1');
    await tap(t, 'count-minus-l1');
    expect(boxText(t), '2.4');
    await t.enterText(find.byKey(const ValueKey('count-qty-l1')), '1.75');
    await t.pump();
    await tap(t, 'count-finish');
    final saved = calls.lastWhere((c) => c.$1 == 'inv_document_save').$2;
    expect((saved['lines'] as List).first['counted_qty'], 1.75);
    expect(calls.last.$1, 'inv_document_view');
    expect(calls.where((c) => c.$1 == 'inv_document_act').single.$2['action'], 'submit');
  });

  testWidgets('a finished count can be opened again (Edit counts) and its quantity changed before the difference is fixed', (t) async {
    final e = env();
    current = doc(status: 'review', counted: 1.75);
    await show(t, StockCountScreen(env: e));
    await tap(t, 'count-doc1');
    expect(find.byKey(const ValueKey('count-qty-l1')), findsNothing, reason: 'finished: read only');
    expect(find.text('1.75 kg'), findsOneWidget);
    await tap(t, 'count-reopen');
    expect(calls.lastWhere((c) => c.$1 == 'inv_document_act').$2['action'], 'reopen');
    expect(find.byKey(const ValueKey('count-qty-l1')), findsOneWidget, reason: 'editable again');
    await t.enterText(find.byKey(const ValueKey('count-qty-l1')), '2');
    await t.pump();
    await tap(t, 'count-finish');
    expect(((calls.lastWhere((c) => c.$1 == 'inv_document_save').$2['lines'] as List).first)['counted_qty'], 2);
  });
}
