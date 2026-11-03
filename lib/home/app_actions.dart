import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/i18n.dart';
import 'home_nav.dart';
import '../devices/device_manager_screen.dart';
import '../reports/rst_reports_screen.dart' show RstReportScreen;
import '../restaurant/rst_page_manager.dart' show RstPageManagerScreen;
import '../restaurant/rst_plans_screen.dart' show RstPlansScreen;
import '../settings/rst_devices_screen.dart' show RstDevicesScreen;
import '../tables/bill_adjust.dart' show AdjustRequestsScreen;
import '../tables/bill_api.dart' show BillApi;
import '../tables/dining_areas_screen.dart' show DiningAreasScreen;
import '../tables/reservations_screen.dart' show ReservationsScreen;
import '../tables/table_widgets.dart' show TablesEnv;

/// One place or action of the store app that the side menu's search can open: what it is called, where it lives, the words people
/// might type for it, and how to open it.
class AppAction {
  const AppAction(this.icon, this.title, this.where, this.words, this.open);
  final IconData icon;
  final String title, where, words;
  final VoidCallback open;

  /// Every typed word must appear in the title, the place or the words (any order, any case).
  bool matches(String query) {
    // the names in the app's language too, so Hindi and Hinglish words find them
    final hay = '$title $where $words ${tr(title)} ${tr(where)}'.toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  /// Title matches first, then the rest, in list order.
  int rank(String query) {
    final q = query.toLowerCase().trim();
    return title.toLowerCase().contains(q) || tr(title).toLowerCase().contains(q) ? 0 : 1;
  }
}

/// Every action of the store app the side menu's search can open (founder, 26 Oct 2026: "any action in the application should be
/// searchable"). Built from the app's open-hooks; one that is not plugged in is left out. [onReports] opens Reports.
List<AppAction> appActions(BuildContext context, {VoidCallback? onReports}) {
  // a restaurant has its own pages: never the store's barcodes, shelf labels, quick add product, device or money pages (founder, 3 Nov 2026)
  if (HomeNav.shell?.kind == 'restaurant') return restaurantActions(context, onReports: onReports);
  final list = <AppAction>[];
  void add(IconData icon, String title, String where, String words, VoidCallback? open) {
    if (open != null) list.add(AppAction(icon, title, where, words, open));
  }

  VoidCallback? route(HomeRoute? r) => r == null ? null : () => r(context);
  VoidCallback? stock(String page) => HomeNav.stockPage == null ? null : () => HomeNav.stockPage!(context, page);
  VoidCallback? bill(String page) => HomeNav.billPage == null ? null : () => HomeNav.billPage!(context, page);
  VoidCallback? money(String screen) => HomeNav.moneyScreen == null ? null : () => HomeNav.moneyScreen!(context, screen);

  // the bottom bar
  add(LucideIcons.house, 'Home', 'Dashboard', 'dashboard today sales summary start', route(HomeNav.home));
  add(LucideIcons.receiptText, 'Bill', 'New sale', 'bill sale sell billing pos checkout counter new bill customer bill', route(HomeNav.bill));
  add(LucideIcons.package, 'Products', 'Item', 'catalogue products items list grid categories maal saman', route(HomeNav.items));
  add(LucideIcons.zap, 'Quick add product', 'Item → Products', 'add new product item create naya product photo barcode price', route(HomeNav.quickAdd));
  add(LucideIcons.shoppingBag, 'Online orders', 'Orders', 'online orders new orders accept onelocal app delivery pickup', route(HomeNav.orders));
  add(LucideIcons.qrCode, 'All orders', 'Orders', 'order history all orders past orders', route(HomeNav.orderHistory));

  // Item → Stock
  add(LucideIcons.boxes, 'Stock management', 'Item → Stock', 'stock inventory update stock price mrp cost quantity store app on off', route(HomeNav.stock));
  add(LucideIcons.slidersHorizontal, 'Adjust stock', 'Item → Stock', 'adjust correct stock damage damaged loss throw away write off quarantine', stock('adjust'));
  add(LucideIcons.arrowLeftRight, 'Transfer stock', 'Item → Stock', 'transfer move stock backroom shelf another store', stock('transfer'));
  add(LucideIcons.history, 'Stock history', 'Item → Stock', 'movements history stock in out ledger', stock('movements'));
  add(LucideIcons.clipboardCheck, 'Count stock', 'Item → Stock', 'count audit physical count stock check ginti', stock('count'));
  add(LucideIcons.bellRing, 'Stock alerts', 'Item → Stock', 'alerts low stock expiry expiring not selling mismatch', stock('alerts'));
  add(LucideIcons.trendingDown, 'Low stock', 'Item → Stock', 'low stock running out out of stock khatam', stock('low'));
  add(LucideIcons.tag, 'Shelf labels', 'Item → Stock', 'labels price tag shelf label print barcode sticker', stock('shelf_labels'));
  add(LucideIcons.packageCheck, 'Putaway', 'Item → Purchase', 'putaway put away place stock backroom shelf after delivery', stock('putaway'));

  // Item → Purchase
  add(LucideIcons.truck, 'Purchase', 'Item → Purchase', 'purchase buy suppliers purchase orders kharid', route(HomeNav.grn));
  add(LucideIcons.packageOpen, 'Receive delivery', 'Item → Purchase', 'receive delivery goods arrived count delivery grn receiving maal aaya', stock('receive'));
  add(LucideIcons.shoppingCart, 'Reorder / buy again', 'Item → Purchase', 'reorder buy again new purchase order supplier order suggestions', stock('reorder'));

  // the Bill's own pages
  add(LucideIcons.layers, 'Open carts', 'Bill', 'open carts parked held bills hold', bill('carts'));
  add(LucideIcons.history, 'Bill history', 'Bill', 'history past bills sales today', bill('history'));
  add(LucideIcons.undo2, 'Returns & refunds', 'Bill', 'return refund wapas exchange', bill('returns'));
  add(LucideIcons.fileText, 'Invoices', 'Bill', 'invoice receipt reprint share bill copy', bill('receipts'));
  add(LucideIcons.wallet, 'Cash shift', 'Bill', 'cash shift open close drawer cash counter galla', bill('shift'));

  // Money
  add(LucideIcons.indianRupee, 'Money', 'Money', 'money finance paisa hisab', route(HomeNav.money));
  add(LucideIcons.creditCard, 'Payments', 'Money', 'payments upi card cash received collections', money('payments'));
  add(LucideIcons.arrowRightLeft, 'Transactions', 'Money', 'transactions all money in out', money('transactions'));
  add(LucideIcons.bookOpen, 'Cashbook', 'Money', 'cashbook cash in out balance', money('cashbook'));
  add(LucideIcons.receipt, 'Expenses', 'Money', 'expenses kharcha rent salary bills spend', money('expenses'));
  add(LucideIcons.landmark, 'Settlements', 'Money', 'settlement onelocal payout commission', money('settlements'));
  add(LucideIcons.banknote, 'Payouts', 'Money', 'payouts bank transfer paid pending', money('payouts'));
  add(LucideIcons.undo, 'Refunds', 'Money', 'refunds money back', money('refunds'));
  add(LucideIcons.chartColumn, 'Money reports', 'Money', 'reports gst tax sales report finance', money('reports'));

  // the rest of the side menu
  add(LucideIcons.scanBarcode, 'Barcodes', 'Side menu', 'barcode make generate create custom code sticker loose weigh weight plu kg label print', route(HomeNav.barcodes));
  add(LucideIcons.images, 'Media manager', 'Side menu', 'media manager photos images pictures gallery product photos master media my photos brand subcategory standard share offer approve', route(HomeNav.productPhotos));
  add(LucideIcons.circleUser, 'Customers', 'Side menu', 'customers grahak contacts credit khata', route(HomeNav.customers));
  add(LucideIcons.fileText, 'Reports', 'Side menu', 'reports sales analytics best sellers', onReports);
  add(LucideIcons.users, 'Team', 'Side menu', 'team staff users roles invite cashier manager employee', route(HomeNav.team));
  add(LucideIcons.settings, 'Settings', 'Side menu', 'settings preferences store timings language', route(HomeNav.settings ?? HomeNav.setup));
  add(LucideIcons.printer, 'Devices', 'Settings', 'devices printer printers receipt label barcode kot kitchen thermal bluetooth test print', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeviceManagerScreen(store: HomeNav.storeName ?? ''))));
  add(LucideIcons.mapPinned, 'Delivery area & charges', 'Settings → Orders & delivery', 'delivery distance radius km fee minimum order free delivery', route(HomeNav.deliverySettings));
  add(LucideIcons.layoutDashboard, 'Page Manager', 'Side menu', 'page manager business profile shop page online store storefront onelocal page how customers see banner theme colours publish details logo hours delivery offers ads promote', route(HomeNav.businessProfile ?? HomeNav.storefront));
  add(LucideIcons.megaphone, 'Ads', 'Page Manager', 'ads advertise promote boost visibility customers nearby', route(HomeNav.businessProfile ?? HomeNav.storefront));
  add(LucideIcons.layoutTemplate, 'Store page', 'Page Manager', 'store page builder sections banner categories products deals preview publish theme', route(HomeNav.storefront));
  add(LucideIcons.wallet, 'OneLocal Wallet', 'Side menu', 'wallet balance', route(HomeNav.wallet));
  add(LucideIcons.bell, 'Notifications', 'Banner', 'notifications alerts messages announcements', route(HomeNav.notifications));
  add(LucideIcons.circleQuestionMark, 'Help & support', 'Side menu', 'help support complaint ticket contact problem', route(HomeNav.support));
  add(LucideIcons.user, 'Manage account', 'Profile', 'account profile name phone password sign in', route(HomeNav.account));
  return list;
}

