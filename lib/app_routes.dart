import 'storefront/menu_link_screen.dart';
import 'package:flutter/material.dart';

import 'account/routes.dart';
import 'auth/auth_repository.dart';
import 'auth/partner_api.dart';
import 'backoffice/low_stock_screen.dart';
import 'catalogue/catalogue_screen.dart';
import 'catalogue/grn_screens.dart';
import 'home/app_shell.dart';
import 'home/control_centre_screen.dart';
import 'home/home_nav.dart';
import 'inventory/inventory_dashboard.dart';
import 'inventory/receiving_screen.dart';
import 'inventory/stock_detail_screen.dart';
import 'kitchen/kds_screen.dart';
import 'kitchen/kitchen_setup_screen.dart';
import 'kitchen/kitchen_widgets.dart';
import 'money/money_env.dart';
import 'money/money_home.dart';
import 'notices/feedback_screen.dart';
import 'notices/notices_api.dart';
import 'notices/notices_home.dart';
import 'menu/menu_screen.dart';
import 'orders/cart_screen.dart';
import 'purchasing/po_history_screen.dart';
import 'purchasing/purchasing_api.dart';
import 'orders/order_screen.dart';
import 'orders/orders_board_screen.dart';
import 'orders/orders_home.dart';
import 'sell/sell_env.dart';
import 'sell/sell_screen.dart';
import 'service/calendar_screen.dart';
import 'service/service_widgets.dart' show ServiceRoutes;
import 'settings/settings_screen.dart';
import 'settings/support_screens.dart';
import 'setup/setup_api.dart';
import 'setup/setup_flow.dart';
import 'storefront/builder_screen.dart';
import 'storefront/settings_screens.dart';
import 'storefront/storefront_api.dart';
import 'tables/floor_screen.dart';
import 'tables/table_qr_screen.dart';
import 'tables/table_widgets.dart';
import 'team/team_screens.dart';
import 'team/team_widgets.dart';

