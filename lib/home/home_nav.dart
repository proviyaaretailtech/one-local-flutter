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

  // Section C: setup and settings.
  static HomeRoute? setup;

  // Later phases (G catalogue, H inventory, F sell, J–Q back office).
  static HomeRoute? items;
  static HomeRoute? stock;
  // Section L: the team (users, invitations, roles, tasks, activity).
  static HomeRoute? team;
  // Section H: one item's stock detail (section J's low-stock "view item" uses it).
  static ItemRoute? stockItem;
  static HomeRoute? bill;
  static HomeRoute? money;
  static HomeRoute? notifications;
  static HomeRoute? complaints;
  static HomeRoute? reviews;
  static HomeRoute? support;

  // Section G: the GRN queue, and where "Open Receipt" on the GRN dashboard goes (section H's receipt screen plugs in here).
  static HomeRoute? grn;
  static void Function(BuildContext context, String receiptDocumentId)? receipt;

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
    home = orders = orderHistory = setup = items = stock = team = bill = money = notifications = complaints = reviews = support = grn = receipt = null;
  }
}
