import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart' show Color;
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;

/// One dish of the guest menu, as the database sends it (`guest__menu`, migration 0561): published, switched on, not hidden, in its window.
class GuestItem {
  GuestItem(this.f);
  final Facts f;
  String get id => f.s('id');
  String get name => f.s('name');
  String? get description => (f.so('description') ?? '').trim().isEmpty ? null : f.so('description')!.trim();
  num get price => f.n('price');
  String? get imageUrl => (f.so('image_url') ?? '').startsWith('http') ? f.so('image_url') : null;
  bool get veg => f.s('food_type') == 'veg' || f.s('food_type') == 'jain' || f.s('food_type') == 'vegan';
  bool get recommended => f.b('is_recommended');
  int get prepMinutes => f.n('prep_minutes').toInt();
  String? get categoryId => f.so('category_id');
  List<String> get tags => f.ls('tags');
}

/// The menu of the guest's outlet with the restaurant's own name and colour from its published storefront, and its guest page (0654).
class GuestMenu {
  GuestMenu(Facts f)
      : brandName = f.m('brand').s('name'),
        tagline = f.m('brand').so('tagline'),
        accent = _hex(f.m('brand').so('accent')),
        tableWord = f.m('brand').so('table_word') ?? 'Table',
        categories = [for (final c in f.l('categories')) (id: c.s('id'), name: c.s('name'))],
        items = [for (final i in f.l('items')) GuestItem(i)],
        experience = f.mo('experience') == null ? null : GuestExperience(f.m('experience')),
        offers = [
          for (final o in f.l('offers'))
            if (const {'percent', 'flat'}.contains(o.s('kind')) && o.n('value') > 0) GuestOffer(o),
        ];
  final String brandName;
  final String? tagline;
  final Color accent;
  final String tableWord;
  final List<({String id, String name})> categories;
  final List<GuestItem> items;

  /// The restaurant's published guest page; null from an older server (the screens keep their first look and order).
  final GuestExperience? experience;

  /// The restaurant's live offers and coupons (specs/guest-experience-builder part 2, contract C): never free text on the page, always one of
  /// its own offers. Empty from an older server.
  final List<GuestOffer> offers;

  GuestItem? byId(String id) => items.where((i) => i.id == id).firstOrNull;

  static Color _hex(String? v, [String fallback = '76EC00']) {
    final m = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(v ?? '');
    return Color(0xFF000000 | int.parse(m?.group(1) ?? fallback, radix: 16));
  }
}

/// The restaurant's guest page as it published it (0654 `experience`, specs/guest-experience-builder): a look, its colours and font, and the
/// blocks a guest walks through in the restaurant's order. Only switched-on blocks count; dishes and prices always come from the menu.
class GuestExperience {
  GuestExperience(Facts f)
      : look = f.s('look'),
        theme = GuestTheme(f.m('theme')),
        blocks = [for (final b in f.l('blocks')) (type: b.s('type'), enabled: b.b('enabled'), props: b.m('props'))],
        welcomeImageUrl = (f.so('welcome_image_url') ?? '').startsWith('http') ? f.so('welcome_image_url') : null,
        isDefault = f.b('is_default');
  final String look;
  final GuestTheme theme;
  final List<({String type, bool enabled, Facts props})> blocks;

  /// The welcome block's picture: a short-lived link the server signs (null = none chosen).
  final String? welcomeImageUrl;

  /// True when the restaurant has not published a page yet and this is OneLocal's starting one.
  final bool isDefault;

  /// Whether the block of [type] is on the page and switched on.
  bool on(String type) => blocks.any((b) => b.type == type && b.enabled);

  /// The settings of a switched-on block ({} when it is off or missing).
  Facts props(String type) => blocks.where((b) => b.type == type && b.enabled).firstOrNull?.props ?? const Facts({});
}

