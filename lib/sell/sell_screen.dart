import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'carts_screen.dart';
import '../shift/shift_api.dart';
import '../shift/shift_screens.dart';
import 'pay_screen.dart';
import 'search_screen.dart';
import 'sell_api.dart';
import 'sell_carts.dart';
import 'sell_env.dart';
import 'sell_widgets.dart';

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

  /// All Items / In Stock / Fast Moving / Low Inventory.
  String _tab = 'all';
  Quote? _quote;
  int _seq = 0, _quoteSeq = 0;
  bool _busy = false;
  ShiftState? _shift; // the store's cash drawer (S5.1); null until read, or when it could not be read

  @override
  void initState() {
    super.initState();
    env.carts.addListener(_cartChanged);
    _load();
    _loadFacts();
    _loadShift();
    _requote();
  }

  Future<void> _loadFacts() async {
    final f = await env.sell.facts();
    if (mounted) setState(() => _facts = f);
  }

  @override
  void dispose() {
    env.carts.removeListener(_cartChanged);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _cartChanged() {
    if (mounted) setState(() {});
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
      setState(() => _quote = null);
      return;
    }
    final mine = ++_quoteSeq;
    try {
      final q = await env.orders.quote(cart.lines, coupon: cart.couponCode);
      if (mounted && mine == _quoteSeq) setState(() => _quote = q);
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

  void _add(SellItem item) {
    cart.add(item);
    env.carts.changed();
    _quote = null;
    _requote();
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(env: env, onAdd: (i) => _add(i))));
    if (mounted) _requote();
  }

  Future<void> _pay() async {
    if (cart.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PayScreen(env: env, cart: cart)));
    if (mounted) {
      setState(() {});
      _requote();
      _loadFacts(); // a sale changes the stock counts
    }
  }

  Future<void> _hold() async {
    if (cart.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await env.orders.hold(lines: cart.lines, key: OrdersApi.newKey(), customerName: cart.customerName, customerPhone: cart.customerPhone, couponCode: cart.couponCode);
      env.carts.finish(cart);
      if (mounted) showToast(context, 'Bill held. Find it under Open carts.');
      _quote = null;
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<SellItem> get _items {
    final all = _catalog?.items ?? const <SellItem>[];
    final inCategory = _category.isEmpty ? all : all.where((i) => i.category == _category).toList();
    SellFacts? f(SellItem i) => _facts[i.id];
    return switch (_tab) {
      'stock' => [for (final i in inCategory) if (i.available && f(i)?.outOfStock != true) i],
      // most sold per day first; only items that sold recently
      'fast' => [for (final i in inCategory) if (f(i)?.perDay != null) i]..sort((a, b) => f(b)!.perDay!.compareTo(f(a)!.perDay!)),
      'low' => [for (final i in inCategory) if (f(i)?.lowInventory == true) i],
      _ => inCategory,
    };
  }

  /// The tabs the data supports: stock tabs need the stock counts, Fast Moving and Low Inventory need the stock list.
  List<(String, String, IconData?)> get _tabs {
    final stock = _facts.values.any((f) => f.stockKnown);
    final status = _facts.values.any((f) => f.status != null);
    return [
      ('all', 'All Items', null),
      if (stock) ('stock', 'In Stock', null),
      if (status) ('fast', 'Fast Moving', LucideIcons.star),
      if (status) ('low', 'Low Inventory', LucideIcons.clock),
    ];
  }

  Widget _tabRow() {
    final tabs = _tabs;
    if (tabs.length < 2) return const SizedBox.shrink();
    return SizedBox(
      height: 38,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          for (final (id, label, icon) in tabs)
            Semantics(
              button: true,
              selected: id == _tab,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _tab = id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(width: 2, color: id == _tab ? kInk : Colors.transparent))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, size: 14, color: id == _tab ? kInk : kMuted), const SizedBox(width: 5)],
                    Text(label, style: inter(13.5, id == _tab ? 700 : 500, color: id == _tab ? kInk : kMuted)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
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
        SellTopBar(
          title: 'Bill',
          initials: env.initials,
          action: Semantics(
            button: true,
            label: 'Items',
            excludeSemantics: true,
            child: IconButton(tooltip: 'Search or scan items', onPressed: _openSearch, icon: const Icon(LucideIcons.scanLine, size: 22, color: kInk)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SellSearchField(
            controller: _search,
            hint: 'Scan bar code or type EAN/SKU…',
            leading: LucideIcons.scanBarcode,
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
        const SizedBox(height: 4),
        _tabRow(),
        const SizedBox(height: 6),
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
                Text('Open shift', style: inter(13.5, 800, color: s.mustOpen ? kWarnText : kGreenText)),
              ]),
            ),
          ),
        ),
      );

  Widget _body() {
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(12), child: StateCard(icon: LucideIcons.database, danger: true, title: 'Items could not load', body: _error!, primary: 'Retry', onPrimary: _load));
    }
    final catalog = _catalog;
    if (catalog == null) return const Center(child: CircularProgressIndicator(color: kGreenText));
    final cats = ['', ...catalog.categories];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 72,
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
      Expanded(
        child: _items.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: _tab == 'all'
                    ? StateCard(icon: LucideIcons.search, title: 'No items found', body: 'Try another name or SKU, or pick another category.', primary: 'Open search', onPrimary: _openSearch)
                    : StateCard(
                        icon: LucideIcons.package,
                        title: switch (_tab) { 'stock' => 'Nothing in stock here', 'fast' => 'No recent sales yet', _ => 'Nothing is running low' },
                        body: switch (_tab) {
                          'fast' => 'Items show here once they sell. The most sold come first.',
                          'low' => 'Items at or under their reorder level show here.',
                          _ => 'Every item in this view is out of stock.',
                        },
                        primary: 'Show all items',
                        onPrimary: () => setState(() => _tab = 'all')),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(4, 0, 12, 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 196),
                itemCount: _items.length,
                itemBuilder: (_, i) => ProductCard(
                    item: _items[i], facts: _facts[_items[i].id], inCart: cart.lines.where((l) => l.menuItemId == _items[i].id).firstOrNull?.qty ?? 0, onAdd: () => _add(_items[i])),
              ),
      ),
    ]);
  }

  Widget _cartBar(int units) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(26)), boxShadow: [BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, -2))]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartsScreen(env: env))),
            child: Row(children: [
              Text('Current Cart', style: inter(15, 700)),
              if (env.carts.carts.length > 1) ...[const SizedBox(width: 8), TagChip('${env.carts.carts.length} open')],
              const Spacer(),
              Badge(
                isLabelVisible: units > 0,
                label: Text('$units'),
                backgroundColor: kChipGreen,
                textColor: kGreenText,
                child: const Icon(LucideIcons.shoppingCart, size: 22, color: kGreenText),
              ),
            ]),
          ),
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
              child: DarkCta(label: _quote == null ? 'PAY' : 'PAY ${rupees(_quote!.total)}', onPressed: cart.isEmpty ? null : _pay),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 1, child: LightCta(label: 'Hold', onPressed: cart.isEmpty || _busy ? null : _hold)),
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
/// price, a lime ADD, and whether it is in stock. An item that is not on sale, or that stock says is out, cannot be added.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.item, required this.onAdd, this.inCart = 0, this.facts});
  final SellItem item;
  final VoidCallback onAdd;
  final int inCart;
  final SellFacts? facts;

  bool get _out => !item.available || facts?.outOfStock == true;

  @override
  Widget build(BuildContext context) {
    final mrp = facts?.mrp;
    final low = !_out && facts?.lowInventory == true;
    final canAdd = !_out;
    return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFECEDE8))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            Container(
              height: 76,
              width: double.infinity,
              decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: item.imageUrl == null
                  ? const Icon(LucideIcons.package, size: 30, color: kKicker)
                  : Image.network(item.imageUrl!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(LucideIcons.package, size: 30, color: kKicker)),
            ),
            if (item.sku.isNotEmpty)
              Positioned(left: 6, top: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)), child: Text(item.sku, style: inter(10.5, 700, color: kMuted)))),
            if (inCart > 0)
              Positioned(right: 6, top: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: kDark, borderRadius: BorderRadius.circular(8)), child: Text('×$inCart', style: inter(10.5, 700, color: kLime)))),
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
            const SizedBox(width: 6),
            Semantics(
              button: true,
              enabled: canAdd,
              label: 'Add ${item.name}',
              child: Material(
                color: canAdd ? const Color(0xFF8BE800) : const Color(0xFFEEF0EB),
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: canAdd ? onAdd : null,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), child: ExcludeSemantics(child: Text('ADD', style: inter(12.5, 800, color: canAdd ? kInk : kKicker)))),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            _out ? 'Out of Stock' : low ? 'Low stock${facts?.stockKnown == true ? ' · ${facts!.stockQty} left' : ''}' : 'Available',
            style: inter(11.5, 600, color: _out ? kBadText : low ? kWarnText : kMuted),
          ),
        ]),
      );
  }
}
