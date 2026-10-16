import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';

/// A server answer read as typed fields. Every number, status and permission comes from the server; the app only draws them.
class Facts {
  const Facts(this.raw);
  final Map<String, dynamic> raw;

  String s(String k) => (raw[k] ?? '').toString();
  String? so(String k) => raw[k]?.toString();
  num n(String k) => _num(raw[k]) ?? 0;
  num? no(String k) => _num(raw[k]);
  bool b(String k) => raw[k] == true;
  Facts m(String k) => Facts((raw[k] as Map?)?.cast<String, dynamic>() ?? const {});
  Facts? mo(String k) => raw[k] is Map ? Facts((raw[k] as Map).cast<String, dynamic>()) : null;
  List<Facts> l(String k) => ((raw[k] as List?) ?? const []).whereType<Map>().map((e) => Facts(e.cast<String, dynamic>())).toList();
  List<String> ls(String k) => ((raw[k] as List?) ?? const []).map((e) => e.toString()).toList();
  DateTime? t(String k) => DateTime.tryParse('${raw[k] ?? ''}')?.toLocal();
  bool has(String k) => raw[k] != null;

  static num? _num(Object? v) => v is num ? v : (v == null ? null : num.tryParse(v.toString()));
}

/// One stock document (receipt, adjustment, transfer, audit) as `GET /documents/:id` returns it.
class InvDocument extends Facts {
  const InvDocument(super.raw);
  String get id => s('id');
  String get type => s('doc_type');
  String get number => s('doc_no');
  String get status => s('status');
  int get version => n('version').toInt();
  List<Facts> get lines => l('lines');
  List<String> get actions => ls('allowed_actions');
  bool can(String action) => actions.contains(action);
  bool get replayed => b('replayed');
}

/// One line the person is editing on a draft. Only ids and quantities go to the server; it checks every one again.
class DraftLine {
  DraftLine({required this.itemId, required this.itemName, this.sku = '', this.lotId, this.lotCode, this.expiryDate, this.fromBinId, this.toBinId,
      this.adjustType, this.expectedQty, this.qty, this.rejectedQty, this.rejectReason, this.countedQty, this.note});
  final String itemId, itemName, sku;
  String? lotId, lotCode, fromBinId, toBinId, adjustType, rejectReason, note;
  DateTime? expiryDate;
  num? expectedQty, qty, rejectedQty, countedQty;

  /// A draft line rebuilt from a saved document line.
  factory DraftLine.from(Facts l) => DraftLine(
        itemId: l.m('item').s('id'),
        itemName: l.m('item').s('name'),
        sku: l.m('item').s('sku'),
        lotId: l.mo('lot')?.s('id'),
        lotCode: l.so('lot_code') ?? l.mo('lot')?.s('lot_code'),
        expiryDate: l.t('expiry_date') ?? l.mo('lot')?.t('expiry_date'),
        fromBinId: l.mo('from_bin')?.s('id'),
        toBinId: l.mo('to_bin')?.s('id'),
        adjustType: l.so('adjust_type'),
        expectedQty: l.no('expected_qty'),
        qty: l.no('qty'),
        rejectedQty: l.no('rejected_qty'),
        rejectReason: l.so('reject_reason'),
        countedQty: l.no('counted_qty'),
        note: l.so('note'),
      );