/// The page's colours (`#RRGGBB`) and font. Dark or light follows the background.
class GuestTheme {
  GuestTheme(Facts f)
      : background = GuestMenu._hex(f.so('background'), '0E0E0E'),
        surface = GuestMenu._hex(f.so('surface'), '1C1C1C'),
        text = GuestMenu._hex(f.so('text'), 'FFFFFF'),
        muted = GuestMenu._hex(f.so('muted'), 'A3A3A3'),
        accent = GuestMenu._hex(f.so('accent'), 'F5B83D'),
        accentText = GuestMenu._hex(f.so('accent_text'), '111111'),
        serif = f.s('font') == 'serif';
  final Color background, surface, text, muted, accent, accentText;
  final bool serif;
  bool get dark => background.computeLuminance() < 0.5;
}

/// One live offer of the restaurant (the menu answer's `offers`, `gx__offers`): a coupon with the code that applies it, or a POS offer the
/// restaurant takes off on the bill by itself (no code); percent or flat, the smallest order it needs and the most it takes off. What it
/// takes off is the restaurant's to decide on the bill; [savingOn] is only the page's estimate.
class GuestOffer {
  GuestOffer(Facts f)
      : id = f.s('id'),
        title = f.s('title').trim(),
        code = (f.so('code') ?? '').trim().isEmpty ? null : f.s('code').trim(),
        percent = f.s('kind') == 'percent',
        value = f.n('value'),
        minOrder = f.n('min_order'),
        maxDiscount = (f.no('max_discount') ?? 0) > 0 ? f.no('max_discount') : null,
        endsAt = f.t('ends_at');
  final String id, title;

  /// The coupon's code; null for an offer the restaurant applies on the bill by itself.
  final String? code;

  /// True for "N% off"; false for a flat amount off.
  final bool percent;
  final num value, minOrder;
  final num? maxDiscount;
  final DateTime? endsAt;

  /// Nothing to apply: the restaurant takes it off on the bill.
  bool get auto => code == null;

  /// How much more the order needs before this offer applies (0 = it applies).
  num shortBy(num subtotal) => math.max<num>(0, minOrder - subtotal);

  /// What this offer would take off [subtotal], to the paisa: an estimate, the bill makes the final figure. 0 below the minimum order.
  num savingOn(num subtotal) {
    if (subtotal <= 0 || shortBy(subtotal) > 0) return 0;
    var off = percent ? subtotal * value / 100 : math.min(value, subtotal);
    if (maxDiscount != null) off = math.min(off, maxDiscount!);
    return (off * 100).round() / 100;
  }
}

/// What the guest sees before ordering: the business, the outlet, the table and the menu.
class GuestVisit {
  GuestVisit(Facts f)
      : business = f.m('business').s('name'),
        outlet = f.m('outlet').s('name'),
        tableLabel = f.m('table').s('label'),
        areaName = f.m('table').so('area_name'),
        session = RegExp(r'^[0-9a-f]{32,128}$').hasMatch(f.s('session')) ? f.s('session') : null,
        storeLink = [f.m('business').so('store_link'), f.m('business').so('slug'), f.m('menu').m('brand').so('store_link')]
            .map((s) => (s ?? '').trim().toLowerCase())
            .where((s) => RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(s))
            .firstOrNull,
        menu = GuestMenu(f.m('menu'));
  final String business;
  final String outlet;
  final String tableLabel;
  final String? areaName;
  final GuestMenu menu;

  /// The table QR visit's session secret (the open answer): a dine-in order through the customer server names its table with it, never with
  /// a table label. Null on the brand page and with Hand to guest.
  final String? session;

  /// The restaurant's store link (`onelocal.co/<store link>`) when the answer carries it: a table QR page names its restaurant with it to the
  /// customer server and the live order feed.
  final String? storeLink;
}

