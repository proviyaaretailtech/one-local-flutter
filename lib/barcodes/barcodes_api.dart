import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

// Store barcodes and loose items (founder, 30 Oct 2026; Master Architecture §2). A code the app makes is a store-level internal code on this
// store's own item, never a GTIN and never part of the master library:
//   store item code  EAN-13  200 + 9-digit store number + check digit
//   weigh label      EAN-13  21 + PLU (5) + weight in grams (5) + check digit
// A loose item is sold by weight: its price is per kg and it has a PLU. Every rule is checked again in the database.

/// One item as the barcode functions describe it.
class BcItem {
  BcItem(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('menu_item_id');
  String get name => _s('name');
  String get sku => _s('sku');
  num get price => (raw['price'] ?? 0) as num;
  String? get imageUrl => raw['image_url'] as String?;
  String? get barcode => (raw['barcode'] as String?)?.isEmpty == true ? null : raw['barcode'] as String?;
  String get category => _s('category');

  /// generated (made by the app), linked (a pack's code saved at the counter), custom (typed), or null (entered on the product).
  String? get barcodeSource => raw['barcode_source'] as String?;
  int? get plu => (raw['plu'] as num?)?.toInt();
  bool get loose => raw['loose'] == true;
  int? get mrpMinor => (raw['mrp_minor'] as num?)?.toInt();
}

/// A weigh label for one pack of a loose item.
class WeighLabel {
  WeighLabel(this.raw);
  final Map<String, dynamic> raw;
  String get code => raw['code'] as String;
  int get weightG => (raw['weight_g'] as num).toInt();
  String get weightText => raw['weight_text'] as String;
  num get amount => raw['amount'] as num;
  num get pricePerKg => (raw['price_per_kg'] ?? 0) as num;
  int? get plu => (raw['plu'] as num?)?.toInt();
  BcItem get item => BcItem((raw['item'] as Map).cast<String, dynamic>());
}

/// A scanned code on the Bill: an item, or a weighed pack of a loose item ([weightG] and [amount] set).
class ScanResult {
  ScanResult(this.raw);
  final Map<String, dynamic> raw;
  bool get weighed => raw['kind'] == 'weight';
  int? get weightG => (raw['weight_g'] as num?)?.toInt();
  num? get amount => raw['amount'] as num?;
  BcItem get item => BcItem((raw['item'] as Map).cast<String, dynamic>());
}

/// "1250" -> "1.250 kg", "500" -> "500 g" (as the database writes it on the bill).
String weightText(int grams) => grams < 1000 ? '$grams g' : '${(grams / 1000).toStringAsFixed(3)} kg';

class BarcodesApi {
  BarcodesApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  /// [tab]: missing (no barcode yet), all, loose. Answers the items and how many each tab has.
  Future<({List<BcItem> items, Map<String, int> counts})> list({String tab = 'missing', String q = ''}) async {
    final r = await _rpc.callMap('bc_list', {'tab': tab, if (q.trim().isNotEmpty) 'q': q.trim()});
    return (
      items: ((r['items'] as List?) ?? const []).map((e) => BcItem((e as Map).cast<String, dynamic>())).toList(),
      counts: {for (final e in ((r['counts'] as Map?) ?? const {}).entries) e.key.toString(): (e.value as num).toInt()},
    );
  }

  Future<BcItem> make(String itemId, {bool replace = false}) async => BcItem(await _rpc.callMap('bc_make', {'menu_item_id': itemId, if (replace) 'replace': true}));
  Future<int> makeAll() async => ((await _rpc.callMap('bc_make_all', {}))['made'] as num).toInt();
  Future<BcItem> link(String itemId, String code, {bool replace = false}) async =>
      BcItem(await _rpc.callMap('bc_link', {'menu_item_id': itemId, 'code': code.trim(), if (replace) 'replace': true}));

  /// A custom barcode: [code] null makes one. With [itemId] it is saved as that item's code ([item] answers it). Otherwise [usedBy] names the
  /// item that already has it.
  Future<({String code, String? usedBy, BcItem? item})> custom({String? code, String? itemId, bool replace = false}) async {
    final r = await _rpc.callMap('bc_custom', {if (code != null && code.trim().isNotEmpty) 'code': code.trim(), 'menu_item_id': ?itemId, if (replace) 'replace': true});
    return (code: r['code'] as String, usedBy: r['used_by'] as String?, item: r['item'] is Map ? BcItem((r['item'] as Map).cast<String, dynamic>()) : null);
  }

  Future<BcItem> setLoose(String itemId, bool loose) async => BcItem(await _rpc.callMap('bc_set_loose', {'menu_item_id': itemId, 'loose': loose}));
  Future<WeighLabel> weighLabel(String itemId, int grams) async => WeighLabel(await _rpc.callMap('bc_weigh_label', {'menu_item_id': itemId, 'weight_g': grams}));
  Future<ScanResult> resolve(String code) async => ScanResult(await _rpc.callMap('bc_resolve', {'code': code.trim()}));
}