/// Connects the sections to each other. Each section only knows its own screens; this file plugs
/// workspace setup (C), the control centre (D), orders (E), the catalogue and GRN (G), low stock (J), money (K), the team (L), the storefront (M), notices (N) and settings and support (P) into the [HomeNav] hooks.
/// workspace setup (C), the control centre (D), orders (E), the catalogue and GRN (G), low stock (J) and the restaurant menu into the [HomeNav] hooks.
void installRoutes() {
  // Home: inside the app shell, its Home tab; otherwise (after setup, first entry) the shell replaces everything.
  HomeNav.home = (c) {
    if (_inShell('Home')) return;
    Navigator.of(c, rootNavigator: true).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => appShell()), (r) => r.isFirst);
  };
  // A restaurant's Orders tab is Live orders | Hold orders (specs/orders-live-hold); a store's Online order tab is Orders History (section E).
  HomeNav.orders = (c) {
    if (_inShell('Online order') || _inShell('Orders')) return;
    final restaurant = HomeNav.shell?.kind == 'restaurant';
    Navigator.of(c).push(MaterialPageRoute(
        builder: (_) => restaurant ? OrdersBoardScreen(onNavigate: (id) => _tab(c, id)) : OrdersHome(onNavigate: (id) => _tab(c, id))));
  };
  HomeNav.orderHistory = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => OrdersHome(onNavigate: (id) => _tab(c, id))));
  // Section F: the till (sell, search, carts, payment, history, returns, receipts). Section E's cart screen stays reachable from the orders list.
  HomeNav.bill = (c) {
    if (HomeNav.shell?.kind == 'store' && _inShell('Bill')) return;
    Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'sell'), builder: (_) => SellScreen(env: SellEnv(onTab: (id) => _tab(c, id)))));
  };
  HomeNav.items = (c) {
    if (_inShell('Item')) return;
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => CatalogueScreen(onNavigate: (id) => _tab(c, id))));
  };
  HomeNav.menu = (c) {
    if (_inShell('Menu')) return;
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => const MenuScreen()));
  };
  HomeNav.grn = (c) => Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => GrnQueueScreen(onReceive: (ctx) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ReceivingScreen(env: _inventoryEnv(ctx)))))));
  const inventoryEnv = _inventoryEnv;
  HomeNav.stock = (c) {
    if (_inShell('Stock')) return;
    Navigator.of(c).push(InventoryDashboard.route(inventoryEnv(c)));
  };
  HomeNav.stockItem = (c, itemId) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => StockDetailScreen(env: inventoryEnv(c), itemId: itemId)));
  KitchenEnv kitchenEnv(BuildContext c) => KitchenEnv(onNavigate: (id) => _kitchenTab(c, id));
  HomeNav.kitchenSetup = (c) => Navigator.of(c).push(KitchenSetupScreen.route(kitchenEnv(c)));
  HomeNav.kitchenDisplay = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KdsScreen(env: kitchenEnv(c))));
  // The restaurant dashboard's "Open kitchen display" and the More page's Kitchen display tile open the same KDS.
  HomeNav.kitchen = HomeNav.kitchenDisplay;
  HomeNav.tables = (c) {
    if (HomeNav.shell?.kind == 'restaurant' && _inShell('Bill')) return;   // a restaurant's Bill tab is the floor
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => _floor(c)));
  };
  HomeNav.menuLink = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const MenuLinkScreen()));
  HomeNav.tableQr = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => TableQrScreen(env: TablesEnv())));
  HomeNav.lowStock = (c) => Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => LowStockScreen(onNavigate: (id) => _tab(c, id), onItems: () => HomeNav.go(c, HomeNav.items, 'Items'), onViewItem: HomeNav.stockItem)));
  HomeNav.service = (c) {
    if (HomeNav.shell?.kind == 'service' && _inShell('Bill')) return;   // a service partner's Bill tab is the calendar
    Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: ServiceRoutes.calendar), builder: (_) => ServiceCalendarScreen(onNavigate: (id) => _tab(c, id))));
  };
  // Section K: money. The server says which screens this person may open; the bottom bar's other tabs go back through _tab.
  HomeNav.money = (c) => Navigator.of(c).push(MoneyHome.route(MoneyEnv(onNavigate: (id) => _tab(c, id))));
  HomeNav.moneyScreen = (c, screen) => Navigator.of(c).push(MoneyHome.route(MoneyEnv(onNavigate: (id) => _tab(c, id)), start: screen));
  HomeNav.team = (c) => Navigator.of(c).push(TeamDashboardScreen.route(TeamEnv(onNavigate: (id) => _tab(c, id), kind: HomeNav.shell?.kind)));
  // Section M: the storefront page builder (profile, hours, delivery, offers, ads and publishing hang off it).
  HomeNav.storefront = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'storefront'), builder: (_) => StorePageBuilder(api: StorefrontApi())));
  HomeNav.deliverySettings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => DeliveryScreen(api: StorefrontApi())));
  // Section N: notification and announcement centres, customer messages and feedback.
  HomeNav.notifications = (c) => Navigator.of(c).push(NoticesHome.route());
  HomeNav.reviews = HomeNav.complaints = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => FeedbackScreen(api: NoticesApi())));
  // Section P: the Settings page and Support & Help. The Team hook (users, roles, invites) belongs to section L.
  HomeNav.settings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen()));
  HomeNav.support = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SupportScreen()));
  // Setup covers the whole screen, bar included.
  HomeNav.setup = (c) => Navigator.of(c, rootNavigator: true).push(MaterialPageRoute(builder: (_) => SetupEntry(onFinished: (ctx) => HomeNav.home!(ctx))));
  installAccountRoutes(); // side nav: Customer, One Local Wallet, Manage account
}

InvEnv _inventoryEnv(BuildContext c) => InvEnv(
    onNavigate: (id) => _tab(c, id),
    onOpenPurchasing: (ctx) => Navigator.of(ctx).push(PoHistoryScreen.pageRoute(PurEnv(inv: _inventoryEnv(ctx)))),
    onOpenLowStock: (ctx) => HomeNav.lowStock?.call(ctx),
    onOpenOrder: (ctx, orderId) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId, onNavigate: (id) => _tab(ctx, id)))));