/// Where an accepted order is (0572 `track`): confirmed -> in_kitchen -> ready -> served, and the minutes left while it cooks.
class GuestTrack {
  GuestTrack(Facts f)
      : stage = f.s('stage'),
        minutesLeft = f.raw['minutes_left'] == null ? null : f.n('minutes_left').toInt(),
        estimateMinutes = f.n('estimate_minutes').toInt(),
        steps = [for (final x in f.l('steps')) (key: x.s('key'), done: x.b('done'), at: DateTime.tryParse(x.so('at') ?? '')?.toLocal())];
  final String stage;
  final int? minutesLeft;
  final int estimateMinutes;
  final List<({String key, bool done, DateTime? at})> steps;
  static GuestTrack? of(Facts request) {
    final t = request.m('order').raw['track'];
    return t is Map ? GuestTrack(Facts(t.cast<String, dynamic>())) : null;
  }
}

/// The table's bill as the guest may see it (0572 `guest_bill`): dishes and money only. Paying stays with the staff.
class GuestBill {
  GuestBill(Facts f)
      : lines = [for (final o in f.l('orders')) for (final i in o.l('items')) (name: i.s('name'), qty: i.n('qty').toInt(), total: i.n('line_total'))],
        subtotal = f.n('subtotal'),
        gst = f.n('gst_amount'),
        discount = f.l('orders').fold<num>(0, (a, o) => a + o.n('discount')),
        serviceCharge = f.l('orders').fold<num>(0, (a, o) => a + o.n('service_charge')),
        roundOff = f.l('orders').fold<num>(0, (a, o) => a + o.n('round_off')),
        total = f.n('total'),
        paid = f.n('paid'),
        due = f.n('due'),
        billReady = f.b('bill_ready'),
        rating = f.raw['feedback'] is Map ? Facts((f.raw['feedback'] as Map).cast<String, dynamic>()).n('rating').toInt() : null;

  /// The bill of one web order (contract A `bill`: its lines, subtotal, GST, service and total), as the restaurant made it.
  GuestBill.web(Facts f)
      : lines = [
          for (final i in f.l('lines'))
            (
              name: (i.so('variant') ?? '').trim().isEmpty ? i.s('name') : '${i.s('name')} (${i.s('variant').trim()})',
              qty: i.n('qty').toInt(),
              total: _first(i, const ['line_total', 'total', 'amount']),
            ),
        ],
        subtotal = _first(f, const ['subtotal']),
        gst = _first(f, const ['gst', 'gst_amount', 'tax']),
        discount = _first(f, const ['discount']),
        serviceCharge = _first(f, const ['service', 'service_charge']),
        roundOff = _first(f, const ['round_off']),
        total = _first(f, const ['total']),
        paid = _first(f, const ['paid']),
        due = f.no('due') ?? math.max<num>(0, _first(f, const ['total']) - _first(f, const ['paid'])),
        billReady = true,
        rating = null;

  static num _first(Facts f, List<String> keys) => keys.map(f.no).nonNulls.firstOrNull ?? 0;
  final List<({String name, int qty, num total})> lines;
  final num subtotal, gst, discount, serviceCharge, roundOff, total, paid, due;
  final bool billReady;

  /// The feedback this visit already left (1-5), or null.
  final int? rating;
}

/// One line the guest wants: a dish, how many, an optional note.
class GuestLine {
  GuestLine(this.item, this.qty, [this.notes]);
  final GuestItem item;
  int qty;
  String? notes;
  Map<String, dynamic> toJson() => {'menu_item_id': item.id, 'qty': qty, if ((notes ?? '').trim().isNotEmpty) 'notes': notes!.trim()};
}

class GuestApiException extends PartnerApiException {
  const GuestApiException(super.status, super.message, this.code);
  final String? code;

  /// The table code changed or the visit is over: the guest has to scan again.
  bool get sessionEnded => code == 'session_expired';
}

