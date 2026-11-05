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

// specs/guest-experience-builder/spec-part2-live-orders.md, contract C: the guest page orders through the customer server (contract A),
// follows the order's stages, asks for the bill, shows the live order feed (contract B), applies the restaurant's offers, and keeps the
// budget on the guest's own phone. Every door is a fake shaped like its contract.

const _track = '0123456789abcdef0123456789abcdef0123';
final _session = 'ab' * 32;
const _thu930 = '2026-11-05T04:00:00+00:00'; // 9:30 AM in Asia/Kolkata

const _bakery = {
  'background': '#F6F1EA',
  'surface': '#FFFFFF',
  'text': '#2B1D14',
  'muted': '#8A7766',
  'accent': '#2B1D14',
  'accent_text': '#FFFFFF',
  'font': 'serif',
};

Map<String, dynamic> _props(String type) => switch (type) {
  'welcome' => {'headline': 'Good food rises people together', 'subtext': 'Fresh bakes.', 'image_id': null, 'cta_label': 'Order now'},
  'order_mode' => {'dine_in': true, 'pre_order': true, 'dine_in_label': 'Dine-in', 'pre_order_label': 'Pre-Order'},
  'budget' => {'min': 500, 'max': 20000, 'default': 2000, 'split': true},
  'categories' => {'style': 'grid'},
  'swipe' => {'card_style': 'stack', 'budget_ring': true},
  'preorder' => {'days_ahead': 3, 'slot_minutes': 30, 'opens': '09:00', 'closes': '21:00', 'lead_minutes': 30, 'note_hint': ''},
  'tracking' => {'show_eta': true},
  'bill' => {'split': true, 'feedback': true},
  _ => <String, dynamic>{},
};

Map<String, dynamic> page({Set<String> off = const {}}) => {
  'look': 'bakery_warm',
  'theme': _bakery,
  'blocks': [
    for (final t in const ['welcome', 'order_mode', 'budget', 'categories', 'swipe', 'preorder', 'tracking', 'bill'])
      {'id': t, 'type': t, 'enabled': !off.contains(t), 'props': _props(t)},
  ],
  'welcome_image_url': null,
  'is_default': false,
};

const _offers = [
  {'id': 'of1', 'title': '10% off breakfast', 'code': 'BAKE10', 'kind': 'percent', 'value': 10, 'min_order': 500, 'ends_at': null},
  {'id': 'of2', 'title': '', 'code': 'FLAT50', 'kind': 'flat', 'value': 50, 'min_order': 0, 'ends_at': null},
  // a POS offer: no code, the restaurant takes it off on the bill
  {'id': 'of3', 'source': 'offer', 'title': 'Free cookie on big orders', 'code': null, 'kind': 'flat', 'value': 30, 'min_order': 300, 'max_discount': null, 'ends_at': null},
  {'id': 'bad', 'title': 'Buy one get one', 'code': 'BOGO', 'kind': 'bogo', 'value': 1, 'min_order': 0},
];

Map<String, dynamic> visit({Map<String, dynamic>? experience, bool table = true, bool offers = false}) => {
  if (table) 'session': _session,
  'business': {'name': 'The Windough Bakery', 'store_link': 'windough'},
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
    if (offers) 'offers': _offers,
  },
};

/// The table QR door (the POS guest door): open with a session; sending through it is the old way and must not happen here.
class TableDoor implements GuestGateway {
  TableDoor({this.experience, this.offers = false, this.waits = true});
  final Map<String, dynamic>? experience;
  final bool offers;
  final bool waits;
  int oldSends = 0;
  final feedbacks = <int>[];

  @override
  bool get waitsForStaff => waits;
  @override
  Future<GuestVisit> open() async => GuestVisit(Facts(visit(experience: experience, offers: offers)..remove(waits ? '' : 'session')));
  @override
  Future<GuestMenu> menu() async => (await open()).menu;
  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) async {
    oldSends++;
    return Facts({'id': 'r1', 'status': waits ? 'waiting' : 'accepted', 'lines': const [], 'order': waits ? null : {'display_no': 'P-00042'}});
  }

  @override
  Future<List<Facts>> status() async => const [];
  @override
  Future<GuestBill?> bill() async => null;
  @override
  Future<void> feedback(int rating, {String? comment}) async => feedbacks.add(rating);
}

/// The brand page (no table), over the real door with a fake network.
MenuCardGateway brandDoor({bool offers = false}) =>
    MenuCardGateway(slug: 'windough', baseUrl: 'https://pos.test', client: MockClient((r) async => _ok(visit(experience: page(), table: false, offers: offers))));

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

