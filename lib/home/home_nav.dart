import 'package:flutter/material.dart';

import '../ui/theme.dart';

typedef HomeRoute = void Function(BuildContext context);
typedef ItemRoute = void Function(BuildContext context, String itemId);

/// Where the control centre's buttons lead. Screens owned by other phases plug themselves in here
/// (for example section E sets `HomeNav.orders = (c) => Navigator.push(...)`). Until a screen is
/// plugged in, the button says plainly that it is not in this release.
class HomeNav {
  HomeNav._();

  // The control centre itself (set by app_routes.dart).
  static HomeRoute? home;

  // Section E: orders across channels.
  static HomeRoute? orders;
  static HomeRoute? orderHistory;

  // Section C: setup. Section P: the Settings page and Support & Help. Section L (Team) plugs in `team`: users, invitations, roles, tasks, activity.
  static HomeRoute? setup;
  static HomeRoute? settings;
  static HomeRoute? team;

  // Later phases (G catalogue, H inventory, F sell, J–Q back office).
  static HomeRoute? items;
  static HomeRoute? stock;
  // Section H: one item's stock detail (section J's low-stock "view item" uses it).
  static ItemRoute? stockItem;
  // Section H kitchen: stations setup and the Kitchen Display System.
  static HomeRoute? kitchenSetup;
  static HomeRoute? kitchenDisplay;
  // Section H: tables and floor (the POS tab).
  static HomeRoute? tables;
  static HomeRoute? bill;
  // Section I: the Service POS calendar, used instead of `bill` by service partners (partner_type 'service').
  static HomeRoute? service;
  static String? partnerType;
  // Section M: the storefront page builder and its settings.
  static HomeRoute? storefront;
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
  // Restaurant: the Menu tab (menu and dish detail). A store keeps [items] (the catalogue).
  static HomeRoute? menu;
  // Restaurant: the kitchen display (KOT queue). Plugged in by the kitchen section; until then the button says so.
  static HomeRoute? kitchen;
  // Side nav: customers, the One Local Wallet and Manage account (plugged by lib/account/routes.dart).
  static HomeRoute? customers;
  static HomeRoute? wallet;
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
    moneyScreen = null;
    kitchenSetup = kitchenDisplay = deliverySettings = null;
    home = orders = orderHistory = setup = items = stock = tables = bill = service = money = notifications = complaints = reviews = support = partnerType = lowStock = grn = receipt = kitchen = team = storefront = settings = customers = wallet = account = menu = null;
  }
}