/// Switches the app shell to the tab with this bar label, when the shell is up and has that tab.
bool _inShell(String label) => HomeNav.shell?.show(label) ?? false;

Widget _floor(BuildContext c) => FloorScreen(env: TablesEnv(onNavigate: (id) => id == 'pos' ? null : id == 'orders' ? HomeNav.go(c, HomeNav.orders, 'Orders') : _tab(c, id)));

/// The signed-in app: one bottom bar over a back stack per tab. Each tab's first screen depends on the kind of
/// business: Bill is the till for a store, the tables floor for a restaurant, the calendar for a service partner.
Widget appShell({AuthRepository? auth}) => AppShell(rootFor: (kind, label) => shellTabRoot(kind, label, auth: auth));

/// The first screen of the bar tab [label] for a business of [kind] ('store', 'restaurant', 'service'); null when the tab has none.
Widget? shellTabRoot(String kind, String label, {AuthRepository? auth}) => switch (label) {
        'Home' => ControlCentreScreen(auth: auth),
        'Item' => Builder(builder: (c) => CatalogueScreen(onNavigate: (id) => _tab(c, id))),
        'Menu' => const MenuScreen(),
        'Bill' => Builder(
            builder: (c) => switch (kind) {
              'restaurant' => _floor(c),
              'service' => ServiceCalendarScreen(onNavigate: (id) => _tab(c, id)),
              _ => SellScreen(env: SellEnv(onTab: (id) => _tab(c, id))),
            },
          ),
        // A store's Online order tab is section E (Orders History, each order opening its stage screen). The Live | Hold board with
        // dine-in / takeaway / delivery is the restaurant's Orders tab (section H), so a store never sees it.
        'Online order' => Builder(builder: (c) => OrdersHome(onNavigate: (id) => _tab(c, id))),
        'Orders' => Builder(builder: (c) => OrdersBoardScreen(onNavigate: (id) => _tab(c, id))),
        'Stock' => Builder(builder: (c) => InventoryDashboard(env: _inventoryEnv(c))),
        _ => null,
      };

/// Bottom-bar tabs of the order screens that belong to other sections.
void _tab(BuildContext context, String id) => switch (id) {
      'home' => HomeNav.go(context, HomeNav.home, 'Home'),
      'item' => HomeNav.go(context, HomeNav.items, 'Items'),
      'menu' => HomeNav.go(context, HomeNav.menu ?? HomeNav.items, 'The menu'),
      'bill' => HomeNav.go(context, HomeNav.bill, 'Bill'),
      'stock' => HomeNav.go(context, HomeNav.stock, 'Stock'),
      _ => HomeNav.go(context, null, 'Online orders'),
    };

/// Bottom-bar tabs of the kitchen screens that belong to other sections.
void _kitchenTab(BuildContext context, String id) => switch (id) {
      'money' => HomeNav.go(context, HomeNav.money, 'Money'),
      'menu' => HomeNav.go(context, HomeNav.items, 'Menu'),
      'orders' => HomeNav.go(context, HomeNav.orders, 'Orders'),
      'stock' => HomeNav.go(context, HomeNav.stock, 'Stock'),
      _ => HomeNav.go(context, null, 'That part of the app'),
    };

/// "Continue to store": an owner or admin whose workspace setup is not finished goes to setup first
/// (Figma: finish setup before using the merchant tools); everyone else goes to the control centre.
/// The server decides who may run setup; a refusal (staff, not yet approved) means "go to the control centre".
Future<void> openWorkspace(BuildContext context, {AuthRepository? auth, SetupApi? setupApi}) async {
  bool needsSetup = false;
  try {
    final setup = await (setupApi ?? SetupApi()).get();
    needsSetup = !setup.completed;
    HomeNav.partnerType = setup.partnerType;
  } on PartnerApiException {
    needsSetup = false;
  } catch (_) {
    needsSetup = false; // offline: the control centre shows its own retry
  }
  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => needsSetup ? SetupEntry(api: setupApi, onFinished: (ctx) => HomeNav.home!(ctx)) : appShell(auth: auth),
  ));
}