/// One POST of the guest page (the POS guest door and the customer server answer alike): JSON in, JSON out, and an error keeps the server's own
/// sentence (`detail`) and its `code`.
Future<Map<String, dynamic>> _postJson(http.Client client, Uri url, Map<String, dynamic> body, {Map<String, String> headers = const {}}) async {
  final http.Response res;
  try {
    res = await client.post(url, headers: {'Content-Type': 'application/json', ...headers}, body: jsonEncode(body)).timeout(const Duration(seconds: 20));
  } catch (_) {
    throw const GuestApiException(0, 'No connection. Check your internet and try again.', 'offline');
  }
  final decoded = res.body.isEmpty ? null : (() {
    try {
      return jsonDecode(res.body);
    } catch (_) {
      return null;
    }
  })();
  if (res.statusCode < 200 || res.statusCode >= 300) {
    final m = decoded is Map ? decoded : const {};
    throw GuestApiException(res.statusCode, (m['detail'] as String?) ?? 'Something went wrong. Please try again.', m['code'] as String?);
  }
  return decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
}

/// How the guest screens talk to the restaurant. Two ways in, one set of screens:
///  - [WebGuestGateway]: the customer's own phone after scanning the table QR (no sign-in; `POST /guest/<name>`). A sent order WAITS for a staff
///    member to accept it.
///  - [StaffGuestGateway]: "Hand to guest" on the staff phone (the staff member's session; POST /rpc/guest_staff_*). A sent order goes straight
///    to the kitchen.
abstract class GuestGateway {
  /// True when a sent order waits for the staff (the QR web page); false when it is placed at once (Hand to guest).
  bool get waitsForStaff;

  Future<GuestVisit> open();
  Future<GuestMenu> menu();

  /// Sends the cart. [key] identifies this one tap: send it again with the same key to retry safely.
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key});

  /// This visit's orders, newest first (the web page only; Hand to guest has no list).
  Future<List<Facts>> status();

  /// The table's bill (the web page only; null where there is none to show).
  Future<GuestBill?> bill();

  /// How the visit was, 1-5, with an optional comment (the web page only).
  Future<void> feedback(int rating, {String? comment});

  static final _rand = math.Random.secure();
  static String newKey() => 'g-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

/// The QR web page's door: `POST {base}/guest/<open|menu|send|status>`. The table code comes from the scanned address; the session secret the
/// server answers with is kept in memory only (a reload scans again, which opens a fresh visit).
class WebGuestGateway implements GuestGateway {
  WebGuestGateway({required this.code, String? baseUrl, http.Client? client})
      : _http = client ?? http.Client(),
        _base = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), '');
  final String code;
  final http.Client _http;
  final String _base;
  String? _session;

  @override
  bool get waitsForStaff => true;

  Future<Map<String, dynamic>> _post(String name, Map<String, dynamic> body) => _postJson(_http, Uri.parse('$_base/guest/$name'), body);

  String get _s => _session ?? (throw const GuestApiException(409, 'Please scan the table code again.', 'session_expired'));

  @override
  Future<GuestVisit> open() async {
    final r = await _post('open', {'code': code});
    _session = r['session'] as String?;
    return GuestVisit(Facts(r));
  }

  @override
  Future<GuestMenu> menu() async => GuestMenu(Facts(await _post('menu', {'session': _s})));

  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) async => Facts(await _post('send', {
        'session': _s,
        'idempotency_key': key,
        'lines': [for (final l in lines) l.toJson()],
        if ((guestName ?? '').trim().isNotEmpty) 'guest_name': guestName!.trim(),
        if ((note ?? '').trim().isNotEmpty) 'note': note!.trim(),
      }));

  @override
  Future<List<Facts>> status() async => Facts(await _post('status', {'session': _s})).l('requests');

  @override
  Future<GuestBill?> bill() async => GuestBill(Facts(await _post('bill', {'session': _s})));

  @override
  Future<void> feedback(int rating, {String? comment}) async =>
      _post('feedback', {'session': _s, 'rating': rating, if ((comment ?? '').trim().isNotEmpty) 'comment': comment!.trim()});
}

