// Every restaurant screen, opened when the server goes wrong: a server error, no access, no internet, an answer that is not
// JSON (a proxy's HTML page) and an empty answer. Each must open without crashing, never show programmer text (Exception,
// TypeError, Instance of …) and, when the load failed, say so in a plain sentence.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/account/wallet_api.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/kitchen/kds_board_screen.dart';
import 'package:vinii_pos/kitchen/kds_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_setup_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/kitchen/kot_screen.dart';
import 'package:vinii_pos/kitchen/station_detail_screen.dart';
import 'package:vinii_pos/money/rst_money.dart';
import 'package:vinii_pos/money/rst_money_api.dart';
import 'package:vinii_pos/money/rst_money_flow.dart';
import 'package:vinii_pos/menu/categories_screen.dart';
import 'package:vinii_pos/menu/dish_screen.dart';
import 'package:vinii_pos/menu/ingredients_screen.dart';
import 'package:vinii_pos/menu/menu_api.dart';
import 'package:vinii_pos/menu/menu_build_api.dart';
import 'package:vinii_pos/menu/menu_build_screens.dart';
import 'package:vinii_pos/menu/menu_screen.dart';
import 'package:vinii_pos/menu/recipes_screen.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/order_alerts.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/orders_board_screen.dart';
import 'package:vinii_pos/orders/orders_home.dart';
import 'package:vinii_pos/purchasing/po_create_screen.dart';
import 'package:vinii_pos/purchasing/po_grn_screen.dart';
import 'package:vinii_pos/purchasing/purchase_hub_screen.dart';
import 'package:vinii_pos/purchasing/purchasing_api.dart';
import 'package:vinii_pos/purchasing/supplier_price_screen.dart';
import 'package:vinii_pos/restaurant/restaurant_api.dart';
import 'package:vinii_pos/restaurant/restaurant_dashboard.dart';
import 'package:vinii_pos/settings/activity_log_screen.dart';
import 'package:vinii_pos/settings/settings_api.dart';
import 'package:vinii_pos/settings/settings_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/tables/actions_screen.dart';
import 'package:vinii_pos/tables/bill_api.dart';
import 'package:vinii_pos/tables/bill_pay_screen.dart';
import 'package:vinii_pos/tables/bill_receipt_screen.dart';
import 'package:vinii_pos/tables/bill_split_screen.dart';
import 'package:vinii_pos/tables/floor_screen.dart';
import 'package:vinii_pos/tables/manage_tables_screen.dart';
import 'package:vinii_pos/tables/merge_screen.dart';
import 'package:vinii_pos/tables/table_order_screen.dart';
import 'package:vinii_pos/tables/table_qr_api.dart';
import 'package:vinii_pos/tables/table_qr_screen.dart';
import 'package:vinii_pos/tables/table_widgets.dart';
import 'package:vinii_pos/tables/tables_api.dart';
import 'package:vinii_pos/tables/take_order_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

/// What the fake server does to every call.
enum Fault { serverError, noAccess, offline, notJson, empty }

const _serverSentence = 'The kitchen server is down (test).';
const _deniedSentence = 'Only the owner can open this (test).';

http.Client faultyClient(Fault f) => MockClient((r) async {
      switch (f) {
        case Fault.serverError:
          return http.Response('{"detail":"$_serverSentence"}', 500, headers: {'content-type': 'application/json'});
        case Fault.noAccess:
          return http.Response('{"detail":"$_deniedSentence","code":"forbidden"}', 403, headers: {'content-type': 'application/json'});
        case Fault.offline:
          throw http.ClientException('Failed host lookup: pos.test');
        case Fault.notJson:
          return http.Response('<html><body>502 Bad Gateway</body></html>', 502, headers: {'content-type': 'text/html'});
        case Fault.empty:
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      }
    });

class _Silent extends OrderAlertSounds {
  const _Silent();
  @override
  Future<void> arrive() async {}
  @override
  Future<void> warning() async {}
  @override
  Future<void> ready() async {}
  @override
  Future<void> cancelled() async {}
}

