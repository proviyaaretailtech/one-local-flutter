import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

// The product media pool (founder, 30 Oct 2026). A store's own product photos are its Store Media Pool. The store may offer one to OneLocal: it
// then sits in the Master Media Pool, grouped by the store's category and then by brand or product category, waiting for review. Only a photo
// OneLocal approves moves into the Standard Data pool, and only those can be used by other stores, nationwide.

/// A photo in the pool (offered, approved, rejected or withdrawn).
class PoolPhoto {
  PoolPhoto(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('pool_id');
  String get imageUrl => _s('image_url');
  String get name => _s('name');
  String? get brand => (raw['brand'] as String?)?.isEmpty == true ? null : raw['brand'] as String?;
  String? get productCategory => raw['product_category'] as String?;
  String get storeCategory => _s('store_category');
  String get status => _s('status');
  String? get note => raw['decision_note'] as String?;
  int get uses => ((raw['use_count'] ?? 0) as num).toInt();
  String? get storeName => raw['store_name'] as String?;

  String get statusLabel => const {'submitted': 'Waiting for review', 'approved': 'In the Standard pool', 'rejected': 'Not approved', 'withdrawn': 'Taken back'}[status] ?? status;

  /// "Aashirvaad · Staples"
  String get group => [brand, productCategory].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
}

/// One of the store's items that has a photo: whether the store took it, and where it stands in the pool.
class StorePhoto {
  StorePhoto(this.raw);
  final Map<String, dynamic> raw;
  String get itemId => raw['menu_item_id'] as String;
  String get name => (raw['name'] ?? '') as String;
  String get imageUrl => (raw['image_url'] ?? '') as String;
  String? get brand => raw['brand'] as String?;
  String? get category => raw['category'] as String?;

  /// The store uploaded it itself (only these can be offered).
  bool get own => raw['own'] == true;

  /// Taken from the Standard pool.
  bool get fromStandard => raw['from_standard'] == true;
  PoolPhoto? get pool => raw['pool'] is Map ? PoolPhoto((raw['pool'] as Map).cast<String, dynamic>()) : null;

  /// Offer is open when the store took it and it is not waiting or approved already.
  bool get canOffer => own && (pool == null || pool!.status == 'rejected' || pool!.status == 'withdrawn');
}

class MediaApi {
  MediaApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  List<PoolPhoto> _photos(Map<String, dynamic> r) => ((r['items'] as List?) ?? const []).map((e) => PoolPhoto((e as Map).cast<String, dynamic>())).toList();

  /// The Store Media Pool, its counts, and whether this person reviews for OneLocal.
  Future<({List<StorePhoto> items, Map<String, int> counts, bool isAdmin})> storePool({String q = ''}) async {
    final r = await _rpc.callMap('media_store_pool', {if (q.trim().isNotEmpty) 'q': q.trim()});
    return (
      items: ((r['items'] as List?) ?? const []).map((e) => StorePhoto((e as Map).cast<String, dynamic>())).toList(),
      counts: {for (final e in ((r['counts'] as Map?) ?? const {}).entries) e.key.toString(): (e.value as num).toInt()},
      isAdmin: r['is_admin'] == true,
    );
  }

  Future<PoolPhoto> offer(String itemId) async => PoolPhoto(await _rpc.callMap('media_offer', {'menu_item_id': itemId}));
  Future<PoolPhoto> withdraw(String poolId) async => PoolPhoto(await _rpc.callMap('media_withdraw', {'pool_id': poolId}));

  /// The Standard Data pool (approved only). With [itemId], that item's pack barcode, brand and category put the best matches first.
  Future<List<PoolPhoto>> standard({String q = '', String? itemId}) async =>
      _photos(await _rpc.callMap('media_standard_search', {if (q.trim().isNotEmpty) 'q': q.trim(), 'menu_item_id': ?itemId}));

  /// Puts an approved photo on one of this store's items; answers its link.
  Future<String> use(String poolId, String itemId) async => (await _rpc.callMap('media_use', {'pool_id': poolId, 'menu_item_id': itemId}))['image_url'] as String;

  /// OneLocal: the Master Media Pool by status, and how it groups (store category → brand / product category).
  Future<({List<PoolPhoto> items, List<Map<String, dynamic>> groups})> queue({String status = 'submitted'}) async {
    final r = await _rpc.callMap('media_admin_queue', {'status': status});
    return (items: _photos(r), groups: ((r['groups'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList());
  }

  /// [mapProduct]: approving the photo also approves its product (barcode, brand, unit, SKU) as standard in the Master library.
  Future<PoolPhoto> decide(String poolId, {required bool approve, String? note, bool? mapProduct}) async => PoolPhoto(await _rpc.callMap('media_admin_decide', {
        'pool_id': poolId,
        'decision': approve ? 'approve' : 'reject',
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'map_product': ?mapProduct,
      }));
}
