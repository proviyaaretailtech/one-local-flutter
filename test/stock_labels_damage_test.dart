import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/label_pdf.dart';
import 'package:vinii_pos/stock/adjust_screen.dart';
import 'package:vinii_pos/stock/labels_screens.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show toast;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) =>
    http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

// Shapes as the local server answers them (inv_options, inv_stock_list, inv_stock_detail, cat_item_lookup, inv_document_*).
const _a01 = 'bin-a01', _q01 = 'bin-q01';
final _options = {
  'me': {'id': 'me1', 'name': 'Raj', 'role': 'org_owner', 'can_record': true, 'can_approve': true},
  'bins': [
    {'id': _a01, 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'storage': 'ambient', 'capacity_units': null},
    {'id': 'bin-b01', 'code': 'B-01', 'name': 'Backroom B-01', 'zone': 'backroom', 'storage': 'ambient', 'capacity_units': null},
    {'id': _q01, 'code': 'Q-01', 'name': 'Quarantine Q-01', 'zone': 'quarantine', 'storage': 'ambient', 'capacity_units': null},
  ],
  'reasons': {
    'adjustment': ['Cycle-count shortage', 'Damaged in store', 'Expired', 'Data entry correction'],
    'transfer': <String>[],
    'reject': <String>[],
  },
  'approvers': [
    {'id': 'me1', 'name': 'Raj', 'role': 'org_owner'},
  ],
};

Map<String, dynamic> _item(String id, String name, String sku, {num available = 0, num damaged = 0, num? days, String status = 'healthy'}) => {
      'id': id, 'sku': sku, 'name': name, 'unit': 'pc', 'status': status, 'damaged': damaged, 'category': 'Beverages', 'reserved': 0,
      'available': available, 'item_type': 'sku', 'in_transit': 0, 'stock_days': null,
      'expiry_date': days == null ? null : DateTime(2026, 10, 24).add(Duration(days: days.toInt())).toIso8601String().substring(0, 10), 'expiry_days': days,
    };

final _items = [
  _item('i1', 'Coca-Cola 500ml', 'CC500', available: 36, damaged: 2, days: 18),
  _item('i2', 'Veg Biryani', 'VB300', available: 3, days: 2, status: 'near_expiry'),
  _item('i3', 'Mango Lassi', 'ML250', damaged: 4, days: -1, status: 'out'),
  _item('i4', 'Tata Salt', 'TS1', available: 20),
];

Map<String, dynamic> _lot(String id, String bin, String binName, String zone, num onHand, String code, num days) =>
    {'id': id, 'zone': zone, 'bin_id': bin, 'on_hand': onHand, 'bin_code': '', 'bin_name': binName, 'lot_code': code, 'days_left': days, 'expiry_date': '2026-11-11'};

Map<String, dynamic> _detail(String id) {
  final it = _items.firstWhere((i) => i['id'] == id);
  final (bins, lots) = switch (id) {
    'i1' => (
        [
          {'id': _a01, 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'on_hand': 36},
          {'id': _q01, 'code': 'Q-01', 'name': 'Quarantine Q-01', 'zone': 'quarantine', 'on_hand': 2},
        ],
        [_lot('l1', _a01, 'Shelf A-01', 'shelf', 36, 'CC-A', 18), _lot('l2', _q01, 'Quarantine Q-01', 'quarantine', 2, 'CC-A', 18)],
      ),
    'i2' => (
        [
          {'id': _a01, 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'on_hand': 3},
        ],
        [_lot('l3', _a01, 'Shelf A-01', 'shelf', 3, 'VB-A', 2)],
      ),
    'i3' => (
        [
          {'id': _q01, 'code': 'Q-01', 'name': 'Quarantine Q-01', 'zone': 'quarantine', 'on_hand': 4},
        ],
        [_lot('l4', _q01, 'Quarantine Q-01', 'quarantine', 4, 'ML-A', -1)],
      ),
    _ => (
        [
          {'id': _a01, 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'on_hand': 20},
        ],
        <Map<String, dynamic>>[],
      ),
  };
  return {
    'bins': bins, 'lots': lots, 'status': it['status'], 'damaged': it['damaged'], 'reserved': 0, 'sellable': it['available'], 'available': it['available'],
    'in_transit': 0, 'stock_days': null, 'expiry_date': it['expiry_date'], 'daily_demand': 0, 'latest_movement': null,
    'location': {'id': 'loc1', 'code': 'MAIN', 'name': 'Main'},
    'item': {'id': id, 'sku': it['sku'], 'name': it['name'], 'unit': 'pc', 'barcode': null, 'category': 'Beverages', 'item_type': 'sku', 'reorder_level': 5},
  };
}

Map<String, dynamic> _catItem(String sku) => {
      'id': 'm-$sku', 'sku': sku, 'name': _items.firstWhere((i) => i['sku'] == sku)['name'], 'status': 'active', 'version': 1, 'category': 'Beverages',
      'price_minor': 4000, 'mrp_minor': 4500, 'cost_minor': 3000, 'barcode': sku == 'CC500' ? '8901764011506' : null, 'selling_unit': 'pc',
    };