/// A web order's status (contract A).
Map<String, dynamic> webStatus(
  String stage, {
  String mode = 'dine_in',
  bool held = false,
  Map<String, dynamic>? paused,
  bool canBill = false,
  Map<String, dynamic>? bill,
  int? eta,
  String? reason,
}) => {
  'order_id': 'o1',
  'display_no': 'WD1234',
  'status': stage,
  'stage': stage,
  'stage_label': stage,
  'mode': mode,
  'table_label': mode == 'dine_in' ? '12' : null,
  'placed_at': '2026-11-05T06:44:00Z',
  'accepted_at': stage == 'waiting_partner' ? null : '2026-11-05T06:46:00Z',
  'eta_minutes': eta,
  'held': held,
  'restaurant_paused': paused,
  'lines': [
    {'name': 'Cinnamon Scroll', 'qty': 2, 'status': 'preparing'},
  ],
  'total': 440,
  'bill': bill,
  'can_request_bill': canBill,
  'decline_reason': ?reason,
};

const _bill = {
  'lines': [
    {'name': 'Cinnamon Scroll', 'qty': 2, 'line_total': 440},
  ],
  'subtotal': 440,
  'gst': 22,
  'service': 44,
  'total': 506,
  'paid': 0,
};

class FakeOrders implements WebOrderDoor {
  FakeOrders([Map<String, dynamic>? now]) : now = now ?? webStatus('waiting_partner');
  final placed = <({Map<String, dynamic> body, String key})>[];
  final keys = <String>[]; // every attempt, failed ones too
  GuestApiException? failPlace;
  GuestApiException? failStatus;
  Map<String, dynamic> now;
  Map<String, dynamic>? afterBill;
  final statusCalls = <String>[];
  int billCalls = 0;

  @override
  Future<WebOrder> place(WebOrderRequest order, {required String key}) async {
    keys.add(key);
    if (failPlace != null) throw failPlace!;
    placed.add((body: order.toJson(), key: key));
    return WebOrder(Facts({'order_id': 'o1', 'display_no': 'WD1234', 'status': 'waiting_partner', 'stage': 'waiting_partner', 'stage_label': 'Sent', 'mode': order.mode, 'table_label': '12', 'track': _track}));
  }

  @override
  Future<WebOrder> status(String track) async {
    statusCalls.add(track);
    if (failStatus != null) throw failStatus!;
    return WebOrder(Facts(now));
  }

  @override
  Future<WebOrder> bill(String track) async {
    billCalls++;
    if (afterBill != null) now = afterBill!;
    return WebOrder(Facts(now));
  }
}

class FakeFeed implements LiveFeedDoor {
  Map<String, dynamic> answer = const {'items': [], 'streaks': []};
  final slugs = <String>[];
  @override
  Future<GuestFeed> feed(String slug) async {
    slugs.add(slug);
    return GuestFeed(Facts(answer));
  }
}

class FakePreorders implements PreorderDoor {
  final tracked = <String>[];
  int oldPlaces = 0;
  @override
  Future<PreorderSlots> slots() async => PreorderSlots(const Facts({
    'timezone': 'Asia/Kolkata',
    'slot_minutes': 30,
    'days': [
      {
        'date': '2026-11-05',
        'slots': ['2026-11-05T03:30:00+00:00', _thu930],
      },
    ],
  }));
  @override
  Future<Facts> place(List<GuestLine> lines, {required String name, required String phone, required String pickupAt, String? note, required String key}) async {
    oldPlaces++;
    return const Facts({});
  }

  @override
  Future<Facts> track(String token) async {
    tracked.add(token);
    return const Facts({'id': 'p1', 'status': 'waiting', 'lines': [], 'estimated_total': 0, 'pickup_at': _thu930});
  }
}

