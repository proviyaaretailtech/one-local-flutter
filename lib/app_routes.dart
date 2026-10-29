import 'storefront/menu_link_screen.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'account/routes.dart';
import 'ads/advertiser_screens.dart' show AdvertiserApi, AdvertiserHomeScreen;
import 'auth/auth_repository.dart';
import 'auth/partner_api.dart';
import 'catalogue/catalogue_api.dart' show CatalogueApi;
import 'catalogue/catalogue_screen.dart';
import 'catalogue/grn_screens.dart';
import 'catalogue/item_parts.dart';
import 'catalogue/item_sheets.dart' show showQuickAdd;
import 'home/app_shell.dart';
import 'home/control_centre_screen.dart';
import 'home/home_nav.dart';
import 'inventory/inv_env.dart';
import 'inventory/receiving_screen.dart';
import 'kitchen/kds_board_screen.dart';
import 'kitchen/kot_screen.dart';
import 'kitchen/kitchen_setup_screen.dart';
import 'kitchen/kitchen_widgets.dart';
import 'money/money_env.dart';
import 'money/money_home.dart';
import 'money/rst_money.dart';
import 'notices/feedback_screen.dart';
import 'notices/notices_api.dart';
import 'notices/notices_home.dart';
import 'menu/menu_api.dart';
import 'menu/menu_hub.dart';
import 'menu/price_control_screen.dart';
import 'menu/menu_screen.dart';
import 'notices/notification_centre.dart';
import 'purchasing/po_create_screen.dart';
import 'purchasing/purchase_hub_screen.dart';
import 'purchasing/purchasing_api.dart';
import 'purchasing/simple_purchase.dart' show ReceiveGoodsScreen;
import 'orders/order_screen.dart';
import 'orders/orders_board_screen.dart';
import 'money/store_money.dart';
import 'team/staff_screen.dart';
import 'orders/online_locked.dart';
import 'orders/orders_home.dart';
import 'plans/subscription_plans.dart';
import 'stock/product_page.dart';
import 'stock/stock_env.dart';
import 'stock/stock_home.dart';
import 'stock/stock_routes.dart';
import 'sell/sell_env.dart';
import 'sell/sell_screen.dart';
import 'service/calendar_screen.dart';
import 'service/service_widgets.dart' show ServiceRoutes;
import 'settings/settings_api.dart' show SettingsApi;
import 'settings/settings_screen.dart';
import 'ui/i18n.dart';
import 'settings/support_screens.dart';
import 'setup/setup_api.dart';
import 'setup/setup_flow.dart';
import 'storefront/builder_screen.dart';
import 'storefront/page_manager_screen.dart';
import 'storefront/settings_screens.dart';
import 'storefront/storefront_api.dart';
import 'tables/floor_screen.dart';
import 'tables/table_qr_screen.dart';
import 'stock/closing_stock_screen.dart';
import 'tables/manage_tables_screen.dart';
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
        builder: (_) => OnlineOrdersGate(child: restaurant ? OrdersBoardScreen(onNavigate: (id) => _tab(c, id)) : OrdersHome(onNavigate: (id) => _tab(c, id)))));
  };
  HomeNav.orderHistory = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => OrdersHome(onNavigate: (id) => _tab(c, id))));
  // Section F: the till (sell, search, carts, payment, history, returns, receipts). Section E's cart screen stays reachable from the orders list.
  HomeNav.bill = (c) {
    if (HomeNav.shell?.kind == 'store' && _inShell('Bill')) return;
    Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'sell'), builder: (_) => SellScreen(env: SellEnv(onTab: (id) => _tab(c, id)))));
  };
  HomeNav.items = (c) => _itemPart(c, 'products');
  HomeNav.menu = (c) {
    if (_inShell('Menu')) return;
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => const MenuHub()));
  };
  // A store's Stock and Purchase are parts of Item (founder, 25 Oct 2026); a restaurant keeps its Stock tab and receipts page.
  HomeNav.grn = (c) => _restaurant
      ? Navigator.of(c).push(MaterialPageRoute(
          builder: (_) => GrnQueueScreen(onReceive: (ctx) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ReceivingScreen(env: _inventoryEnv(ctx)))))))
      : _itemPart(c, 'purchase');
  // "Open Receipt" on Check delivery: that delivery's receipt in Receiving.
  HomeNav.receipt = (c, documentId) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => ReceivingScreen(env: _inventoryEnv(c), documentId: documentId)));
  HomeNav.stock = (c) {
    if (!_restaurant) return _itemPart(c, 'stock');
    if (_inShell('Stock')) return;
    Navigator.of(c).push(StockHomeScreen.route(_stockEnv(c)));
  };
  HomeNav.stockItem = (c, itemId) => openStockPage(c, _stockEnv(c), StockPage.item, itemId: itemId);
  HomeNav.stockPage = (c, page, {itemId}) => openStockPage(c, _stockEnv(c), page, itemId: itemId);
  // the side menu's search: the Bill's own pages, and Quick add (it adds the product, its stock and its supplier in one screen)
  HomeNav.billPage = (c, page) => SellEnv(onTab: (id) => _tab(c, id)).open(c, page);
  HomeNav.quickAdd = (c) => showQuickAdd(c, CatalogueApi());
  HomeNav.loadLanguage = () async {
    try {
      setAppLanguage((await SettingsApi().get()).language);
    } catch (_) {} // English until the settings can be read
  };
  KitchenEnv kitchenEnv(BuildContext c) => KitchenEnv(onNavigate: (id) => _kitchenTab(c, id));
  HomeNav.kitchenSetup = (c) => Navigator.of(c).push(KitchenSetupScreen.route(kitchenEnv(c)));
  // the KDS view is the kitchen board (founder, 27 Oct 2026); the older list display stays in kds_screen.dart
  HomeNav.kitchenDisplay = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KdsBoardScreen(env: kitchenEnv(c))));
  HomeNav.kotView = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => KotScreen(env: kitchenEnv(c))));
  // The restaurant dashboard's "Open kitchen display" and the More page's Kitchen display tile open the same KDS.
  HomeNav.kitchen = HomeNav.kitchenDisplay;
  HomeNav.tables = (c) {
    if (HomeNav.shell?.kind == 'restaurant' && _inShell('Bill')) return;   // a restaurant's Bill tab is the floor
    Navigator.of(c).push(MaterialPageRoute(builder: (_) => _floor(c)));
  };
  HomeNav.menuLink = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const MenuLinkScreen()));
  HomeNav.tableQr = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => TableQrScreen(env: TablesEnv())));
  HomeNav.lowStock = (c) => openStockPage(c, _stockEnv(c), StockPage.low);
  HomeNav.newPurchase = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => PoCreateScreen(env: PurEnv(inv: _inventoryEnv(c)))));
  HomeNav.purchases = (c) => _restaurant
      ? Navigator.of(c).push(MaterialPageRoute(builder: (_) => PurchaseHubScreen(env: PurEnv(inv: _inventoryEnv(c)), stock: _stockEnv(c))))
      : _itemPart(c, 'purchase');
  // The restaurant side bar's Inventory (0627): each page it folds open. Recipe and Ingredients are sub-masters of the Menu tab.
  // Each page opens on top and answers true once it is closed, so the side bar opens again on Back; a sub-master of the Menu tab only
  // switches the tab (false: nothing to come back from).
  HomeNav.inventory = (c, page) async {
    Future<bool> push(Widget w) async {
      await Navigator.of(c).push(MaterialPageRoute(builder: (_) => w));
      return true;
    }

    switch (page) {
      case 'purchase':
        return push(PurchaseHubScreen(env: PurEnv(inv: _inventoryEnv(c)), stock: _stockEnv(c)));
      case 'prices':
        return push(const PriceControlScreen());
      case 'closing':
        return push(ClosingStockScreen(env: _stockEnv(c))); // the tabular closing stock with Excel export (0628)
      case 'recipes' || 'ingredients':
        MenuHub.requestedTab.value = page == 'recipes' ? 1 : 2;
        if (_inShell('Menu')) return false;
        return push(MenuHub(initial: page == 'recipes' ? 1 : 2));
      case 'tables':
        return push(ManageTablesScreen(env: TablesEnv()));
    }
    return false;
  };
  HomeNav.service = (c) {
    if (HomeNav.shell?.kind == 'service' && _inShell('Bill')) return;   // a service partner's Bill tab is the calendar
    Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: ServiceRoutes.calendar), builder: (_) => ServiceCalendarScreen(onNavigate: (id) => _tab(c, id))));
  };
  // Section K: money. The server says which screens this person may open; the bottom bar's other tabs go back through _tab.
  // A store has its own minimal Money (founder, 28 Oct 2026): accounts, Record transaction, cash register, dues. Restaurants keep section K.
  HomeNav.money = (c) => _isStore
      ? Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: '/money'), builder: (_) => const StoreMoneyScreen()))
      // a restaurant's Money is the store's design rebuilt on its own records (0622, founder 29 Oct 2026)
      : HomeNav.shell?.kind == 'restaurant'
          ? Navigator.of(c).push(RstMoneyScreen.route())
          : Navigator.of(c).push(MoneyHome.route(MoneyEnv(onNavigate: (id) => _tab(c, id))));
  HomeNav.moneyScreen = (c, screen) => _isStore
      ? HomeNav.money!(c)
      : Navigator.of(c).push(MoneyHome.route(MoneyEnv(onNavigate: (id) => _tab(c, id)), start: screen));
  // A store's Team is its staff (founder, 28 Oct 2026): staff, attendance, salary, advances; app logins and roles one tap away.
  HomeNav.team = (c) => _isStore
      ? Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'staff'), builder: (ctx) => StaffScreen(
            onAppUsers: () => Navigator.of(ctx).push(TeamDashboardScreen.route(TeamEnv(onNavigate: (id) => _tab(ctx, id), kind: HomeNav.shell?.kind))))))
      : Navigator.of(c).push(TeamDashboardScreen.route(TeamEnv(onNavigate: (id) => _tab(c, id), kind: HomeNav.shell?.kind)));
  // Section M: the storefront page builder (profile, hours, delivery, offers, ads and publishing hang off it).
  HomeNav.storefront = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'storefront'), builder: (_) => StorePageBuilder(api: StorefrontApi())));
  HomeNav.businessProfile = (c) => Navigator.of(c).push(MaterialPageRoute(settings: const RouteSettings(name: 'business-profile'), builder: (_) => PageManagerScreen(api: StorefrontApi())));
  HomeNav.deliverySettings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => DeliveryScreen(api: StorefrontApi())));
  // Section N: notification and announcement centres, customer messages and feedback.
  HomeNav.notifications = (c) => Navigator.of(c).push(NoticesHome.route());
  // The menu's "Add images to items" / "Add descriptions" suggestions live in the Notification Centre (founder, 27 Oct 2026), worked out
  // from the live menu each time it opens; a store (no restaurant menu) or a person who may not edit the menu gets none.
  NotificationCentre.tips = () async {
    if (!_restaurant) return const [];
    final m = await MenuApi().menu();
    if (!m.canEdit) return const [];
    final total = m.count('total');
    void openMenu(BuildContext c, {String? filter}) {
      final nav = Navigator.of(c);
      nav.maybePop();   // off the notifications page, onto the menu
      if (filter != null) MenuScreen.requestedFilter.value = filter;
      HomeNav.go(nav.context, HomeNav.menu, 'The menu');
    }
    return [
      if (total > 0 && m.count('needs_image') > 0)
        NoticeTip(icon: LucideIcons.image, title: 'Add images to items', line: '${m.count('with_image')}/$total items complete',
            onTap: (c) => openMenu(c, filter: 'needs_image')),
      if (total > 0 && m.count('missing_description') > 0)
        NoticeTip(icon: LucideIcons.alignLeft, title: 'Add descriptions', line: 'Missing for ${m.count('missing_description')} items · Write with AI on the dish',
            onTap: (c) => openMenu(c)),
    ];
  };
  HomeNav.reviews = HomeNav.complaints = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => FeedbackScreen(api: NoticesApi())));
  // Section P: the Settings page and Support & Help. The Team hook (users, roles, invites) belongs to section L.
  HomeNav.settings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen()));
  HomeNav.outletTimings = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen(part: SettingsPart.timings)));
  HomeNav.phoneNumbers = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen(part: SettingsPart.phones)));
  HomeNav.outletInfo = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SettingsScreen(part: SettingsPart.outletInfo)));
  HomeNav.support = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => SupportScreen()));
  // Setup covers the whole screen, bar included.
  HomeNav.setup = (c) => Navigator.of(c, rootNavigator: true).push(MaterialPageRoute(builder: (_) => SetupEntry(onFinished: (ctx) => HomeNav.home!(ctx))));
  installAccountRoutes(); // side nav: Customer, One Local Wallet, Manage account
  HomeNav.plans = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const SubscriptionPlansScreen()));
}