/// The public menu link (`<server>/m/<slug>`, database 0571): anyone may open it, with no sign-in and no table. Read-only: the menu card of a
/// live business (`POST /guest/card`); there is nothing to send, so [send] refuses and [status] is empty.
class MenuCardGateway implements GuestGateway {
  MenuCardGateway({required this.slug, String? baseUrl, http.Client? client}) : _web = WebGuestGateway(code: '', baseUrl: baseUrl, client: client);
  final String slug;
  final WebGuestGateway _web;

  @override
  bool get waitsForStaff => false;

  @override
  Future<GuestVisit> open() async => GuestVisit(Facts(await _web._post('card', {'slug': slug})));

  @override
  Future<GuestMenu> menu() async => (await open()).menu;

  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) =>
      Future.error(const GuestApiException(400, 'Ordering is done at the restaurant: scan the QR code on your table.', 'menu_only'));

  @override
  Future<List<Facts>> status() async => const [];

  @override
  Future<GuestBill?> bill() async => null;

  @override
  Future<void> feedback(int rating, {String? comment}) async {}
}

/// The pickup times a brand page offers (0654 `gx_preorder_slots`): each day (the restaurant's date) that still has a time, and its times
/// exactly as the database wrote them, because a pre-order sends one back unchanged.
class PreorderSlots {
  PreorderSlots(Facts f)
      : timezone = f.s('timezone'),
        slotMinutes = f.n('slot_minutes').toInt(),
        noteHint = (f.so('note_hint') ?? '').trim().isEmpty ? null : f.so('note_hint')!.trim(),
        days = [for (final d in f.l('days')) (date: d.s('date'), slots: d.ls('slots'))];
  final String timezone;
  final int slotMinutes;
  final String? noteHint;
  final List<({String date, List<String> slots})> days;
}

/// A pickup time as the restaurant's clock shows it (a UTC DateTime whose fields are that clock). The page carries no time-zone table: India's
/// zone (the only one in use) is known; any other zone, or none, shows this phone's own clock.
DateTime guestWallTime(String iso, [String? timezone]) {
  final t = DateTime.parse(iso);
  final offset = const {'Asia/Kolkata': Duration(minutes: 330), 'Asia/Calcutta': Duration(minutes: 330)}[timezone];
  if (offset == null) {
    final l = t.toLocal();
    return DateTime.utc(l.year, l.month, l.day, l.hour, l.minute);
  }
  return t.toUtc().add(offset);
}

/// The brand page's pre-order door (0654): the pickup times, the pre-order itself (a name, a 10-digit mobile number and one of the offered
/// times; limited per phone and per address), and its tracking by the token the pre-order answered with. Nobody signs in.
abstract class PreorderDoor {
  Future<PreorderSlots> slots();

  /// Sends the pre-order. [key] identifies this one tap: send it again with the same key to retry safely.
  Future<Facts> place(List<GuestLine> lines, {required String name, required String phone, required String pickupAt, String? note, required String key});

  /// Where the pre-order of [token] is now: the request (waiting / accepted / declined) and, once accepted, its order and tracking.
  Future<Facts> track(String token);
}

/// [PreorderDoor] over `POST {base}/guest/<slots|preorder|pretrack>` for the business at `onelocal.co/<slug>`.
class PreorderGateway implements PreorderDoor {
  PreorderGateway({required this.slug, String? baseUrl, http.Client? client}) : _web = WebGuestGateway(code: '', baseUrl: baseUrl, client: client);
  final String slug;
  final WebGuestGateway _web;

  @override
  Future<PreorderSlots> slots() async => PreorderSlots(Facts(await _web._post('slots', {'slug': slug})));

  @override
  Future<Facts> place(List<GuestLine> lines, {required String name, required String phone, required String pickupAt, String? note, required String key}) async =>
      Facts(await _web._post('preorder', {
        'slug': slug,
        'idempotency_key': key,
        'lines': [for (final l in lines) l.toJson()],
        'guest_name': name.trim(),
        'phone': phone.trim(),
        'pickup_at': pickupAt,
        if ((note ?? '').trim().isNotEmpty) 'note': note!.trim(),
      }));

