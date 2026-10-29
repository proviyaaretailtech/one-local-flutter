import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inv_env.dart';

/// Purchasing calls through the one generic door, `POST /rpc/<pur_function>` ([RpcClient]); the database functions of migration 0430 do the work and
/// check the business, the location, the role and every rule. Money is whole paise (`*_minor`); the app only formats it. Creating an order, starting
/// a receipt and choosing the preferred supplier carry an Idempotency-Key so a retried tap never doubles.
class PurchasingApi {
  PurchasingApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The store the screens look at; null lets the database use every store the person may see (reads) or their main one (writes).
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'pur-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{
      if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
      ...args,
    }..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw PurchasingApiException(e.status, e.message, e.code);
    }
  }

  /// Suppliers, stock items, known supplier prices and the open order count: what a new purchase order picks from.
  Future<Facts> options() async => Facts(await _call('pur_options', {}));

  /// Purchase History: [status] all / open / pending / received, [due] all / open / overdue.
  Future<Facts> orders({String status = 'all', String due = 'all', String q = '', int limit = 20}) async =>
      Facts(await _call('pur_po_list', {'status': status, 'due': due, 'q': q.trim().isEmpty ? null : q.trim(), 'limit': limit}));

  Future<PurchaseOrder> order(String id) async => PurchaseOrder(await _call('pur_po_view', {'id': id}));

  /// [lines]: `{inventory_item_id, qty, unit_cost_minor, gst_pct}`.
  /// The order is live at once (founder, 28 Oct 2026: one step, no approval); [submit] is kept for older servers.
  Future<PurchaseOrder> create({required String supplierId, required List<Map<String, Object?>> lines, String? notes, String? expectedDelivery, bool submit = true, required String key}) async =>
      PurchaseOrder(await _call('pur_po_create', {'supplier_id': supplierId, 'lines': lines, 'notes': notes, 'expected_delivery': expectedDelivery, 'submit': submit}, key: key));

  /// submit / approve / reject / cancel. The database decides who may, and refuses approving your own order above its limit.
  Future<PurchaseOrder> act(String id, String action, {String? note}) async => PurchaseOrder(await _call('pur_po_act', {'id': id, 'action': action, 'note': note}));

  /// Starts (or reopens) the receipt draft for an order. The answer names the receipt document ([Facts.s] `document_id`); section H's receiving screen takes it from there.
  Future<Facts> receive(String poId, {String? key}) async => Facts(await _call('pur_po_receive', {'id': poId}, key: key ?? newKey()));

  // ---- one-step purchase (founder, 28 Oct 2026): Generate PO, Received, the bill, past purchases

  /// Orders not received or cancelled yet, oldest first, each with days_waiting and its lines' MRP (mrp_minor).
  Future<List<PurchaseOrder>> openOrders() async => Facts(await _call('pur_po_open', {})).l('orders').map((f) => PurchaseOrder(f.raw)).toList();

  /// An item by name, code or barcode, with its MRP and price: the extra line on Received.
  Future<List<Facts>> findItems(String q) async => Facts(await _call('pur_item_find', {'q': q.trim()})).l('items');

  /// The store's categories with how many items each has, and with [categoryId] that category's items ('none': items in no category),
  /// to tick several at once on Add purchase. {categories: [{id, name, count}], items: [...as findItems]}
  Future<Facts> browseItems([String? categoryId]) async => Facts(await _call('pur_item_browse', {'category_id': ?categoryId}));

  /// Received, in one step: [lines] {inventory_item_id, qty, mrp, cost, ordered_qty}, money in rupees. Stock goes up, the MRP and price are saved on the
  /// items, the order ([poId]) is closed, and the bill is started. Without an order, [supplierName] says who it came from.
  Future<Facts> receivePost({String? poId, String? supplierName, String? invoiceNo, String? replaces, required List<Map<String, Object?>> lines, required String key}) async =>
      Facts(await _call('pur_receive_post', {'po_id': poId, 'supplier_name': supplierName, if (invoiceNo != null && invoiceNo.isNotEmpty) 'invoice_no': invoiceNo, if (replaces != null) 'replaces_receipt_id': replaces, 'lines': lines}, key: key));

  /// A received delivery (receipt) and its bill (bill).
  Future<Facts> bill(String receiptId) async => Facts(await _call('pur_bill_get', {'receipt_document_id': receiptId}));

  Future<Facts> saveBill(Map<String, Object?> body) async => Facts(await _call('pur_bill_save', body));

  /// Past purchases: [from] / [to] as yyyy-mm-dd, [sort] newest | oldest | amount.
  Future<List<Facts>> history({String? from, String? to, String q = '', String sort = 'newest'}) async =>
      Facts(await _call('pur_history', {'from': from, 'to': to, 'q': q.trim().isEmpty ? null : q.trim(), 'sort': sort})).l('purchases');

  Future<Facts> price(String priceId) async => Facts(await _call('pur_price_view', {'price_id': priceId}));

  /// Makes the supplier of [priceId] the preferred one for its ingredient (the database logs who, when, before and after).
  Future<Facts> selectSourcing(String priceId, {String? note, String? key}) async =>
      Facts(await _call('pur_sourcing_select', {'price_id': priceId, 'note': note}, key: key ?? newKey()));

  /// This business's suppliers with their contact details (`suppliers`: id, name, phone, gstin, city, contact_person, payment_terms).
  Future<List<Facts>> suppliers() async => Facts(await _call('pur_supplier_list', {})).l('suppliers');

  /// An item's usual supplier and its buying price (Quick Add): New order then suggests them.
  Future<Facts> setItemSupplier(String inventoryItemId, String supplierId, {int? priceMinor, String? key}) async => Facts(await _call('pur_item_supplier_set', {
        'inventory_item_id': inventoryItemId,
        'supplier_id': supplierId,
        'price_minor': ?priceMinor,
      }, key: key ?? newKey()));

  /// Adds a supplier ([id] null) or changes one. Only [name] is required; the database checks phone, GSTIN and duplicates.
  Future<Facts> saveSupplier({String? id, required String name, String? phone, String? gstin, String? city, String? key}) async => Facts(await _call('pur_supplier_save', {
        'id': id,
        'name': name.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (gstin != null && gstin.trim().isNotEmpty) 'gstin': gstin.trim(),
        if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
      }, key: key ?? newKey()));

  /// One audit round: `{name, detail, result: pass|warning|fail}` per check.
  Future<Facts> recordAudit(String priceId, List<Map<String, String>> checks) async => Facts(await _call('pur_audit_record', {'price_id': priceId, 'checks': checks}));
}

class PurchasingApiException extends PartnerApiException {
  const PurchasingApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}

/// One purchase order as `pur_po_view` / `pur_po_list` return it.
class PurchaseOrder extends Facts {
  const PurchaseOrder(super.raw);
  String get id => s('id');
  String get number => s('number');
  String get status => s('status');
  String get supplierName => m('supplier').s('name');
  List<Facts> get lines => l('lines');
  Facts get totals => m('totals');
  List<String> get actions => ls('allowed_actions');
  bool get canReceive => actions.contains('receive');
  bool can(String action) => actions.contains(action);
  bool get overdue => b('overdue');
  Facts? get openReceipt => mo('open_receipt');
}

/// The purchasing screens' environment: the API, and section H's [InvEnv] for the bottom bar and the receiving screen the receipt hands over to.
class PurEnv {
  PurEnv({PurchasingApi? api, InvEnv? inv}) : api = api ?? PurchasingApi(), inv = inv ?? InvEnv();
  final PurchasingApi api;
  final InvEnv inv;
}
