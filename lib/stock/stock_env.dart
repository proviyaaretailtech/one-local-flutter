import 'package:flutter/material.dart';

import '../api/rpc_client.dart';
import '../catalogue/catalogue_api.dart';
import '../inventory/inv_env.dart';
import '../inventory/inventory_api.dart';
import 'stock_routes.dart';

/// Every stock screen's environment: the stock API (through [inv], which also owns the bottom bar), the catalogue API (prices,
/// System Code, photos), a plain RPC client for the two on/off switches, and [open] for going to another stock page.
class StockEnv {
  StockEnv({InvEnv? inv, CatalogueApi? catalogue, RpcClient? rpc, StockOpener? open, this.onOpenPurchase, this.onOpenReceiving})
      : inv = inv ?? InvEnv(),
        catalogue = catalogue ?? CatalogueApi(),
        rpc = rpc ?? RpcClient(),
        _open = open;

  final InvEnv inv;
  final CatalogueApi catalogue;
  final RpcClient rpc;
  final StockOpener? _open;

  /// Purchase (new purchase order) and Receiving (count a delivery): they live in the Purchase section; null shows a note.
  /// A new purchase order, with [want] already on it when given.
  final void Function(BuildContext context, [List<OrderWant> want])? onOpenPurchase;
  final void Function(BuildContext context)? onOpenReceiving;

  InventoryApi get api => inv.api;

  /// Bottom-bar tab ('home', 'item', 'bill', 'online', 'stock').
  void tab(BuildContext context, String id) => inv.tab(context, id);

  /// Opens one stock page ([StockPage] ids) on top, for one item when [itemId] is given. Tests pass their own [open] to record it.
  Future<void> open(BuildContext context, String page, {String? itemId}) async =>
      _open != null ? _open(context, page, itemId: itemId) : openStockPage(context, this, page, itemId: itemId);
}

typedef StockOpener = Future<void> Function(BuildContext context, String page, {String? itemId});

/// An item to buy and how much: Reorder and Purchase's "Need to order" hand these to a new purchase order (founder, 29 Oct 2026).
typedef OrderWant = ({String itemId, String name, String unit, num qty});

/// The stock pages. Stock (bottom bar, side menu) opens Stock Management; the others open from buttons on other screens (founder,
/// 25 Oct 2026): Receive from Purchase, Low stock from Home's "Restock critical items", Alerts from Home's Stock health "Full report",
/// and Movements / Adjust / Transfer / Reorder / labels from a product's stock page.
abstract final class StockPage {
  static const home = 'home', item = 'item';
  static const prices = 'prices', movements = 'movements', receive = 'receive', adjust = 'adjust';
  static const transfer = 'transfer', low = 'low', reorder = 'reorder', alerts = 'alerts', count = 'count';
  static const productLabels = 'product_labels', shelfLabels = 'shelf_labels', putaway = 'putaway';

  /// Labels for a whole received lot; its itemId is the receipt note's id.
  static const lotLabels = 'lot_labels';
}