  @override
  Future<Facts> track(String token) async => Facts(await _web._post('pretrack', {'track': token}));
}

/// "Hand to guest": the staff member's own session, the table they opened, the same published menu (`guest_staff_menu`), and the order placed
/// at once (`guest_staff_place` -> `pos_place_order`, placed by guest).
class StaffGuestGateway implements GuestGateway {
  StaffGuestGateway({required this.tableId, this.locationId, RpcClient? rpc}) : _rpc = rpc ?? RpcClient();
  final String tableId;
  final String? locationId;
  final RpcClient _rpc;

  @override
  bool get waitsForStaff => false;

  Map<String, dynamic> _args([Map<String, dynamic> more = const {}]) => {
        if ((locationId ?? '').isNotEmpty) 'location_id': locationId,
        'table_id': tableId,
        ...more,
      };

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args, [String? key]) async {
    try {
      return await _rpc.callMap(fn, args, key);
    } on RpcException catch (e) {
      throw GuestApiException(e.status, e.message, e.code);
    }
  }

  @override
  Future<GuestVisit> open() async => GuestVisit(Facts(await _call('guest_staff_menu', _args())));

  @override
  Future<GuestMenu> menu() async => (await open()).menu;

  @override
  Future<Facts> send(List<GuestLine> lines, {String? guestName, String? note, required String key}) async => Facts(await _call(
      'guest_staff_place',
      _args({
        'lines': [for (final l in lines) l.toJson()],
        'idempotency_key': key,
        if ((guestName ?? '').trim().isNotEmpty) 'guest_name': guestName!.trim(),
        if ((note ?? '').trim().isNotEmpty) 'note': note!.trim(),
      }),
      key));

  @override
  Future<List<Facts>> status() async => const [];

  @override
  Future<GuestBill?> bill() async => null;

  @override
  Future<void> feedback(int rating, {String? comment}) async {}
}

// ---- specs/guest-experience-builder part 2: web orders through the customer server (contract A) and the live order feed (contract B)

/// A little memory of this browser: the device key and the "Live mode" choice. The web page keeps it in localStorage (guest_link_web.dart);
/// elsewhere, and in tests, it lives in memory only.
abstract class GuestPrefs {
  String? read(String key);
  void write(String key, String value);
}

class MemoryGuestPrefs implements GuestPrefs {
  final _values = <String, String>{};
  @override
  String? read(String key) => _values[key];
  @override
  void write(String key, String value) => _values[key] = value;
}

/// The guest browser's own key for the customer server (`x-customer-key`): 32 random bytes as 64 hex, made once and kept in [prefs], so this
/// phone's orders stay apart from another's. A convenience, not an identity: it is never a name, a phone or an account.
String guestDeviceKey(GuestPrefs prefs) {
  const name = 'ol_customer_key';
  final kept = prefs.read(name);
  if (kept != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(kept)) return kept;
  final made = List.generate(32, (_) => GuestGateway._rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  prefs.write(name, made);
  return made;
}

/// Where the customer server is (`CUSTOMER_API_BASE_URL`): the `--dart-define` when it is given (empty = none: the page then orders through
/// the POS guest door as before), else `http://localhost:8099` on a page served from this machine, else the page's own host with `/api`.
/// A page not on http(s) (tests) has none.
String? customerApiBaseFor(Uri page, {bool defined = const bool.hasEnvironment('CUSTOMER_API_BASE_URL'), String value = const String.fromEnvironment('CUSTOMER_API_BASE_URL')}) {
  if (defined) {
    final v = value.trim().replaceAll(RegExp(r'/+$'), '');
    return v.isEmpty ? null : v;
  }
  if (!page.isScheme('http') && !page.isScheme('https')) return null;
  final h = page.host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]' || h.endsWith('.localhost')) return 'http://localhost:8099';
  return '${page.origin}/api';
}

