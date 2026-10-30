import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

// Standard SKUs (founder's "OL SKU.xlsx", 31 Oct 2026). The database makes every SKU from the item's parts; the app only picks them.
//   MRP-based    OL-SUB-BRD-SIZE-NN          one list for every OneLocal store; the same barcode reuses the SKU
//   store-based  OL-SUB-ITM-SIZE-INI-DDMM-NN  the store's own: its initials and the day and month the item was made

class SkuSub {
  SkuSub(this.raw);
  final Map<String, dynamic> raw;
  String get code => '${raw['code']}';
  String get name => '${raw['name']}';
  String get category => '${raw['category'] ?? ''}';
  String get examples => '${raw['examples'] ?? ''}';
  String get units => '${raw['units'] ?? ''}';
}

class SkuBrand {
  SkuBrand(this.raw);
  final Map<String, dynamic> raw;
  String get code => '${raw['code']}';
  String get name => '${raw['name']}';

  /// brand (packed goods), loose_item (TOM), local_brand (SGU) or reserved (LSE: loose / unbranded).
  String get kind => '${raw['kind']}';
  String get synonyms => '${raw['synonyms'] ?? ''}';

  /// approved, or pending: proposed by a store, waiting for Master review (it is used meanwhile).
  String get status => '${raw['status']}';
  bool get pending => status == 'pending';
}

class SkuOptions {
  SkuOptions(Map<String, dynamic> raw)
      : subs = ((raw['subcategories'] as List?) ?? const []).map((e) => SkuSub((e as Map).cast<String, dynamic>())).toList(),
        units = ((raw['units'] as List?) ?? const []).map((e) => '${(e as Map)['code']}').toList(),
        brands = ((raw['brands'] as List?) ?? const []).map((e) => SkuBrand((e as Map).cast<String, dynamic>())).toList(),
        initials = '${raw['store_initials'] ?? ''}',
        lot = '${raw['lot'] ?? ''}';
  final List<SkuSub> subs;
  final List<String> units;
  final List<SkuBrand> brands;

  /// The store's initials and today's lot (DDMM), for a store-based SKU's preview.
  final String initials, lot;
}

/// An OneLocal product (the Master list): found by its barcode, or one of the variants with the same parts.
class MasterProduct {
  MasterProduct(this.raw);
  final Map<String, dynamic> raw;
  String get sku => '${raw['sku']}';
  String get name => '${raw['name'] ?? ''}';
  String get sub => '${raw['sub'] ?? ''}';
  String get slot3 => '${raw['slot3'] ?? ''}';
  String get size => '${raw['size'] ?? ''}';
  String? get barcode => raw['barcode'] as String?;
  String? get imageUrl => raw['image_url'] as String?;
  bool get approved => raw['status'] == 'approved';
}

/// The parts an SKU is made from. [masterSku]: the OneLocal product this item is (its SKU is reused).
class SkuParts {
  const SkuParts({required this.sub, required this.slot3, required this.size, this.masterSku});
  final String sub, slot3, size;
  final String? masterSku;
  Map<String, dynamic> toJson() => {'sub': sub, 'slot3': slot3, 'size': size, 'master_sku': ?masterSku};
}

class SkuApi {
  SkuApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<SkuOptions> options() async => SkuOptions(await _rpc.callMap('sku_options', {}));

  /// Barcode first: the OneLocal product with this barcode, or null.
  Future<MasterProduct?> lookup(String barcode) async {
    final r = await _rpc.callMap('sku_lookup', {'barcode': barcode.trim()});
    return r['found'] == true ? MasterProduct(r) : null;
  }

  Future<List<MasterProduct>> variants({required String sub, required String slot3, required String size}) async =>
      (((await _rpc.callMap('sku_variants', {'sub': sub, 'slot3': slot3, 'size': size}))['variants'] as List?) ?? const [])
          .map((e) => MasterProduct((e as Map).cast<String, dynamic>()))
          .toList();

  /// A brand the list does not have: its code (proposed now, used at once, checked in Master review).
  Future<SkuBrand> proposeBrand(String name, {String kind = 'brand', String? barcode}) async =>
      SkuBrand(await _rpc.callMap('sku_brand_propose', {'name': name.trim(), 'kind': kind, if (barcode != null && barcode.trim().isNotEmpty) 'barcode': barcode.trim()}));
}