InvEnv _inventoryEnv(BuildContext c) => InvEnv(
    onNavigate: (id) => _tab(c, id),
    onOpenPurchasing: (ctx) => HomeNav.grn?.call(ctx), // Item → Purchase
    onOpenLowStock: (ctx) => HomeNav.lowStock?.call(ctx),
    onOpenOrder: (ctx, orderId) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: orderId, onNavigate: (id) => _tab(ctx, id)))));

bool get _restaurant => (HomeNav.shell?.kind ?? HomeNav.partnerType) == 'restaurant';

/// The store's Item tab: Products · Stock · Purchase (founder, 25 Oct 2026). A product opens its one Product page.
Widget _itemHome(BuildContext c) => ItemHome(parts: {
      'products': (ctx) => CatalogueScreen(
            onNavigate: (id) => _tab(c, id),
            openProduct: (ctx, item) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ProductPage(env: _stockEnv(ctx), item: item))),
          ),
      'stock': (ctx) => StockHomeScreen(env: _stockEnv(ctx)),
      'purchase': (ctx) => PurchaseHubScreen(env: PurEnv(inv: _inventoryEnv(ctx)), stock: _stockEnv(ctx)),
    });

/// Opens Item on one of its parts: switches to the Item tab when the shell has it, else opens Item on top.
void _itemPart(BuildContext c, String part) {
  ItemHome.requested.value = part;
  WidgetsBinding.instance.addPostFrameCallback((_) => ItemHome.requested.value = null); // asked once, not every later visit
  if (_inShell('Item')) return;
  Navigator.of(c).push(MaterialPageRoute(builder: (_) => _itemHome(c)));
}