Future<void> showApp(
  WidgetTester t,
  GuestGateway g, {
  WebOrderDoor? orders,
  LiveFeedDoor? feed,
  PreorderDoor? preorders,
  GuestPrefs? prefs,
  String? track,
  String? storeLink,
  ValueChanged<String>? onTrackLink,
}) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(800, 1700);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: GuestApp(
      key: UniqueKey(),
      gateway: g,
      orders: orders,
      feed: feed,
      preorders: preorders,
      prefs: prefs,
      track: track,
      storeLink: storeLink,
      onTrackLink: onTrackLink,
      pollEvery: const Duration(hours: 1),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

String _text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

/// "7:30 PM" for an ISO time on this machine's clock, as the page writes it.
String _clockOf(String iso) {
  final d = DateTime.parse(iso).toLocal();
  return '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// Table QR: welcome -> budget skipped -> all dishes -> add the first dish -> order -> review.
Future<void> toReview(WidgetTester t, {bool budget = false}) async {
  await tap(t, 'guest-start');
  await tap(t, budget ? 'budget-save' : 'budget-skip');
  await tap(t, 'mood-all');
  await tap(t, 'deck-add');
  await tap(t, 'cart-bar');
  await tap(t, 'order-continue');
}

void main() {
  group('the customer server door', () {
    test('an order goes to /api/web/orders with the device key and an Idempotency-Key; status and bill by the tracking token', () async {
      final calls = <http.Request>[];
      final prefs = MemoryGuestPrefs();
      final door = CustomerOrderGateway(
        baseUrl: 'http://localhost:8099/',
        prefs: prefs,
        client: MockClient((r) async {
          calls.add(r);
          return switch (r.url.path) {
            '/api/web/orders' => _ok({'order_id': 'o1', 'display_no': 'WD1234', 'status': 'waiting_partner', 'stage': 'waiting_partner', 'stage_label': 'Sent', 'mode': 'dine_in', 'table_label': '12', 'track': _track}),
            '/api/web/orders/status' => _ok(webStatus('preparing', eta: 12)),
            '/api/web/orders/bill' => http.Response(jsonEncode({'detail': 'Your bill can be made once every dish is served.', 'code': 'not_ready'}), 409),
            _ => http.Response('{}', 404),
          };
        }),
      );
      final menu = GuestMenu(Facts(visit()['menu'] as Map<String, dynamic>));
      final o = await door.place(
        WebOrderRequest(storeLink: 'windough', mode: 'dine_in', tableSession: _session, lines: [GuestLine(menu.byId('i1')!, 2, ' warm ')], guestName: ' Asha ', note: '', couponCode: 'FLAT50'),
        key: 'g-0123456789abcdef',
      );
      expect((o.track, o.displayNo, o.stage), (_track, 'WD1234', 'waiting_partner'));
      expect(calls[0].url.toString(), 'http://localhost:8099/api/web/orders');
      expect(calls[0].headers['Idempotency-Key'], 'g-0123456789abcdef');
      final key = calls[0].headers['x-customer-key']!;
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue, reason: '32 random bytes as hex');
      expect(jsonDecode(calls[0].body), {
        'store_link': 'windough',
        'mode': 'dine_in',
        'table_session': _session,
        'lines': [
          {'menu_item_id': 'i1', 'qty': 2, 'notes': 'warm'},
        ],
        'guest_name': 'Asha',
        'coupon_code': 'FLAT50',
      });
      final s = await door.status(_track);
      expect((s.shown, s.etaMinutes, s.lines.single.name), ('preparing', 12, 'Cinnamon Scroll'));
      expect(jsonDecode(calls[1].body), {'track': _track});
      expect(calls[1].headers['Idempotency-Key'], isNull);
      expect(calls[1].headers['x-customer-key'], key);
      await expectLater(
        door.bill(_track),
        throwsA(isA<GuestApiException>().having((e) => (e.message, e.code), 'error', ('Your bill can be made once every dish is served.', 'not_ready'))),
      );
      expect(calls[2].url.path, '/api/web/orders/bill');
      // the same browser keeps its key; another browser has its own
      expect(CustomerOrderGateway(baseUrl: 'http://x', prefs: prefs).deviceKey, key);
      expect(CustomerOrderGateway(baseUrl: 'http://x', prefs: MemoryGuestPrefs()).deviceKey, isNot(key));
    });

    test('a base that already ends in /api is not doubled; the device key is made once and a damaged one is replaced', () async {
      final urls = <String>[];
      final door = CustomerOrderGateway(baseUrl: 'https://onelocal.co/api', client: MockClient((r) async {
        urls.add(r.url.toString());
        return _ok(webStatus('ready'));
      }));
      await door.status(_track);
      expect(urls, ['https://onelocal.co/api/web/orders/status']);
      final prefs = MemoryGuestPrefs()..write('ol_customer_key', 'not-a-key');
      final k1 = guestDeviceKey(prefs);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(k1), isTrue);
      expect(guestDeviceKey(prefs), k1);
    });

    test('where the customer server is: the define, else localhost:8099 on this machine, else the page host with /api', () {
      expect(customerApiBaseFor(Uri.parse('http://localhost:8090/niks-cafe'), defined: false), 'http://localhost:8099');
      expect(customerApiBaseFor(Uri.parse('http://127.0.0.1:8090/t/${'cd' * 32}'), defined: false), 'http://localhost:8099');
      expect(customerApiBaseFor(Uri.parse('https://onelocal.co/niks-cafe'), defined: false), 'https://onelocal.co/api');
      expect(customerApiBaseFor(Uri.parse('file:///tmp/x'), defined: false), isNull);
      expect(customerApiBaseFor(Uri.parse('https://onelocal.co/niks-cafe'), defined: true, value: ''), isNull, reason: 'empty = the POS guest door as before');
      expect(customerApiBaseFor(Uri.parse('https://onelocal.co/niks-cafe'), defined: true, value: 'http://192.168.1.4:8099/'), 'http://192.168.1.4:8099');
    });

    test('the page address: table code, store link and tracking token parse as before; a table QR page keeps ?track= too', () {
      final code = 'cd' * 32;
      final table = Uri.parse('https://pos.test/t/$code?track=$_track');
      expect(tableCodeFrom(table), code);
      expect(trackFrom(table), _track);
      expect(menuSlugFrom(table), isNull);
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/niks-cafe?track=$_track')), 'niks-cafe');
      expect(trackFrom(Uri.parse('https://onelocal.co/niks-cafe?track=$_track')), _track);
      expect(menuSlugFrom(Uri.parse('https://onelocal.co/api')), isNull);
    });
  });

  group('ordering through the customer server', () {
    testWidgets('table QR: the order carries the QR session and the store link, never the budget; then "Waiting for the restaurant"', (t) async {
      final orders = FakeOrders();
      final g = TableDoor(experience: page());
      final links = <String>[];
      await showApp(t, g, orders: orders, onTrackLink: links.add);
      await toReview(t, budget: true);
      await t.enterText(find.byKey(const ValueKey('order-name')), 'Asha');
      await t.enterText(find.byKey(const ValueKey('order-note')), 'less sweet');
      await tap(t, 'send-order');
      expect(g.oldSends, 0, reason: 'not through the POS guest door any more');
      final p = orders.placed.single;
      expect(p.body, {
        'store_link': 'windough',
        'mode': 'dine_in',
        'table_session': _session,
        'lines': [
          {'menu_item_id': 'i1', 'qty': 1},
        ],
        'guest_name': 'Asha',
        'note': 'less sweet',
      });
      expect(jsonEncode(p.body).contains('budget'), isFalse);
      expect(RegExp(r'^[\w:.-]{8,200}$').hasMatch(p.key), isTrue);
      expect(links, [_track], reason: 'the tracking token goes into the page address');
      expect(find.byKey(const ValueKey('stage-screen')), findsOneWidget);
      expect(_text(t, 'stage-title'), 'Order sent');
      expect(_text(t, 'stage-line'), 'Waiting for the restaurant');
      expect(find.text('Your order #WD1234'), findsOneWidget);
      expect(_text(t, 'stage-where'), 'Table 12 · 2 items');
      expect(orders.statusCalls, [_track]);
      orders.now = webStatus('preparing', eta: 12);
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(orders.statusCalls, [_track, _track], reason: 'asked again about every 4 s');
      expect(_text(t, 'stage-title'), 'Preparing');
      await t.pump(const Duration(milliseconds: 800));
      await tap(t, 'order-more');
      expect(find.byKey(const ValueKey('deck-card')), findsOneWidget);
      await tap(t, 'menu-orders');
      expect(find.byKey(const ValueKey('stage-screen')), findsOneWidget);
    });

    testWidgets('a failed send keeps the order; the retry sends the same Idempotency-Key, a changed order a new one', (t) async {
      final orders = FakeOrders()..failPlace = const GuestApiException(503, 'The restaurant is not taking orders right now.', 'unavailable');
      await showApp(t, TableDoor(experience: page()), orders: orders);
      await toReview(t);
      await tap(t, 'send-order');
      expect(find.text('The restaurant is not taking orders right now.'), findsOneWidget);
      await tap(t, 'send-order');
      expect(orders.keys, hasLength(2));
      expect(orders.keys[1], orders.keys[0], reason: 'the same tap retried');
      await t.enterText(find.byKey(const ValueKey('order-note')), 'no sugar');
      orders.failPlace = null;
      await tap(t, 'send-order');
      expect(orders.keys[2], isNot(orders.keys[0]), reason: 'a changed order is a new tap');
      expect(orders.placed.single.key, orders.keys[2]);
      expect(find.byKey(const ValueKey('stage-screen')), findsOneWidget);
    });

    testWidgets('brand page pre-order: the pickup time from the slot picker, the name and the 10-digit phone; tracking shows the pickup', (t) async {
      final orders = FakeOrders(webStatus('waiting_partner', mode: 'pickup'));
      final pre = FakePreorders();
      await showApp(t, brandDoor(), orders: orders, preorders: pre, storeLink: 'windough');
      await tap(t, 'guest-start');
      await tap(t, 'mode-pre-order');
      await tap(t, 'pre-slot-$_thu930');
      await tap(t, 'pre-slot-continue');
      await tap(t, 'mood-all');
      await tap(t, 'deck-add');
      await tap(t, 'cart-bar');
      await tap(t, 'order-continue');
      await t.enterText(find.byKey(const ValueKey('pre-name')), 'Asha');
      await t.enterText(find.byKey(const ValueKey('pre-phone')), '+91 98765 43210');
      await tap(t, 'pre-send');
      expect(pre.oldPlaces, 0);
      expect(orders.placed.single.body, {
        'store_link': 'windough',
        'mode': 'pickup',
        'pickup_at': _thu930,
        'lines': [
          {'menu_item_id': 'i1', 'qty': 1},
        ],
        'guest_name': 'Asha',
        'phone': '9876543210',
      });
      expect(_text(t, 'stage-where'), 'Pickup Thu, 5 Nov · 9:30 AM · 2 items');
      expect(_text(t, 'stage-line'), 'Waiting for the restaurant');
    });

    testWidgets('a reload with ?track= reopens the order; an older pre-order link still opens its pre-order', (t) async {
      final orders = FakeOrders(webStatus('ready'));
      await showApp(t, TableDoor(experience: page()), orders: orders, track: _track);
      expect(orders.statusCalls, [_track]);
      expect(_text(t, 'stage-title'), 'Ready');
      expect(_text(t, 'stage-line'), 'Your order is ready and on its way to your table.');

      final pre = FakePreorders();
      final missing = FakeOrders()..failStatus = const GuestApiException(404, 'This order link is not valid.', 'not_found');
      ignoreOverflow();
      await t.pumpWidget(GuestWebPage(code: null, slug: 'windough', track: _track, gateway: brandDoor(), preorders: pre, orders: missing));
      await t.pumpAndSettle();
      expect(missing.statusCalls, [_track]);
      expect(pre.tracked, [_track]);
      expect(find.byKey(const ValueKey('pre-sent')), findsOneWidget);
    });
  });

  group('the stage screens', () {
    final backAt = '2026-11-05T14:00:00Z';
    final cases = <(String, Map<String, dynamic>, String, String)>[
      ('sent', webStatus('waiting_partner'), 'Order sent', 'Waiting for the restaurant'),
      ('accepted', webStatus('accepted', eta: 15), 'Accepted', 'The restaurant has accepted your order.'),
      ('preparing', webStatus('preparing', eta: 9), 'Preparing', 'The kitchen is preparing your order.'),
      ('on hold', webStatus('on_hold'), 'On hold', 'The kitchen has put your order on hold'),
      ('held while preparing', webStatus('preparing', held: true), 'On hold', 'The kitchen has put your order on hold'),
      ('restaurant paused', webStatus('accepted', paused: {'reason': 'The kitchen is very busy', 'back_at': backAt}), 'Restaurant paused', 'The kitchen is very busy'),
      ('restaurant paused, reason code', webStatus('waiting_partner', paused: {'reason': 'auto_missed', 'back_at': null}), 'Restaurant paused', 'The restaurant has paused orders for a little while. Your order waits for them.'),
      ('ready', webStatus('ready'), 'Ready', 'Your order is ready and on its way to your table.'),
      ('served', webStatus('served'), 'Served', 'Hope you enjoy your meal.'),
      ('bill ready', webStatus('bill_ready', bill: _bill), 'Bill ready', 'Your bill is ready. A member of staff will take the payment at your table.'),
      ('paid', webStatus('paid', bill: {..._bill, 'paid': 506}), 'Paid', 'Thank you! See you again soon.'),
      ('declined', webStatus('declined', reason: 'We ran out of Cinnamon Scrolls'), 'Declined', 'We ran out of Cinnamon Scrolls'),
      ('cancelled', webStatus('cancelled'), 'Cancelled', 'This order was cancelled.'),
    ];
    for (final (name, now, title, line) in cases) {
      testWidgets('$name: "$title"', (t) async {
        await showApp(t, TableDoor(experience: page()), orders: FakeOrders(now), track: _track);
        expect(_text(t, 'stage-title'), title);
        expect(_text(t, 'stage-line'), line);
        final stage = now['stage'] as String;
        expect(find.byKey(const ValueKey('stage-eta')), now['eta_minutes'] != null ? findsOneWidget : findsNothing);
        if (now['eta_minutes'] != null) expect(find.text('About ${now['eta_minutes']} min'), findsOneWidget);
        if ((now['restaurant_paused'] as Map?)?['back_at'] != null) expect(_text(t, 'stage-back-at'), 'Back at ${_clockOf(backAt)}');
        expect(find.byKey(const ValueKey('stage-timeline')), const {'declined', 'cancelled'}.contains(stage) ? findsNothing : findsOneWidget);
        expect(find.byKey(const ValueKey('view-bill')), now['bill'] != null ? findsOneWidget : findsNothing);
        expect(find.text('2 × Cinnamon Scroll'), findsOneWidget);
      });
    }

    testWidgets('the page stops asking once the order is paid', (t) async {
      final orders = FakeOrders(webStatus('served'));
      await showApp(t, TableDoor(experience: page()), orders: orders, track: _track);
      await t.pump(const Duration(seconds: 4));
      expect(orders.statusCalls, hasLength(2));
      orders.now = webStatus('paid', bill: {..._bill, 'paid': 506});
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(_text(t, 'stage-title'), 'Paid');
      await t.pump(const Duration(seconds: 12));
      expect(orders.statusCalls, hasLength(3));
    });

    testWidgets('a missed check says so and keeps trying', (t) async {
      final orders = FakeOrders(webStatus('preparing'));
      await showApp(t, TableDoor(experience: page()), orders: orders, track: _track);
      orders.failStatus = const GuestApiException(0, 'No connection. Check your internet and try again.', 'offline');
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('stage-offline')), findsOneWidget);
      orders.failStatus = null;
      orders.now = webStatus('ready');
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('stage-offline')), findsNothing);
      expect(_text(t, 'stage-title'), 'Ready');
    });
  });

  group('the bill', () {
    testWidgets('"Get the bill" asks for it; the bill shows its lines, GST, service, total and the split; then it is paid', (t) async {
      final orders = FakeOrders(webStatus('served', canBill: true))..afterBill = webStatus('bill_ready', bill: _bill);
      final g = TableDoor(experience: page());
      await showApp(t, g, orders: orders, track: _track);
      expect(find.byKey(const ValueKey('view-bill')), findsNothing);
      await t.pump(const Duration(milliseconds: 800));
      await tap(t, 'get-bill');
      expect(orders.billCalls, 1);
      expect(find.byKey(const ValueKey('bill-screen')), findsOneWidget);
      expect(_text(t, 'bill-where'), 'Table 12 · Order #WD1234');
      expect(find.text('Cinnamon Scroll'), findsOneWidget);
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('GST'), findsOneWidget);
      expect(find.text('₹22'), findsOneWidget);
      expect(find.text('Service charge'), findsOneWidget);
      expect(find.text('₹44'), findsOneWidget);
      expect(_text(t, 'bill-total'), '₹506');
      expect(find.byKey(const ValueKey('bill-split')), findsOneWidget);
      expect(find.text('₹253 each for 2'), findsOneWidget);
      await tap(t, 'bill-split-plus');
      expect(find.text('₹168.67 each for 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-pay')), findsOneWidget);
      orders.now = webStatus('paid', bill: {..._bill, 'paid': 506});
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('bill-paid')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-pay')), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('rate-5')));
      await t.tap(find.byKey(const ValueKey('rate-5')));
      await t.pumpAndSettle();
      await tap(t, 'feedback-send');
      expect(g.feedbacks, [5], reason: 'feedback still goes with the table visit');
      await tap(t, 'back');
      expect(_text(t, 'stage-title'), 'Paid');
    });

    testWidgets('a bill asked for too early says when it can be made', (t) async {
      final orders = FakeOrders(webStatus('preparing', canBill: true));
      await showApp(t, TableDoor(experience: page()), orders: orders, track: _track);
      await t.pump(const Duration(milliseconds: 800));
      await tap(t, 'get-bill');
      expect(find.byKey(const ValueKey('bill-screen')), findsNothing);
      expect(_text(t, 'bill-note'), 'Your bill can be made once every dish is ready or served.');
    });
  });

  group('Live mode', () {
    Map<String, dynamic> item(String name, int qty, String? table, int ago, [String category = 'Mains']) => {'name': name, 'qty': qty, 'table_label': table, 'seconds_ago': ago, 'category': category};

    testWidgets('each new order is a short toast, one after another; a trending dish gets the fire banner; nothing from before opening', (t) async {
      final feed = FakeFeed()
        ..answer = {
          'items': [item('Masala Chai', 1, '4', 30)],
          'streaks': [],
        };
      await showApp(t, TableDoor(experience: page()), orders: FakeOrders(), feed: feed);
      expect(feed.slugs, ['windough'], reason: 'the table QR page names its restaurant by the store link of its visit');
      expect(find.byKey(const ValueKey('live-toast')), findsNothing, reason: 'what was ordered before the page opened does not pop up');
      feed.answer = {
        'items': [item('Cold Coffee', 2, null, 1, 'Drinks'), item('Butter Chicken', 1, '10', 3), item('Masala Chai', 1, '4', 36)],
        'streaks': [
          {'label': 'Cold Coffee', 'count': 3, 'kind': 'dish'},
        ],
      };
      await t.pump(const Duration(seconds: 6));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(feed.slugs, hasLength(2));
      expect(find.text('1 Butter Chicken ordered on Table 10'), findsOneWidget);
      expect(find.text('2 Cold Coffee just ordered'), findsNothing, reason: 'one toast at a time');
      expect(find.text('3 tables ordered Cold Coffee'), findsOneWidget);
      expect(find.byKey(const ValueKey('live-streak')), findsOneWidget);
      expect(find.textContaining('Masala Chai'), findsNothing);
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('1 Butter Chicken ordered on Table 10'), findsNothing);
      expect(find.text('2 Cold Coffee just ordered'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-toast')), findsNothing);
      expect(find.byKey(const ValueKey('live-streak')), findsNothing, reason: 'the banner shows briefly');
      expect(find.textContaining('₹'), findsNothing, reason: 'no amounts');
    });

    testWidgets('the Live mode switch in the menu header turns it off, and the choice is kept', (t) async {
      final feed = FakeFeed();
      final prefs = MemoryGuestPrefs();
      await showApp(t, TableDoor(experience: page()), orders: FakeOrders(), feed: feed, prefs: prefs);
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      final semantics = t.ensureSemantics();
      expect(t.getSemantics(find.bySemanticsLabel('Live mode')), isSemantics(isButton: true, hasToggledState: true, isToggled: true), reason: 'on by default');
      await tap(t, 'live-mode');
      expect(t.getSemantics(find.bySemanticsLabel('Live mode')), isSemantics(hasToggledState: true, isToggled: false));
      semantics.dispose();
      expect(prefs.read('ol_guest_live'), '0');
      final asked = feed.slugs.length;
      feed.answer = {
        'items': [item('Butter Chicken', 1, '10', 1)],
        'streaks': [
          {'label': 'Breads', 'count': 4, 'kind': 'category'},
        ],
      };
      await t.pump(const Duration(seconds: 13));
      await t.pumpAndSettle();
      expect(feed.slugs.length, asked, reason: 'off: the feed is not read');
      expect(find.byKey(const ValueKey('live-toast')), findsNothing);
      // a reload keeps it off
      final again = FakeFeed();
      await showApp(t, TableDoor(experience: page()), orders: FakeOrders(), feed: again, prefs: prefs);
      expect(again.slugs, isEmpty);
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      await tap(t, 'live-mode');
      expect(prefs.read('ol_guest_live'), '1');
      expect(again.slugs, ['windough']);
    });

    testWidgets('a category streak and the brand page store link', (t) async {
      final feed = FakeFeed()
        ..answer = {
          'items': [],
          'streaks': [
            {'label': 'Breads', 'count': 4, 'kind': 'category'},
          ],
        };
      await showApp(t, brandDoor(), orders: FakeOrders(), feed: feed, preorders: FakePreorders(), storeLink: 'windough');
      await t.pump(const Duration(milliseconds: 300));
      expect(feed.slugs, ['windough']);
      expect(find.text('4 Breads ordered'), findsOneWidget);
    });

    test('the feed never keeps a line without a dish, and a streak needs two', () {
      final f = GuestFeed(const Facts({
        'items': [
          {'name': ' ', 'qty': 1, 'seconds_ago': 2},
          {'name': 'Dosa', 'qty': 0, 'table_label': ' ', 'seconds_ago': -5, 'category': null},
        ],
        'streaks': [
          {'label': 'Dosa', 'count': 1, 'kind': 'dish'},
          {'label': 'Dosa', 'count': 2, 'kind': 'weird'},
        ],
      }));
      expect(f.items.single, (name: 'Dosa', qty: 1, table: null, secondsAgo: 0, category: null));
      expect(f.streaks.single, (name: 'Dosa', label: 'Dosa', count: 2, kind: 'dish'));
      // gx_live_feed's own shape: the label is already a sentence, the dish is its name
      final g = GuestFeed(const Facts({
        'items': [],
        'streaks': [
          {'label': '3 tables ordered Cold Coffee', 'count': 3, 'kind': 'dish', 'name': 'Cold Coffee'},
        ],
      }));
      expect(g.streaks.single.name, 'Cold Coffee');
    });
  });

  group('the budget', () {
    testWidgets("is optional on the guest's own phone: Skip goes on without one", (t) async {
      await showApp(t, TableDoor(experience: page()), orders: FakeOrders());
      await tap(t, 'guest-start');
      expect(find.byKey(const ValueKey('budget-skip')), findsOneWidget);
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('budget-ring')), findsNothing);
    });

    testWidgets('Hand to guest (the staff phone) never shows the budget step or the ring', (t) async {
      for (final exp in [page(), null]) {
        await showApp(t, TableDoor(experience: exp, waits: false));
        await tap(t, 'guest-start');
        expect(find.byKey(const ValueKey('budget-skip')), findsNothing);
        expect(find.byKey(const ValueKey('budget-slider')), findsNothing);
        await tap(t, 'mood-all');
        await tap(t, 'deck-add');
        expect(find.byKey(const ValueKey('budget-ring')), findsNothing);
        await tap(t, 'cart-bar');
        expect(find.byKey(const ValueKey('budget-note')), findsNothing);
      }
    });
  });

  group('offers', () {
    testWidgets('the strip shows the live offers; one below its minimum says how much more to add; Apply puts the code in the order', (t) async {
      final orders = FakeOrders();
      await showApp(t, TableDoor(experience: page(), offers: true), orders: orders);
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('offers-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-of1')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-of2')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-bad')), findsNothing, reason: 'only percent or flat offers: the page shows nothing it cannot explain');
      expect(find.text('10% off breakfast'), findsOneWidget);
      expect(find.text('₹50 off'), findsOneWidget);
      await tap(t, 'deck-add'); // Cinnamon Scroll, 220
      expect(_text(t, 'offer-min-of1'), 'Add ₹280 more to use it');
      expect(t.widget<TextButton>(find.byKey(const ValueKey('offer-apply-of1'))).onPressed, isNull);
      await tap(t, 'cart-bar');
      await tap(t, 'plus-i1');
      await tap(t, 'plus-i1'); // 3 x 220 = 660
      await tap(t, 'order-continue');
      expect(find.byKey(const ValueKey('review-offers')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-of3')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-apply-of3')), findsNothing, reason: 'a POS offer has no code to apply: the bill takes it off');
      expect(_text(t, 'offer-line-of3'), 'On orders of ₹300 or more · on the bill');
      await tap(t, 'offer-apply-of1');
      expect(_text(t, 'offer-saving'), 'You save about ₹66 with BAKE10. The final amount is on the bill.');
      expect(_text(t, 'review-offer'), '−₹66');
      expect(_text(t, 'review-total'), '₹594');
      expect(find.text('Estimated total'), findsOneWidget);
      await tap(t, 'offer-remove');
      expect(find.byKey(const ValueKey('offer-saving')), findsNothing);
      expect(_text(t, 'review-total'), '₹660');
      await tap(t, 'offer-apply-of2');
      expect(_text(t, 'review-offer'), '−₹50');
      await tap(t, 'send-order');
      expect(orders.placed.single.body['coupon_code'], 'FLAT50');
    });

    testWidgets('without the customer server, or reading the brand page, offers show without Apply', (t) async {
      await showApp(t, TableDoor(experience: page(), offers: true));
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('offer-of1')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-apply-of1')), findsNothing);
      await showApp(t, brandDoor(offers: true), orders: FakeOrders(), preorders: FakePreorders(), storeLink: 'windough');
      await tap(t, 'guest-start');
      await tap(t, 'mode-dine-in');
      await tap(t, 'scan-browse');
      await tap(t, 'mood-all');
      expect(find.byKey(const ValueKey('offer-of2')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-apply-of2')), findsNothing);
    });

    test('the saving is an estimate: percent of the order, a flat amount never more than the order, nothing below the minimum', () {
      final pct = GuestOffer(const Facts({'id': 'a', 'code': 'P', 'kind': 'percent', 'value': 12.5, 'min_order': 100}));
      final flat = GuestOffer(const Facts({'id': 'b', 'code': 'F', 'kind': 'flat', 'value': 200, 'min_order': 0}));
      expect(pct.savingOn(99), 0);
      expect(pct.shortBy(99), 1);
      expect(pct.savingOn(333), 41.63);
      final capped = GuestOffer(const Facts({'id': 'c', 'code': 'CAP', 'kind': 'percent', 'value': 50, 'min_order': 0, 'max_discount': 100}));
      expect(capped.savingOn(1000), 100, reason: 'never more than the most it takes off');
      expect(GuestOffer(const Facts({'id': 'd', 'code': null, 'kind': 'flat', 'value': 30})).auto, isTrue);
      expect(flat.savingOn(150), 150);
      expect(flat.savingOn(0), 0);
    });
  });

  group('the dish details', () {
    testWidgets('swipe up opens the photo edge to edge with the name and price, and Add; Close closes', (t) async {
      await showApp(t, TableDoor(experience: page()), orders: FakeOrders());
      await tap(t, 'guest-start');
      await tap(t, 'budget-skip');
      await tap(t, 'mood-all');
      await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(0, -300));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('item-detail')), findsOneWidget);
      expect(_text(t, 'detail-name'), 'Cinnamon Scroll');
      expect(find.byTooltip('Close'), findsOneWidget);
      await tap(t, 'detail-close');
      expect(find.byKey(const ValueKey('item-detail')), findsNothing);
      await t.drag(find.byKey(const ValueKey('deck-card')), const Offset(0, -300));
      await t.pumpAndSettle();
      await tap(t, 'detail-plus');
      await tap(t, 'detail-add');
      expect(find.byKey(const ValueKey('added-title')), findsOneWidget);
      expect(find.text('2 × ₹220'), findsOneWidget);
    });
  });
}
