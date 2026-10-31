import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

/// Section G calls through the POS server's one generic endpoint (`POST /rpc/<name>`: cat_item_* and grn_*, see
/// server/src/rpc-manifest.ts). The Supabase session token is the only credential; the server runs each function as the signed-in
/// person and the database checks the business, the location, the role and every rule. The app holds no business rule: it draws
/// what the database says and sends what the person typed. Money travels in minor units (paise).
class CatalogueApi {
  CatalogueApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The same door for the SKU lists (SkuApi), so a screen built with this API reaches the same server.
  RpcClient get rpc => _rpc;
  static final _rand = Random.secure();

  /// One key per intent (one tap); send it again when retrying that same tap.
  static String newKey() => 'cat-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, args, key);
    } on RpcException catch (e) {
      throw CatalogueApiException(e.status, e.message, e.code);
    }
  }

  // ---------------------------------------------------------------- catalogue
  Future<CatalogueList> list({String q = '', String status = 'all', String? category, int page = 1, int pageSize = 20}) async {
    final r = await _call('cat_item_list', {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (status != 'all') 'status': status,
      'category': ?category,
      'page': page,
      'page_size': pageSize,
    });
    return CatalogueList(r);
  }

  Future<CatItem> lookup(String code) async => CatItem(await _call('cat_item_lookup', {'code': code.trim()}));
  Future<CatItem> get(String id) async => CatItem(await _call('cat_item_view', {'id': id}));

  /// The categories (and subcategories) the store registered with at onboarding: Quick add lists them first.
  Future<List<String>> storeCategories() async =>
      (((await _call('cat_store_categories', {}))['categories'] as List?) ?? const []).map((e) => e.toString()).toList();

  /// [fields] holds only what the person typed (names as the database expects them); `version` is required when [id] is set.
  Future<CatItem> save(Map<String, dynamic> fields, {String? id, String? key}) async => CatItem(id == null
      ? await _call('cat_item_save', fields, key: key ?? newKey())
      : await _call('cat_item_save', {...fields, 'id': id}));

  // ---------------------------------------------------------------- GRN (receiptId is the section H receipt document)
  Future<List<GrnQueueRow>> grnQueue() async {
    final r = await _call('grn_list', {});
    return ((r['items'] as List?) ?? const []).map((e) => GrnQueueRow((e as Map).cast<String, dynamic>())).toList();
  }

  Map<String, dynamic> _r(String receiptId) => {'receipt_document_id': receiptId};
  Future<GrnView> grnOpen(String receiptId) async => GrnView(await _call('grn_open', _r(receiptId)));
  Future<GrnView> grn(String receiptId) async => GrnView(await _call('grn_view', _r(receiptId)));
  Future<GrnMatching> grnMatching(String receiptId) async => GrnMatching(await _call('grn_matching_view', _r(receiptId)));

  Future<GrnView> grnResolve(String receiptId, {required int version, required String resolution, String? claimRef, String? evidence, String? note}) async =>
      GrnView(await _call('grn_resolve', {
        ..._r(receiptId),
        'version': version,
        'resolution': resolution,
        if (claimRef != null && claimRef.trim().isNotEmpty) 'claim_ref': claimRef.trim(),
        if (evidence != null && evidence.trim().isNotEmpty) 'evidence': evidence.trim(),
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }));

  /// The supplier's bill for a delivery: its number and date, and one line per product (quantity and unit price before GST).
  Future<GrnView> grnInvoiceSave(String receiptId, {required String supplier, required String invoiceNo, required DateTime date, String poRef = '',
          required List<({String? itemId, String name, num qty, int unitPriceMinor})> lines}) async =>
      GrnView(await _call('grn_invoice_save', {
        ..._r(receiptId),
        'supplier_name': supplier.trim(),
        'invoice_no': invoiceNo.trim(),
        'invoice_date': '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        if (poRef.isNotEmpty) 'po_ref': poRef,
        'lines': [for (final l in lines) {'inventory_item_id': ?l.itemId, 'product_name': l.name, 'qty': l.qty, 'unit_price_minor': l.unitPriceMinor}],
      }));

  Future<GrnView> grnRequestApproval(String receiptId, {required int version}) async =>
      GrnView(await _call('grn_request_approval', {..._r(receiptId), 'version': version}));

  Future<GrnView> grnDecide(String receiptId, {required int version, required bool approve, String? note}) async =>
      GrnView(await _call('grn_decide', {
        ..._r(receiptId),
        'version': version,
        'decision': approve ? 'approve' : 'reject',
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }));
}

class CatalogueApiException extends PartnerApiException {
  const CatalogueApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
  bool get taxRequired => code == 'tax_required';
}

