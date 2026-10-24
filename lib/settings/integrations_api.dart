import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

/// One provider on the Integrations page, as `pos_integrations_get` describes it. The keys never come back: only the last four characters of
/// the main key ([keyHint]) and the non-secret account fields, and those only for a person who may change integrations.
class IntegrationInfo {
  IntegrationInfo(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  String? _s(Map<String, dynamic> m, String k) {
    final v = m[k];
    return v == null || v.toString().isEmpty ? null : v.toString();
  }

  String get provider => raw['provider']?.toString() ?? '';

  /// `connected`, `error` (the last check failed; the keys are kept) or `disconnected`.
  String get status => raw['status']?.toString() ?? 'disconnected';
  bool get isConnected => status != 'disconnected';
  bool get needsAttention => status == 'error';

  String? get restaurantId => _s(_m('account'), 'restaurant_id');
  String? get storeUrl => _s(_m('account'), 'store_url');
  String? get outletId => _s(_m('account'), 'outlet_id');
  String? get keyHint => _s(raw, 'key_hint');

  bool get syncMenu => _m('sync')['menu'] == true;
  bool get syncOrders => _m('sync')['orders'] == true;
  bool get syncStock => _m('sync')['stock'] == true;

  DateTime? get lastCheckAt => DateTime.tryParse(_m('last_check')['at']?.toString() ?? '')?.toLocal();
  bool? get lastCheckOk => _m('last_check')['ok'] as bool?;
  String? get lastCheckMessage => _s(_m('last_check'), 'message');
}

/// The Integrations page. [check] is only set on the answer of a connection check (`pos_integration_test`).
class IntegrationsState {
  IntegrationsState(this.raw);
  final Map<String, dynamic> raw;

  bool get canEdit => raw['can_edit'] == true;
  List<IntegrationInfo> get integrations => ((raw['integrations'] as List?) ?? const []).map((e) => IntegrationInfo((e as Map).cast<String, dynamic>())).toList();
  IntegrationInfo? of(String provider) => integrations.where((i) => i.provider == provider).firstOrNull;

  ({bool ok, String message})? get check {
    final c = (raw['check'] as Map?)?.cast<String, dynamic>();
    return c == null ? null : (ok: c['ok'] == true, message: c['message']?.toString() ?? '');
  }
}

/// What the app says about each provider. The database decides which providers exist; one it lists that the app does not know is still
/// drawn, by its id.
class ProviderInfo {
  const ProviderInfo({required this.name, required this.blurb, required this.menu, required this.orders, required this.stock, required this.help});
  final String name, blurb, help;

  /// The labels of the three sync switches for this provider (title, subtitle).
  final (String, String) menu, orders, stock;
}

const kIntegrationProviders = <String, ProviderInfo>{
  'petpooja': ProviderInfo(
    name: 'Petpooja',
    blurb: 'Restaurant POS. Bring in your Petpooja menu and send One Local orders to your Petpooja billing.',
    menu: ('Menu', 'Import categories, items and prices from Petpooja'),
    orders: ('Orders', 'Send One Local orders to Petpooja for billing and KOT'),
    stock: ('Item availability', 'Mark items in or out of stock when Petpooja does'),
    help: 'Petpooja gives you these when it turns on the online-ordering integration for your outlet. Ask Petpooja support for your restaurant ID, app key, app secret and access token.',
  ),
  'gofrugal': ProviderInfo(
    name: 'GoFrugal',
    blurb: 'Retail and restaurant ERP. Bring in your GoFrugal items and stock and send One Local orders as sales orders.',
    menu: ('Items & prices', 'Import items, prices and taxes from GoFrugal'),
    orders: ('Orders', 'Send One Local orders to GoFrugal as sales orders'),
    stock: ('Stock', 'Keep stock levels in step with GoFrugal'),
    help: 'In GoFrugal: turn on the eCommerce API add-on, then take the API key from WebReporter > API users (HQ: Admin > Employee details > API key). The store URL is shown in SAM as "Store URL".',
  ),
};

ProviderInfo providerInfo(String id) =>
    kIntegrationProviders[id] ?? ProviderInfo(name: id, blurb: '', menu: ('Menu', ''), orders: ('Orders', ''), stock: ('Stock', ''), help: '');

/// One call per action through the one `/rpc/<name>` door ([RpcClient]). Connecting and checking go to the server's secure handlers, which
/// talk to the provider and keep the keys encrypted in the database; every rule (who may, connect before sync) is the database's.
class IntegrationsApi {
  IntegrationsApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<IntegrationsState> _state(String fn, [Map<String, dynamic> args = const {}]) async => IntegrationsState(await _rpc.callMap(fn, args));

  Future<IntegrationsState> get() => _state('pos_integrations_get');

  Future<IntegrationsState> connectPetpooja({required String restaurantId, required String appKey, required String appSecret, required String accessToken}) =>
      _state('pos_integration_connect', {'provider': 'petpooja', 'restaurant_id': restaurantId, 'app_key': appKey, 'app_secret': appSecret, 'access_token': accessToken});

  Future<IntegrationsState> connectGofrugal({required String storeUrl, required String apiKey, String? outletId}) =>
      _state('pos_integration_connect', {'provider': 'gofrugal', 'store_url': storeUrl, 'api_key': apiKey, if ((outletId ?? '').isNotEmpty) 'outlet_id': outletId});

  /// Checks the saved keys with the provider again. The answer's [IntegrationsState.check] says how it went.
  Future<IntegrationsState> test(String provider) => _state('pos_integration_test', {'provider': provider});

  Future<IntegrationsState> setSync(String provider, {bool? menu, bool? orders, bool? stock}) =>
      _state('pos_integration_set_sync', {'provider': provider, 'menu': ?menu, 'orders': ?orders, 'stock': ?stock});

  Future<IntegrationsState> disconnect(String provider) => _state('pos_integration_disconnect', {'provider': provider});
}
