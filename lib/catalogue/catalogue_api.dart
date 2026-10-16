import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';

/// Section G server calls (`/api/partner/catalogue/*` and `/api/partner/grn/*`). The Supabase session token is the only credential; the
/// server and the database check the business, the role and every rule again. The app holds no business rule: it draws what the server
/// says and sends what the person typed. Money travels in minor units (paise).
class CatalogueApi {
  CatalogueApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;
  static final _rand = Random.secure();

  /// One key per intent (one tap); send it again when retrying that same tap.
  static String newKey() => 'cat-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    var uri = Uri.parse('$_base/api/partner$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final headers = {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json', 'Idempotency-Key': ?key};
    final enc = body == null ? null : jsonEncode(body);
    final future = switch (method) {
      'GET' => _http.get(uri, headers: headers),
      'PUT' => _http.put(uri, headers: headers, body: enc),
      _ => _http.post(uri, headers: headers, body: enc),
    };
    final res = await future.timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CatalogueApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  // ---------------------------------------------------------------- catalogue
  Future<CatalogueList> list({String q = '', String status = 'all', String? category, int page = 1, int pageSize = 20}) async {
    final r = await _send('GET', '/catalogue', query: {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (status != 'all') 'status': status,
      'category': ?category,
      'page': '$page',
      'page_size': '$pageSize',
    });
    return CatalogueList(r);
  }

  Future<CatItem> lookup(String code) async => CatItem((await _send('GET', '/catalogue/lookup', query: {'code': code.trim()})));
  Future<CatItem> get(String id) async => CatItem(await _send('GET', '/catalogue/$id'));

  /// [fields] holds only what the person typed (names as the server expects them); `version` is required when [id] is set.
  Future<CatItem> save(Map<String, dynamic> fields, {String? id, String? key}) async => CatItem(id == null
      ? await _send('POST', '/catalogue', body: fields, key: key ?? newKey())
      : await _send('PUT', '/catalogue/$id', body: fields));

  // ---------------------------------------------------------------- GRN
  Future<List<GrnQueueRow>> grnQueue() async {
    final r = await _send('GET', '/grn');
    return ((r['items'] as List?) ?? const []).map((e) => GrnQueueRow((e as Map).cast<String, dynamic>())).toList();
  }

  Future<GrnView> grnOpen(String receiptId) async => GrnView(await _send('POST', '/grn/open', body: {'receipt_document_id': receiptId}));
  Future<GrnView> grn(String receiptId) async => GrnView(await _send('GET', '/grn/$receiptId'));
  Future<GrnMatching> grnMatching(String receiptId) async => GrnMatching(await _send('GET', '/grn/$receiptId/matching'));

  Future<GrnView> grnResolve(String receiptId, {required int version, required String resolution, String? claimRef, String? evidence, String? note}) async =>
      GrnView(await _send('POST', '/grn/$receiptId/resolve', body: {
        'version': version,
        'resolution': resolution,
        if (claimRef != null && claimRef.trim().isNotEmpty) 'claim_ref': claimRef.trim(),
        if (evidence != null && evidence.trim().isNotEmpty) 'evidence': evidence.trim(),
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }));

  Future<GrnView> grnRequestApproval(String receiptId, {required int version}) async =>
      GrnView(await _send('POST', '/grn/$receiptId/request-approval', body: {'version': version}));

  Future<GrnView> grnDecide(String receiptId, {required int version, required bool approve, String? note}) async =>
      GrnView(await _send('POST', '/grn/$receiptId/decide', body: {
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
