import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/catalogue_api.dart';
import '../orders/order_widgets.dart';
import '../ui/barcode_scanner.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'cart_customer.dart';
import 'carts_screen.dart';
import '../shift/shift_api.dart';
import '../shift/shift_screens.dart';
import 'pay_screen.dart';
import 'search_screen.dart';
import 'sell_api.dart';
import 'sell_carts.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';
import '../ui/i18n.dart';

/// The Bill's scan button: the camera reads a barcode (null when closed). Tests replace it.
Future<String?> Function(BuildContext context) scanForSale = scanBarcode;

/// A scanned barcode's System Code, from the catalogue (null when no product has it). Tests replace it.
Future<String?> Function(String code) systemCodeForBarcode = (code) async {
  try {
    return (await CatalogueApi().lookup(code)).sku;
  } catch (_) {
    return null;
  }
};

/// Figma "439 Sell" / "444 Discount": the till. Search or scan, pick a category, tap ADD; the Current Cart bar shows the server's total and
/// leads to payment. A cart that is not paid can be held (saved unpaid on the server).
class SellScreen extends StatefulWidget {
  const SellScreen({super.key, required this.env});
  final SellEnv env;
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  SellEnv get env => widget.env;
  SellCart get cart => env.carts.active;
  final _search = TextEditingController();
  Timer? _debounce;
  SellCatalog? _catalog;
  String? _error;
  String _category = '';

  /// MRP and stock per item (Figma "444 Discount"); empty until read, or when this person may not see the catalogue.
  Map<String, SellFacts> _facts = const {};

  Quote? _quote;
  num? _lastTotal; // the total last quoted: PAY keeps showing it while the next quote loads, so nothing flickers
  int _seq = 0, _quoteSeq = 0;
  bool _busy = false;
  ShiftState? _shift; // the store's cash drawer (S5.1); null until read, or when it could not be read
  int _heldBills = 0; // bills held on the server, shown on the cart bar's pile
  List<String> _related = const []; // bought together with the cart (or best sellers), best first: All items shows them first
  String _relatedFor = '-';
  Timer? _relatedWait;

  @override
  void initState() {
    super.initState();
    env.carts.addListener(_cartChanged);
    _load();
    _loadFacts();
    _loadShift();
    _loadHeld();
    _loadRelated();
    _requote();
  }

  Future<void> _loadHeld() async {
    try {
      final r = await env.sell.receipts(status: 'unpaid');
      if (mounted) setState(() => _heldBills = r.length);
    } catch (_) {} // the pile then shows only the carts parked here
  }

