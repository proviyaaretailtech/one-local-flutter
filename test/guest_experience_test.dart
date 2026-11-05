import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/guest/guest_api.dart';
import 'package:vinii_pos/guest/guest_app.dart';
import 'package:vinii_pos/guest_web_main.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

// The restaurant's own guest page (specs/guest-experience-builder): its look and blocks, the brand page (onelocal.co/<store link>) with
// dine-in and pre-order, and the pre-order's tracking. Shapes as the database answers them (0656: gx__public_def, gx_preorder_*).

const _bakery = {
  'background': '#F6F1EA',
  'surface': '#FFFFFF',
  'text': '#2B1D14',
  'muted': '#8A7766',
  'accent': '#2B1D14',
  'accent_text': '#FFFFFF',
  'font': 'serif',
};

const _order = ['welcome', 'order_mode', 'budget', 'categories', 'swipe', 'highlights', 'preorder', 'tracking', 'bill'];

Map<String, dynamic> _props(String type) => switch (type) {
  'welcome' => {'headline': 'Good food rises people together', 'subtext': 'Fresh bakes, honest ingredients.', 'image_id': null, 'cta_label': 'Order now'},
  'order_mode' => {'dine_in': true, 'pre_order': true, 'dine_in_label': 'Dine-in', 'pre_order_label': 'Pre-Order'},
  'budget' => {'min': 500, 'max': 20000, 'default': 2000, 'split': true},
  'categories' => {'style': 'grid'},
  'swipe' => {'card_style': 'stack', 'budget_ring': true},
  'highlights' => {
    'picks_title': "Chef's picks",
    'pick_ids': ['i1', 'i3'],
    'limited_title': 'Limited today',
    'limited_ids': ['i2'],
    'limited_until': '16:30',
  },
  'preorder' => {'days_ahead': 3, 'slot_minutes': 30, 'opens': '09:00', 'closes': '21:00', 'lead_minutes': 30, 'note_hint': 'e.g. pack separately'},
  'tracking' => {'show_eta': true},
  'bill' => {'split': true, 'feedback': true},
  _ => <String, dynamic>{},
};

/// A published page: every block in [order] (switched on unless in [off]), with [props] laid over the defaults.
Map<String, dynamic> page({
  Map<String, dynamic> theme = _bakery,
  List<String> order = _order,
  Set<String> off = const {},
  Map<String, Map<String, dynamic>> props = const {},
}) => {
  'look': theme == _bakery ? 'bakery_warm' : 'custom',
  'theme': theme,
  'blocks': [
    for (final t in order) {'id': t, 'type': t, 'enabled': !off.contains(t), 'props': {..._props(t), ...?props[t]}},
  ],
  'welcome_image_url': null,
  'is_default': false,
};

Map<String, dynamic> visit({Map<String, dynamic>? experience, bool table = true}) => {
  if (table) 'session': 'ab' * 32,
  'business': {'name': 'The Windough Bakery'},
  'outlet': {'name': 'Indiranagar'},
  'table': table ? {'label': '12', 'area_name': null, 'seats': 4} : null,
  'menu': {
    'brand': {'name': 'The Windough', 'accent': '#76EC00', 'table_word': 'Table'},
    'categories': [
      {'id': 'c1', 'name': 'Breads'},
      {'id': 'c2', 'name': 'Drinks'},
    ],
    'items': [
      {'id': 'i1', 'name': 'Cinnamon Scroll', 'price': 220, 'food_type': 'veg', 'is_recommended': true, 'prep_minutes': 5, 'category_id': 'c1', 'tags': []},
      {'id': 'i2', 'name': 'Sourdough Loaf', 'price': 320, 'food_type': 'veg', 'prep_minutes': 5, 'category_id': 'c1', 'tags': []},
      {'id': 'i3', 'name': 'Iced Latte', 'price': 240, 'food_type': 'veg', 'prep_minutes': 3, 'category_id': 'c2', 'tags': []},
    ],
    'experience': ?experience,
  },
};

/// A table QR visit with the restaurant's page.
class TableDoor implements GuestGateway {
  TableDoor(this.experience);
  final Map<String, dynamic>? experience;
  final sent = <List<Map<String, dynamic>>>[];
  List<Facts> requests = [];
  GuestBill? billToShow;

