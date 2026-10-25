import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/stock/move_stock_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/stock/stock_movements_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

// Answers shaped like the local server's (Sharma General Store, 24 Oct 2026).
const shelf = {'id': 'bin-a', 'code': 'A-01', 'name': 'Shelf A-01', 'zone': 'shelf', 'storage': 'ambient', 'capacity_units': 60};
const back = {'id': 'bin-b', 'code': 'B-01', 'name': 'Backroom B-01', 'zone': 'backroom', 'storage': 'ambient', 'capacity_units': null};
const quar = {'id': 'bin-q', 'code': 'Q-01', 'name': 'Quarantine Q-01', 'zone': 'quarantine', 'storage': 'ambient', 'capacity_units': null};
const store = {'id': 'loc-1', 'code': 'MAIN', 'name': 'Sharma General Store - Main'};

final options = {
  'me': {'id': 'u1', 'name': 'Raj', 'role': 'org_owner', 'can_record': true, 'can_approve': true},
  'bins': [shelf, back, quar],
  'reasons': {
    'transfer': ['Refill sales shelf', 'Free up backroom'],
    'adjustment': ['Cycle-count shortage'],
    'reject': ['Broken seal'],
  },
  'location': store,
  'locations': [store],
  'snapshot_at': '2026-10-24T10:30:00Z',
};

const parle = {'id': 'it-pg', 'sku': 'PG250', 'name': 'Parle-G 250g', 'unit': 'pc', 'barcode': '8901', 'category': 'Biscuits'};
final detail = {
  'item': parle,
  'bins': [
    {...shelf, 'on_hand': 12},
    {...back, 'on_hand': 30},
    {...quar, 'on_hand': 2},
  ],
  'lots': [
    {'id': 'lot-2', 'zone': 'backroom', 'bin_id': 'bin-b', 'on_hand': 30, 'bin_name': 'Backroom B-01', 'lot_code': 'PG-2611', 'days_left': 140, 'expiry_date': '2027-03-13'},
    {'id': 'lot-1', 'zone': 'shelf', 'bin_id': 'bin-a', 'on_hand': 12, 'bin_name': 'Shelf A-01', 'lot_code': 'PG-2610', 'days_left': 117, 'expiry_date': '2027-02-18'},
    {'id': 'lot-q', 'zone': 'quarantine', 'bin_id': 'bin-q', 'on_hand': 2, 'bin_name': 'Quarantine Q-01', 'lot_code': 'PG-2609', 'days_left': 20, 'expiry_date': '2026-11-13'},
  ],
  'available': 42,
  'reserved': 3,
  'damaged': 2,
  'in_transit': 0,
  'status': 'low',
  'location': store,
  'snapshot_at': '2026-10-24T10:30:00Z',
};

Map<String, dynamic> move(int id, String kind, num delta, {String item = 'Parle-G 250g'}) => {
      'id': id,
      'kind': kind,
      'delta': delta,
      'quantity': delta,
      'item': {...parle, 'name': item},
      'actor': {'name': 'Raj'},
      'ref': {'label': 'P-000$id', 'method': 'POS checkout'},
      'created_at': '2026-10-2${id % 10}T06:15:00Z',
    };

final moveDetail = {
  'id': 13,
  'kind': 'sale',
  'item': parle,
  'before': 12,
  'delta': -1,
  'after': 11,
  'location': store,
  'reference': {'label': 'P-00020', 'method': 'POS checkout', 'recorded_by': {'name': 'Raj'}},
  'created_at': '2026-10-24T06:15:00Z',
  'allocations': [
    {'bin': shelf, 'lot': {'lot_code': 'PG-2610'}, 'quantity': -1, 'bin_before': 12, 'bin_after': 11},
  ],
  'trail': [
    {'at': '2026-10-24T06:15:00Z', 'label': 'Order P-00020 placed'},
  ],
};

Map<String, dynamic> receipt({String status = 'draft', String? toBin}) => {
      'id': 'rcv-1',
      'doc_no': 'RCV-001',
      'doc_type': 'receipt',
      'status': status,
      'version': 7,
      'supplier_name': 'Latur Wholesale Traders',
      'po_ref': 'PO-2026-014',
      'invoice_ref': 'INV-47',
      'location': store,
      'lines': [
        {'id': 'rl1', 'item': {'id': 'it-m', 'sku': 'M001', 'name': 'Milk 1 ltr', 'unit': 'l'}, 'qty': 26, 'rejected_qty': 2, 'reject_reason': 'Broken seal', 'expected_qty': 24,
          'to_bin': toBin == null ? null : {'id': toBin, 'name': 'Backroom B-01'}},
      ],
      'allowed_actions': ['submit', 'cancel'],
    };

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  Fake(this.answer);
  final Object? Function(String fn, Map<String, dynamic> body) answer;
  final requests = <http.Request>[];
  final opened = <String>[];

  Iterable<Map<String, dynamic>> bodies(String fn) => requests.where((r) => fnOf(r) == fn).map((r) => jsonDecode(r.body) as Map<String, dynamic>);

  late final env = StockEnv(
    inv: InvEnv(
      api: InventoryApi(
        baseUrl: 'http://inv.test',
        accessToken: () => 't',
        client: MockClient((r) async {
          requests.add(r);
          final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
          final a = answer(fnOf(r), body);
          if (a is http.Response) return a;
          if (a != null) return ok(a);
          return switch (fnOf(r)) {
            'inv_options' => ok(options),
            'inv_stock_detail' => ok(detail),
            'inv_stock_list' => ok({'items': [{...parle, 'available': 42, 'reserved': 3, 'damaged': 2}], 'total': 1}),
            'inv_document_list' => ok({'documents': []}),
            _ => http.Response(jsonEncode({'detail': 'not found'}), 404),
          };
        }),
      ),
    ),
    open: (context, page, {itemId}) async => opened.add('$page${itemId == null ? '' : ':$itemId'}'),
  );
}