  Future<void> _openCarts() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartsScreen(env: env)));
    if (mounted) {
      _loadHeld();
      _requote();
    }
  }

  Future<void> _loadFacts() async {
    final f = await env.sell.facts();
    if (mounted) setState(() => _facts = f);
  }

  @override
  void dispose() {
    env.carts.removeListener(_cartChanged);
    _relatedWait?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _cartChanged() {
    if (mounted) setState(() {});
    _relatedWait?.cancel();
    _relatedWait = Timer(const Duration(milliseconds: 400), _loadRelated);
  }

  /// Market basket analysis (founder, 27 Oct 2026): what other bills had with the products in this cart; nothing in the cart, the best sellers.
  Future<void> _loadRelated() async {
    final ids = [for (final l in cart.lines) l.menuItemId]..sort();
    final key = ids.join(',');
    if (key == _relatedFor) return;
    try {
      final r = await env.sell.boughtWith(ids);
      if (!mounted) return;
      setState(() {
        _related = r;
        _relatedFor = key;
      });
    } catch (_) {} // the list stays in its usual order
  }

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() => _error = null);
    try {
      final c = await env.sell.catalog(q: _search.text);
      if (!mounted || mine != _seq) return;
      setState(() => _catalog = c);
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _error = sellErrorText(e));
    }
  }

  Future<void> _requote() async {
    if (cart.isEmpty) {
      setState(() {
        _quote = null;
        _lastTotal = null;
      });
      return;
    }
    final mine = ++_quoteSeq;
    try {
      final q = await env.orders.quote(cart.lines, coupon: cart.couponCode);
      if (mounted && mine == _quoteSeq) {
        setState(() {
          _quote = q;
          _lastTotal = q.total;
        });
      }
    } catch (_) {
      if (mounted && mine == _quoteSeq) setState(() => _quote = null);
    }
  }

  Future<void> _loadShift() async {
    try {
      final s = await env.shift.current();
      if (mounted) setState(() => _shift = s);
    } catch (_) {
      if (mounted) setState(() => _shift = null); // the banner stays hidden; a payment that needs a shift is refused by the database anyway
    }
  }

  Future<void> _openShift() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => OpenShiftScreen(api: env.shift, storeLine: env.storeLine, initials: env.initials, required: _shift?.mustOpen == true)));
    if (ok == true && mounted) await _loadShift();
  }

  /// Scan with the camera: the product with that barcode (or System Code) goes into the cart; anything else is left in the search box.
  Future<void> _scan() async {
    final code = (await scanForSale(context))?.trim() ?? '';
    if (code.isEmpty || !mounted) return;
    final sku = await systemCodeForBarcode(code) ?? code;
    try {
      final c = await env.sell.catalog(q: sku);
      final hit = c.items.where((i) => i.sku.toLowerCase() == sku.toLowerCase()).firstOrNull;
      if (!mounted) return;
      if (hit != null) {
        if (!await _haveCustomer() || !mounted) return;
        await _add(hit);
        if (mounted) showToast(context, '${hit.name} added.');
        return;
      }
      _search.text = code;
      _load();
      showToast(context, 'No product has the code $code.');
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    }
  }

  /// A cart starts with its customer (founder, 29 Oct 2026): the mobile number first; the name is optional. A vendor in a hurry may skip it,
  /// and that cart is then a walk-in and not asked again. True when the cart may go on (asked now if needed).
  Future<bool> _haveCustomer() async {
    if (cart.customerPhone.isNotEmpty || cart.customerSkipped) return true;
    final r = await askCartCustomer(context, title: tr('Who is this cart for?'), canSkip: true);
    if (r == null || !mounted) return false;
    cart.customerName = r.$1;
    cart.customerPhone = r.$2;
    cart.customerSkipped = r.$2.isEmpty;
    env.carts.changed();
    return true;
  }

  Future<void> _editCustomer() async {
    final r = await askCartCustomer(context, name: cart.customerName, phone: cart.customerPhone);
    if (r == null || !mounted) return;
    cart.customerName = r.$1;
    cart.customerPhone = r.$2;
    env.carts.changed();
  }

  Future<void> _add(SellItem item) async {
    if (!await _haveCustomer()) return;
    cart.add(item);
    env.carts.changed();
    _quote = null;
    _requote();
  }

  Future<void> _openSearch() async {
    if (!await _haveCustomer() || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: (i) => _add(i))));
    if (mounted) _requote();
  }

  Future<void> _pay() async {
    if (cart.isEmpty || !await _haveCustomer() || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(env: env, cart: cart)));
    if (mounted) {
      setState(() {});
      _requote();
      _loadFacts(); // a sale changes the stock counts
    }
  }

  Future<void> _hold() async {
    if (cart.isEmpty || _busy || !await _haveCustomer() || !mounted) return;
    setState(() => _busy = true);
    try {
      await env.orders.hold(lines: cart.lines, key: OrdersApi.newKey(), customerName: cart.customerName, customerPhone: cart.customerPhone, couponCode: cart.couponCode);
      env.carts.finish(cart);
      if (mounted) showToast(context, 'Bill held. Find it under Open carts.');
      _quote = null;
      _loadHeld();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // the products of the chosen category (no All / In Stock / Fast Moving / Low Inventory tabs: founder, 26 Oct 2026)
  List<SellItem> get _items {
    final all = _catalog?.items ?? const <SellItem>[];
    if (_category.isNotEmpty) return all.where((i) => i.category == _category).toList();
    // All items: the related products first, in their order, then the rest as they come
    final rank = {for (final (i, id) in _related.indexed) id: i};
    return [...all.where((i) => rank.containsKey(i.id)).toList()..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!)), ...all.where((i) => !rank.containsKey(i.id))];
  }

  /// Why a card is near the top of All items (null when it is not one of the related products).
  String? _why(SellItem item) {
    if (_category.isNotEmpty || !_related.contains(item.id)) return null;
    return cart.isEmpty ? 'Popular' : 'Bought together';
  }

  void _less(SellItem item) {
    final l = cart.lines.where((l) => l.menuItemId == item.id).firstOrNull;
    if (l == null) return;
    cart.setQty(l, l.qty - 1);
    env.carts.changed();
    _quote = null;
    _requote();
  }

  /// Savings against MRP for what is in the cart ("Atta 5kg: ₹15 off MRP"): the selling price is below the printed MRP.
  List<(String, num)> get _savings => [
        for (final l in cart.lines)
          if ((_facts[l.menuItemId]?.mrp ?? 0) > (cart.unitPrice[l.menuItemId] ?? double.infinity))
            (l.name, (_facts[l.menuItemId]!.mrp! - cart.unitPrice[l.menuItemId]!) * l.qty),
      ];

  @override
  Widget build(BuildContext context) {
    final units = cart.units;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // ☰ is the side menu (as on every screen); the till's own pages are the shortcuts under the search.
        // no scanner on the banner (founder, 28 Oct 2026): the search below has its own; the banner carries the wallet like every screen
        SellTopBar(title: tr('Bill'), initials: env.initials),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SellSearchField(
            controller: _search,
            hint: tr('Search name or System Code…'),
            leading: LucideIcons.search,
            // the camera scanner at the right end (founder, 27 Oct 2026)
            trailing: IconButton(
              key: const ValueKey('sell-scan'),
              tooltip: tr('Scan barcode'),
              style: IconButton.styleFrom(backgroundColor: kLime, minimumSize: const Size(38, 38), padding: EdgeInsets.zero),
              onPressed: _scan,
              icon: const Icon(LucideIcons.scanBarcode, size: 20, color: kInk),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), _load);
            },
          ),
        ),
        SizedBox(
          height: 38,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final (id, icon, label) in const [
                ('carts', LucideIcons.layers, 'Open carts'),
                ('history', LucideIcons.history, 'History'),
                ('returns', LucideIcons.undo2, 'Returns'),
                ('receipts', LucideIcons.receiptText, 'Invoices'),
                ('shift', LucideIcons.wallet, 'Cash shift'),
              ])
                _Shortcut(icon: icon, label: label, onTap: () => env.open(context, id)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        if (_shift != null && _shift!.shift == null) _shiftBanner(_shift!),
        Expanded(child: _body()),
        _cartBar(units),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  /// S5.1: no cash shift is open at this store. When the store requires one the database refuses payments until it is opened.
  Widget _shiftBanner(ShiftState s) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Material(
          color: s.mustOpen ? kWarnBg : kLimeSoft,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _openShift,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Icon(LucideIcons.wallet, size: 18, color: s.mustOpen ? kWarnText : kGreenText),
                const SizedBox(width: 10),
                Expanded(child: Text(s.mustOpen ? 'Open the cash shift before the first bill' : 'No cash shift open', style: inter(13.5, 600, color: s.mustOpen ? kWarnText : kInk))),
                Text(tr('Open shift'), style: inter(13.5, 800, color: s.mustOpen ? kWarnText : kGreenText)),
              ]),
            ),
          ),
        ),
      );

  Widget _body() {
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(12), child: StateCard(icon: LucideIcons.database, danger: true, title: tr('Items could not load'), body: _error!, primary: 'Retry', onPrimary: _load));
    }
    final catalog = _catalog;
    if (catalog == null) return const Center(child: CircularProgressIndicator(color: kGreenText));
    final cats = ['', ...catalog.categories];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 72,
        // the categories only (no New category here: founder, 26 Oct 2026; categories are made in Item → Products)
        child: Column(children: [
          Expanded(
            child: ListView(children: [
              for (final c in cats)
                Semantics(
                  button: true,
                  selected: c == _category,
                  label: c.isEmpty ? 'All items' : c,
                  child: InkWell(
                    onTap: () => setState(() => _category = c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(color: c == _category ? const Color(0xFFFFF4E0) : null, border: Border(left: BorderSide(width: 3, color: c == _category ? const Color(0xFFF59E0B) : Colors.transparent))),
                      child: Column(children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: kLine)),
                          child: Icon(c.isEmpty ? LucideIcons.layoutGrid : LucideIcons.tag, size: 16, color: c == _category ? const Color(0xFFD97706) : kMuted),
                        ),
                        const SizedBox(height: 6),
                        ExcludeSemantics(child: Text(c.isEmpty ? 'All items' : c, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11, c == _category ? 700 : 500, color: c == _category ? const Color(0xFFB45309) : kMuted))),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
      Expanded(
        child: _items.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: StateCard(icon: LucideIcons.search, title: tr('No items found'), body: tr('Try another name or System Code, or pick another category.'), primary: tr('Open search'), onPrimary: _openSearch),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(4, 0, 12, 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 196),
                itemCount: _items.length,
                itemBuilder: (_, i) => ProductCard(
                    item: _items[i],
                    facts: _facts[_items[i].id],
                    inCart: cart.lines.where((l) => l.menuItemId == _items[i].id).firstOrNull?.qty ?? 0,
                    why: _why(_items[i]),
                    onAdd: () => _add(_items[i]),
                    onLess: () => _less(_items[i])),
              ),
      ),
    ]);
  }

  /// The way into cart management (founder, 27 Oct 2026): a small wallet. The green card is this cart (its items and worth); the warm
  /// cards peeking behind it are the carts on hold. One tap opens all of them.
  Widget _walletBar(int units) {
    final onHold = env.carts.carts.length - 1 + _heldBills;
    final worth = _quote?.total ?? cart.estimate;
    final peeks = onHold.clamp(0, 2);
    return Semantics(
      button: true,
      label: 'Open carts, ${cart.label} active, $onHold on hold',
      child: GestureDetector(
        key: const ValueKey('cart-wallet-bar'),
        onTap: _openCarts,
        child: Padding(
          padding: EdgeInsets.only(top: peeks * 6.0),
          child: Stack(clipBehavior: Clip.none, children: [
            // the held carts' edges, peeking above the green card
            for (var i = peeks; i >= 1; i--)
              Positioned(
                top: -6.0 * i,
                left: 14.0 * i,
                right: 14.0 * i,
                height: 30,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(colors: i == 1 ? const [Color(0xFFC2410C), Color(0xFFF97316)] : const [Color(0xFFB91C1C), Color(0xFFEF4444)]),
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF14532D), Color(0xFF2F8F4E)]),
                boxShadow: const [BoxShadow(color: Color(0x332F8F4E), blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), shape: BoxShape.circle),
                  child: Badge(
                    isLabelVisible: units > 0,
                    label: Text('$units'),
                    backgroundColor: kLime,
                    textColor: kInk,
                    alignment: const AlignmentDirectional(0.9, -0.9),
                    child: const Center(child: Icon(LucideIcons.shoppingCart, size: 19, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text([tr('Current Cart'), cart.label, if (units > 0) rupees(worth)].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600, color: Colors.white70)),
                    Text(
                      cart.customerPhone.isEmpty
                          ? tr(cart.customerSkipped ? 'Walk-in · add number' : 'Add customer number')
                          : [if (cart.customerName.isNotEmpty) cart.customerName, showMobile(cart.customerPhone)].join(' · '),
                      key: const ValueKey('cart-wallet-customer'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: inter(15, 800, color: cart.customerPhone.isEmpty ? kLime : Colors.white),
                    ),
                  ]),
                ),
                IconButton(
                  key: const ValueKey('cart-wallet-edit-customer'),
                  tooltip: tr(cart.customerPhone.isEmpty ? 'Add customer' : 'Change customer'),
                  onPressed: _editCustomer,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.18)),
                  icon: Icon(cart.customerPhone.isEmpty ? LucideIcons.userPlus : LucideIcons.userPen, size: 17, color: Colors.white),
                ),
                const SizedBox(width: 6),
                if (onHold > 0)
                  Container(
                    key: const ValueKey('cart-wallet-held'),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFF97316), borderRadius: BorderRadius.circular(99)),
                    child: Text('$onHold ${tr('on hold')}', style: inter(11.5, 800, color: Colors.white)),
                  ),
                const SizedBox(width: 6),
                const Icon(LucideIcons.chevronsUp, size: 18, color: Colors.white),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cartBar(int units) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(26)), boxShadow: [BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, -2))]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _walletBar(units),
          if (_savings.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 28,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final (name, off) in _savings)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    constraints: const BoxConstraints(maxWidth: 220),
                    decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(999)),
                    child: Text('$name: ${rupees(off)} off MRP', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 700, color: kGreenText)),
                  ),
              ]),
            ),
          ],
          const Divider(height: 18, color: kLine),
          Row(children: [
            Expanded(
              flex: 3,
              child: DarkCta(label: 'PAY', labelStart: true, amount: cart.isEmpty || (_quote?.total ?? _lastTotal) == null ? null : rupees(_quote?.total ?? _lastTotal!), onPressed: cart.isEmpty ? null : _pay),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 1, child: LightCta(label: tr('Hold'), onPressed: cart.isEmpty || _busy ? null : _hold)),
          ]),
        ]),
      );
}