  @override
  bool get waitsForStaff => true;
  @override
  Future<GuestVisit> open() async => GuestVisit(Facts(visit(experience: experience)));
  @override
  Future<GuestMenu> menu() async => (await open()).menu;
  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) async {
    sent.add([for (final l in lines) l.toJson()]);
    final r = Facts({'id': 'r1', 'status': 'waiting', 'lines': [for (final l in lines) {'name': l.item.name, 'qty': l.qty}], 'order': null});
    requests = [r];
    return r;
  }

  @override
  Future<List<Facts>> status() async => requests;
  @override
  Future<GuestBill?> bill() async => billToShow;
  @override
  Future<void> feedback(int rating, {String? comment}) async {}
}

/// The brand page's menu (no table), over the real door with a fake network.
MenuCardGateway brandDoor(Map<String, dynamic>? experience) =>
    MenuCardGateway(slug: 'windough', baseUrl: 'https://pos.test', client: MockClient((r) async => _ok(visit(experience: experience, table: false))));

const _token = 'abababababababababababababababababab';
const _thu930 = '2026-11-05T04:00:00+00:00'; // 9:30 AM in Asia/Kolkata

Map<String, dynamic> preRequest(String status, {String? reason, Map<String, dynamic>? order}) => {
  'id': 'p1',
  'status': status,
  'created_at': '2026-11-04T10:00:00Z',
  'decided_at': null,
  'lines': [
    {'name': 'Cinnamon Scroll', 'qty': 2},
  ],
  'item_count': 2,
  'estimated_total': 440,
  'note': null,
  'decline_reason': reason,
  'order': order,
  'kind': 'preorder',
  'pickup_at': _thu930,
};

class FakePreorders implements PreorderDoor {
  final placed = <({List<Map<String, dynamic>> lines, String name, String phone, String pickupAt, String? note, String key})>[];
  GuestApiException? failPlace;
  Map<String, dynamic> now = preRequest('waiting');
  final tracked = <String>[];

  @override
  Future<PreorderSlots> slots() async => PreorderSlots(const Facts({
    'timezone': 'Asia/Kolkata',
    'slot_minutes': 30,
    'note_hint': 'e.g. pack separately',
    'days': [
      {
        'date': '2026-11-04',
        'slots': ['2026-11-04T12:30:00+00:00', '2026-11-04T13:00:00+00:00'],
      },
      {
        'date': '2026-11-05',
        'slots': ['2026-11-05T03:30:00+00:00', _thu930],
      },
    ],
  }));

  @override
  Future<Facts> place(List<GuestLine> lines, {required String name, required String phone, required String pickupAt, String? note, required String key}) async {
    if (failPlace != null) throw failPlace!;
    placed.add((lines: [for (final l in lines) l.toJson()], name: name, phone: phone, pickupAt: pickupAt, note: note, key: key));
    return Facts({...preRequest('waiting'), 'replayed': false, 'track': _token});
  }

  @override
  Future<Facts> track(String token) async {
    tracked.add(token);
    return Facts(now);
  }
}