/// One order as the guest sends it to the customer server (`POST /api/web/orders`). Dine-in names its table by the QR visit's session, never
/// by a label; a pickup names its time (one the restaurant offered) and a 10-digit mobile number. Prices are the server's; the budget is
/// never part of it.
class WebOrderRequest {
  const WebOrderRequest({this.storeLink, required this.mode, this.tableSession, this.pickupAt, required this.lines, this.guestName, this.phone, this.note, this.couponCode});
  final String? storeLink;

  /// `dine_in` or `pickup`.
  final String mode;
  final String? tableSession, pickupAt, guestName, phone, note, couponCode;
  final List<GuestLine> lines;

  Map<String, dynamic> toJson() {
    String? clean(String? v) => (v ?? '').trim().isEmpty ? null : v!.trim();
    return {
      'store_link': ?clean(storeLink),
      'mode': mode,
      'table_session': ?clean(tableSession),
      'pickup_at': ?clean(pickupAt),
      'lines': [for (final l in lines) l.toJson()],
      'guest_name': ?clean(guestName),
      'phone': ?clean(phone),
      'note': ?clean(note),
      'coupon_code': ?clean(couponCode),
    };
  }
}

/// Where a web order is (contract A's order and status answers). [stage] is one of waiting_partner, accepted, preparing, on_hold, ready,
/// served, bill_ready, paid, declined, cancelled; [held] and [paused] say the kitchen or the restaurant has stopped for now.
class WebOrder {
  WebOrder(Facts f)
      : id = f.s('order_id'),
        displayNo = f.s('display_no'),
        status = f.s('status'),
        stage = f.s('stage'),
        stageLabel = (f.so('stage_label') ?? '').trim().isEmpty ? null : f.s('stage_label').trim(),
        mode = f.s('mode'),
        tableLabel = (f.so('table_label') ?? '').trim().isEmpty ? null : f.s('table_label').trim(),
        track = RegExp(r'^[0-9a-f]{36}$').hasMatch(f.s('track')) ? f.s('track') : null,
        placedAt = f.t('placed_at'),
        acceptedAt = f.t('accepted_at'),
        pickupAt = f.so('pickup_at'),
        etaMinutes = f.no('eta_minutes')?.toInt(),
        held = f.b('held'),
        paused = f.mo('restaurant_paused') == null
            ? null
            : (reason: (f.m('restaurant_paused').so('reason') ?? '').trim().isEmpty ? null : f.m('restaurant_paused').s('reason').trim(), backAt: f.m('restaurant_paused').t('back_at')),
        lines = [for (final l in f.l('lines')) (name: l.s('name'), qty: l.n('qty').toInt(), status: l.s('status'))],
        total = f.no('total'),
        bill = f.mo('bill') == null ? null : GuestBill.web(f.m('bill')),
        canRequestBill = f.b('can_request_bill'),
        declineReason = [f.so('decline_reason'), f.so('cancel_reason'), f.so('reason')].map((s) => (s ?? '').trim()).where((s) => s.isNotEmpty).firstOrNull;
  final String id, displayNo, status, stage, mode;
  final String? stageLabel, tableLabel, track, pickupAt, declineReason;
  final DateTime? placedAt, acceptedAt;
  final int? etaMinutes;
  final bool held;
  final ({String? reason, DateTime? backAt})? paused;
  final List<({String name, int qty, String status})> lines;
  final num? total;
  final GuestBill? bill;
  final bool canRequestBill;

  bool get pickup => mode == 'pickup';

  /// Nothing more will happen to it: the page stops asking.
  bool get done => const {'paid', 'declined', 'cancelled'}.contains(stage);

  /// The stage the guest is shown: a paused restaurant or a held kitchen stops an order that is still on its way; a finished one says so.
  String get shown {
    if (const {'waiting_partner', 'accepted', 'preparing', 'on_hold'}.contains(stage) && paused != null) return 'paused';
    if (stage == 'on_hold' || (held && const {'waiting_partner', 'accepted', 'preparing'}.contains(stage))) return 'on_hold';
    return stage;
  }
}