/// A till shortcut under the search (Open carts, History, Returns, Invoices, Cash shift): what the old ☰ "Sell" sheet held.
class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: Colors.white,
          shape: const StadiumBorder(side: BorderSide(color: Color(0xFFE3E5DF))),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 16, color: kInk),
                const SizedBox(width: 6),
                Text(label, style: inter(13, 600)),
              ]),
            ),
          ),
        ),
      );
}

/// One product card (Figma "439 Sell" / "444 Discount"): SKU chip, picture, name, the MRP struck through when the price is lower, the
/// price, a lime ADD, and whether it is in stock. An item that is not on sale cannot be added. One with no stock still can (founder,
/// 29 Oct 2026, negative stock): it is greyed and says so, the sale goes through, and its stock goes below zero until goods come in.
/// A product on the till (founder, 27 Oct 2026): the whole card is the button (no ADD). In the cart it turns green, with a gradient
/// border, the count in its corner and a small − to take one back. [why] tags a related product ("Bought together", "Popular").
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.item, required this.onAdd, this.onLess, this.inCart = 0, this.facts, this.why});
  final SellItem item;
  final VoidCallback onAdd;
  final VoidCallback? onLess;
  final int inCart;
  final SellFacts? facts;
  final String? why;

  /// Not on sale: the only thing that stops a tap.
  bool get _off => !item.available;

  bool get _known => facts?.stockKnown == true;

  /// What stays on the shelf once this bill is paid: the stock less what is already in the cart (it can go below zero).
  num get _left => (facts?.stockQty ?? 0) - inCart;

  /// No stock to sell before this bill: greyed, but it still sells.
  bool get _out => !_off && facts?.outOfStock == true;

  static String _n(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// The stock line under the price, counting the cart as it fills (founder, 29 Oct 2026: show it going negative).
  String _stockLine(bool low, bool picked) {
    if (_off) return tr('Not on sale');
    if (_known && _left < 0) return '${tr('Stock')} ${_n(_left)}${picked ? ' ${tr('after this bill')}' : ' · ${tr('still sells')}'}';
    if (_out) return tr('No stock · still sells');
    if (_known && picked && _left == 0) return tr('Stock 0 after this bill');
    if (low) return 'Low stock${_known ? ' · ${_n(_left)} left' : ''}';
    return picked ? tr('In cart · tap to add one more') : tr('Tap to add');
  }

  void _tap(BuildContext context) {
    if (_off) return showToast(context, '${item.name} is not on sale.');
    // the first one of an item with no stock: say what happens, then sell it anyway
    if (_out && inCart == 0) showToast(context, '${item.name} has no stock. It is billed anyway; stock goes below zero until you restock.');
    onAdd();
  }

  static const _gradient = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF8BE800), Color(0xFF2F8F4E)]);

  @override
  Widget build(BuildContext context) {
    final mrp = facts?.mrp;
    final low = !_out && facts?.lowInventory == true;
    final below = _known && _left < 0;
    final picked = inCart > 0;
    return Semantics(
      button: true,
      enabled: !_off,
      label: 'Add ${item.name}${picked ? ', $inCart in cart' : ''}',
      child: Container(
        key: ValueKey('product-${item.id}'),
        // the border: a green gradient when it is in the cart
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: picked ? _gradient : null,
          color: picked ? null : const Color(0xFFECEDE8),
          borderRadius: BorderRadius.circular(20),
          boxShadow: picked ? const [BoxShadow(color: Color(0x332F8F4E), blurRadius: 10, offset: Offset(0, 3))] : null,
        ),
        child: Material(
          color: picked ? const Color(0xFFF4FDE9) : (_out || _off) ? const Color(0xFFF1F2EE) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _tap(context),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Stack(clipBehavior: Clip.none, children: [
                  Container(
                    height: 76,
                    width: double.infinity,
                    decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(14)),
                    clipBehavior: Clip.antiAlias,
                    // no stock: the picture greys out
                    child: Opacity(
                      opacity: (_out || _off) && !picked ? 0.45 : 1,
                      child: ColorFiltered(
                        colorFilter: (_out || _off) && !picked
                            ? const ColorFilter.matrix([0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0, 0, 0, 1, 0])
                            : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                        child: item.imageUrl == null
                            ? const Icon(LucideIcons.package, size: 30, color: kKicker)
                            : Image.network(item.imageUrl!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(LucideIcons.package, size: 30, color: kKicker)),
                      ),
                    ),
                  ),
                  if (item.sku.isNotEmpty)
                    Positioned(left: 6, top: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)), child: Text(item.sku, style: inter(10.5, 700, color: kMuted)))),
                  if (why != null && !picked)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFF2F8F4E), borderRadius: BorderRadius.circular(8)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(LucideIcons.sparkles, size: 10, color: Colors.white),
                          const SizedBox(width: 3),
                          Text(tr(why!), style: inter(10, 700, color: Colors.white)),
                        ]),
                      ),
                    ),
                  // how many are in the cart, in the corner
                  if (picked)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        key: ValueKey('product-count-${item.id}'),
                        constraints: const BoxConstraints(minWidth: 28),
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(gradient: _gradient, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white, width: 2)),
                        child: Text('$inCart', style: inter(13, 800, color: Colors.white)),
                      ),
                    ),
                ]),
                const SizedBox(height: 6),
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13, 600, height: 1.2)),
                const Spacer(),
                Row(children: [
                  // MRP and price stay together; on a narrow card they shrink a little rather than lose the price
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                        if (mrp != null && mrp > item.price) ...[
                          Text(rupees(mrp), style: inter(12.5, 600, color: kKicker).copyWith(decoration: TextDecoration.lineThrough, decorationColor: kKicker)),
                          const SizedBox(width: 5),
                        ],
                        Text(rupees(item.price), style: inter(15, 800)),
                      ]),
                    ),
                  ),
                  if (picked && onLess != null)
                    Semantics(
                      button: true,
                      label: 'One less ${item.name}',
                      child: InkWell(
                        key: ValueKey('product-less-${item.id}'),
                        customBorder: const CircleBorder(),
                        onTap: onLess,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF8BE800), width: 1.5)),
                          child: const Icon(LucideIcons.minus, size: 15, color: Color(0xFF2F8F4E)),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(
                  _stockLine(low, picked),
                  key: ValueKey('product-stock-${item.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: inter(11.5, below ? 700 : 600, color: _off || _out || below ? kBadText : low ? kWarnText : picked ? const Color(0xFF2F8F4E) : kMuted),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
