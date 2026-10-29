import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import 'menu_api.dart' show MenuApiException;

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).whereType<Map>().map(_map).toList();
int? _iN(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
int _i(Object? v) => _iN(v) ?? 0;
double? _dN(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
double _d(Object? v) => _dN(v) ?? 0;
String _s(Object? v) => v == null ? '' : '$v';
List<String> _strs(Object? v) => ((v as List?) ?? const []).map((e) => '$e').toList();

/// "₹25.68" from paise; whole rupees drop the decimals ("₹69").
String rupeesMinor(int? minor) {
  if (minor == null) return '—';
  final r = minor / 100;
  return r == r.roundToDouble() ? '₹${r.toInt()}' : '₹${r.toStringAsFixed(2)}';
}

/// Where an ingredient's cost comes from, in the words the screens show.
String costSourceLabel(String source) => switch (source) {
      'last_purchase' => 'Last purchase',
      'supplier_price' => 'Supplier price',
      'set_by_you' => 'Set by you',
      _ => 'No cost yet',
    };

// ---------------------------------------------------------------- ingredients

/// One of the business's ingredients (`ing_list`).
/// One menu category (0616): its parent when it is a subcategory, its place in the order and how many dishes sit in it.
class MenuCat {
  const MenuCat(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  String? get parentId => raw['parent_id'] == null ? null : _s(raw['parent_id']);
  int get sortOrder => _i(raw['sort_order']);
  int get dishes => _i(raw['dishes']);
}

/// The category list: main categories in order, each with its subcategories, and whether this person may change them.
class MenuCategories {
  const MenuCategories(this.raw);
  final Map<String, dynamic> raw;
  bool get canEdit => raw['can_edit'] == true;
  List<MenuCat> get all => [for (final c in _list(raw['categories'])) MenuCat(c)];
  List<MenuCat> get main => [for (final c in all) if (c.parentId == null) c];
  List<MenuCat> subsOf(String id) => [for (final c in all) if (c.parentId == id) c];

  /// Every category for a dish's category dropdown: each main one, then its subcategories ("Beverages › Cold coffee").
  List<({String name, String label})> get choices => [
        for (final m in main) ...[(name: m.name, label: m.name), for (final s in subsOf(m.id)) (name: s.name, label: '${m.name} › ${s.name}')],
      ];
}

class Ingredient {
  const Ingredient(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  String get category => _s(raw['category']);
  String get unit => _s(raw['unit']);
  int? get costMinor => _iN(raw['cost_minor']);
  String get costSource => _s(raw['cost_source']);
  double get onHand => _d(raw['on_hand']);
  double get reorderLevel => _d(raw['reorder_level']);
  bool get low => raw['low'] == true;
  bool get active => raw['active'] != false;
  bool get isVeg => raw['is_veg'] != false;
  int get usedIn => _i(raw['used_in']);
  Map<String, dynamic>? get supplier => raw['supplier'] == null ? null : _map(raw['supplier']);
}

class IngredientList {
  const IngredientList(this.raw);
  final Map<String, dynamic> raw;
  List<Ingredient> get items => _list(raw['items']).map(Ingredient.new).toList();
  List<String> get categories => _strs(raw['categories']);
  List<String> get units => _strs(raw['units']);
  int get total => _i(_map(raw['counts'])['total']);
  int get noCost => _i(_map(raw['counts'])['no_cost']);
  int get low => _i(_map(raw['counts'])['low']);
  bool get canEdit => raw['can_edit'] != false;
  int? get added => _iN(raw['added']);
}

/// One entry of the shared starting list (`ing_library`).
class LibraryIngredient {
  const LibraryIngredient(this.raw);
  final Map<String, dynamic> raw;
  String get code => _s(raw['code']);
  String get name => _s(raw['name']);
  String get category => _s(raw['category']);
  String get unit => _s(raw['unit']);
  int get typicalCostMinor => _i(raw['typical_cost_minor']);
  bool get isVeg => raw['is_veg'] != false;
  bool get added => raw['added'] == true;
}

// ---------------------------------------------------------------- recipes

class RecipeLine {
  const RecipeLine(this.raw);
  final Map<String, dynamic> raw;
  String get ingredientId => _s(raw['inventory_item_id']);
  String get name => _s(raw['name']);
  String get unit => _s(raw['unit']);
  double get qty => _d(raw['qty']);
  double get wastagePct => _d(raw['wastage_pct']);
  bool get isKey => raw['is_key'] == true;
  int? get unitCostMinor => _iN(raw['unit_cost_minor']);
  String get costSource => _s(raw['cost_source']);
  int? get lineCostMinor => _iN(raw['line_cost_minor']);
}

/// A dish's recipe and its figures (`rcp_view` / `rcp_save`; `rcp_list` rows have the same totals without lines).
class Recipe {
  const Recipe(this.raw);
  final Map<String, dynamic> raw;
  String get dishId => _s(raw['menu_item_id']);
  String get name => _s(raw['name']);
  String get category => _s(raw['category']);
  String get foodType => _s(raw['food_type']);
  String? get imageUrl => raw['image_url'] == null ? null : _s(raw['image_url']);
  int get priceMinor => _i(raw['price_minor']);
  List<RecipeLine> get lines => _list(raw['lines']).map(RecipeLine.new).toList();
  int get lineCount => _i(raw['line_count']);
  int get keyCount => _i(raw['key_count']);
  int get missingCost => _i(raw['missing_cost']);
  int get costMinor => _i(raw['cost_minor']);
  double? get foodCostPct => _dN(raw['food_cost_pct']);
  int? get marginMinor => _iN(raw['margin_minor']);
  double? get marginPct => _dN(raw['margin_pct']);
  bool get hasRecipe => lineCount > 0;
  /// An add-on's recipe (0626): its group is the category; without a recipe it may still use one ingredient (set in the add-on master).
  bool get isAddon => raw['kind'] == 'addon';
  /// Its price on a channel (0627: 'onelocal', 'zomato', 'swiggy') where one is set; null = the selling price applies there.
  num? channelPrice(String channel) => (raw['channel_prices'] is Map) ? (raw['channel_prices'] as Map)[channel] as num? : null;
  ({String name, String unit, num? qty})? get single => raw['single'] is Map
      ? (name: _s(raw['single']['name']), unit: _s(raw['single']['unit']), qty: raw['single']['qty'] as num?)
      : null;
}

class RecipeList {
  const RecipeList(this.raw);
  final Map<String, dynamic> raw;
  List<Recipe> get items => _list(raw['items']).map(Recipe.new).toList();
  List<Recipe> get addons => _list(raw['addons']).map(Recipe.new).toList(); // 0626
  Map<String, dynamic> get _sum => _map(raw['summary']);
  int get withRecipe => _i(_sum['with_recipe']);
  int get withoutRecipe => _i(_sum['without_recipe']);
  double? get avgFoodCostPct => _dN(_sum['avg_food_cost_pct']);
}

/// One recipe line while it is being edited (the screen works out the cost as you type; the server's answer replaces it on save).
class DraftLine {
  DraftLine({required this.ingredientId, required this.name, required this.unit, required this.qty, this.wastagePct = 0, this.isKey = false, this.unitCostMinor});
  final String ingredientId, name, unit;
  double qty, wastagePct;
  bool isKey;
  final int? unitCostMinor;
  int? get lineCostMinor => unitCostMinor == null ? null : (unitCostMinor! * qty * (1 + wastagePct / 100)).round();
  Map<String, dynamic> toJson() => {'inventory_item_id': ingredientId, 'qty': qty, 'wastage_pct': wastagePct, 'is_key': isKey};
  factory DraftLine.of(RecipeLine l) =>
      DraftLine(ingredientId: l.ingredientId, name: l.name, unit: l.unit, qty: l.qty, wastagePct: l.wastagePct, isKey: l.isKey, unitCostMinor: l.unitCostMinor);
}

// ---------------------------------------------------------------- dishes, add-ons, combos

/// The detailed settings of one dish (`menu_item_settings`).
class DishSettings {
  const DishSettings(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  int get version => _i(raw['version']);
  String get name => _s(raw['name']);
  int get priceMinor => _i(raw['price_minor']);
  /// The dish's sizes (0611 / 0613): id, name, price, how many times the recipe it uses, and whether it is the default (Small).
  List<({String id, String name, num price, num factor, bool isDefault})> get sizes => [
        for (final s in _list(raw['sizes']))
          (id: _s(s['id']), name: _s(s['name']), price: (s['price'] as num?) ?? 0, factor: (s['recipe_factor'] as num?) ?? 1, isDefault: s['is_default'] == true),
      ];
  String get categoryId => _s(raw['category_id']);
  String get category => _s(raw['category']);
  String get foodType => _s(raw['food_type']);
  String get course => _s(raw['course']);
  String get station => _s(raw['station']);
  int get prepMinutes => _i(raw['prep_minutes']);
  bool get recommended => raw['is_recommended'] == true;
  String get sku => _s(raw['sku']);
  List<String> get addonGroupIds => _strs(raw['addon_group_ids']);
  List<String> get comboGroupIds => _strs(raw['combo_group_ids']);
  List<({String id, String name, int combos})> get comboGroups =>
      [for (final g in _list(raw['combo_groups'])) (id: _s(g['id']), name: _s(g['name']), combos: _i(g['combos']))];
  Recipe get recipe => Recipe(_map(raw['recipe']));
  List<({String id, String name})> get categories => [for (final c in _list(raw['categories'])) (id: _s(c['id']), name: _s(c['name']))];
  List<({String id, String name, int addons})> get addonGroups =>
      [for (final g in _list(raw['addon_groups'])) (id: _s(g['id']), name: _s(g['name']), addons: _i(g['addons']))];
  List<String> get stations => _strs(raw['stations']);
}

class Addon {
  const Addon(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  int get priceMinor => _i(raw['price_minor']);
  String get foodType => _s(raw['food_type']);
  /// The ingredient it is made of (0624): its id, name and unit, and how much of it one add-on uses (billing it uses that much).
  String get ingredientId => _s(raw['inventory_item_id']);
  String get ingredient => _s(raw['ingredient']);
  String get unit => _s(raw['unit']);
  num? get consumeQty => raw['consume_qty'] as num?;
}

class AddonGroup {
  const AddonGroup(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  int get minSelect => _i(raw['min_select']);
  int get maxSelect => _i(raw['max_select']);
  int get dishCount => _i(raw['dish_count']);
  List<Addon> get addons => _list(raw['addons']).map(Addon.new).toList();
  String get rule => minSelect == 0 ? 'Optional · up to $maxSelect' : (minSelect == maxSelect ? 'Pick $minSelect' : 'Pick $minSelect to $maxSelect');
}

class Combo {
  const Combo(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  String get description => _s(raw['description']);
  int get priceMinor => _i(raw['price_minor']);
  int get separateMinor => _i(raw['separate_minor']);
  int get savingMinor => separateMinor - priceMinor;
  List<({String dishId, String name, int qty, int priceMinor})> get items =>
      [for (final i in _list(raw['items'])) (dishId: _s(i['menu_item_id']), name: _s(i['name']), qty: _i(i['qty']), priceMinor: _i(i['price_minor']))];
}

/// A combo group (0624): combos offered together on a dish, with how many may be chosen.
class ComboGroup {
  const ComboGroup(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  int get minSelect => _i(raw['min_select']);
  int get maxSelect => _i(raw['max_select']);
  int get dishCount => _i(raw['dish_count']);
  List<String> get comboIds => _strs(raw['combo_ids']);
  List<({String id, String name, int priceMinor})> get combos => [for (final c in _list(raw['combos'])) (id: _s(c['id']), name: _s(c['name']), priceMinor: _i(c['price_minor']))];
  String get rule => minSelect == 0 ? 'Optional · up to ' : (minSelect == maxSelect ? 'Pick ' : 'Pick  to ');
}

class ComboGroups {
  const ComboGroups(this.raw);
  final Map<String, dynamic> raw;
  List<ComboGroup> get groups => _list(raw['groups']).map(ComboGroup.new).toList();
  List<({String id, String name, int priceMinor, String items})> get combos =>
      [for (final c in _list(raw['combos'])) (id: _s(c['id']), name: _s(c['name']), priceMinor: _i(c['price_minor']), items: _s(c['items']))];
}

class ComboData {
  const ComboData(this.raw);
  final Map<String, dynamic> raw;
  List<Combo> get combos => _list(raw['combos']).map(Combo.new).toList();
  List<({String id, String name, int priceMinor, String category})> get dishes =>
      [for (final d in _list(raw['dishes'])) (id: _s(d['id']), name: _s(d['name']), priceMinor: _i(d['price_minor']), category: _s(d['category']))];
}

// ---------------------------------------------------------------- the calls

/// Menu · Recipe · Ingredients (migrations/0600). Every rule (who may change what, names, prices, quantities, duplicates) is in the database.
class MenuBuildApi {
  MenuBuildApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
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

  // ingredients
  Future<IngredientList> ingredients({String? q, String? category}) async =>
      IngredientList(await _call('ing_list', {if (q != null && q.trim().isNotEmpty) 'q': q.trim(), 'category': ?category}));
  Future<List<LibraryIngredient>> library({String? q, String? category}) async =>
      _list((await _call('ing_library', {if (q != null && q.trim().isNotEmpty) 'q': q.trim(), 'category': ?category}))['items']).map(LibraryIngredient.new).toList();
  Future<IngredientList> addFromLibrary(List<String> codes) async => IngredientList(await _call('ing_add_from_library', {'codes': codes}));
  Future<IngredientList> saveIngredient({String? id, required String name, String? category, required String unit, int? costMinor, double? reorderLevel, bool? active}) async =>
      IngredientList(await _call('ing_save', {
        'id': ?id, 'name': name, 'category': (category == null || category.trim().isEmpty) ? null : category.trim(), 'unit': unit,
        'cost_minor': costMinor, 'reorder_level': ?reorderLevel, 'active': ?active,
      }));

  // recipes
  Future<RecipeList> recipes({String? q}) async => RecipeList(await _call('rcp_list', {if (q != null && q.trim().isNotEmpty) 'q': q.trim()}));
  /// A dish's recipe, or with [addon] an add-on's (0626).
  Future<Recipe> recipe(String id, {bool addon = false}) async => Recipe(await _call('rcp_view', {addon ? 'addon_id' : 'menu_item_id': id}));
  Future<Recipe> saveRecipe(String id, List<DraftLine> lines, {bool addon = false}) async =>
      Recipe(await _call('rcp_save', {addon ? 'addon_id' : 'menu_item_id': id, 'lines': [for (final l in lines) l.toJson()]}));

  /// A dish's price on OneLocal, Zomato or Swiggy (0627); null clears it so the selling price applies there.
  Future<void> saveChannelPrice(String dishId, String channel, double? price) => _call('menu_channel_price_save', {'menu_item_id': dishId, 'channel': channel, 'price': price});

  // dishes
  /// Categories and subcategories (0616): the list, add or rename (with [parentId] a subcategory; `clearParent` makes it a main one),
  /// and deleting an empty one. Each answers the whole list again.
  Future<MenuCategories> categories() async => MenuCategories(await _call('menu_category_list', {}));
  Future<MenuCategories> saveCategory({String? id, required String name, String? parentId, bool clearParent = false, int? sortOrder}) async => MenuCategories(await _call(
      'menu_category_save', {'id': ?id, 'name': name, if (parentId != null) 'parent_id': parentId else if (clearParent) 'parent_id': null, 'sort_order': ?sortOrder}));
  Future<MenuCategories> deleteCategory(String id) async => MenuCategories(await _call('menu_category_delete', {'id': id}));

  Future<DishSettings> quickAdd({required String name, required String category, required double price, String foodType = 'veg', String course = 'eat'}) async =>
      DishSettings(await _call('menu_item_quick_add', {'name': name, 'category': category, 'price': price, 'food_type': foodType, 'course': course}));
  Future<DishSettings> settings(String dishId) async => DishSettings(await _call('menu_item_settings', {'id': dishId}));
  /// The dish's selling price and, for a dish with sizes, each size's price (0613); the default size follows the dish's price.
  Future<DishSettings> savePrice(String dishId, int version, double price, {Map<String, double> sizes = const {}}) async => DishSettings(await _call(
      'menu_price_save', {'id': dishId, 'version': version, 'price': price, if (sizes.isNotEmpty) 'sizes': [for (final e in sizes.entries) {'id': e.key, 'price': e.value}]}));
  Future<DishSettings> saveSettings(String dishId, int version, Map<String, dynamic> changes) async =>
      DishSettings(await _call('menu_item_settings_save', {'id': dishId, 'version': version, ...changes}));

  // add-ons
  Future<List<AddonGroup>> addonGroups() async => _list((await _call('menu_addon_list', {}))['groups']).map(AddonGroup.new).toList();
  Future<List<AddonGroup>> saveAddonGroup({String? id, required String name, required int minSelect, required int maxSelect, required List<Map<String, dynamic>> addons}) async =>
      _list((await _call('menu_addon_group_save', {'id': ?id, 'name': name, 'min_select': minSelect, 'max_select': maxSelect, 'addons': addons}))['groups'])
          .map(AddonGroup.new)
          .toList();
  /// The ingredient master, to pick an add-on from (0624): id, name, unit.
  Future<List<({String id, String name, String unit})>> addonIngredients() async =>
      [for (final i in _list((await _call('menu_addon_list', {}))['ingredients'])) (id: _s(i['id']), name: _s(i['name']), unit: _s(i['unit']))];
  Future<List<AddonGroup>> deleteAddonGroup(String id) async => _list((await _call('menu_addon_group_delete', {'id': id}))['groups']).map(AddonGroup.new).toList();

  // combos
  Future<ComboData> combos() async => ComboData(await _call('menu_combo_list', {}));
  Future<ComboData> saveCombo({String? id, required String name, String? description, required double price, required Map<String, int> items}) async =>
      ComboData(await _call('menu_combo_save', {
        'id': ?id, 'name': name, if (description != null && description.trim().isNotEmpty) 'description': description.trim(), 'price': price,
        'items': [for (final e in items.entries) {'menu_item_id': e.key, 'qty': e.value}],
      }));
  Future<ComboData> deleteCombo(String id) async => ComboData(await _call('menu_combo_delete', {'id': id}));

  // combo groups (0624)
  Future<ComboGroups> comboGroups() async => ComboGroups(await _call('menu_combo_group_list', {}));
  Future<ComboGroups> saveComboGroup({String? id, required String name, required int minSelect, required int maxSelect, required List<String> comboIds}) async =>
      ComboGroups(await _call('menu_combo_group_save', {'id': ?id, 'name': name, 'min_select': minSelect, 'max_select': maxSelect, 'combo_ids': comboIds}));
  Future<ComboGroups> deleteComboGroup(String id) async => ComboGroups(await _call('menu_combo_group_delete', {'id': id}));

  /// Both reads of menu_stock_signals in one call: what stock says about each dish with a recipe (dish id → 'out' or 'low' and the
  /// ingredient; dishes not listed are fine), and how many of each dish with a recipe can be made (0605; null = its ingredients were never
  /// stocked). A dish missing from canMake has no recipe.
  Future<({Map<String, ({String state, String ingredient})> signals, Map<String, int?> canMake})> stockAll() async {
    final r = await _call('menu_stock_signals', {});
    return (
      signals: {for (final i in _list(r['items'])) _s(i['menu_item_id']): (state: _s(i['state']), ingredient: _s(i['ingredient']))},
      canMake: {for (final i in _list(r['can_make'])) _s(i['menu_item_id']): (i['can_make'] as num?)?.toInt()},
    );
  }

  /// Just the out / low tags of [stockAll].
  Future<Map<String, ({String state, String ingredient})>> stockSignals() async => (await stockAll()).signals;
}