/// Every stock page's environment: the stock API and bottom bar, and the ways to Purchase (new purchase order) and Receiving.
StockEnv _stockEnv(BuildContext c) => StockEnv(
    inv: _inventoryEnv(c),
    onOpenPurchase: (ctx, [want = const []]) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => PoCreateScreen(env: PurEnv(inv: _inventoryEnv(ctx)), want: want))),
    // a store receives in one step, Add purchase (founder, 29 Oct 2026); a restaurant keeps its count
    onOpenReceiving: (ctx) => Navigator.of(ctx).push(MaterialPageRoute(
        builder: (_) => _restaurant ? ReceivingScreen(env: _inventoryEnv(ctx)) : ReceiveGoodsScreen(api: PurchasingApi()))));

/// Switches the app shell to the tab with this bar label, when the shell is up and has that tab.
bool _inShell(String label) => HomeNav.shell?.show(label) ?? false;

Widget _floor(BuildContext c) => FloorScreen(env: TablesEnv(onNavigate: (id) => id == 'pos' ? null : id == 'orders' ? HomeNav.go(c, HomeNav.orders, 'Orders') : _tab(c, id)));

/// The signed-in app: one bottom bar over a back stack per tab. Each tab's first screen depends on the kind of
/// business: Bill is the till for a store, the tables floor for a restaurant, the calendar for a service partner.
/// A store (not a restaurant or a service partner): the business kind the shell knows, a store until it knows.
bool get _isStore => (HomeNav.shell?.kind ?? 'store') == 'store';

