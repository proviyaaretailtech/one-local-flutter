import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../catalogue/catalogue_api.dart';
import '../catalogue/item_form_screen.dart';
import '../catalogue/item_sheets.dart' show parsePriceMinor;
import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'stock_env.dart';
import 'stock_kit.dart';
import 'stock_movements_screen.dart' show movementLabel, showMovement;
import 'update_stock_screen.dart' show UpdateStockScreenTones;
import '../ui/i18n.dart';

/// One product, everything about it on one page (founder, 25 Oct 2026; replaces the catalogue detail drawer and the stock page):
/// photo, name, codes and the Store / App switches; prices with the margin rules; its stock; its last movements; and small buttons
/// for every job on it. Opened with the catalogue record ([item]) or with the stock item id ([inventoryId]); each finds the other.
class ProductPage extends StatefulWidget {
  const ProductPage({super.key, required this.env, this.inventoryId, this.item});
  final StockEnv env;
  final String? inventoryId;
  final CatItem? item;
  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> {
  StockEnv get env => widget.env;
  CatItem? _cat; // the catalogue record (price, codes, photo, Store switch); null for a stock item that is not sold
  String? _invId; // the stock item (stock card, movements, the buttons)
  Facts? _stock;
  List<Facts>? _moves;
  bool? _app; // shown on the OneLocal app; null when it cannot be read
  bool _loading = true, _savingPrices = false, _switching = false;
  String? _error;
  String? _key; // one save of prices, kept for a retry
  final _price = TextEditingController(), _mrp = TextEditingController(), _cost = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cat = widget.item;
    _invId = widget.inventoryId ?? _invOf(widget.item);
    _fill();
    _load();
  }

  @override
  void dispose() {
    _price.dispose();
    _mrp.dispose();
    _cost.dispose();
    super.dispose();
  }

  static String? _invOf(CatItem? c) {
    final v = (c?.raw['inventory_item_id'] ?? '').toString();
    return v.isEmpty ? null : v;
  }

