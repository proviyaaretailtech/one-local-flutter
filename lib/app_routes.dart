import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'auth/partner_api.dart';
import 'catalogue/catalogue_screen.dart';
import 'catalogue/grn_screens.dart';
import 'backoffice/low_stock_screen.dart';
import 'home/control_centre_screen.dart';
import 'home/home_nav.dart';
import 'inventory/inventory_dashboard.dart';
import 'inventory/stock_detail_screen.dart';
import 'kitchen/kds_screen.dart';
import 'kitchen/kitchen_setup_screen.dart';
import 'kitchen/kitchen_widgets.dart';
import 'purchasing/po_history_screen.dart';
import 'purchasing/purchasing_api.dart';
import 'orders/cart_screen.dart';
import 'money/money_env.dart';
import 'money/money_home.dart';
import 'notices/feedback_screen.dart';
import 'notices/notices_api.dart';
import 'notices/notices_home.dart';
import 'orders/order_screen.dart';
import 'orders/orders_home.dart';
import 'sell/sell_env.dart';
import 'sell/sell_screen.dart';
import 'service/calendar_screen.dart';
import 'service/service_widgets.dart' show ServiceRoutes;
import 'settings/settings_screen.dart';
import 'settings/support_screens.dart';
import 'setup/setup_api.dart';
import 'setup/setup_flow.dart';
import 'tables/floor_screen.dart';
import 'tables/table_widgets.dart';
import 'storefront/builder_screen.dart';
import 'storefront/storefront_api.dart';

/// Connects the sections to each other. Each section only knows its own screens; this file plugs
/// workspace setup (C), the control centre (D), orders (E), the catalogue and GRN (G), low stock (J), money (K), the team (L), the storefront (M), notices (N) and settings and support (P) into the [HomeNav] hooks.
import 'team/team_screens.dart';
import 'team/team_widgets.dart';
void installRoutes() {
  HomeNav.home = (c) => Navigator.of(c).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const ControlCentreScreen()), (r) => r.isFirst);
  HomeNav.orders = HomeNav.orderHistory = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => OrdersHome(onNavigate: (id) => _tab(c, id))));
  // Section F: the till (sell, search, carts, payment, history, returns, receipts). Section E's cart screen stays reachable from the orders list.
  HomeNav.bill = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'sell'), builder: (_) => SellScreen(env: SellEnv(onTab: (id) => _tab(c, id)))));
  HomeNav.items = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => CatalogueScreen(onNavigate: (id) => _tab(c, id))));
  HomeNav.grn = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const GrnQueueScreen()));
  InvEnv inventoryEnv(BuildContext c) => InvEnv(
      onNavigate: (id) => _tab(c, id),
      onOpenPurchasing: (ctx) => Navigator.of(ctx).push(PoHistoryScreen.pageRoute(PurEnv(inv: inventoryEnv(ctx)))),
      onOpenOrder: (ctx, orderId) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId, onNavigate: (id) => _tab(ctx, id)))));
  HomeNav.stock = (c) => Navigator.of(c).push(InventoryDashboard.route(inventoryEnv(c)));
  HomeNav.stockItem = (c, itemId) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => StockDetailScreen(env: inventoryEnv(c), itemId: itemId)));
  KitchenEnv kitchenEnv(BuildContext c) => KitchenEnv(onNavigate: (id) => _kitchenTab(c, id));
  HomeNav.kitchenSetup = (c) => Navigator.of(c).push(KitchenSetupScreen.route(kitchenEnv(c)));
  HomeNav.kitchenDisplay = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KdsScreen(env: kitchenEnv(c))));
  HomeNav.tables = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => FloorScreen(env: TablesEnv(onNavigate: (id) => id == 'pos' ? null : id == 'orders' ? HomeNav.go(c, HomeNav.orders, 'Orders') : _tab(c, id == 'menu' ? 'item' : id)))));
  HomeNav.lowStock = (c) => Navigator.of(c).push(MaterialPageRoute(
      builder: (_) => LowStockScreen(onNavigate: (id) => _tab(c, id), onItems: () => HomeNav.go(c, HomeNav.items, 'Items'), onViewItem: HomeNav.stockItem)));
  HomeNav.service = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: ServiceRoutes.calendar), builder: (_) => ServiceCalendarScreen(onNavigate: (id) => _tab(c, id))));
  // Section K: money. The server says which screens this person may open; the bottom bar's other tabs go back through _tab.
  HomeNav.money = (c) => Navigator.of(c).push(MoneyHome.route(MoneyEnv(onNavigate: (id) => _tab(c, id))));
  HomeNav.team = (c) => Navigator.of(c).push(TeamDashboardScreen.route(TeamEnv(onNavigate: (id) => _tab(c, id))));
  // Section M: the storefront page builder (profile, hours, delivery, offers, ads and publishing hang off it).
  HomeNav.storefront = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'storefront'), builder: (_) => StorePageBuilder(api: StorefrontApi())));
  // Section N: notification and announcement centres, customer messages and feedback.
  HomeNav.notifications = (c) => Navigator.of(c).push(NoticesHome.route());
  HomeNav.reviews = HomeNav.complaints = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => FeedbackScreen(api: NoticesApi())));
  // Section P: the Settings page and Support & Help. The Team hook (users, roles, invites) belongs to section L.
  HomeNav.settings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen()));
  HomeNav.support = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SupportScreen()));
  HomeNav.setup = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SetupEntry(onFinished: (ctx) => HomeNav.home!(ctx))));
}

/// Bottom-bar tabs of the order screens that belong to other sections.
void _tab(BuildContext context, String id) => switch (id) {
      'home' => HomeNav.go(context, HomeNav.home, 'Home'),
      'item' => HomeNav.go(context, HomeNav.items, 'Items'),
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
    builder: (_) => needsSetup ? SetupEntry(api: setupApi, onFinished: (ctx) => HomeNav.home!(ctx)) : ControlCentreScreen(auth: auth),
  ));
}