Widget appShell({AuthRepository? auth}) => AppShell(rootFor: (kind, label) => shellTabRoot(kind, label, auth: auth));

/// The first screen of the bar tab [label] for a business of [kind] ('store', 'restaurant', 'service'); null when the tab has none.
Widget? shellTabRoot(String kind, String label, {AuthRepository? auth}) => switch (label) {
        'Home' => ControlCentreScreen(auth: auth),
        'Item' => Builder(builder: _itemHome),
        'Menu' => const MenuHub(),
        'Bill' => Builder(
            builder: (c) => switch (kind) {
              'restaurant' => _floor(c),
              'service' => ServiceCalendarScreen(onNavigate: (id) => _tab(c, id)),
              _ => SellScreen(env: SellEnv(onTab: (id) => _tab(c, id))),
            },
          ),
        // A store's Online order tab is section E (Orders History, each order opening its stage screen). The Live | Hold board with
        // dine-in / takeaway / delivery is the restaurant's Orders tab (section H), so a store never sees it.
        // POS only: the tab offers the OneLocal subscription instead (founder, 28 Oct 2026)
        'Online order' => Builder(builder: (c) => OnlineOrdersGate(child: OrdersHome(onNavigate: (id) => _tab(c, id)))),
        'Orders' => Builder(builder: (c) => OrdersBoardScreen(onNavigate: (id) => _tab(c, id))),
        'Stock' => Builder(builder: (c) => StockHomeScreen(env: _stockEnv(c))),
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
Future<void> openWorkspace(BuildContext context, {AuthRepository? auth, SetupApi? setupApi, AdvertiserApi? advertiserApi}) async {
  // an advertising-only partner has no store to set up: its app is Ads (the Advertising & Partner Growth spec, 29 Oct 2026)
  try {
    final p = await (advertiserApi ?? AdvertiserApi()).profile();
    if (p['partner_kind'] == 'advertising') {
      if (context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => AdvertiserHomeScreen(auth: auth)));
      return;
    }
  } catch (_) {
    // not known (offline, or a server without advertisers yet): carry on as a store
  }
  if (!context.mounted) return;
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