/// The customer server's order door (contract A) as the guest screens use it; [CustomerOrderGateway] over the network, a fake in tests.
abstract class WebOrderDoor {
  /// Sends the order. [key] identifies this one tap: send it again with the same key to retry safely.
  Future<WebOrder> place(WebOrderRequest order, {required String key});

  /// Where the order of [track] is now.
  Future<WebOrder> status(String track);

  /// Asks for the bill of [track]; the answer is its status with the bill once the restaurant has made it.
  Future<WebOrder> bill(String track);
}

/// [WebOrderDoor] over `POST {base}/api/web/orders[/status|/bill]` with this browser's device key (`x-customer-key`) and, for an order, an
/// `Idempotency-Key`. [baseUrl] may already end in `/api`.
class CustomerOrderGateway implements WebOrderDoor {
  CustomerOrderGateway({required String baseUrl, GuestPrefs? prefs, http.Client? client})
      : _http = client ?? http.Client(),
        _prefs = prefs ?? MemoryGuestPrefs(),
        _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final http.Client _http;
  final GuestPrefs _prefs;
  final String _base;

  /// This browser's key, made on first use and kept.
  late final String deviceKey = guestDeviceKey(_prefs);

  Uri _url(String path) => Uri.parse('$_base${_base.endsWith('/api') ? '' : '/api'}/web/orders$path');

  Future<WebOrder> _call(String path, Map<String, dynamic> body, {String? key}) async =>
      WebOrder(Facts(await _postJson(_http, _url(path), body, headers: {'x-customer-key': deviceKey, 'Idempotency-Key': ?key})));

  @override
  Future<WebOrder> place(WebOrderRequest order, {required String key}) => _call('', order.toJson(), key: key);

  @override
  Future<WebOrder> status(String track) => _call('/status', {'track': track});

  @override
  Future<WebOrder> bill(String track) => _call('/bill', {'track': track});
}

/// What was ordered at the restaurant in the last minutes (contract B, `gx_live_feed`): dishes, quantities and tables only, never a name, a
/// phone or an amount; and the dishes or categories several tables ordered ([streaks]).
class GuestFeed {
  GuestFeed(Facts f)
      : items = [
          for (final i in f.l('items'))
            if (i.s('name').trim().isNotEmpty)
              (
                name: i.s('name').trim(),
                qty: math.max(1, i.n('qty').toInt()),
                table: (i.so('table_label') ?? '').trim().isEmpty ? null : i.s('table_label').trim(),
                secondsAgo: math.max(0, i.n('seconds_ago').toInt()),
                category: (i.so('category') ?? '').trim().isEmpty ? null : i.s('category').trim(),
              ),
        ],
        streaks = [
          for (final s in f.l('streaks'))
            if ((s.so('name') ?? s.so('label') ?? '').trim().isNotEmpty && s.n('count') >= 2)
              (
                name: (s.so('name') ?? '').trim().isNotEmpty ? s.s('name').trim() : s.s('label').trim(),
                label: s.s('label').trim(),
                count: s.n('count').toInt(),
                kind: s.s('kind') == 'category' ? 'category' : 'dish',
              ),
        ];
  final List<({String name, int qty, String? table, int secondsAgo, String? category})> items;

  /// [name] is the dish (or category) several tables ordered; [label] the server's own sentence for it, when it sends one.
  final List<({String name, String label, int count, String kind})> streaks;
}

abstract class LiveFeedDoor {
  /// The live feed of the restaurant at [slug].
  Future<GuestFeed> feed(String slug);
}

/// [LiveFeedDoor] over the POS guest door: `POST {base}/guest/feed {slug}`.
class LiveFeedGateway implements LiveFeedDoor {
  LiveFeedGateway({String? baseUrl, http.Client? client}) : _web = WebGuestGateway(code: '', baseUrl: baseUrl, client: client);
  final WebGuestGateway _web;

  @override
  Future<GuestFeed> feed(String slug) async => GuestFeed(Facts(await _web._post('feed', {'slug': slug})));
}