/// Every API the restaurant screens use, all talking to one faulty server.
class Apis {
  Apis(Fault f) : client = faultyClient(f);
  final http.Client client;
  static const base = 'http://pos.test';
  static String? token() => 'token-123';
  late final rpc = RpcClient(client: client, baseUrl: base, accessToken: token);
  late final tables = TablesApi(rpc: rpc);
  late final qr = TableQrApi(rpc: rpc);
  late final bill = BillApi(rpc: rpc);
  late final kitchen = KitchenApi(rpc: rpc);
  late final menu = MenuApi(rpc: rpc);
  late final build = MenuBuildApi(rpc: rpc);
  late final orders = OrdersApi(client: client, baseUrl: base, accessToken: token);
  late final purchasing = PurchasingApi(rpc: rpc);
  late final inventory = InventoryApi(rpc: rpc);
  late final catalogue = CatalogueApi(rpc: rpc);
  late final restaurant = RestaurantApi(rpc: rpc);
  late final settings = SettingsApi(rpc: rpc);
  late final rmoney = RstMoneyApi(rpc: rpc);
  late final wallet = WalletApi(rpc: rpc);
  late final tablesEnv = TablesEnv(api: tables, qrApi: qr);
  late final kitchenEnv = KitchenEnv(api: kitchen, refreshEvery: null, sounds: const _Silent());
  late final inv = InvEnv(api: inventory);
  late final stock = StockEnv(inv: inv, catalogue: catalogue, rpc: rpc);
  late final purEnv = PurEnv(api: purchasing, inv: inv);
  late final settingsEnv = SettingsEnv(api: settings);
}

/// The restaurant screens, by name.
final Map<String, Widget Function(Apis a)> screens = {
  'Tables floor': (a) => FloorScreen(env: a.tablesEnv),
  'Manage tables': (a) => ManageTablesScreen(env: a.tablesEnv),
  'Merge tables': (a) => MergeScreen(env: a.tablesEnv),
  'Table order': (a) => TableOrderScreen(env: a.tablesEnv, tableId: 't1', bill: a.bill),
  'Table actions': (a) => ActionsScreen(env: a.tablesEnv, tableId: 't1'),
  'Add dishes': (a) => AddDishesScreen(env: a.tablesEnv, tableId: 't1', tableLabel: 'T1'),
  'Ready to serve': (a) => ReadyToServeScreen(env: a.tablesEnv),
  'Table QR codes': (a) => TableQrScreen(env: a.tablesEnv),
  'Checkout': (a) => BillPayScreen(env: a.tablesEnv, tableId: 't1', bill: a.bill),
  'Split bill': (a) => BillSplitScreen(env: a.tablesEnv, tableId: 't1', orderId: 'o1', bill: a.bill),
  'Receipt': (a) => BillReceiptScreen(env: a.tablesEnv, orderId: 'o1', bill: a.bill),
  'KDS board': (a) => KdsBoardScreen(env: a.kitchenEnv),
  'KDS': (a) => KdsScreen(env: a.kitchenEnv),
  'KOT': (a) => KotScreen(env: a.kitchenEnv),
  'Kitchen setup': (a) => KitchenSetupScreen(env: a.kitchenEnv),
  'Station': (a) => StationDetailScreen(env: a.kitchenEnv, stationId: 's1'),
  'Orders board': (a) => OrdersBoardScreen(api: a.orders, poll: Duration.zero, sounds: const _Silent()),
  'Orders history': (a) => OrdersHome(api: a.orders),
  'Order': (a) => OrderScreen(api: a.orders, orderId: 'o1'),
  'Cart': (a) => CartScreen(api: a.orders),
  'Menu': (a) => MenuScreen(api: a.menu, buildApi: a.build),
  'Dish': (a) => DishScreen(api: a.menu, dishId: 'd1'),
  'Dish settings': (a) => DishSettingsScreen(api: a.build, dishId: 'd1'),
  'Categories': (a) => CategoriesScreen(api: a.build),
  'Quick add': (a) => QuickAddSheet(api: a.build),
  'Ingredients': (a) => Scaffold(body: IngredientsView(api: a.build)),
  'Recipes': (a) => Scaffold(body: RecipesView(api: a.build)),
  'Recipe editor': (a) => RecipeEditorScreen(api: a.build, dishId: 'd1'),
  'Add-ons': (a) => Scaffold(body: AddonsView(api: a.build)),
  'Combos': (a) => Scaffold(body: CombosView(api: a.build)),
  'Purchasing': (a) => PurchaseHubScreen(env: a.purEnv, stock: a.stock, catalogue: a.catalogue),
  'New purchase order': (a) => PoCreateScreen(env: a.purEnv),
  'Purchase order': (a) => PoGrnScreen(env: a.purEnv, orderId: 'po1'),
  'Supplier price': (a) => SupplierPriceScreen(env: a.purEnv, priceId: 'p1'),
  'Restaurant home': (a) => Scaffold(body: RestaurantHomeBody(api: a.restaurant, personName: 'QA', onMenu: () {})),
  'Settings': (a) => SettingsScreen(env: a.settingsEnv),
  'Activity log': (a) => ActivityLogScreen(env: a.settingsEnv),
  'Money': (a) => RstMoneyScreen(api: a.rmoney, walletApi: a.wallet),
  'Money in': (a) => RstMoneyFlowScreen(api: a.rmoney, direction: 'in'),
  'Money out': (a) => RstMoneyFlowScreen(api: a.rmoney, direction: 'out'),
};