/// One catalogue item as the server describes it. Every label comes from the server's data; nothing is decided here.
class CatItem {
  CatItem(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String? _n(String k) => raw[k]?.toString();

  String get id => _s('id');
  String get name => _s('name');
  String get sku => _s('sku');
  String get category => _s('category');
  String? get brand => _n('brand');
  String? get barcode => _n('barcode');
  bool get hasBarcode => raw['has_barcode'] == true;
  int get priceMinor => (raw['price_minor'] as num?)?.toInt() ?? 0;
  int? get mrpMinor => (raw['mrp_minor'] as num?)?.toInt();
  int? get costMinor => (raw['cost_minor'] as num?)?.toInt();
  String get currency => _s('currency').isEmpty ? 'INR' : _s('currency');
  String get sellingUnit => _s('selling_unit').isEmpty ? 'pc' : _s('selling_unit');
  num? get netQty => raw['net_qty'] as num?;
  String? get netQtyUnit => _n('net_qty_unit');
  String? get unitDescription => _n('unit_description');
  num get purchasePackUnits => (raw['purchase_pack_units'] as num?) ?? 1;
  String? get storage => _n('storage');
  String? get hsn => _n('hsn');
  num? get gstPct => raw['gst_pct'] as num?;
  bool get taxVerified => raw['tax_verified'] == true;
  String get status => _s('status');
  bool get available => raw['available'] == true;
  num? get stockQty => raw['stock_qty'] as num?;
  String? get imageUrl => _n('image_url');
  int get version => (raw['version'] as num?)?.toInt() ?? 1;
  String get kind => _s('item_kind');
}

class CatalogueList {
  CatalogueList(this.raw);
  final Map<String, dynamic> raw;
  Map<String, dynamic> get counts => (raw['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
  int count(String k) => (counts[k] as num?)?.toInt() ?? 0;
  List<String> get categories => ((raw['categories'] as List?) ?? const []).map((e) => e.toString()).toList();
  List<CatItem> get items => ((raw['items'] as List?) ?? const []).map((e) => CatItem((e as Map).cast<String, dynamic>())).toList();
  int get totalMatching => (raw['total_matching'] as num?)?.toInt() ?? 0;
  int get page => (raw['page'] as num?)?.toInt() ?? 1;
  int get pageSize => (raw['page_size'] as num?)?.toInt() ?? 20;
}

// ---------------------------------------------------------------- GRN models
class GrnQueueRow {
  GrnQueueRow(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get receiptId => _s('receipt_document_id');
  String get docNo => _s('doc_no');
  String get grnNo => _s('grn_no');
  String get docStatus => _s('doc_status');
  String get reviewStatus => _s('review_status');
  String get supplier => _s('supplier_name');
  String get invoiceNo => _s('invoice_no');
  String get poRef => _s('po_ref');
  bool get hasInvoice => raw['has_invoice'] == true;
  int? get exceptions => (raw['exceptions'] as num?)?.toInt();
}

/// One matched line: the invoice side and the received side, with the state the database worked out.
class GrnRow {
  GrnRow(this.raw);
  final Map<String, dynamic> raw;
  String get state => (raw['state'] ?? '').toString();
  String get severity => (raw['severity'] ?? 'ok').toString();
  Map<String, dynamic>? get invoice => (raw['invoice'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get received => (raw['received'] as Map?)?.cast<String, dynamic>();
  num get acceptedQty => (raw['accepted_qty'] as num?) ?? 0;
  num get shortfallQty => (raw['shortfall_qty'] as num?) ?? 0;
  int get claimMinor => (raw['claim_minor'] as num?)?.toInt() ?? 0;
  int get acceptedValueMinor => (raw['accepted_value_minor'] as num?)?.toInt() ?? 0;
  String get name => (invoice?['name'] ?? received?['name'] ?? '').toString();
  String get itemId => (raw['item_id'] ?? name).toString();

  /// The GST rate on this line: the purchase order's, else the product's catalogue rate (0 when neither says).
  num get gstPct => (raw['gst_pct'] as num?) ?? 0;

  /// What one unit should cost before the bill is in: the purchase order's price, else the product's cost.
  num? get refUnitMinor => raw['ref_unit_minor'] as num?;
}

class GrnMatching {
  GrnMatching(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get receiptId => _s('receipt_document_id');
  String get docNo => _s('doc_no');
  String get invoiceNo => _s('invoice_no');
  String get invoiceDate => _s('invoice_date');
  String get supplier => _s('supplier_name');
  bool get hasInvoice => raw['has_invoice'] == true;
  String? get operatorName => (raw['operator'] as Map?)?['name'] as String?;
  List<Map<String, dynamic>> get invoiceLines => ((raw['invoice_lines'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  List<GrnRow> get rows => ((raw['rows'] as List?) ?? const []).map((e) => GrnRow((e as Map).cast<String, dynamic>())).toList();
  int get matched => (raw['matched'] as num?)?.toInt() ?? 0;
  int get exceptions => (raw['exceptions'] as num?)?.toInt() ?? 0;
}

class GrnView {
  GrnView(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  List<Map<String, dynamic>> _l(String k) => ((raw[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  String get receiptId => _s('receipt_document_id');
  String get grnNo => _s('grn_no');
  String get docNo => _s('doc_no');
  String get poRef => _s('po_ref');
  String get invoiceNo => _s('invoice_no');
  String get supplier => _s('supplier_name');
  bool get hasInvoice => raw['has_invoice'] == true;
  String get status => _s('status');
  int get version => (raw['version'] as num?)?.toInt() ?? 1;
  bool get posted => _s('posting_status') == 'posted';
  Map<String, dynamic> get approver => _m('approver');
  Map<String, dynamic> get totals => _m('totals');
  int get exceptions => (totals['exceptions'] as num?)?.toInt() ?? 0;
  int get claimMinor => (totals['claim_minor'] as num?)?.toInt() ?? 0;
  List<GrnRow> get rows => _l('rows').map(GrnRow.new).toList();
  Map<String, dynamic> get resolution => _m('resolution');
  List<Map<String, dynamic>> get options => ((resolution['options'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  List<Map<String, dynamic>> get preview => _l('preview');
  List<Map<String, dynamic>> get checklist => _l('checklist');
  List<String> get blockers => ((raw['blockers'] as List?) ?? const []).map((e) => e.toString()).toList();
  Map<String, dynamic> get actions => _m('actions');
  bool can(String a) => actions[a] == true;
  bool get voided => raw['voided'] == true;
  String? get decisionNote => raw['decision_note'] as String?;
}
