import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).whereType<Map>().map(_map).toList();
int _i(Object? v) => v is num ? v.toInt() : (int.tryParse('${v ?? 0}') ?? 0);
bool _b(Object? v) => v == true;
String? _s(Object? v) => v == null ? null : '$v';

/// One dish card on the menu list (`rst_menu`). Every figure is the server's.
class MenuDish {
  const MenuDish(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id']}';
  String get name => '${raw['name'] ?? ''}';
  int get priceMinor => _i(raw['price_minor']);
  String? get description => _s(raw['description']);
  String get foodType => '${raw['food_type'] ?? 'veg'}';
  String? get imageUrl => (_s(raw['image_url']) ?? '').trim().isEmpty ? null : _s(raw['image_url']);
  bool get inStock => _b(raw['in_stock']);
  int get variants => _i(raw['variants']);
  bool get hasWindows => _b(raw['has_windows']);
  bool get orderableNow => _b(raw['orderable_now']);
}

class MenuCategory {
  const MenuCategory(this.raw);
  final Map<String, dynamic> raw;
  String? get id => _s(raw['id']);
  String get name => '${raw['name'] ?? ''}';
  int get count => _i(raw['count']);
  bool get allInStock => _b(raw['all_in_stock']);
  List<MenuDish> get items => _list(raw['items']).map(MenuDish.new).toList();
}

/// The restaurant menu (`rst_menu`): counts, categories, dishes, the outlet whose clock is used.
class MenuData {
  const MenuData(this.raw);
  final Map<String, dynamic> raw;
  String get locationId => '${_map(raw['location'])['id'] ?? ''}';
  String get locationName => '${_map(raw['location'])['name'] ?? ''}';
  List<Map<String, dynamic>> get outlets => _list(raw['outlets']);
  bool get canEdit => _b(raw['can_edit']);
  int count(String k) => _i(_map(raw['counts'])[k]);
  List<MenuCategory> get categories => _list(raw['categories']).map(MenuCategory.new).toList();
}

/// A serving window. Morning, Evening and Night carry fixed times decided by the database; Custom carries its own.
class ServingWindow {
  const ServingWindow(this.slot, this.startsAt, this.endsAt, [this.days]);
  factory ServingWindow.fromJson(Map<String, dynamic> j) =>
      ServingWindow('${j['slot']}', '${j['starts_at']}', '${j['ends_at']}', (j['days'] as List?)?.map(_i).toList());
  final String slot;
  final String startsAt;
  final String endsAt;
  final List<int>? days;
  Map<String, dynamic> toJson() => {
        'slot': slot,
        if (slot == 'custom') 'starts_at': startsAt,
        if (slot == 'custom') 'ends_at': endsAt,
        'days': ?days,
      };
  String get label => '$startsAt – $endsAt';
  @override
  bool operator ==(Object other) => other is ServingWindow && other.slot == slot && other.startsAt == startsAt && other.endsAt == endsAt;
  @override
  int get hashCode => Object.hash(slot, startsAt, endsAt);
}

/// The default presets (the database stores the same times; it decides, this only labels the chips).
const kPresets = [
  ServingWindow('morning', '06:00', '12:00'),
  ServingWindow('evening', '16:00', '20:00'),
  ServingWindow('night', '20:00', '24:00'),
];

/// One dish (`rst_menu_item_view`).
class DishDetail {
  const DishDetail(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id']}';
  String get name => '${raw['name'] ?? ''}';
  int get priceMinor => _i(raw['price_minor']);
  String get description => '${raw['description'] ?? ''}';
  String get foodType => '${raw['food_type'] ?? 'veg'}';
  List<String> get images => ((raw['images'] as List?) ?? const []).map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
  bool get inStock => _b(raw['in_stock']);
  bool get orderableNow => _b(raw['orderable_now']);
  bool get canEdit => _b(raw['can_edit']);
  int get version => _i(raw['version']);
  String? get locationId => _s(raw['location_id']);
  String? get category => _s(_map(raw['category'])['name']);
  List<Map<String, dynamic>> get ingredients => _list(raw['ingredients']);
  List<Map<String, dynamic>> get variants => _list(raw['variants']);
  List<ServingWindow> get availability => _list(raw['availability']).map(ServingWindow.fromJson).toList();
}

class MenuApiException extends PartnerApiException {
  const MenuApiException(super.status, super.message, this.code);
  final String? code;
  bool get aiNotConfigured => code == 'ai_not_configured';
  bool get stale => code == 'version_conflict';
}

/// The restaurant Menu and Dish detail calls. All rules (who may edit, serving windows, the AI limit, tenancy) are in the database.
class MenuApi {
  MenuApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args) async {
    try {
      return await _rpc.callMap(fn, args);
    } on RpcException catch (e) {
      throw MenuApiException(e.status, e.message, e.code);
    } on PartnerApiException catch (e) {
      throw MenuApiException(e.status, e.message, null);
    }
  }

  Future<MenuData> menu({String? locationId, String? q, String filter = 'all'}) async =>
      MenuData(await _call('rst_menu', {'location_id': ?locationId, if (q != null && q.trim().isNotEmpty) 'q': q.trim(), 'filter': filter}));

  Future<DishDetail> dish(String id, {String? locationId}) async => DishDetail(await _call('rst_menu_item_view', {'id': id, 'location_id': ?locationId}));

  /// The dish screen's one save. Only the keys given are changed.
  Future<DishDetail> save(String id, int version, {String? locationId, String? description, List<ServingWindow>? availability}) async =>
      DishDetail(await _call('rst_menu_item_save', {
        'id': id,
        'version': version,
        'location_id': ?locationId,
        'description': ?description,
        if (availability != null) 'availability': availability.map((w) => w.toJson()).toList(),
      }));

  Future<void> setStock({String? dishId, String? categoryId, required bool inStock}) =>
      _call('rst_menu_stock_set', {'id': ?dishId, 'category_id': ?categoryId, 'in_stock': inStock});

  /// Write with AI: a suggestion only. Nothing is saved until the owner presses Save.
  Future<String> aiDescribe(String dishId, String notes) async =>
      '${(await _call('menu_ai_describe', {'item_id': dishId, if (notes.trim().isNotEmpty) 'notes': notes.trim()}))['text'] ?? ''}';
}
