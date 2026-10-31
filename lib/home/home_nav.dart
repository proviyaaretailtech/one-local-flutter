import 'package:flutter/material.dart';

import '../ui/theme.dart';

typedef HomeRoute = void Function(BuildContext context);
typedef ItemRoute = void Function(BuildContext context, String itemId);

/// The app shell (lib/home/app_shell.dart) while it is on screen: one bottom bar, a back stack per tab.
abstract class TabShell {
  /// 'store', 'restaurant' or 'service': which tab set the bar shows and what Bill opens.
  String get kind;
  void setKind(String kind);

  /// Switches to the tab with this bar label (tapping the current tab goes back to its first screen); false when the
  /// bar has no such tab, so the caller opens the screen the old way.
  bool show(String label);
}

/// Where the control centre's buttons lead. Screens owned by other phases plug themselves in here
/// (for example section E sets `HomeNav.orders = (c) => Navigator.push(...)`). Until a screen is
/// plugged in, the button says plainly that it is not in this release.
class HomeNav {
  HomeNav._();

  // The control centre itself (set by app_routes.dart).
  static HomeRoute? home;

  // The app shell, set while it is mounted; the tab hooks below switch its tabs instead of pushing a new page.
  static TabShell? shell;

  // Set by the dashboard: the side menu (☰ on every screen's header) and the store's name (the header's top line).
  static HomeRoute? openMenu;
  static String? storeName;

  /// The signed-in person's name, for the profile icon on every header (their initials); null until the dashboard has read it.
  static String? personName;

  // Section E: orders across channels.
  static HomeRoute? orders;
  static HomeRoute? orderHistory;

  // Section C: setup. Section P: the Settings page and Support & Help. Section L (Team) plugs in `team`: users, invitations, roles, tasks, activity.
  static HomeRoute? setup;
  static HomeRoute? settings;
  // One part of Settings on its own (the restaurant More page's tiles): timings, phone numbers, outlet info.
  static HomeRoute? outletTimings;
  static HomeRoute? phoneNumbers;
  static HomeRoute? outletInfo;
  static HomeRoute? team;

  // Later phases (G catalogue, H inventory, F sell, J–Q back office).
  static HomeRoute? items;
  static HomeRoute? stock;
  // Section H: one item's stock detail (section J's low-stock "view item" uses it).
  static ItemRoute? stockItem;
  // Stock management: one stock page by its id (lib/stock/stock_env.dart StockPage), for one stock item when [itemId] is given.
  static void Function(BuildContext context, String page, {String? itemId})? stockPage;
  // The Bill's own pages by id ('carts', 'history', 'returns', 'receipts', 'shift'), and Quick add (the side menu's search opens them).
  static void Function(BuildContext context, String page)? billPage;
  static HomeRoute? quickAdd;
  // Reads the store's language when the app opens (the app sets it; tests leave it unset).
  static Future<void> Function()? loadLanguage;
  // After a sign-in: a pending account deletion is cancelled (the app sets it; tests leave it unset).
  static Future<void> Function(BuildContext context)? afterSignIn;
  // Section H kitchen: stations setup and the Kitchen Display System.
  static HomeRoute? kitchenSetup;
  static HomeRoute? kitchenDisplay;
  // The KOT view: the kitchen order tickets as slips (lib/kitchen/kot_screen.dart).
  static HomeRoute? kotView;
  // Section H: tables and floor (the POS tab).
  static HomeRoute? tables;
  // Table QR codes (0560): print, share, switch, replace the codes guests scan to order.
  static HomeRoute? tableQr;
  // The public menu link (0571): the business's published menu for anyone, no sign-in.
  static HomeRoute? menuLink;
  static HomeRoute? bill;
  // Section I: the Service POS calendar, used instead of `bill` by service partners (partner_type 'service').
  static HomeRoute? service;
  static String? partnerType;
  // Section M: the storefront page builder and its settings.
  static HomeRoute? storefront;

  /// Page Manager (founder, 28 Oct 2026; was Business profile, 27 Oct): how the shop looks to customers, every storefront screen in one place.
  static HomeRoute? businessProfile;
  static HomeRoute? money;
  // Section K: one Money screen by its key ('payouts', 'invoices', 'settlements', ...), for links that name a screen.
  static void Function(BuildContext context, String screen)? moneyScreen;
  // Section M: the storefront's delivery settings (radius, delivery window, pickup).
  static HomeRoute? deliverySettings;
  static HomeRoute? notifications;
  static HomeRoute? complaints;
  static HomeRoute? reviews;
  static HomeRoute? support;

  // Section G: the GRN queue, and where "Open Receipt" on the GRN dashboard goes (section H's receipt screen plugs in here).
  static HomeRoute? grn;
  static void Function(BuildContext context, String receiptDocumentId)? receipt;
  // Section J: low stock and purchase suggestions ("view item" uses section H's [stockItem]).
  static HomeRoute? lowStock;
  // Purchase orders: the list, each order (approve, send to the supplier, receive) and New order.
  static HomeRoute? purchases;
  // A new purchase order (Menu → Ingredients "Buy from supplier").
  static HomeRoute? newPurchase;
  // The side bar's Inventory pages (0627): purchase, prices, closing, recipes, ingredients, tables. True once a page that was opened on
  // top is closed again (the side bar then opens again, founder 29 Oct 2026); false when it only switched a tab.
  static Future<bool> Function(BuildContext context, String page)? inventory;
  // Restaurant: the Menu tab (menu and dish detail). A store keeps [items] (the catalogue).
  static HomeRoute? menu;
  // Restaurant: the kitchen display (KOT queue). Plugged in by the kitchen section; until then the button says so.
  static HomeRoute? kitchen;
  // Side nav: customers, the One Local Wallet and Manage account (plugged by lib/account/routes.dart).
  static HomeRoute? customers;
  // Side menu → Barcodes (30 Oct 2026): store codes, loose items, custom barcodes.
  static HomeRoute? barcodes;
  // Side menu → Product photos (30 Oct 2026): the store's photos, the Standard pool, OneLocal's review.
  static HomeRoute? productPhotos;
  static HomeRoute? wallet;

  /// Side menu → Subscription plans (founder, 28 Oct 2026).
  static HomeRoute? plans;
  static HomeRoute? account;

  /// Opens [route], or tells the person that [what] is not available yet.
  static void go(BuildContext context, HomeRoute? route, String what) {
    if (route != null) {
      route(context);
    } else {
      showToast(context, '$what opens in a later release.');
    }
  }

  /// Clears every hook (tests).
  static void reset() {
    stockItem = null;
    stockPage = null;
    billPage = null;
    quickAdd = null;
    loadLanguage = null;
    afterSignIn = null;
    moneyScreen = null;
    kitchenSetup = kitchenDisplay = deliverySettings = null;
    home = orders = orderHistory = setup = items = stock = tables = bill = service = money = notifications = complaints = reviews = support = partnerType = lowStock = grn = receipt = kitchen = kotView = team = storefront = businessProfile = settings = customers = wallet = account = menu = plans = null;
    tableQr = menuLink = null;
    outletTimings = phoneNumbers = outletInfo = null;
    newPurchase = purchases = null;
    inventory = null;
    shell = null;
    openMenu = null;
    storeName = null;
    personName = null;
  }
}