Future<void> tall(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 7000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, Finder f) async {
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  group('Stock movements', () {
    testWidgets('lists movements in plain words; In hides sales; a card opens before → after; older ones load', (t) async {
      final f = Fake((fn, b) => switch (fn) {
            'inv_movement_list' => b['before_id'] == null
                ? {'movements': [for (var i = 30; i >= 1; i--) i == 29 ? move(i, 'receipt', 24) : move(i, 'sale', -1)]}
                : {'movements': [move(0, 'adjustment', -2)]},
            'inv_movement_detail' => moveDetail,
            _ => null,
          });
      await tall(t, StockMovementsScreen(env: f.env));
      expect(find.textContaining('All products', findRichText: true), findsOneWidget);
      expect(find.text('Sold · −1 pc'), findsWidgets);
      expect(find.text('Delivery received · +24 pc'), findsOneWidget);
      await tap(t, find.text('In').first);
      expect(find.text('Sold · −1 pc'), findsNothing);
      expect(find.text('Delivery received · +24 pc'), findsOneWidget);
      await tap(t, find.text('All').first);
      await tap(t, find.text('Show older movements'));
      expect(f.bodies('inv_movement_list').last['before_id'], 1);
      expect(find.text('Correction · −2 pc'), findsOneWidget);
      await tap(t, find.text('Delivery received · +24 pc'));
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After'), findsOneWidget);
      expect(find.text('12 → 11 pc'), findsOneWidget);
      expect(find.text('Order P-00020 placed'), findsOneWidget);
    });

    testWidgets('opened for one product: its stock right now, and only its movements', (t) async {
      final f = Fake((fn, b) => fn == 'inv_movement_list' ? {'movements': [move(5, 'sale', -2)]} : null);
      await tall(t, StockMovementsScreen(env: f.env, itemId: 'it-pg'));
      expect(f.bodies('inv_movement_list').single['item_id'], 'it-pg');
      expect(find.textContaining('Parle-G 250g', findRichText: true), findsWidgets);
      expect(find.text('Ready to sell'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
    });
  });

  group('Move stock', () {
    testWidgets('moves from the backroom to the shelf: one draft, then post, with ids and quantity only', (t) async {
      final f = Fake((fn, b) => switch (fn) {
            'inv_document_save' => {'id': 'trf-1', 'doc_no': 'TRF-001', 'doc_type': 'transfer', 'status': 'draft', 'version': 1, 'allowed_actions': ['post']},
            'inv_document_act' => {'id': 'trf-1', 'doc_no': 'TRF-001', 'doc_type': 'transfer', 'status': 'posted', 'version': 2},
            _ => null,
          });
      await tall(t, MoveStockScreen(env: f.env, itemId: 'it-pg'));
      expect(find.textContaining('Backroom B-01 · 30 pc', findRichText: true), findsOneWidget); // the place with the most units
      expect(find.textContaining('Shelf A-01 · 12 pc now', findRichText: true), findsOneWidget);
      expect(find.text('Quarantine Q-01'), findsNothing);
      for (var i = 0; i < 11; i++) {
        await t.tap(find.text('+'));
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(find.text('30 − 12 → 18'), findsOneWidget);
      expect(find.text('12 + 12 → 24'), findsOneWidget);
      await tap(t, find.text('Move stock').last);
      final save = f.bodies('inv_document_save').single;
      expect(save['doc_type'], 'transfer');
      expect(save['reason'], 'Refill sales shelf');
      expect(save['lines'], [
        {'inventory_item_id': 'it-pg', 'from_bin_id': 'bin-b', 'to_bin_id': 'bin-a', 'qty': 12}
      ]);
      expect(f.bodies('inv_document_act').single, {'id': 'trf-1', 'action': 'post', 'version': 1});
      expect(f.requests.where((r) => fnOf(r) == 'inv_document_save').single.headers['Idempotency-Key'], startsWith('inv-'));
      expect(toast('Moved 12 pc to Shelf A-01.'), findsOneWidget);
    });

    testWidgets('a business with one store is told so on "To another store"', (t) async {
      final f = Fake((fn, b) => null);
      await tall(t, MoveStockScreen(env: f.env, itemId: 'it-pg'));
      await tap(t, find.text('To another store'));
      expect(find.text('Only one store'), findsOneWidget);
    });
  });

}