Map<String, dynamic> _doc(String id, String no, {required String title, required String status, required String type, required String itemId, num qty = 2, String createdBy = 'other', List<String> actions = const []}) {
  final it = _items.firstWhere((i) => i['id'] == itemId);
  return {
    'id': id, 'doc_no': no, 'doc_type': 'adjustment', 'title': title, 'status': status, 'version': 2, 'reason': 'Damaged in store', 'note': '',
    'created_by': {'id': createdBy, 'name': createdBy == 'me1' ? 'Raj' : 'Niraj'}, 'approved_by': status == 'posted' ? {'id': 'me1', 'name': 'Raj'} : null,
    'submitted_at': '2026-10-24T09:20:00Z', 'posted_at': status == 'posted' ? '2026-10-24T10:00:00Z' : null, 'allowed_actions': actions,
    'lines': [
      {'item': {'id': itemId, 'sku': it['sku'], 'name': it['name'], 'unit': 'pc'}, 'qty': qty, 'adjust_type': type},
    ],
  };
}

/// One fake server for stock and catalogue calls. [docs] are the adjustment documents it knows; writes are recorded.
class Server {
  Server({this.docs = const [], this.handler});
  final List<Map<String, dynamic>> docs;
  final http.Response? Function(http.Request r)? handler;
  final requests = <http.Request>[];
  final opened = <(String, String?)>[];

  late final client = MockClient((r) async {
    requests.add(r);
    final custom = handler?.call(r);
    if (custom != null) return custom;
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    switch (fnOf(r)) {
      case 'inv_options':
        return ok(_options);
      case 'inv_stock_list':
        return ok({'items': _items, 'total': _items.length, 'page': 1, 'page_size': 50, 'counts': {}, 'categories': [], 'location': {}});
      case 'inv_stock_detail':
        return ok(_detail(b['item_id'] as String));
      case 'cat_item_lookup':
        final code = b['code'] as String;
        if (!_items.any((i) => i['sku'] == code) || code == 'TS1') return err(404, 'No item has that code.', 'not_found');
        return ok(_catItem(code));
      case 'inv_document_list':
        final statuses = (b['statuses'] as List?)?.cast<String>() ?? const [];
        return ok({
          'documents': [
            for (final d in docs)
              if (statuses.isEmpty || statuses.contains(d['status'])) {'id': d['id'], 'doc_no': d['doc_no'], 'title': d['title'], 'status': d['status'], 'doc_type': 'adjustment'},
          ],
        });
      case 'inv_document_view':
        return ok(docs.firstWhere((d) => d['id'] == b['id']));
      case 'inv_document_save':
        return ok({'id': 'new1', 'doc_no': 'ADJ-009', 'doc_type': 'adjustment', 'status': 'draft', 'version': 1, 'lines': b['lines'], 'allowed_actions': ['submit']});
      case 'inv_document_act':
        return ok({'id': b['id'], 'doc_no': 'ADJ-009', 'doc_type': 'adjustment', 'status': 'awaiting_approval', 'version': 2, 'lines': [], 'allowed_actions': []});
    }
    return err(404, 'not found: ${fnOf(r)}');
  });

  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://inv.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://inv.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://inv.test', accessToken: () => 't', client: client),
    open: (context, page, {itemId}) async => opened.add((page, itemId)),
  );

  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// A 390-point-wide phone with the real Inter and Lucide fonts, so an overflow here is a real one.
