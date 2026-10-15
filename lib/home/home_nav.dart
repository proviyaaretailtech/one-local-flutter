import 'package:flutter/material.dart';

import '../ui/theme.dart';

typedef HomeRoute = void Function(BuildContext context);

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
  static HomeRoute? bill;
  // Section I: the Service POS calendar, used instead of `bill` by service partners (partner_type 'service').
  static HomeRoute? service;
  static String? partnerType;
  static HomeRoute? money;
  static HomeRoute? notifications;
  static HomeRoute? complaints;
  static HomeRoute? reviews;
  static HomeRoute? support;

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
    home = orders = orderHistory = setup = items = stock = bill = service = money = notifications = complaints = reviews = support = partnerType = null;
  }
}
