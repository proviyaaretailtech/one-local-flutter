import 'dart:convert';
import 'dart:math';

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

/// The menu of the guest's outlet with the restaurant's own name and colour from its published storefront.
class GuestMenu {
  GuestMenu(Facts f)
      : brandName = f.m('brand').s('name'),
        tagline = f.m('brand').so('tagline'),
        accent = _hex(f.m('brand').so('accent')),
        tableWord = f.m('brand').so('table_word') ?? 'Table',
        categories = [for (final c in f.l('categories')) (id: c.s('id'), name: c.s('name'))],
        items = [for (final i in f.l('items')) GuestItem(i)];
  final String brandName;
  final String? tagline;
  final Color accent;
  final String tableWord;
  final List<({String id, String name})> categories;
  final List<GuestItem> items;

  GuestItem? byId(String id) => items.where((i) => i.id == id).firstOrNull;

  static Color _hex(String? v) {
    final m = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(v ?? '');
    return Color(0xFF000000 | int.parse(m?.group(1) ?? '76EC00', radix: 16));
  }
}

/// What the guest sees before ordering: the business, the outlet, the table and the menu.
class GuestVisit {
  GuestVisit(Facts f)
      : business = f.m('business').s('name'),
        outlet = f.m('outlet').s('name'),
        tableLabel = f.m('table').s('label'),
        areaName = f.m('table').so('area_name'),
        menu = GuestMenu(f.m('menu'));
  final String business;
  final String outlet;
  final String tableLabel;
  final String? areaName;
  final GuestMenu menu;
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

/// How the guest screens talk to the restaurant. Two ways in, one set of screens:
///  - [WebGuestGateway]: the customer's own phone after scanning the table QR (no sign-in; POST /guest/<name>). A sent order WAITS for a staff
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

  static final _rand = Random.secure();
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

  Future<Map<String, dynamic>> _post(String name, Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _http.post(Uri.parse('$_base/guest/$name'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 20));
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
