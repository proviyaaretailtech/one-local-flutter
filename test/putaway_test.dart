import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/putaway_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

/// Answers captured from the real local database (the same fixtures the stock tests use).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/inventory_server.json').readAsStringSync()) as Map<String, dynamic>;
http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

class Fake {
  Fake({this.done = const []});
  final List<Map<String, dynamic>> done; // putaway moves already made
  final requests = <http.Request>[];
  late final client = MockClient((r) async {
    requests.add(r);
    final b = r.body.isEmpty ? <String, dynamic>{} : body(r);
    return switch (fnOf(r)) {
      'inv_options' => ok(fx['options']),
      'inv_document_list' => ok(b['doc_type'] == 'transfer' || b['type'] == 'transfer' ? {'documents': done} : {'documents': [fx['receipt_posted']]}),
      'inv_document_view' => ok(fx['receipt_posted']),
      'inv_stock_detail' => ok(fx['stock_detail']),
      'inv_document_save' => ok({...(fx['transfer_draft'] as Map<String, dynamic>), 'id': 't-new', 'version': 1}),
      'inv_document_act' => ok({...(fx['transfer_posted'] as Map<String, dynamic>), 'id': 't-new'}),
      _ => http.Response('{"detail":"not found"}', 404),
    };
  });
  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://t.test', accessToken: () => 't', client: client),
    open: (context, page, {itemId}) async {},
  );
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

Future<void> phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(780, 5000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

final _receipt = fx['receipt_posted'] as Map<String, dynamic>;
final _lines = (_receipt['lines'] as List).cast<Map<String, dynamic>>();
String _lineId(int i) => _lines[i]['id'] as String;

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  testWidgets('received deliveries wait under To put away; one opens with each batch in the place it was received into', (t) async {
    final f = Fake();
    await phone(t, PutawayScreen(env: f.env));
    expect(find.text('Putaway'), findsWidgets);
    expect(find.text('To put away'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('putaway-receipt-${_receipt['id']}')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('putaway-line-${_lineId(0)}')), findsOneWidget);
    expect(find.byKey(ValueKey('putaway-line-${_lineId(1)}')), findsOneWidget); // same product, second batch
    expect(find.textContaining('received into Shelf A-01'), findsOneWidget);
    expect(find.text('All placed'), findsNWidgets(2));
  });

  testWidgets('splitting a batch across two places posts one move titled with the receipt: only the units that leave move', (t) async {
    final f = Fake();
    await phone(t, PutawayScreen(env: f.env));
    await t.tap(find.byKey(ValueKey('putaway-receipt-${_receipt['id']}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('putaway-add-${_lineId(0)}'))); // 42 on the shelf → 21 + 21 in the next place
    await t.pumpAndSettle();
    expect(find.text('All placed'), findsNWidgets(2)); // the total stays right
    await t.ensureVisible(find.byKey(const ValueKey('putaway-assign')));
    await t.tap(find.byKey(const ValueKey('putaway-assign')));
    await t.pumpAndSettle();
    final save = body(f.calls('inv_document_save').single);
    expect(save['doc_type'], 'transfer');
    expect(save['title'], 'Putaway ${_receipt['doc_no']}');
    final lines = (save['lines'] as List).cast<Map<String, dynamic>>();
    expect(lines, hasLength(1));
    expect(lines.single['qty'], 21);
    expect(lines.single['from_bin_id'], (_lines[0]['to_bin'] as Map)['id']);
    expect(lines.single['lot_id'], (_lines[0]['lot'] as Map)['id']);
    expect(body(f.calls('inv_document_act').single)['action'], 'post');
  });

  testWidgets('a place left short blocks Assign and says how many are left', (t) async {
    final f = Fake();
    await phone(t, PutawayScreen(env: f.env));
    await t.tap(find.byKey(ValueKey('putaway-receipt-${_receipt['id']}')));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp('Decrease Coca-Cola')).first);
    await t.pumpAndSettle();
    expect(find.text('1 left'), findsOneWidget);
    await t.ensureVisible(find.byKey(const ValueKey('putaway-assign')));
    await t.tap(find.byKey(const ValueKey('putaway-assign')));
    await t.pumpAndSettle();
    expect(f.calls('inv_document_save'), isEmpty);
  });

  testWidgets('a delivery already put away shows under Done', (t) async {
    final f = Fake(done: [{'id': 'x', 'doc_no': 'TRF-9', 'status': 'posted', 'title': 'Putaway ${_receipt['doc_no']}'}]);
    await phone(t, PutawayScreen(env: f.env));
    expect(find.byKey(ValueKey('putaway-receipt-${_receipt['id']}')), findsNothing);
    await t.tap(find.byKey(const ValueKey('chip-done')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('putaway-receipt-${_receipt['id']}')), findsOneWidget);
  });
}
