import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../orders/orders_api.dart';
import '../orders/orders_home.dart';
import 'carts_screen.dart';
import 'history_screen.dart';
import 'receipts_screen.dart';
import 'returns_screen.dart';
import 'sell_api.dart';
import 'sell_carts.dart';
import 'sell_screen.dart';
import 'sell_widgets.dart';

/// What every till screen shares: the two API clients, the open carts, and where the other sections' tabs lead.
/// Tests pass fakes; the app passes nothing and gets the live ones.
class SellEnv {
  SellEnv({SellApi? sell, OrdersApi? orders, SellCarts? carts, this.onTab, this.storeName = 'OneLocal', this.branchName, this.initials = 'RP', Future<bool> Function(Uri)? openUrl})
      : sell = sell ?? SellApi(),
        openUrl = openUrl ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication)),
        orders = orders ?? OrdersApi(),
        carts = carts ?? SellCarts.instance;
  final SellApi sell;
  final OrdersApi orders;
  final SellCarts carts;
  final SellNavigate? onTab;
  final Future<bool> Function(Uri) openUrl; // WhatsApp links; tests replace it
  final String storeName, initials;
  final String? branchName;

  String get storeLine => branchName == null ? storeName : '$storeName · $branchName';

  /// Bottom-bar tabs that belong to other sections go to [onTab]; 'bill' stays on the till.
  void tab(BuildContext context, String id) {
    if (id == 'bill') {
      Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == 'sell');
      return;
    }
    if (onTab != null) {
      onTab!(id);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('That part of the app opens in a later release.')));
    }
  }

  /// The menu sheet and the screens it leads to.
  Future<void> menu(BuildContext context) async {
    final id = await showSellMenu(context);
    if (id == null || !context.mounted) return;
    open(context, id);
  }

  void open(BuildContext context, String id) {
    final nav = Navigator.of(context);
    Widget? page = switch (id) {
      'sell' => SellScreen(env: this),
      'carts' => CartsScreen(env: this),
      'history' => HistoryScreen(env: this),
      'returns' => ReturnsScreen(env: this),
      'receipts' => ReceiptsScreen(env: this),
      'orders' => OrdersHome(api: orders, onNavigate: (t) => tab(context, t)),
      _ => null,
    };
    if (page == null) return;
    nav.push(MaterialPageRoute(settings: RouteSettings(name: id == 'sell' ? 'sell' : null), builder: (_) => page));
  }
}