/// Every place a restaurant's search and Ol can open (founder, 3 Nov 2026: "Search the app and Ol show store actions to a restaurant …
/// Train Ol for restaurant"): the restaurant's own tabs, side menu, Inventory pages, reports, money and devices, each with the words
/// restaurant staff use for it. Built from the same open-hooks; one that is not plugged in is left out.
List<AppAction> restaurantActions(BuildContext context, {VoidCallback? onReports}) {
  final list = <AppAction>[];
  void add(IconData icon, String title, String where, String words, VoidCallback? open) {
    if (open != null) list.add(AppAction(icon, title, where, words, open));
  }

  VoidCallback? route(HomeRoute? r) => r == null ? null : () => r(context);
  VoidCallback push(Route<Object?> Function() r) => () => Navigator.of(context).push(r());
  VoidCallback? inventory(String page) => HomeNav.inventory == null ? null : () => HomeNav.inventory!(context, page);
  VoidCallback report(String kind) => push(() => MaterialPageRoute(builder: (_) => RstReportScreen(kind: kind)));
  final settings = HomeNav.settings ?? HomeNav.setup;

  // the bottom bar
  add(LucideIcons.house, 'Home', 'Dashboard', "dashboard today's sales bills kitchen summary start", route(HomeNav.home));
  add(LucideIcons.receiptText, 'Bill', 'Tables and orders',
      'bill floor tables table order take order dine in takeaway parcel delivery kot send to kitchen hold generate bill checkout pay', route(HomeNav.tables));
  add(LucideIcons.bookOpen, 'Menu', 'Menu', 'menu dishes dish items food price category veg out of stock photo description timings', route(HomeNav.menu));
  add(LucideIcons.plus, 'Add a dish', 'Menu → Quick add', 'add dish new dish item quick add create naya price category', route(HomeNav.menu));
  add(LucideIcons.shoppingBag, 'Orders', 'Orders', 'orders live orders delivery swiggy zomato onelocal takeaway on call phone held hold send to kitchen collect', route(HomeNav.orders));
  add(LucideIcons.qrCode, 'All orders', 'Side menu', 'all orders order history past orders old bills', route(HomeNav.orderHistory ?? HomeNav.orders));
  add(LucideIcons.monitor, 'Kitchen display (KDS)', 'Orders', 'kds kitchen display screen cooking ready chef', route(HomeNav.kitchenDisplay));
  add(LucideIcons.ticket, 'KOT view', 'Orders', 'kot kitchen ticket tickets reprint kot', route(HomeNav.kotView));

  // the floor
  add(LucideIcons.calendarClock, 'Reservations', 'Side menu', 'reservations reservation booking book table seat no show guests', push(() => ReservationsScreen.route(TablesEnv())));
  add(LucideIcons.layoutGrid, 'Table management', 'Bill → ⋮ → Manage tables', 'tables add table rename seats manage tables remove table', inventory('tables'));
  add(LucideIcons.layers, 'Dining areas', 'Manage tables', 'dining areas area section ac hall rooftop garden floor', push(() => DiningAreasScreen.route(TablesEnv())));
  add(LucideIcons.qrCode, 'Table QR codes', 'Bill → ⋮', 'table qr code scan guest order from table', route(HomeNav.tableQr));
  add(LucideIcons.badgeCheck, 'Approvals', 'Side menu', 'approvals approve cancel dish refund void requests manager cashier',
      push(() => MaterialPageRoute(builder: (_) => AdjustRequestsScreen(api: BillApi()))));

  // money
  add(LucideIcons.indianRupee, 'Money', 'Side menu', 'money cash drawer upi bank wallet balance money in money out transfer paisa hisab', route(HomeNav.money));
  add(LucideIcons.moon, 'Day end', 'Money → Cash register', 'day end close day end of day count cash drawer register reopen day galla', route(HomeNav.money));
  add(LucideIcons.arrowUpRight, 'Money out', 'Money', 'money out expense pay rent salary supplier kharcha paid out', route(HomeNav.money));
  add(LucideIcons.arrowDownLeft, 'Money in', 'Money', 'money in cash in owner money add cash', route(HomeNav.money));
  add(LucideIcons.handCoins, 'Dues', 'Money', 'dues credit collect udhar khata bill on credit supplier invoices to pay', route(HomeNav.money));
  add(LucideIcons.wallet, 'OneLocal Wallet', 'Side menu', 'onelocal wallet settlement payout online orders money', route(HomeNav.wallet));

  // Inventory (side menu)
  add(LucideIcons.truck, 'Purchase', 'Side menu → Inventory', 'purchase buy supplier purchase order vendor kharid', inventory('purchase'));
  add(LucideIcons.packageOpen, 'Receive delivery', 'Inventory → Purchase', 'receive delivery goods arrived grn receiving maal aaya', route(HomeNav.grn));
  add(LucideIcons.table, 'Price control', 'Side menu → Inventory', 'price control dish prices change price rate list', inventory('prices'));
  add(LucideIcons.clipboardCheck, 'Closing stock check', 'Side menu → Inventory', 'closing stock check count stock end of day ingredients left', inventory('closing'));
  add(LucideIcons.chefHat, 'Recipe', 'Side menu → Inventory', 'recipe recipes food cost margin profit ingredients per dish', inventory('recipes'));
  add(LucideIcons.carrot, 'Ingredients', 'Side menu → Inventory', 'ingredients raw material stock vegetables groceries kitchen stock barcode scan ingredient barcodes', inventory('ingredients'));
  add(LucideIcons.boxes, 'Stock', 'Inventory', 'stock inventory ingredients on hand', route(HomeNav.stock));
  add(LucideIcons.trendingDown, 'Low stock', 'Inventory', 'low stock running out finished khatam reorder', route(HomeNav.lowStock));

  // the kitchen and devices
  add(LucideIcons.cookingPot, 'Kitchen setup', 'Settings', 'kitchen setup stations printer groups which dishes go to which kitchen', route(HomeNav.kitchenSetup));
  add(LucideIcons.printer, 'Devices', 'Settings', 'devices printer printers kot printer receipt printer bill printer thermal bluetooth test print',
      push(() => RstDevicesScreen.route()));

  // reports
  add(LucideIcons.fileText, 'Reports', 'Side menu', 'reports sales analytics', onReports);
  add(LucideIcons.chartColumn, 'Sales summary', 'Reports', 'sales summary report today month revenue net sales gst', report('sales'));
  add(LucideIcons.utensils, 'Item-wise sales', 'Reports', 'item wise dish wise best selling top dishes report', report('items'));
  add(LucideIcons.creditCard, 'Payment mode', 'Reports', 'payment mode cash upi card report collections', report('payments'));
  add(LucideIcons.userCheck, 'Cashier & day end', 'Reports', 'cashier who took money day end cash count report', report('cashiers'));
  add(LucideIcons.badgePercent, 'Discounts report', 'Reports', 'discounts coupon manual discount report', report('discounts'));
  add(LucideIcons.shieldAlert, 'Leakage audit', 'Reports', 'leakage revenue leakage audit admin pin cancelled unpaid unsettled day end reopened', report('audit'));
  add(LucideIcons.undo2, 'Cancellations & refunds', 'Reports', 'cancellations refunds void cancelled dishes report', report('cancellations'));

  // the rest of the side menu
  add(LucideIcons.circleUser, 'Customers', 'Side menu', 'customers guests contacts phone numbers', route(HomeNav.customers));
  add(LucideIcons.users, 'Team', 'Side menu', 'team staff waiter captain cashier manager roles invite', route(HomeNav.team));
  add(LucideIcons.layoutTemplate, 'Page Manager', 'Side menu', 'page manager onelocal page online ads offers reviews profile hours delivery link',
      push(() => RstPageManagerScreen.route()));
  add(LucideIcons.link, 'Menu link', 'Page Manager', 'menu link share menu online menu qr whatsapp', route(HomeNav.menuLink));
  add(LucideIcons.store, 'Business profile', 'Side menu', 'business profile outlet name address phone gst fssai', route(HomeNav.outletInfo ?? settings));
  add(LucideIcons.settings, 'Settings', 'Side menu', 'settings timings hours phone numbers language bill settings service charge gst', route(settings));
  add(LucideIcons.crown, 'Subscription plans', 'Side menu', 'subscription plan plans pay renew', push(() => RstPlansScreen.route()));
  add(LucideIcons.bell, 'Notifications', 'Banner', 'notifications alerts messages', route(HomeNav.notifications));
  add(LucideIcons.circleQuestionMark, 'Help & support', 'Side menu', 'help support complaint ticket contact problem', route(HomeNav.support));
  add(LucideIcons.user, 'Manage account', 'Profile', 'account profile name phone password sign out delete account', route(HomeNav.account));
  return list;
}

/// The actions that match [query], title matches first.
List<AppAction> searchActions(List<AppAction> all, String query) {
  if (query.trim().isEmpty) return const [];
  final hits = all.where((a) => a.matches(query));
  return [...hits.where((a) => a.rank(query) == 0), ...hits.where((a) => a.rank(query) != 0)];
}