/// Text a person should never read.
final _programmerText = RegExp(
    r'Exception|Error:|TypeError|Instance of|is not a subtype|Null check|NoSuchMethod|FormatException|ClientException|SocketException|'
    r'Unexpected character|<html|_Map<|List<dynamic>|\bnull\b|\bundefined\b|\bNaN\b|RangeError');

List<String> _texts(WidgetTester t) => [
      for (final w in t.widgetList(find.byWidgetPredicate((w) => w is Text || w is RichText || w is EditableText, skipOffstage: true)))
        switch (w) {
          Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText() ?? '',
          RichText(:final text) => text.toPlainText(),
          EditableText(:final controller) => controller.text,
          _ => '',
        },
    ];

void main() {
  for (final fault in Fault.values) {
    group('${fault.name}:', () {
      for (final MapEntry(key: name, value: make) in screens.entries) {
        testWidgets(name, (t) async {
          final problems = <String>[];
          t.view.physicalSize = const Size(800, 1720); // a 400 × 860 phone
          t.view.devicePixelRatio = 2;
          addTearDown(t.view.reset);

          await t.pumpWidget(MaterialApp(theme: posTheme(), home: make(Apis(fault))));
          for (var i = 0; i < 6; i++) {
            await t.pump(const Duration(milliseconds: 400));
          }
          final thrown = t.takeException();
          if (thrown != null) problems.add('crash: ${'$thrown'.split('\n').first}');

          final texts = _texts(t);
          for (final s in texts) {
            if (_programmerText.hasMatch(s)) problems.add('raw text: "${s.length > 120 ? '${s.substring(0, 120)}…' : s}"');
          }
          final all = texts.join(' | ');
          // the cart and Quick add load nothing on opening (they ask the server only when a dish is added or saved)
          if (!const {'Cart', 'Quick add'}.contains(name)) switch (fault) {
            case Fault.serverError:
              if (!all.contains(_serverSentence)) problems.add('the server\'s sentence is not shown');
            case Fault.noAccess:
              if (!all.contains(_deniedSentence)) problems.add('the no-access sentence is not shown');
            case Fault.offline:
              if (!all.contains('internet')) problems.add('no word about the internet');
            case Fault.notJson:
            case Fault.empty:
              break;
          }
          if (texts.where((s) => s.trim().isNotEmpty).isEmpty) problems.add('blank screen');

          await t.pumpWidget(const SizedBox());
          await t.pump(const Duration(seconds: 1));
          t.takeException();
          expect(problems.toSet().toList(), isEmpty, reason: '$name, ${fault.name}');
        });
      }
    });
  }
}
