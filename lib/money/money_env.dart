import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'money_api.dart';

/// Every screen of the Money area, in the order of the section switcher. The server decides which of them a person may open (`money_options.screens`).
const moneyScreens = <(String key, String title)>[
  ('overview', 'Overview'),
  ('payments', 'Payments'),
  ('transactions', 'Transactions'),
  ('invoices', 'Invoices'),
  ('cashbook', 'Cashbook'),
  ('expenses', 'Expenses'),
  ('settlements', 'Settlements'),
  ('payouts', 'Payouts'),
  ('refunds', 'Refunds & Adjustments'),
  ('reports', 'Reports'),
];

/// What every section K screen shares: the API, the screens this person may open, and the ways out (other bottom-bar tabs, Items, bell).
class MoneyEnv {
  MoneyEnv({MoneyApi? api, this.onNavigate, this.onItems, this.onBell, this.allowed}) : api = api ?? MoneyApi();
  final MoneyApi api;

  /// Bottom-bar tabs this section does not own: 'item', 'bill', 'online', 'stock'.
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onItems, onBell;

  /// Screen keys the server said this person may open; null until known (every screen is listed, the server still refuses).
  List<String>? allowed;

  /// What the person may do (`money_options.can`); null until known, then the buttons show and the server still decides.
  Facts? can;
  bool may(String k) => can == null || can!.b(k);

  /// Builds a screen by key; set by money_home.dart.
  Widget Function(MoneyEnv env, String key)? screenFor;

  List<(String, String)> get switcher => [for (final s in moneyScreens) if (allowed == null || allowed!.contains(s.$1)) s];

  static const homeRoute = '/money';

  void tab(BuildContext context, String id) {
    if (id == 'money') {
      Navigator.of(context).popUntil((r) => r.settings.name == homeRoute || r.isFirst);
    } else if (onNavigate != null) {
      onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  /// Switches the screen in place (the section switcher), keeping one Money screen on the stack.
  void open(BuildContext context, String key) {
    final build = screenFor;
    if (build == null) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(settings: const RouteSettings(name: homeRoute), builder: (_) => build(this, key)));
  }

  /// Opens a screen on top of the current one (Settlement detail).
  Future<T?> push<T>(BuildContext context, Widget screen) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

  void later(BuildContext context, String what) => showToast(context, '$what opens in a later release.');
}
