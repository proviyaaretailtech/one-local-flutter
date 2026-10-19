import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../outlets/outlet_scope.dart';
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

/// One stock document (receipt, adjustment, transfer, audit) as `inv_document_view` returns it.
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

/// Inventory calls through the one generic door, `POST /rpc/<inv_function>` ([RpcClient]); the database functions of migrations 0400-0403 do
/// the work and check the business, the location, the role and every rule. The Supabase session token is the only credential. Creating a
/// document and every document action carry an Idempotency-Key so a retried tap never doubles; edits carry the version the person saw.
class InventoryApi {
  InventoryApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The store the screens look at; null lets the database pick the person's main location.
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'inv-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{
      // the outlet chosen in the header's switcher when the screen names none (specs/outlets-multi)
      if (OutletScope.pick(locationId) != null) 'location_id': OutletScope.pick(locationId),
      ...args,
    }..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw InventoryApiException(e.status, e.message, e.code);
    }
  }

  Future<Facts> options() async => Facts(await _call('inv_options', {}));
  Future<Facts> dashboard() async => Facts(await _call('inv_dashboard', {}));

  Future<Facts> stock({String filter = 'all', String q = '', String category = '', int page = 1, int pageSize = 8}) async =>
      Facts(await _call('inv_stock_list', {'filter': filter, 'q': q.trim(), 'category': category, 'page': page, 'page_size': pageSize}));

  Future<Facts> stockDetail(String itemId) async => Facts(await _call('inv_stock_detail', {'item_id': itemId}));

  Future<List<Facts>> movements({String? itemId, int? beforeId, int limit = 30}) async {
    final r = await _call('inv_movement_list', {'item_id': itemId, 'before_id': beforeId, 'limit': limit});
    return Facts(r).l('movements');
  }

  Future<Facts> movement(int id) async => Facts(await _call('inv_movement_detail', {'id': id}));

  Future<List<Facts>> documents(String type, {List<String> statuses = const [], String scope = 'all', String q = '', int limit = 20}) async {
    final r = await _call('inv_document_list', {'doc_type': type, 'statuses': statuses.isEmpty ? null : statuses, 'scope': scope, 'q': q.trim(), 'limit': limit});
    return Facts(r).l('documents');
  }

  Future<InvDocument> document(String id) async => InvDocument(await _call('inv_document_view', {'id': id}));

  /// Creates a draft. [fields] are header fields (title, reason, note, supplier_name, po_ref, invoice_ref, expected_at, to_location_id, operator_id).
  Future<InvDocument> createDraft(String type, {Map<String, Object?> fields = const {}, List<DraftLine>? lines, required String key}) async =>
      InvDocument(await _call('inv_document_save', {
        'doc_type': type,
        ...fields,
        if (lines != null) 'lines': lines.map((l) => l.toJson()).toList(),
      }, key: key));

  /// Saves a draft the person opened at [version]. Only the fields and lines sent change.
  Future<InvDocument> saveDraft(String id, {required int version, Map<String, Object?> fields = const {}, List<DraftLine>? lines}) async =>
      InvDocument(await _call('inv_document_save', {
        'id': id,
        'version': version,
        ...fields,
        if (lines != null) 'lines': lines.map((l) => l.toJson()).toList(),
      }));

  /// submit / approve / reject / post / dispatch / receive / return / reopen / complete / cancel.
  Future<InvDocument> act(String id, String action, {required int version, String? note, String? key}) async =>
      InvDocument(await _call('inv_document_act', {'id': id, 'action': action, 'version': version, 'note': note}, key: key ?? newKey()));

  /// From an audit in review or completed: one adjustment draft for its variances (the same one again if it exists).
  Future<InvDocument> adjustmentFromAudit(String auditId, {String? key}) async =>
      InvDocument(await _call('inv_audit_to_adjustment', {'id': auditId}, key: key ?? newKey()));

  Future<Facts> forecast(String itemId, {int days = 7, num? demandPerDay}) async =>
      Facts(await _call('inv_forecast', {'item_id': itemId, 'days': days, 'demand_per_day': demandPerDay}));
}

class InventoryApiException extends PartnerApiException {
  const InventoryApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}
