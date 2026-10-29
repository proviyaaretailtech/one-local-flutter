// Closing stock (0628): every stock item in one table with its count typed in, the difference worked out, saved as one stock count, and the
// whole table exported as an Excel (.xlsx) file.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/closing_stock_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';
import 'package:vinii_pos/ui/xlsx.dart';

final _items = [
  {'id': 'i-bp', 'name': 'Baking powder', 'sku': 'ING-BAK-13', 'unit': 'kg', 'category': 'Bakery', 'available': 0, 'reserved': 0, 'damaged': 0},
  {'id': 'i-bell', 'name': 'Bell pepper (red/yellow)', 'sku': 'ING-VEG-05', 'unit': 'kg', 'category': 'Vegetables', 'available': 2.93, 'reserved': 0, 'damaged': 0},
  {'id': 'i-bread', 'name': 'Sandwich bread', 'sku': 'ING-BAK-01', 'unit': 'pc', 'category': 'Bakery', 'available': 12, 'reserved': 0, 'damaged': 0},
];

void main() {
  late List<(String, Map<String, dynamic>)> calls;
  late Map<String, dynamic>? current;

  Map<String, dynamic> doc(String status, List lines, int version) => {
        'id': 'doc1', 'doc_type': 'audit', 'doc_no': 'AUD-0009', 'status': status, 'version': version, 'allowed_actions': [],
        'lines': [
          for (final l in lines)
            {
              'id': 'l-${l['inventory_item_id']}', 'counted_qty': l['counted_qty'],
              'system_qty': _items.firstWhere((i) => i['id'] == l['inventory_item_id'])['available'],
              'item': {'id': l['inventory_item_id'], 'name': 'x', 'unit': 'kg'},
            },
        ],
      };

  StockEnv env() {
    calls = [];
    current = null;
    final client = MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body));
      final answer = switch (fn) {
        'inv_stock_list' => {'items': _items, 'total': _items.length},
        'inv_document_list' => {'documents': current == null ? [] : [{'id': 'doc1', 'status': current!['status']}]},
        'inv_document_save' => current = doc('draft', body['lines'] as List, ((current?['version'] as int?) ?? 0) + 1),
        'inv_document_act' => current = {...current!, 'status': body['action'] == 'submit' ? 'review' : 'draft', 'version': (current!['version'] as int) + 1},
        'inv_document_view' => current,
        _ => <String, dynamic>{},
      };
      return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
    });
    final rpc = RpcClient(client: client, baseUrl: 'http://t.test', accessToken: () => 't');
    return StockEnv(inv: InvEnv(api: InventoryApi(rpc: rpc)), catalogue: CatalogueApi(rpc: rpc), rpc: rpc);
  }

  Future<void> show(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(900, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String key) async {
    await t.ensureVisible(find.byKey(ValueKey(key)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(key)));
    await t.pumpAndSettle();
  }

  testWidgets('every item in one table: type the closing stock, see the difference; only counted items are saved; Finish closes the count', (t) async {
    await show(t, ClosingStockScreen(env: env(), today: DateTime(2026, 10, 29)));
    expect(find.byKey(const ValueKey('cs-table')), findsOneWidget);
    final heads = [for (final k in ['item', 'count', 'unit', 'system', 'diff']) t.getRect(find.byKey(ValueKey('cs-col-$k'))).left];
    expect(heads, [...heads]..sort(), reason: 'Item, Closing stock, Unit, In the app, Difference');
    for (final n in ['Baking powder', 'Bell pepper (red/yellow)', 'Sandwich bread']) {
      expect(find.text(n), findsOneWidget);
    }
    await t.enterText(find.byKey(const ValueKey('cs-count-i-bell')), '2.5');
    await t.enterText(find.byKey(const ValueKey('cs-count-i-bread')), '12');
    await t.pump();
    expect(t.widget<Text>(find.byKey(const ValueKey('cs-diff-i-bell'))).data, '−0.43', reason: 'a real minus sign');
    expect(t.widget<Text>(find.byKey(const ValueKey('cs-diff-i-bread'))).data, 'Matches');
    await tap(t, 'cs-show-diff');
    expect(find.text('Bell pepper (red/yellow)'), findsOneWidget);
    expect(find.text('Sandwich bread'), findsNothing, reason: 'matches: not a difference');
    expect(find.text('Baking powder'), findsNothing, reason: 'not counted');
    await tap(t, 'cs-show-all');
    await tap(t, 'cs-save');
    final saved = calls.lastWhere((c) => c.$1 == 'inv_document_save').$2;
    expect(saved['doc_type'], 'audit');
    expect([for (final l in saved['lines'] as List) (l['inventory_item_id'], l['counted_qty'])], [('i-bell', 2.5), ('i-bread', 12)]);
    expect(find.byKey(const ValueKey('cs-doc')), findsOneWidget);
    await tap(t, 'cs-finish');
    expect(calls.lastWhere((c) => c.$1 == 'inv_document_act').$2['action'], 'submit');
    expect(find.byKey(const ValueKey('cs-count-i-bell')), findsNothing, reason: 'finished: read only until Edit counts');
    await tap(t, 'cs-reopen');
    expect(calls.lastWhere((c) => c.$1 == 'inv_document_act').$2['action'], 'reopen');
    expect(find.byKey(const ValueKey('cs-count-i-bell')), findsOneWidget);
  });

  testWidgets('Export Excel saves closing-stock-<date>.xlsx with every item, what the app has, the count and the difference', (t) async {
    Uint8List? file;
    String? name;
    final before = saveSpreadsheet;
    saveSpreadsheet = (b, n) async {
      file = b;
      name = n;
    };
    addTearDown(() => saveSpreadsheet = before);
    await show(t, ClosingStockScreen(env: env(), today: DateTime(2026, 10, 29)));
    await t.enterText(find.byKey(const ValueKey('cs-count-i-bell')), '2.5');
    await t.pump();
    await tap(t, 'cs-export');
    expect(name, 'closing-stock-2026-10-29.xlsx');
    final zip = ZipDecoder().decodeBytes(file!);
    expect(zip.files.map((f) => f.name), containsAll(['[Content_Types].xml', 'xl/workbook.xml', 'xl/worksheets/sheet1.xml']));
    final sheet = utf8.decode(zip.findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet, contains('Closing stock (counted)'));
    expect(sheet, contains('<c r="D1" t="inlineStr" s="1"><is><t xml:space="preserve">Closing stock (counted)</t>'), reason: 'right after Item, Code, Category');
    expect(sheet, contains('Bell pepper (red/yellow)'));
    expect(sheet, contains('<v>2.93</v>'), reason: 'in the app, as a number');
    expect(sheet, contains('<v>2.5</v>'), reason: 'the count');
    expect(sheet, contains('<v>-0.43</v>'), reason: 'the difference');
    expect(utf8.decode(zip.findFile('xl/workbook.xml')!.content as List<int>), contains('Closing stock 2026-10-29'));
  });

  test('buildXlsx: text is escaped, numbers stay numbers, header row is bold', () {
    final zip = ZipDecoder().decodeBytes(buildXlsx('S', [
      ['Name', 'Qty'],
      ['Salt & pepper <fine>', 3],
    ]));
    final sheet = utf8.decode(zip.findFile('xl/worksheets/sheet1.xml')!.content as List<int>);
    expect(sheet, contains('Salt &amp; pepper &lt;fine&gt;'));
    expect(sheet, contains('<c r="B2"><v>3</v></c>'));
    expect(sheet, contains('<c r="A1" t="inlineStr" s="1">'));
  });
}
