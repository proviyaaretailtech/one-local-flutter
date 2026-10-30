import 'package:flutter/foundation.dart';

import '../orders/orders_api.dart';
import '../barcodes/barcodes_api.dart' show weightText;
import 'sell_api.dart';

/// A cart being built at the counter. Nothing is on the server until it is held or paid; only item ids and quantities are kept,
/// the price of every line comes from the server's quote.
class SellCart {
  SellCart({required this.id, required this.number});
  final String id;
  final int number;
  String customerName = '', customerPhone = '';

  /// The person at the counter was in a hurry and skipped the customer's number: the cart goes on as a walk-in and is not asked again.
  bool customerSkipped = false;
  String? couponCode;
  final List<CartLine> lines = [];
  final Map<String, num> unitPrice = {}; // shown beside a line before the server quotes; the quote is what is charged

  String get label => '#$number';
  int get units => lines.fold(0, (n, l) => n + l.qty);
  bool get isEmpty => lines.isEmpty;
  num get estimate => lines.fold<num>(0, (n, l) => n + lineEstimate(l));

  /// What one line comes to before the server quotes: a weighed pack is the price per kg × its weight.
  num lineEstimate(CartLine l) {
    final p = unitPrice[l.menuItemId] ?? 0;
    return l.weightG == null ? p * l.qty : ((p * l.weightG! / 1000) * 100).round() / 100;
  }

  /// One weighed pack of a loose item: always its own line ("Rice · 1.250 kg").
  void addWeighed(SellItem item, int grams) {
    unitPrice[item.id] = item.price;
    lines.add(CartLine(menuItemId: item.id, name: '${item.name} · ${weightText(grams)}', weightG: grams));
  }

  void add(SellItem item) {
    unitPrice[item.id] = item.price;
    final existing = lines.where((l) => l.menuItemId == item.id && l.weightG == null).firstOrNull;
    if (existing != null) {
      if (existing.qty < 99) existing.qty++;
    } else {
      lines.add(CartLine(menuItemId: item.id, name: item.name));
    }
  }

  void setQty(CartLine line, int qty) {
    if (qty <= 0) {
      lines.remove(line);
    } else {
      line.qty = line.weightG != null ? 1 : (qty > 99 ? 99 : qty); // a weighed pack stays one pack: weigh another for more
    }
  }
}

/// All the carts open on this till (Figma "multiple Cart"): one is active, the others wait. Carts live in memory for the session; a bill
/// the person wants to keep is held, which saves it on the server (unpaid, no stock or money moves).
class SellCarts extends ChangeNotifier {
  SellCarts() {
    _carts.add(SellCart(id: 'c1', number: 1));
  }

  static final SellCarts instance = SellCarts();
  final List<SellCart> _carts = [];
  int _active = 0;
  int _seq = 1;

  List<SellCart> get carts => List.unmodifiable(_carts);
  SellCart get active => _carts[_active];
  int get totalUnits => active.units;

  SellCart newCart() {
    final c = SellCart(id: 'c${++_seq}', number: _seq);
    _carts.add(c);
    _active = _carts.length - 1;
    notifyListeners();
    return c;
  }

  void select(SellCart c) {
    final i = _carts.indexOf(c);
    if (i >= 0) _active = i;
    notifyListeners();
  }

  /// A cart that was paid or held leaves the list; the till always keeps at least one empty cart.
  void finish(SellCart c) {
    _carts.remove(c);
    if (_carts.isEmpty) _carts.add(SellCart(id: 'c${++_seq}', number: _seq));
    _active = _active.clamp(0, _carts.length - 1);
    notifyListeners();
  }

  void changed() => notifyListeners();
}
