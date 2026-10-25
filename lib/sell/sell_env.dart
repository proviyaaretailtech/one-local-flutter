import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalogue/catalogue_api.dart';
import '../catalogue/item_sheets.dart' show showQuickAdd;
import '../orders/orders_api.dart';
import '../orders/orders_home.dart';
import '../shift/shift_api.dart';
import '../shift/shift_screens.dart';
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
  SellEnv({SellApi? sell, OrdersApi? orders, ShiftApi? shift, SellCarts? carts, this.onTab, this.storeName = 'OneLocal', this.branchName, this.initials = 'RP', Future<bool> Function(Uri)? openUrl,
      Future<bool> Function(BuildContext context, String category)? addFirstItem})
      : addFirstItem = addFirstItem ?? ((context, category) async => await showQuickAdd(context, CatalogueApi(), category: category) != null),
        sell = sell ?? SellApi(),
        shift = shift ?? ShiftApi(),
        openUrl = openUrl ?? ((u) => launchUrl(u, mode: LaunchMode.externalApplication)),
        orders = orders ?? OrdersApi(),
        carts = carts ?? SellCarts.instance;
  final SellApi sell;
  final ShiftApi shift; // cash shift, payment pending, refund check (0500-0502)
  final OrdersApi orders;
  final SellCarts carts;
  final SellNavigate? onTab;
  final Future<bool> Function(Uri) openUrl; // WhatsApp links; tests replace it
  /// "+ New" category on the Bill: a category is made with its first product, so this opens Quick add in it; true when one was added.
  final Future<bool> Function(BuildContext context, String category) addFirstItem;
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
      'shift' => ShiftScreen(api: shift, storeLine: storeLine, initials: initials),
      _ => null,
    };
    if (page == null) return;
    nav.push(MaterialPageRoute(settings: RouteSettings(name: id == 'sell' ? 'sell' : null), builder: (_) => page));
  }
}
