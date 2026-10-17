import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;

/// Storefront calls through the one generic door, `POST /rpc/<sf_function>` ([RpcClient]); the database functions of migrations 0450-0451
/// do the work and check the business, the role and every rule. The Supabase session token is the only credential. Pictures go through the
/// secure `storefront_image_slot` / `storefront_image_attach` handlers: the app only ever sends bytes to a one-time signed upload address.
class StorefrontApi {
  StorefrontApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final http.Client _http;
  final RpcClient _rpc;

  Future<Facts> _c(String fn, [Map<String, Object?> args = const {}]) async {
    try {
      return Facts(await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null)));
    } on RpcException catch (e) {
      throw StorefrontException(e.status, e.message, e.code);
    }
  }

  Future<Facts> options() => _c('sf_options');

  /// The page being edited: `source` (draft / published / starter), `definition`, `draft_version`, `published_version`, `has_unpublished_changes`.
  Future<Facts> builder() => _c('sf_builder_get');
  Future<Facts> saveDraft(int draftVersion, Map<String, dynamic> definition) => _c('sf_draft_save', {'expected_draft_version': draftVersion, 'definition': definition});
  Future<Facts> discardDraft({int? draftVersion}) => _c('sf_draft_discard', {'expected_draft_version': draftVersion});
  Future<Facts> preview({bool published = false}) => _c('sf_preview', {'source': published ? 'published' : 'draft'});

  /// Publishes the SAVED draft; [expectedVersion] is the live version the person saw, [draftVersion] the draft they previewed.
  Future<Facts> publish({required int expectedVersion, int? draftVersion}) => _c('sf_publish', {'expected_version': expectedVersion, 'expected_draft_version': draftVersion});

  Future<Facts> products({String filter = 'all', String q = '', int limit = 30, int offset = 0}) =>
      _c('sf_products', {'filter': filter, 'q': q.trim().isEmpty ? null : q.trim(), 'limit': limit, 'offset': offset});
  Future<Facts> saveProduct(Map<String, Object?> body) => _c('sf_product_save', body);

  Future<Facts> settings() => _c('sf_settings_get');
  Future<Facts> saveProfile(Map<String, Object?> body) => _c('sf_profile_save', body);
  Future<Facts> saveHours({required bool show, required List<Map<String, Object?>> days}) => _c('sf_hours_save', {'show': show, 'days': days});
  Future<Facts> saveDelivery(Map<String, Object?> body) => _c('sf_delivery_save', body);

  Future<List<Facts>> offers() async => (await _c('sf_offer_list')).l('offers');
  Future<Facts> saveOffer(Map<String, Object?> body) => _c('sf_offer_save', body);
  Future<Facts> actOffer(String id, String action) => _c('sf_offer_act', {'id': id, 'action': action});

  Future<List<Facts>> ads() async => (await _c('sf_ad_list')).l('ads');
  Future<Facts> saveAd(Map<String, Object?> body) => _c('sf_ad_save', body);
  Future<Facts> actAd(String id, String action) => _c('sf_ad_act', {'id': id, 'action': action});

  Future<List<Facts>> images({String? kind}) async => (await _c('sf_image_library', {'kind': kind})).l('images');

  /// Ask for a one-time slot, send the bytes to it, then confirm so the server records the picture. Answers `{id, kind, image_url}`.
  Future<Facts> uploadImage({required String kind, required Uint8List bytes, required String contentType}) async {
    final slot = await _c('storefront_image_slot', {'kind': kind, 'content_type': contentType, 'size': bytes.length});
    final put = await _http.put(Uri.parse(slot.s('upload_url')), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const StorefrontException(502, 'The upload did not finish. Please try again.', null);
    return _c('storefront_image_attach', {'kind': kind, 'path': slot.s('path'), 'content_type': contentType, 'size': bytes.length});
  }

  /// Logo or cover: the existing setup handlers (owner only). Answers the setup state; the app only needs to know it worked.
  Future<void> uploadListingImage({required String kind, required Uint8List bytes, required String contentType}) async {
    final slot = await _rpc.callMap('partner_setup_image_slot', {'kind': kind, 'content_type': contentType, 'size': bytes.length});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const StorefrontException(502, 'The upload did not finish. Please try again.', null);
    await _rpc.callMap('partner_setup_image_attach', {'kind': kind, 'path': slot['path'], 'content_type': contentType, 'size': bytes.length});
  }
}

class StorefrontException extends PartnerApiException {
  const StorefrontException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}

/// One page section as the draft holds it: `{id, type, title, enabled, config}`. Editing returns a changed copy.
class Section {
  Section(Map<String, dynamic> raw) : raw = Map<String, dynamic>.from(raw)..['config'] = Map<String, dynamic>.from((raw['config'] as Map?) ?? const {});
  final Map<String, dynamic> raw;
  String get id => '${raw['id']}';
  String get type => '${raw['type']}';
  String get title => '${raw['title'] ?? ''}';
  bool get enabled => raw['enabled'] != false;
  Map<String, dynamic> get config => raw['config'] as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String k) => ((config[k] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  Section copy() => Section(raw);
  Map<String, dynamic> toJson() => raw;

  /// Name shown in the builder list (Figma: Header, Banner / Slider, Category Grid, Product List, Deals Section).
  String get label => title.isNotEmpty ? title : sectionLabel(type);
}

String sectionLabel(String type) => const {
      'header': 'Header',
      'banner': 'Banner / Slider',
      'category_grid': 'Category Grid',
      'product_list': 'Product List',
      'deals': 'Deals Section',
      'custom_card': 'Custom Card',
      'brand': 'Brand Section',
      'divider': 'Divider',
      'ads': 'Ads',
    }[type] ??
    type;