Future<void> phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(780, 5200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  final f = find.text(text).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  group('label PDF', () {
    const label = LabelData(name: 'Coca-Cola 500ml', priceMinor: 4000, mrpMinor: 4500, code: '8901764011506', systemCode: 'CC500', store: 'Sharma General Store', shelf: 'Shelf A-01');

    test('both sizes make a real PDF, one page per label copy', () async {
      for (final size in LabelSize.values) {
        final pdf = await buildLabelsPdf([(label, 3)], size: size);
        expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
        expect(pdf.length, greaterThan(1000));
        expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(pdf)).length, 3, reason: size.name);
      }
    });

    test('with the app font the price keeps its ₹; without it, it reads Rs', () async {
      final font = await rootBundle.load('fonts/Inter.ttf');
      expect(labelMoney(4000), '₹40');
      expect(labelMoney(4050, rupee: false), 'Rs 40.50');
      expect(labelBarcodeData('CC-500 ₹'), 'CC-500 -');
      final withFont = await buildLabelsPdf([(label, 1)], size: LabelSize.product, font: pw.Font.ttf(font));
      expect(withFont.length, greaterThan(1000));
    });
  });

  group('Product and shelf labels', () {
    late List<(Uint8List, String)> printed, shared;
    setUp(() {
      printed = [];
      shared = [];
      printLabelPdf = (pdf, name) async => printed.add((pdf, name));
      shareLabelPdf = (pdf, name) async => shared.add((pdf, name));
    });

    testWidgets('opened for a product: its price, barcode and a preview; more copies; Print sends a PDF', (t) async {
      final s = Server();
      await phone(t, ProductLabelsScreen(env: s.env, itemId: 'i1'));
      expect(find.text('Product labels'), findsOneWidget);
      expect(s.body(s.calls('cat_item_lookup').single)['code'], 'CC500');
      expect(find.text('CC500 · ₹40 per pc'), findsOneWidget);
      expect(find.byKey(const ValueKey('label-preview')), findsOneWidget);
      expect(find.text('8901764011506'), findsOneWidget); // the product's own barcode, not the System Code
      expect(find.textContaining('connected'), findsNothing);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('label-entry-i1')), matching: find.text('+')));
      await t.pumpAndSettle();
      expect(find.text('Print 2 labels'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.text('Print 2 labels'));
        for (var i = 0; i < 50 && printed.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await t.pumpAndSettle();
      expect(printed, hasLength(1));
      expect(printed.single.$2, 'product-labels.pdf');
      expect(String.fromCharCodes(printed.single.$1.sublist(0, 5)), '%PDF-');
    });

    testWidgets('a product the shop does not sell has no price: it says so and is not added', (t) async {
      final s = Server();
      await phone(t, ProductLabelsScreen(env: s.env, itemId: 'i4'));
      expect(toast('Tata Salt is not sold in the shop, so it has no price for a label.'), findsOneWidget);
      expect(find.byKey(const ValueKey('label-preview')), findsNothing);
      await t.tap(find.text('Print labels'));
      await t.pump();
      expect(printed, isEmpty);
    });

  });


  group('Adjust (J.101)', () {
    testWidgets('Add stock: one increase into a shelf, sent for approval', (t) async {
      final s = Server();
      await phone(t, AdjustStockScreen(env: s.env, itemId: 'i4'));
      expect(find.text('Adjust stock'), findsOneWidget);
      for (final k in ['add', 'remove', 'damage', 'throw']) {
        expect(find.byKey(ValueKey('adjust-kind-$k')), findsOneWidget, reason: k);
      }
      await t.enterText(find.byKey(const ValueKey('adjust-qty')), '6');
      await t.ensureVisible(find.byKey(const ValueKey('adjust-send')));
      await t.tap(find.byKey(const ValueKey('adjust-send')));
      await t.pumpAndSettle();
      final save = s.body(s.calls('inv_document_save').single);
      expect(save['doc_type'], 'adjustment');
      expect(save['lines'], [
        {'inventory_item_id': 'i4', 'to_bin_id': _a01, 'adjust_type': 'increase', 'qty': 6},
      ]);
      expect(s.body(s.calls('inv_document_act').single)['action'], 'submit');
      expect(toast('Sent for approval as ADJ-009. Stock changes once a manager approves it.'), findsOneWidget);
    });

    testWidgets('Remove stock: never more than the place holds; a decrease from the shelf, never from the damaged area', (t) async {
      final s = Server();
      await phone(t, AdjustStockScreen(env: s.env, itemId: 'i1'));
      await t.tap(find.byKey(const ValueKey('adjust-kind-remove')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('adjust-qty')), '40');
      await t.ensureVisible(find.byKey(const ValueKey('adjust-send')));
      await t.tap(find.byKey(const ValueKey('adjust-send')));
      await t.pump();
      expect(toast('Only 36 are there.'), findsOneWidget);
      expect(s.calls('inv_document_save'), isEmpty);
      await t.pump(const Duration(seconds: 4));
      await t.enterText(find.byKey(const ValueKey('adjust-qty')), '5');
      await t.tap(find.byKey(const ValueKey('adjust-send')));
      await t.pumpAndSettle();
      expect(s.body(s.calls('inv_document_save').single)['lines'], [
        {'inventory_item_id': 'i1', 'from_bin_id': _a01, 'adjust_type': 'decrease', 'qty': 5},
      ]);
    });

    testWidgets('Damaged and Throw away use the held-apart form; waiting changes are approved after a confirm', (t) async {
      final s = Server(docs: [_doc('d1', 'ADJ-004', title: 'Stock removed', status: 'awaiting_approval', type: 'decrease', itemId: 'i1', actions: ['approve', 'reject'])]);
      await phone(t, AdjustStockScreen(env: s.env));
      await t.tap(find.byKey(const ValueKey('adjust-kind-damage')));
      await t.pumpAndSettle();
      expect(find.text('Record damage'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('adjust-kind-throw')));
      await t.pumpAndSettle();
      expect(find.text('Throw away'), findsWidgets);
      expect(find.text('ADJ-004'), findsOneWidget);
      await tapText(t, 'Approve');
      expect(find.text('Approve ADJ-004?'), findsOneWidget);
      await tapText(t, 'Approve');
      final act = s.body(s.calls('inv_document_act').single);
      expect(act['action'], 'approve');
      expect(act['id'], 'd1');
    });
  });
}