  static String _rs(int? minor) => minor == null ? '' : (minor % 100 == 0 ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2));

  void _fill() {
    final c = _cat;
    _price.text = c == null ? '' : _rs(c.priceMinor);
    _mrp.text = _rs(c?.mrpMinor);
    _cost.text = _rs(c?.costMinor);
  }

  String _problem(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // a stock item opened on its own: its catalogue record comes from its System Code
      if (_cat == null && _invId != null) {
        _stock = await env.api.stockDetail(_invId!);
        final sku = _stock!.m('item').s('sku');
        if (sku.isNotEmpty) {
          try {
            _cat = await env.catalogue.lookup(sku);
            _fill();
          } catch (_) {
            // not sold in the shop: the page shows its stock only
          }
        }
      } else if (_invId != null) {
        _stock = await env.api.stockDetail(_invId!);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _problem(e, 'Could not load this product. Pull down to try again.'));
    }
    if (_invId != null) {
      try {
        _moves = await env.api.movements(itemId: _invId, limit: 5);
      } catch (_) {
        _moves = const [];
      }
    }
    await _loadApp();
    if (mounted) setState(() => _loading = false);
  }

  /// The OneLocal app switch, read from the storefront's product list (50 at a time). Unreadable: the switch is greyed.
  Future<void> _loadApp() async {
    final c = _cat;
    if (c == null) return;
    try {
      for (var offset = 0; offset < 1000; offset += 50) {
        final rows = Facts(await env.rpc.callMap('sf_products', {'limit': 50, 'offset': offset})).l('items');
        for (final p in rows) {
          if (p.s('id') == c.id) {
            _app = p.b('visible');
            return;
          }
        }
        if (rows.length < 50) break;
      }
      _app = false;
    } catch (_) {
      _app = null;
    }
  }

  // ---------------------------------------------------------------- switches (save at once)
  Future<void> _setStore(bool on) async {
    final c = _cat!;
    setState(() => _switching = true);
    try {
      await env.rpc.call('rst_menu_stock_set', {'id': c.id, 'in_stock': on});
      _cat = CatItem({...c.raw, 'available': on});
      if (mounted) showToast(context, on ? '${c.name} is on sale in the store.' : '${c.name} is off sale in the store.');
    } catch (e) {
      if (mounted) showToast(context, _problem(e, 'The store switch was not saved.'));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _setApp(bool on) async {
    final c = _cat!;
    setState(() => _switching = true);
    try {
      await env.rpc.call('sf_product_save', {'id': c.id, 'visible': on});
      _app = on;
      if (mounted) showToast(context, on ? '${c.name} is shown on the OneLocal app.' : '${c.name} is hidden from the OneLocal app.');
    } catch (e) {
      if (mounted) showToast(context, _problem(e, 'The app switch was not saved.'));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  // ---------------------------------------------------------------- prices
  int? _minor(TextEditingController c) => c.text.trim().isEmpty ? null : parsePriceMinor(c.text);

  bool get _pricesChanged {
    final c = _cat;
    if (c == null) return false;
    return _minor(_price) != c.priceMinor || _minor(_mrp) != c.mrpMinor || _minor(_cost) != c.costMinor;
  }

  Future<void> _savePrices() async {
    final c = _cat!;
    final price = _minor(_price), mrp = _minor(_mrp), cost = _minor(_cost);
    if (price == null) return showToast(context, 'Enter a selling price.');
    for (final t in [_mrp, _cost]) {
      if (t.text.trim().isNotEmpty && parsePriceMinor(t.text) == null) return showToast(context, 'Check the amounts.');
    }
    if (mrp != null && price > mrp) return showToast(context, 'The price is above the MRP. Lower the price or raise the MRP.');
    setState(() => _savingPrices = true);
    _key ??= CatalogueApi.newKey();
    try {
      final saved = await env.catalogue.save({
        'mode': 'quick',
        'version': c.version,
        if (price != c.priceMinor) 'price_minor': price,
        if (mrp != c.mrpMinor) 'mrp_minor': mrp,
        if (cost != c.costMinor) 'cost_minor': cost,
      }, id: c.id, key: _key);
      _key = null;
      _cat = CatItem({...c.raw, ...saved.raw});
      _fill();
      if (mounted) showToast(context, 'Prices saved.');
    } catch (e) {
      if (mounted) showToast(context, _problem(e, 'The prices were not saved.'));
    } finally {
      if (mounted) setState(() => _savingPrices = false);
    }
  }

  Future<void> _editDetails() async {
    final c = _cat;
    if (c == null) return;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ItemFormScreen(api: env.catalogue, item: c)));
    if (saved != true || !mounted) return;
    try {
      _cat = await env.catalogue.lookup(c.sku);
      _fill();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final c = _cat;
    final s = _stock;
    final name = c?.name ?? s?.m('item').s('name') ?? 'Product';
    return StockScaffold(
      env: env,
      title: name,
      line: _codeLine(),
      onRefresh: _load,
      children: [
        if (_loading && c == null && s == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (_error != null && c == null && s == null)
          StockEmpty(tr('This product could not load'), _error!, icon: LucideIcons.cloudOff, action: tr('Try again'), onAction: _load)
        else ...[
          _header(),
          const SizedBox(height: 12),
          if (c != null) _priceCard(c) else InvNote(tr('Not sold in the shop, so it has no price here.')),
          const SizedBox(height: 2),
          if (_invId == null) InvNote(tr('No stock record yet: stock, movements and the stock buttons appear once it has one.')) else ...[
            _stockCard(),
            _movesCard(),
          ],
          const SizedBox(height: 4),
          _buttons(),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  String? _codeLine() {
    final c = _cat;
    final item = _stock?.m('item');
    final sku = c?.sku ?? item?.s('sku') ?? '';
    final unit = c?.sellingUnit ?? item?.s('unit') ?? '';
    final parts = [if (sku.isNotEmpty) 'System Code: $sku', if (unit.isNotEmpty) unit];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _photo() {
    final name = _cat?.name ?? _stock?.m('item').s('name') ?? '';
    const tints = [Color(0xFFE3F1FC), Color(0xFFFDF0DC), Color(0xFFFBF3D0), Color(0xFFFCE9E7), Color(0xFFE9F2FB), Color(0xFFFFF7D6)];
    final tint = tints[(name.isEmpty ? 0 : name.codeUnitAt(0)) % tints.length];
    final url = _cat?.imageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        key: const ValueKey('product-photo'),
        aspectRatio: 1.8,
        child: Container(
          color: tint,
          child: url != null && url.isNotEmpty
              ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(LucideIcons.package, size: 40, color: kMuted))
              : const Icon(LucideIcons.package, size: 40, color: kMuted),
        ),
      ),
    );
  }

  Widget _header() {
    final c = _cat;
    final barcode = c?.barcode ?? _stock?.m('item').so('barcode');
    final category = (c?.category.isNotEmpty ?? false) ? c!.category : (_stock?.m('item').s('category') ?? '');
    return InvCard(
      margin: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _photo(),
        const SizedBox(height: 10),
        StockRow(tr('Barcode'), barcode == null || barcode.isEmpty ? 'None' : barcode),
        StockRow(tr('Category'), category.isEmpty ? '—' : category),
        if (c != null) ...[
          const Divider(height: 18, color: kCardLine),
          _switchRow('Store', 'Sold in your till', c.available, 'product-store',
              c.status == 'draft' || _switching ? null : _setStore),
          _switchRow('App', _app == null ? 'Could not read the OneLocal app setting' : 'Shown on the OneLocal app', _app ?? false, 'product-app',
              _app == null || _switching ? null : _setApp),
          if (c.status == 'draft') Text(tr('A draft is not sold. Finish it with Edit details first.'), style: inter(12, 400, color: kMuted)),
        ],
      ]),
    );
  }

  Widget _switchRow(String label, String line, bool on, String key, ValueChanged<bool>? onChanged) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: inter(14.5, 700, color: onChanged == null ? kMuted : kInk)),
            Text(line, style: inter(12, 400, color: kMuted)),
          ]),
        ),
        Switch(
          key: ValueKey(key),
          value: on,
          onChanged: onChanged,
          activeThumbColor: kNavyH,
          activeTrackColor: kLimeH,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: const Color(0xFFE1E3DD),
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ]);

  Widget _priceCard(CatItem c) {
    final price = _minor(_price), mrp = _minor(_mrp), cost = _minor(_cost);
    final tone = UpdateStockScreenTones.tone(price, mrp);
    final m = UpdateStockScreenTones.margin(price, cost);
    final low = m != null && m.pct < 5;
    String rupees(int minor) => (minor < 0 ? '−₹' : '₹') + _rs(minor.abs());
    return InvCard(
      margin: const EdgeInsets.only(top: 12, bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Price'), style: inter(15.5, 700)),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _money('MRP ₹', _mrp, 'product-mrp'),
          const SizedBox(width: 10),
          _money('Price ₹', _price, 'product-price', tone: tone),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _money('Cost ₹', _cost, 'product-cost'),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InvLabel(tr('Margin')),
              Container(
                key: const ValueKey('product-margin'),
                height: 46,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: m == null ? kGreyBg : (low ? kRedBgH : const Color(0xFFEBFAE0)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: m == null ? kCardLine : (low ? kRedText : kPostedText)),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(m == null ? 'Enter price and cost' : '${rupees(m.amount)} · ${m.pct.toStringAsFixed(1)}%',
                      style: inter(m == null ? 12.5 : 15, 800, color: m == null ? kMuted : (low ? kRedText : kPostedText))),
                ),
              ),
              if (low) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('Below 5%'), style: inter(11.5, 600, color: kRedText))),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        InvPrimary(tr('Save prices'), key: const ValueKey('product-save-prices'), busy: _savingPrices, onPressed: _pricesChanged && !_savingPrices ? _savePrices : null),
      ]),
    );
  }

  Widget _money(String label, TextEditingController c, String key, {(Color, Color, String)? tone}) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InvLabel(label),
          SizedBox(
            height: 46,
            child: TextField(
              key: ValueKey(key),
              controller: c,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: inter(15, tone == null ? 400 : 700, color: tone?.$2 ?? kInk),
              decoration: InputDecoration(
                hintText: '—',
                filled: true,
                fillColor: tone?.$1 ?? Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: tone?.$2 ?? const Color(0xFFD9DBD5), width: tone == null ? 1 : 1.6)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: tone?.$2 ?? kInk, width: 1.8)),
              ),
            ),
          ),
          if (tone != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(tone.$3, key: ValueKey('$key-note'), style: inter(11.5, 600, color: tone.$2))),
        ]),
      );

  Widget _stockCard() {
    final d = _stock;
    if (d == null) return InvNote(tr('Stock could not load. Pull down to try again.'));
    final unit = d.m('item').s('unit');
    String u(num v) => units(v, unit.isEmpty ? 'unit' : unit);
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text(tr('Stock'), style: inter(15.5, 700))), StockStatusChip(d.s('status'))]),
        const SizedBox(height: 10),
        StockNumbers([StockNumber(qty(d.n('available')), 'In stock', color: kPostedText), StockNumber(qty(d.n('reserved')), 'On hold')]),
        const SizedBox(height: 10),
        StockNumbers([
          StockNumber(qty(d.n('in_transit')), 'Incoming', color: d.n('in_transit') > 0 ? kAmberText : null),
          StockNumber(qty(d.n('damaged')), 'Damaged', color: d.n('damaged') > 0 ? kRedText : null),
        ]),
        const SizedBox(height: 8),
        StockRow(tr('Sells per day'), d.n('daily_demand') == 0 ? 'No recent sales' : u(d.n('daily_demand'))),
        StockRow(tr('Lasts about'), d.no('stock_days') == null ? '—' : '${qty(d.n('stock_days'))} days'),
        StockRow(tr('Kept at'), d.l('bins').isEmpty ? '—' : d.l('bins').map((b) => '${b.s('name')} (${qty(b.n('on_hand'))})').join(', ')),
      ]),
    );
  }

  Widget _movesCard() {
    final moves = _moves;
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(tr('Last movements'), style: inter(15.5, 700))),
          TextButton(
            key: const ValueKey('product-moves-all'),
            onPressed: () => env.open(context, StockPage.movements, itemId: _invId),
            child: Text(tr('See all'), style: inter(13.5, 700, color: kLink)),
          ),
        ]),
        if (moves == null)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
        else if (moves.isEmpty)
          Text(tr('No movements yet. Sales, deliveries and corrections show here.'), style: inter(13, 400, color: kMuted))
        else
          for (final m in moves)
            InkWell(
              onTap: () => showMovement(context, env, m.n('id').toInt()),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(movementLabel(m.s('kind')), style: inter(14, 600)),
                      Text(
                        [if (m.m('ref').s('label').isNotEmpty) m.m('ref').s('label'), if (m.t('created_at') != null) stamp(m.t('created_at')!)].join(' · '),
                        style: inter(12, 400, color: kMuted),
                      ),
                    ]),
                  ),
                  Text(signed(m.no('delta') ?? m.n('quantity')), style: inter(15, 800, color: (m.no('delta') ?? m.n('quantity')) < 0 ? kRedText : kPostedText)),
                ]),
              ),
            ),
      ]),
    );
  }

  Widget _buttons() {
    final inv = _invId;
    Widget b(String label, IconData icon, String key, VoidCallback? onTap) => Material(
          color: Colors.white,
          shape: StadiumBorder(side: BorderSide(color: onTap == null ? kCardLine : const Color(0xFFD9DBD5))),
          child: InkWell(
            key: ValueKey(key),
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: onTap == null ? kMuted : kInk),
                const SizedBox(width: 6),
                Text(label, style: inter(13, 600, color: onTap == null ? kMuted : kInk)),
              ]),
            ),
          ),
        );
    VoidCallback? go(String page) => inv == null ? null : () => env.open(context, page, itemId: inv);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      b('Adjust', LucideIcons.slidersHorizontal, 'product-adjust', go(StockPage.adjust)),
      b('Transfer', LucideIcons.arrowLeftRight, 'product-transfer', go(StockPage.transfer)),
      b('Buy again', LucideIcons.shoppingCart, 'product-reorder', go(StockPage.reorder)),
      b('Print label', LucideIcons.tag, 'product-label', go(StockPage.productLabels)),
      b('Edit details', LucideIcons.pencil, 'product-edit', _cat == null ? null : _editDetails),
    ]);
  }
}