  Map<String, dynamic> toJson() => {
        'inventory_item_id': itemId,
        'lot_id': ?lotId,
        'lot_code': ?lotCode,
        'expiry_date': ?(expiryDate == null ? null : _day(expiryDate!)),
        'from_bin_id': ?fromBinId,
        'to_bin_id': ?toBinId,
        'adjust_type': ?adjustType,
        'expected_qty': ?expectedQty,
        'qty': ?qty,
        'rejected_qty': ?rejectedQty,
        'reject_reason': ?rejectReason,
        'counted_qty': ?countedQty,
        'note': ?note,
      };

  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Calls One Local's server (`/api/partner/inventory/*`, contract in specs/pos-section-h/spec.md). The Supabase session token is the only
/// credential; the server and the database check the business, the location, the role and every rule again. Creating a document and every
/// document action carry an Idempotency-Key so a retried tap never doubles; edits carry the version the person saw.
class InventoryApi {
  InventoryApi({http.Client? client, String? baseUrl, String? Function()? accessToken, this.locationId})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  /// The store the screens look at; null lets the server pick the person's main location.
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'inv-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final q = {'location_id': ?locationId, ...?query}..removeWhere((_, v) => v.isEmpty);
    var uri = Uri.parse('$_base/api/partner/inventory$path');
    if (q.isNotEmpty) uri = uri.replace(queryParameters: q);
    final headers = {
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
      'Idempotency-Key': ?key,
    };
    final res = await (method == 'GET' ? _http.get(uri, headers: headers) : _http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)))
        .timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw InventoryApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  Future<Facts> options() async => Facts(await _send('GET', '/options'));
  Future<Facts> dashboard() async => Facts(await _send('GET', '/dashboard'));

  Future<Facts> stock({String filter = 'all', String q = '', String category = '', int page = 1, int pageSize = 8}) async => Facts(await _send('GET', '/stock',
      query: {'filter': filter, 'q': q.trim(), 'category': category, 'page': '$page', 'page_size': '$pageSize'}));

  Future<Facts> stockDetail(String itemId) async => Facts(await _send('GET', '/stock/$itemId'));

  Future<List<Facts>> movements({String? itemId, int? beforeId, int limit = 30}) async {
    final r = await _send('GET', '/movements', query: {'item_id': ?itemId, if (beforeId != null) 'before_id': '$beforeId', 'limit': '$limit'});
    return Facts(r).l('movements');
  }

  Future<Facts> movement(int id) async => Facts(await _send('GET', '/movements/$id'));

  Future<List<Facts>> documents(String type, {List<String> statuses = const [], String scope = 'all', String q = '', int limit = 20}) async {
    final r = await _send('GET', '/documents',
        query: {'doc_type': type, 'statuses': statuses.join(','), 'scope': scope, 'q': q.trim(), 'limit': '$limit'});
    return Facts(r).l('documents');
  }

  Future<InvDocument> document(String id) async => InvDocument(await _send('GET', '/documents/$id'));

  /// Creates a draft. [fields] are header fields (title, reason, note, supplier_name, po_ref, invoice_ref, expected_at, to_location_id, operator_id).
  Future<InvDocument> createDraft(String type, {Map<String, Object?> fields = const {}, List<DraftLine>? lines, required String key}) async =>
      InvDocument(await _send('POST', '/documents', key: key, body: {
        'doc_type': type,
        ...fields,
        if (lines != null) 'lines': lines.map((l) => l.toJson()).toList(),
      }));

  /// Saves a draft the person opened at [version]. Only the fields and lines sent change.
  Future<InvDocument> saveDraft(String id, {required int version, Map<String, Object?> fields = const {}, List<DraftLine>? lines}) async =>
      InvDocument(await _send('POST', '/documents/$id', body: {
        'version': version,
        ...fields,
        if (lines != null) 'lines': lines.map((l) => l.toJson()).toList(),
      }));

  /// submit / approve / reject / post / dispatch / receive / return / reopen / complete / cancel.
  Future<InvDocument> act(String id, String action, {required int version, String? note, String? key}) async =>
      InvDocument(await _send('POST', '/documents/$id/act', key: key ?? newKey(), body: {'action': action, 'version': version, 'note': ?note}));

  /// From an audit in review or completed: one adjustment draft for its variances (the same one again if it exists).
  Future<InvDocument> adjustmentFromAudit(String auditId, {String? key}) async =>
      InvDocument(await _send('POST', '/documents/$auditId/adjustment-draft', key: key ?? newKey()));

  Future<Facts> forecast(String itemId, {int days = 7, num? demandPerDay}) async =>
      Facts(await _send('GET', '/forecast', query: {'item_id': itemId, 'days': '$days', if (demandPerDay != null) 'demand_per_day': '$demandPerDay'}));
}

class InventoryApiException extends PartnerApiException {
  const InventoryApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}
