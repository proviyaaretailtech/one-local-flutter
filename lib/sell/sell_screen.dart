import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../ui/theme.dart';
import 'carts_screen.dart';
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
  Quote? _quote;
  int _seq = 0, _quoteSeq = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    env.carts.addListener(_cartChanged);
    _load();
    _requote();
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
    return _category.isEmpty ? all : all.where((i) => i.category == _category).toList();
  }

  @override
  Widget build(BuildContext context) {
    final units = cart.units;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(
          title: 'OneLocal',
          initials: env.initials,
          onMenu: () => env.menu(context),
          action: Material(
            color: kDark,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: _openSearch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(LucideIcons.camera, size: 16, color: kLime),
                  const SizedBox(width: 8),
                  Text('Items', style: inter(14, 600, color: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
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
        Expanded(child: _body()),
        _cartBar(units),
        PosBottomNav(active: 'bill', onTap: (id) => env.tab(context, id)),
      ]),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(12), child: StateCard(icon: LucideIcons.database, danger: true, title: 'Items could not load', body: _error!, primary: 'Retry', onPrimary: _load));
    }
    final catalog = _catalog;
    if (catalog == null) return const Center(child: CircularProgressIndicator(color: kGreenText));
    final cats = ['', ...catalog.categories];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 84,
        child: ListView(children: [
          for (final c in cats)
            Semantics(
              button: true,
              selected: c == _category,
              label: c.isEmpty ? 'All items' : c,
              child: InkWell(
                onTap: () => setState(() => _category = c),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: c == _category ? const Color(0xFFFFF4E0) : null, border: Border(left: BorderSide(width: 3, color: c == _category ? const Color(0xFFF59E0B) : Colors.transparent))),
                  child: Column(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: kLine)),
                      child: Icon(c.isEmpty ? LucideIcons.layoutGrid : LucideIcons.tag, size: 20, color: c == _category ? const Color(0xFFD97706) : kMuted),
                    ),
                    const SizedBox(height: 6),
                    ExcludeSemantics(child: Text(c.isEmpty ? 'All items' : c, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, c == _category ? 700 : 500, color: c == _category ? const Color(0xFFB45309) : kMuted))),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      Expanded(
        child: _items.isEmpty
            ? Padding(padding: const EdgeInsets.all(12), child: StateCard(icon: LucideIcons.search, title: 'No items found', body: 'Try another name or SKU, or pick another category.', primary: 'Open search', onPrimary: _openSearch))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(4, 0, 12, 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 196),
                itemCount: _items.length,
                itemBuilder: (_, i) => ProductCard(item: _items[i], inCart: cart.lines.where((l) => l.menuItemId == _items[i].id).firstOrNull?.qty ?? 0, onAdd: () => _add(_items[i])),
              ),
      ),
    ]);
  }

  Widget _cartBar(int units) => Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(26)), boxShadow: [BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, -2))]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartsScreen(env: env))),
            child: Row(children: [
              Text('Current Cart', style: inter(18, 700)),
              if (env.carts.carts.length > 1) ...[const SizedBox(width: 8), TagChip('${env.carts.carts.length} open')],
              const Spacer(),
              Badge(
                isLabelVisible: units > 0,
                label: Text('$units'),
                backgroundColor: kChipGreen,
                textColor: kGreenText,
                child: const Icon(LucideIcons.shoppingCart, size: 26, color: kGreenText),
              ),
            ]),
          ),
          const Divider(height: 22, color: kLine),
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

/// One product card (Figma): SKU chip, picture, name, price and a lime ADD; an unavailable item says so and cannot be added.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.item, required this.onAdd, this.inCart = 0});
  final SellItem item;
  final VoidCallback onAdd;
  final int inCart;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFECEDE8))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            Container(
              height: 84,
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
          Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(13.5, 600, height: 1.2)),
          const Spacer(),
          if (!item.available) Text('Out of stock', style: inter(11.5, 600, color: kBadText)),
          Row(children: [
            Text(rupees(item.price), style: inter(17, 800)),
            const Spacer(),
            Semantics(
              button: true,
              enabled: item.available,
              label: 'Add ${item.name}',
              child: Material(
                color: item.available ? const Color(0xFF8BE800) : const Color(0xFFEEF0EB),
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: item.available ? onAdd : null,
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7), child: ExcludeSemantics(child: Text('ADD', style: inter(12.5, 800, color: item.available ? kInk : kKicker)))),
                ),
              ),
            ),
          ]),
        ]),
      );
}
