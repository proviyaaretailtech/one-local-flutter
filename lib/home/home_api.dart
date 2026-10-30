
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';
import '../api/app_env.dart';
import '../api/net_guard.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
int? _int(Object? v) => _num(v)?.toInt();

/// One active order card. Status is the server's own status string; the screen only labels it.
class ActiveOrder {
  ActiveOrder(Map<String, dynamic> j)
      : id = (j['id'] ?? '') as String,
        number = (j['number'] ?? '').toString(),
        items = _int(j['items']),
        total = _num(j['total']),
        fulfilment = (j['fulfilment'] ?? '') as String,
        status = (j['status'] ?? '') as String,
        etaMinutes = _int(j['eta_minutes']);
  final String id, number, fulfilment, status;
  final int? items, etaMinutes;
  final num? total;
  bool get isDelivery => fulfilment == 'delivery';
}

class StockRow {
  StockRow(Map<String, dynamic> j)
      : name = (j['name'] ?? '') as String,
        quantity = _num(j['quantity']),
        unit = j['unit'] as String?,
        level = (j['level'] ?? 'low') as String;
  final String name;
  final num? quantity;
  final String? unit;

  /// `out` (nothing left) or `low` (at or under the reorder level).
  final String level;
}

class TopItem {
  TopItem(Map<String, dynamic> j)
      : name = (j['name'] ?? '') as String,
        qty = _num(j['qty']) ?? 0,
        revenue = _num(j['revenue']) ?? 0;
  final String name;
  final num qty, revenue;
}

/// GET /api/partner/home. Every number is nullable: null means "no source reports this yet",
/// and the screen shows an honest empty state instead of a figure.
class HomeSummary {
  HomeSummary(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get outlet => _map(raw['outlet']);
  String get outletName => (outlet['name'] ?? '') as String;
  String get outletKind => (outlet['kind'] ?? 'store') as String;

  /// true open, false closed, null unknown (no hours or live status recorded).
  bool? get isOpen => outlet['is_open'] as bool?;
  String get personName => (_map(raw['person'])['name'] ?? '') as String;

  DateTime get day => DateTime.tryParse((raw['date'] ?? '') as String) ?? DateTime.now();
  DateTime get asOf => DateTime.tryParse((raw['as_of'] ?? '') as String)?.toLocal() ?? DateTime.now();

  Map<String, dynamic> get sales => _map(raw['sales']);
  num? get salesTotal => _num(sales['total']);
  int? get ordersCount => _int(sales['orders']);
  int? get settledCount => _int(sales['settled']);
  int? get pax => _int(sales['pax']);
  int? get activeCount => _int(sales['active']);
  num? get unitsSold => _num(sales['units']);
  DateTime? get lastSync => DateTime.tryParse((outlet['last_sync_at'] ?? '') as String)?.toLocal();
  List<Map<String, dynamic>> get outlets => _list(raw['outlets']);

  Map<String, dynamic> get catalogue => _map(raw['catalogue']);
  int? get itemsTotal => _int(catalogue['items']);
  int? get missingDescriptions => _int(catalogue['missing_descriptions']);
  int? get missingPhotos => _int(catalogue['missing_photos']);
  int? get missingRecipes => _int(catalogue['missing_recipes']);

  List<ActiveOrder> get activeOrders => _list(raw['active_orders']).map(ActiveOrder.new).toList();
  List<StockRow> get stock => _list(raw['stock_health']).map(StockRow.new).toList();
  int get stockLowCount => _int(raw['stock_low_count']) ?? stock.length;

  /// false when the outlet keeps no stock records, so "Stock health" says so instead of "all good".
  bool get stockTracked => raw['stock_tracked'] == true;
  List<TopItem> get topItems => _list(raw['top_items']).map(TopItem.new).toList();

  Map<String, dynamic> get insights => _map(raw['insights']);
  num? get expenses => _num(insights['expenses']);
  int? get kotNotBilled => _int(insights['kot_not_billed']);
  int? get grnBills => insights['grn'] == null ? null : _int(_map(insights['grn'])['bills']);
  num? get grnAmount => insights['grn'] == null ? null : _num(_map(insights['grn'])['amount']);
}

/// One day's takings for the hub chart.
class DayTotal {
  DayTotal(Map<String, dynamic> j)
      : day = DateTime.tryParse((j['date'] ?? '') as String) ?? DateTime(2000),
        sales = _num(j['sales']) ?? 0;
  final DateTime day;
  final num sales;
}

/// GET /api/partner/home/feed. Outlets are only the person's own organisation's.
class HubFeed {
  HubFeed(this.raw);
  final Map<String, dynamic> raw;

  List<Map<String, dynamic>> get outlets => _list(raw['outlets']);
  String get scopeLabel => (raw['scope'] ?? '') as String;
  int get days => _int(raw['days']) ?? 7;

  Map<String, dynamic> get today => _map(raw['today']);
  num get todaySales => _num(today['sales']) ?? 0;
  int get todayOrders => _int(today['orders']) ?? 0;
  bool? get isOpen => today['is_open'] as bool?;

  Map<String, dynamic> get period => _map(raw['period']);
  Map<String, dynamic> get previous => raw['previous'] == null ? const {} : _map(raw['previous']);
  bool get hasPrevious => raw['previous'] != null;
  num get netSales => _num(period['net_sales']) ?? 0;
  int get delivered => _int(period['orders_completed']) ?? 0;
  num? get aov => _num(period['aov']);
  num? get prevNetSales => _num(previous['net_sales']);
  int? get prevDelivered => _int(previous['orders_completed']);
  num? get prevAov => _num(previous['aov']);
  List<DayTotal> get daily => _list(raw['daily']).map(DayTotal.new).toList();
}

/// Change from [prev] to [now] in percent, or null when there is nothing to compare with.
double? percentChange(num? now, num? prev) {
  if (now == null || prev == null || prev == 0) return null;
  return (now - prev) * 100 / prev;
}

/// Calls One Local's server for the control centre. Same credential rules as [PartnerApi].
class HomeApi {
  HomeApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? AppEnv.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final uri = Uri.parse('$_base/api/partner$path').replace(queryParameters: query);
    final res = await guardNet(_http.get(uri, headers: {'Authorization': 'Bearer $token'}), (s) => throw PartnerApiException(0, s));
    final decoded = readJson(res, (s) => throw PartnerApiException(res.statusCode, s));
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode != 200) {
      throw PartnerApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.');
    }
    return map;
  }

  /// [location] narrows to one of the person's outlets; the server refuses any other.
  Future<HomeSummary> summary({String? location}) async => HomeSummary(await _get('/home', location == null ? null : {'location': location}));

  /// [days] is 1, 7 or 30. [compare] adds the same-length period before it.
  Future<HubFeed> feed({int days = 7, bool compare = true, String? location}) async =>
      HubFeed(await _get('/home/feed', {'days': '$days', 'compare': compare ? '1' : '0', 'location': ?location}));
}