class _BadTrack extends FakePreorders {
  @override
  Future<Facts> track(String token) async => throw const GuestApiException(404, 'This tracking link is not valid.', 'not_found');
}

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> showApp(WidgetTester t, GuestGateway g, {PreorderDoor? preorders, String? track, ValueChanged<String>? onTrackLink}) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(800, 1700);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: GuestApp(key: UniqueKey(), gateway: g, preorders: preorders, track: track, onTrackLink: onTrackLink, pollEvery: const Duration(seconds: 5)),
  ));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  group('the restaurant page', () {
    testWidgets("the bakery's light background, serif headline and own wording are applied", (t) async {
      await showApp(t, TableDoor(page()));
      expect(t.widget<Scaffold>(find.byKey(const ValueKey('guest-app'))).backgroundColor, const Color(0xFFF6F1EA));
      final ctx = t.element(find.byKey(const ValueKey('guest-headline')));
      expect(Theme.of(ctx).colorScheme.brightness, Brightness.light);
      final head = (t.widget<Text>(find.byKey(const ValueKey('guest-headline'))).textSpan! as TextSpan).children!.first as TextSpan;
      expect(head.style!.fontFamily, 'serif');
      expect(head.style!.color, const Color(0xFF2B1D14), reason: 'no photo: the page text colour on the page background');
      expect(find.text('Fresh bakes, honest ingredients.'), findsOneWidget);
      expect(find.text('Order now'), findsOneWidget);
      expect(find.text('Table 12'), findsOneWidget);
    });

    testWidgets('an older server with no page keeps neon on black', (t) async {
      await showApp(t, TableDoor(null));
      expect(t.widget<Scaffold>(find.byKey(const ValueKey('guest-app'))).backgroundColor, const Color(0xFF0A0A0A));
      expect(find.text('Start exploring'), findsOneWidget);
    });

    testWidgets('switched-off budget and categories are skipped: the welcome opens the deck, Back returns to it', (t) async {
      await showApp(t, TableDoor(page(off: {'budget', 'categories'})));
      await tap(t, 'guest-start');
      expect(find.byKey(const ValueKey('order-mode')), findsNothing, reason: 'a table QR orders at the table: no pre-order there');
      expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
      await tap(t, 'menu-back');
      expect(find.byKey(const ValueKey('guest-start')), findsOneWidget);
    });

    testWidgets("the screens follow the restaurant's order, and the budget its range and default", (t) async {
      await showApp(t, TableDoor(page(order: ['welcome', 'order_mode', 'categories', 'budget', 'swipe', 'tracking', 'bill'], props: {'budget': {'min': 1000, 'max': 5000, 'default': 1500, 'split': false}})));
      await tap(t, 'guest-start');
      expect(find.byKey(const ValueKey('mood-all')), findsOneWidget);
      await tap(t, 'mood-all');
      expect(t.widget<Text>(find.byKey(const ValueKey('budget-amount'))).data, '₹1,500');
      expect(find.byKey(const ValueKey('budget-split')), findsNothing);
      await t.drag(find.byKey(const ValueKey('budget-slider')), const Offset(-2000, 0));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('budget-amount'))).data, '₹1,000');
      await tap(t, 'budget-save');
      expect(find.byKey(const ValueKey('budget-ring')), findsOneWidget);
      expect(find.text('₹0 / ₹1,000'), findsOneWidget);
    });

    testWidgets('the full card style shows one dish edge to edge; no budget ring when the swipe block hides it', (t) async {
      await showApp(t, TableDoor(page(props: {'swipe': {'card_style': 'full', 'budget_ring': false}})));
      await tap(t, 'guest-start');
      await tap(t, 'budget-save');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('deck-full')), findsOneWidget);
      expect(find.byKey(const ValueKey('budget-ring')), findsNothing);
      await tap(t, 'deck-add');
      expect(find.text('1 dish · ₹220'), findsOneWidget);
    });

    testWidgets("highlights: chef's picks and limited today lead the list; their chip narrows the deck", (t) async {
      await showApp(t, TableDoor(page(props: {'highlights': {'pick_ids': ['i1', 'gone'], 'limited_ids': ['i3']}})));
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      await tap(t, 'mode-list');
      expect(find.byKey(const ValueKey('highlights-picks')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-i1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-gone')), findsNothing, reason: 'a dish off the menu is left out');
      expect(find.byKey(const ValueKey('highlights-limited')), findsOneWidget);
      expect(find.byKey(const ValueKey('limited-i3')), findsOneWidget);
      expect(find.text('Ends at 16:30'), findsOneWidget);
      await tap(t, 'mode-swipe');
      await tap(t, 'cat-picks');
      expect(t.widget<Text>(find.byKey(const ValueKey('deck-name'))).data, 'Cinnamon Scroll');
      await tap(t, 'deck-skip');
      expect(t.widget<Text>(find.byKey(const ValueKey('deck-name'))).data, 'Iced Latte', reason: 'the deck holds the picks and the limited dish only');
    });

    testWidgets('tracking without the estimate; the bill with the split and no feedback', (t) async {
      final g = TableDoor(page(props: {'tracking': {'show_eta': false}, 'bill': {'split': true, 'feedback': false}}));
      await showApp(t, g);
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      await tap(t, 'deck-add');
      await tap(t, 'cart-bar');
      await tap(t, 'order-continue');
      await tap(t, 'send-order');
      await t.pump(const Duration(milliseconds: 800));
      g.requests = [
        Facts({
          'id': 'r1',
          'status': 'accepted',
          'lines': [
            {'name': 'Cinnamon Scroll', 'qty': 1},
          ],
          'order': {
            'display_no': 'P-00031',
            'status': 'sent_to_kitchen',
            'status_label': 'Being prepared',
            'track': {
              'stage': 'in_kitchen',
              'minutes_left': 12,
              'estimate_minutes': 15,
              'steps': [
                {'key': 'confirmed', 'done': true, 'at': '2026-11-04T10:00:00Z'},
                {'key': 'in_kitchen', 'done': true, 'at': '2026-11-04T10:02:00Z'},
                {'key': 'ready', 'done': false, 'at': null},
                {'key': 'served', 'done': false, 'at': null},
              ],
            },
          },
        }),
      ];
      g.billToShow = GuestBill(Facts({
        'orders': [
          {
            'items': [
              {'name': 'Cinnamon Scroll', 'qty': 1, 'line_total': 220},
            ],
          },
        ],
        'subtotal': 220,
        'gst_amount': 11,
        'total': 231,
        'paid': 0,
        'due': 231,
        'bill_ready': false,
        'feedback': null,
      }));
      await tap(t, 'order-more');
      await tap(t, 'menu-orders');
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byKey(const ValueKey('track')), findsOneWidget);
      expect(find.byKey(const ValueKey('track-eta')), findsNothing);
      await tap(t, 'view-bill');
      expect(find.byKey(const ValueKey('bill-split')), findsOneWidget);
      expect(find.text('₹115.50 each for 2'), findsOneWidget);
      await tap(t, 'bill-split-plus');
      expect(find.text('₹77 each for 3'), findsOneWidget);
      expect(find.text('How was your experience?'), findsNothing);
    });
  });

  group('the brand page (no table)', () {
    testWidgets('both ways in with the restaurant\'s labels; dine-in asks to scan the table\'s code, then the menu can be read', (t) async {
      await showApp(t, brandDoor(page()), preorders: FakePreorders());
      expect(find.byKey(const ValueKey('guest-table')), findsNothing);
      await tap(t, 'guest-start');
      expect(find.byKey(const ValueKey('order-mode')), findsOneWidget);
      expect(find.text('How would you like to enjoy The Windough?'), findsOneWidget);
      expect(find.text('Dine-in'), findsOneWidget);
      expect(find.text('Pre-Order'), findsOneWidget);
      await tap(t, 'mode-dine-in');
      expect(find.byKey(const ValueKey('brand-scan-qr')), findsOneWidget);
      expect(find.text('Scan the QR code on your table to order'), findsOneWidget);
      await tap(t, 'scan-browse');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('deck-skip')), findsNothing, reason: 'reading only: nothing to add');
      expect(find.byKey(const ValueKey('browse-scan-note')), findsOneWidget);
      await tap(t, 'deck-add');
      expect(find.byKey(const ValueKey('cart-bar')), findsNothing);
    });

    testWidgets('a page that offers dine-in only goes from the welcome to "scan the QR code"', (t) async {
      await showApp(t, brandDoor(page(props: {'order_mode': {'pre_order': false}})), preorders: FakePreorders());
      await tap(t, 'guest-start');
      expect(find.byKey(const ValueKey('order-mode')), findsNothing);
      expect(find.byKey(const ValueKey('brand-scan-qr')), findsOneWidget);
    });

    testWidgets('pre-order: day and time, dishes, name and mobile, sent; the tracking follows the restaurant', (t) async {
      final pre = FakePreorders()..failPlace = const GuestApiException(429, 'You already have pre-orders waiting for the restaurant. They will confirm shortly.', 'rate_limited');
      final links = <String>[];
      await showApp(t, brandDoor(page()), preorders: pre, onTrackLink: links.add);
      await tap(t, 'guest-start');
      await tap(t, 'mode-pre-order');
      expect(find.text('Select date & time'), findsOneWidget);
      expect(find.byKey(const ValueKey('pre-day-2026-11-04')), findsOneWidget);
      expect(t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('pre-slot-2026-11-04T12:30:00+00:00')), matching: find.byType(Text))).data, '6:00 PM');
      await tap(t, 'pre-day-2026-11-05');
      await tap(t, 'pre-slot-$_thu930');
      expect(find.text('Pickup Thu, 5 Nov · 9:30 AM'), findsOneWidget);
      await tap(t, 'pre-slot-continue');
      await tap(t, 'mood-all');
      expect(t.widget<Text>(find.byKey(const ValueKey('menu-subtitle'))).data, 'Pickup Thu, 5 Nov · 9:30 AM');
      await tap(t, 'deck-add');
      await tap(t, 'cart-bar');
      await tap(t, 'plus-i1');
      await tap(t, 'order-continue');
      expect(find.byKey(const ValueKey('pre-review')), findsOneWidget);
      expect(find.text('Thu, 5 Nov · 9:30 AM'), findsOneWidget);
      await tap(t, 'pre-send');
      expect(find.text('Enter your name so the restaurant knows whose order it is.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('pre-name')), 'Asha');
      await t.enterText(find.byKey(const ValueKey('pre-phone')), '12345');
      await tap(t, 'pre-send');
      expect(find.text('Enter a 10-digit mobile number.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('pre-phone')), '+91 98765 43210');
      await t.enterText(find.byKey(const ValueKey('pre-note')), 'birthday box');
      await tap(t, 'pre-send');
      expect(find.text('You already have pre-orders waiting for the restaurant. They will confirm shortly.'), findsOneWidget);
      pre.failPlace = null;
      await tap(t, 'pre-send');
      expect(pre.placed, hasLength(1));
      final p = pre.placed.single;
      expect(p.lines, [
        {'menu_item_id': 'i1', 'qty': 2},
      ]);
      expect((p.name, p.phone, p.pickupAt, p.note), ('Asha', '9876543210', _thu930, 'birthday box'));
      expect(RegExp(r'^[A-Za-z0-9_:.-]{8,100}$').hasMatch(p.key), isTrue);
      expect(find.byKey(const ValueKey('pre-sent')), findsOneWidget);
      expect(find.text('Pre-order sent'), findsOneWidget);
      expect(find.text('Waiting for the restaurant to confirm'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('pre-sent-pickup'))).data, 'Thu, 5 Nov · 9:30 AM');
      expect(t.widget<Text>(find.byKey(const ValueKey('pre-sent-total'))).data, '₹440');
      expect(find.text('2 × Cinnamon Scroll'), findsOneWidget);
      expect(links, [_token], reason: 'the tracking token goes into the page address');
      pre.now = preRequest('accepted', order: {
        'display_no': 'P-00012',
        'status': 'sent_to_kitchen',
        'total': 440,
        'status_label': 'Being prepared',
        'track': {
          'stage': 'in_kitchen',
          'minutes_left': 9,
          'estimate_minutes': 10,
          'steps': [
            {'key': 'confirmed', 'done': true, 'at': '2026-11-05T03:40:00Z'},
            {'key': 'in_kitchen', 'done': true, 'at': '2026-11-05T03:45:00Z'},
            {'key': 'ready', 'done': false, 'at': null},
            {'key': 'served', 'done': false, 'at': null},
          ],
        },
      });
      await t.pump(const Duration(seconds: 6));
      await t.pump();
      expect(pre.tracked, [_token]);
      expect(find.text('Pre-order confirmed'), findsOneWidget);
      expect(find.text('P-00012 · Being prepared'), findsOneWidget);
      expect(find.text('In the kitchen'), findsOneWidget);
      expect(find.text('Estimated serving time: about 9 min'), findsOneWidget);
    });

    testWidgets('the tracking link (?track=) opens the pre-order; a declined one shows the reason', (t) async {
      final pre = FakePreorders()..now = preRequest('declined', reason: 'We are closed that morning');
      ignoreOverflow();
      t.view.physicalSize = const Size(800, 1700);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(GuestWebPage(code: null, slug: 'windough', track: _token, gateway: brandDoor(page()), preorders: pre));
      await t.pumpAndSettle();
      expect(pre.tracked, [_token]);
      expect(find.text('Pre-order not accepted'), findsOneWidget);
      expect(find.text('We are closed that morning'), findsOneWidget);
      await tap(t, 'pre-again');
      expect(find.byKey(const ValueKey('guest-start')), findsOneWidget, reason: 'back to the start of the brand page');
    });

    testWidgets('a tracking link that does not open says so and offers the menu', (t) async {
      final pre = _BadTrack();
      await showApp(t, brandDoor(page()), preorders: pre, track: _token);
      expect(find.text('This tracking link is not valid.'), findsOneWidget);
      await tap(t, 'guest-retry');
      expect(find.byKey(const ValueKey('guest-start')), findsOneWidget);
    });
  });

  group('the address and the pre-order door', () {
    test('the page finds the store link, the table code and the tracking token in its address', () {
      final code = 'cd' * 32;
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/niks-cafe')), 'niks-cafe');
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/Niks-Cafe/')), 'niks-cafe');
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/r/niks-cafe')), 'niks-cafe');
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/m/niks-cafe')), 'niks-cafe');
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/niks-cafe#/')), 'niks-cafe');
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/t/$code')), isNull);
      expect(tableCodeFrom(Uri.parse('https://onelocal.co/t/$code')), code);
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/t/')), isNull);
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/privacy')), isNull, reason: "OneLocal's own pages are never a store link");
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/index.html')), isNull);
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/')), isNull);
      final tracked = Uri.parse('https://onelocal.co/niks-cafe?track=$_token');
      expect(menuSlugFrom(tracked), 'niks-cafe');
      expect(trackFrom(tracked), _token);
      expect(trackFrom(Uri.parse('https://onelocal.co/niks-cafe?track=nope')), isNull);
      expect(trackFrom(Uri.parse('https://onelocal.co/niks-cafe')), isNull);
    });

    test('slots, pre-order and tracking go through the guest door with the store link; errors keep the server sentence', () async {
      final calls = <http.Request>[];
      final door = PreorderGateway(
        slug: 'niks-cafe',
        baseUrl: 'https://pos.test/',
        client: MockClient((r) async {
          calls.add(r);
          return switch (r.url.path) {
            '/guest/slots' => _ok({'timezone': 'Asia/Kolkata', 'slot_minutes': 30, 'note_hint': ' ', 'days': [{'date': '2026-11-05', 'slots': [_thu930]}]}),
            '/guest/preorder' => _ok({...preRequest('waiting'), 'track': _token}),
            '/guest/pretrack' => http.Response(jsonEncode({'detail': 'this tracking link is not valid.'}), 404),
            _ => http.Response('{}', 404),
          };
        }),
      );
      final s = await door.slots();
      expect((s.timezone, s.slotMinutes, s.noteHint), ('Asia/Kolkata', 30, null));
      expect(s.days.single.slots, [_thu930]);
      expect(jsonDecode(calls[0].body), {'slug': 'niks-cafe'});
      final menu = GuestMenu(Facts(visit()['menu'] as Map<String, dynamic>));
      final r = await door.place([GuestLine(menu.byId('i3')!, 1)], name: ' Asha ', phone: '9876543210', pickupAt: _thu930, note: '', key: 'g-0123456789abcdef');
      expect(r.s('track'), _token);
      expect(jsonDecode(calls[1].body), {
        'slug': 'niks-cafe',
        'idempotency_key': 'g-0123456789abcdef',
        'lines': [
          {'menu_item_id': 'i3', 'qty': 1},
        ],
        'guest_name': 'Asha',
        'phone': '9876543210',
        'pickup_at': _thu930,
      });
      await expectLater(door.track(_token), throwsA(isA<GuestApiException>().having((e) => e.message, 'message', 'this tracking link is not valid.')));
      expect(jsonDecode(calls[2].body), {'track': _token});
    });

    test('the page reads its look and blocks; a switched-off block has no settings', () {
      final e = GuestMenu(Facts(visit(experience: page(off: {'budget'}))['menu'] as Map<String, dynamic>)).experience!;
      expect(e.theme.dark, isFalse);
      expect(e.theme.serif, isTrue);
      expect(e.on('budget'), isFalse);
      expect(e.props('budget').raw, isEmpty);
      expect(e.props('welcome').s('cta_label'), 'Order now');
      expect(GuestMenu(Facts(visit()['menu'] as Map<String, dynamic>)).experience, isNull);
      expect(guestWallTime(_thu930, 'Asia/Kolkata'), DateTime.utc(2026, 11, 5, 9, 30));
    });
  });
}
