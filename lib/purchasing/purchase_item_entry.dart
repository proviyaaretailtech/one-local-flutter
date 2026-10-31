import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../barcodes/barcode_sheets.dart' show itemLabel, printBarcodeLabels;
import '../barcodes/barcode_ui.dart' show LabelCountStepper;
import '../barcodes/barcodes_api.dart';
import '../catalogue/price_basis.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart' show kCardLine, kPostedText;
import '../inventory/receiving_screen.dart' show newItemForReceiving;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'purchasing_api.dart';
import 'purchasing_widgets.dart' show money;
import 'simple_purchase.dart' show PurchaseThumb, gstRates, scanForPurchase;

// Purchase entry (founder, 30 Oct 2026): every purchase adds the right quantity to stock and records the supplier, rate and invoice.
//   Search bar (scan, name, SKU or barcode) → the store's own item (its permanent SKU is reused, never a new one for a new supplier or rate)
//   or, only when nothing matches, a new store item made right here → quantity and rate → the line → review → confirm → stock.
// A product without a barcode is not a new product: the search shows what the store already has before "Create new item".
// The maker's barcode, the store SKU and a store code (200…) stay separate; a store code never goes into the master library.

/// Tests replace the barcode calls made for a new item.
BarcodesApi Function() purchaseBarcodes = () => BarcodesApi();

const _measured = {'kg', 'g', 'l', 'ml'};

String _rupees(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
num? _num(String s) => num.tryParse(s.trim().replaceAll(',', ''));
String _paise(num rupees) => money((rupees * 100).round());

/// How an item of the purchase search is bought and counted.
extension PurchaseItemFacts on Facts {
  /// The unit its stock is counted in: kg / g / l / ml for loose goods, else pc, pack, box…
  String get buyUnit {
    final u = s('selling_unit').isNotEmpty ? s('selling_unit') : s('unit');
    return u.isEmpty ? 'pc' : u;
  }

  /// Sold by weight or volume: the quantity may have decimals (12.5 kg).
  bool get byMeasure => _measured.contains(buyUnit);

  /// A code the store made or typed (200…), not the maker's barcode on the pack.
  bool get storeCode => const {'generated', 'custom'}.contains(s('barcode_source'));

  /// "SKU AMB500 · Maker's barcode 8901…" — the item's identity, each code named for what it is.
  String get codeLine => [
        if (s('sku').isNotEmpty) '${tr('SKU')} ${s('sku')}',
        if (s('barcode').isNotEmpty) '${tr(storeCode ? 'Store code' : 'Maker’s barcode')} ${s('barcode')}',
        if (s('plu').isNotEmpty) 'PLU ${s('plu')}',
      ].join(' · ');
}

/// A quantity as typed: 12, 12.5, 8.25, 1.125 (up to grams in a kg).
String qtyText(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

/// "kg", "pcs".
String buyUnitWord(String unit, [num qty = 2]) => switch (unit) { 'pc' => qty == 1 ? 'pc' : 'pcs', '' => 'pcs', _ => unit };

/// The search bar on Add purchase / Received (founder, 31 Oct 2026: no separate Add item screen): type a name, SKU or barcode, or scan,
/// and the store's whole catalogue drops down under it. Only when nothing matches does it offer a new store item (made here, without
/// leaving the purchase). A scanned code that matches an item goes straight to [onPick]; one that matches nothing offers a new item
/// with that code as its maker's barcode.
class PurchaseItemSearch extends StatefulWidget {
  const PurchaseItemSearch({super.key, required this.api, required this.onPick, this.onPurchase = const {}});
  final PurchasingApi api;

  /// The item found (or just made), as [PurchasingApi.findItems] describes it.
  final void Function(Facts item) onPick;

  /// Items already on this purchase, marked in the list.
  final Set<String> onPurchase;

  @override
  State<PurchaseItemSearch> createState() => _PurchaseItemSearchState();
}

class _PurchaseItemSearchState extends State<PurchaseItemSearch> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  String? _code; // the scanned code being shown
  List<Facts> _items = const [];
  bool _loading = false, _creating = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    ++_seq;
    _q.clear();
    setState(() {
      _items = const [];
      _error = null;
      _loading = false;
      _code = null;
    });
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return _clear();
    final mine = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.findItems(q);
      if (!mounted || mine != _seq) return;
      // a scan that names one item exactly: it is that item, straight to its quantity
      final hit = _code == null ? null : r.where((i) => i.s('barcode') == _code || i.s('sku').toLowerCase() == _code!.toLowerCase()).firstOrNull;
      if (hit != null) return _pick(hit);
      setState(() => _items = r);
    } catch (e) {
      if (mounted && mine == _seq) {
        setState(() {
          _items = const [];
          _error = e is PartnerApiException ? e.message : tr('Could not load the items. Check your connection and try again.');
        });
      }
    } finally {
      if (mounted && mine == _seq) setState(() => _loading = false);
    }
  }

  void _pick(Facts item) {
    _clear();
    _focus.unfocus();
    widget.onPick(item);
  }

  Future<void> _scan() async {
    final code = (await scanForPurchase(context))?.trim();
    if (code == null || code.isEmpty || !mounted) return;
    _q.text = code;
    _code = code;
    await _search(code);
  }

  /// Looks like a barcode (scanned, or digits only, 8 or more): a new item made from it keeps it as the maker's barcode, not as its name.
  bool get _typedCode => _code != null || RegExp(r'^\d{8,}$').hasMatch(_q.text.trim());

  /// A new store item, made here: the product form with the name (or the maker's barcode) filled in. The database gives it its own
  /// permanent SKU and refuses a barcode or SKU another item has. Loose goods get a PLU for weigh labels; only an item with no barcode
  /// is offered a store code (and its label).
  Future<void> _create() async {
    if (_creating) return;
    final text = _q.text.trim();
    setState(() => _creating = true);
    try {
      final made = await newItemForReceiving(context, name: _typedCode ? null : text, barcode: _typedCode ? text : null);
      if (made == null || !mounted) return;
      var item = made;
      final menuId = item.s('menu_item_id');
      if (menuId.isNotEmpty && item.byMeasure && item.buyUnit == 'kg') {
        try {
          final bc = await purchaseBarcodes().setLoose(menuId, true);
          item = Facts({...item.raw, 'plu': bc.plu});
        } catch (_) {} // the PLU can be given later from Barcodes
      }
      if (!mounted) return;
      if (menuId.isNotEmpty && item.s('barcode').isEmpty) item = await offerStoreCode(context, item, justSaved: true);
      if (mounted) _pick(item);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _row(Facts h) {
    final on = widget.onPurchase.contains(h.s('id'));
    return Material(
      color: Colors.white,
      child: InkWell(
        key: ValueKey('pick-${h.s('id')}'),
        onTap: () => _pick(h),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            PurchaseThumb(url: h.s('image_url'), name: h.s('name')),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(h.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
                if (h.codeLine.isNotEmpty) Text(h.codeLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11.5, 500, color: kMuted)),
                Text(
                  [if (on) tr('On this purchase'), if (h.s('barcode').isEmpty) tr('No barcode: make one after picking'), h.byMeasure ? '${tr('Bought by')} ${h.buyUnit}' : '${tr('Counted in')} ${buyUnitWord(h.buyUnit)}'].join(' · '),
                  style: inter(11.5, 600, color: on ? kPostedText : kMuted),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Text(
              h.no('mrp_minor') == null ? tr('No MRP') : '${tr('MRP')} ${money(h.n('mrp_minor'))}',
              key: ValueKey('pick-mrp-${h.s('id')}'),
              style: inter(13, h.no('mrp_minor') == null ? 500 : 700, color: h.no('mrp_minor') == null ? kMuted : kInk),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim();
    final createLabel = _typedCode
        ? '${tr('Create new item with barcode')} $q'
        : _items.isEmpty
            ? '${tr('Create new item')} “$q”'
            : tr('Not in the list? Create new item');
    final showNone = q.isNotEmpty && !_loading && _error == null && _items.isEmpty;
    final showCreate = q.length >= 2 && !_loading && _error == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('recv-find'),
        controller: _q,
        focusNode: _focus,
        onChanged: (v) {
          _code = null;
          _search(v);
        },
        style: inter(15, 600),
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('Search or scan an item'),
          hintStyle: inter(14.5, 500, color: kMuted),
          prefixIcon: const Icon(LucideIcons.search, size: 19),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (q.isNotEmpty) IconButton(key: const ValueKey('recv-find-clear'), onPressed: _clear, icon: const Icon(LucideIcons.x, size: 18, color: kMuted)),
            IconButton(key: const ValueKey('recv-scan'), onPressed: _scan, tooltip: tr('Scan a barcode'), icon: const Icon(LucideIcons.scanLine, size: 21, color: kInk)),
          ]),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kCardLine)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kCardLine)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kPostedText, width: 1.5)),
        ),
      ),
      if (_loading) const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: LinearProgressIndicator(minHeight: 2)),
      if (_error != null || showNone || _items.isNotEmpty || showCreate)
        Container(
          key: const ValueKey('recv-dropdown'),
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kCardLine),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 6))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_error != null) ...[
              Padding(key: const ValueKey('pick-error'), padding: const EdgeInsets.fromLTRB(14, 14, 14, 0), child: Text(_error!, style: inter(13.5, 600, color: const Color(0xFFC62828)))),
              TextButton(key: const ValueKey('pick-retry'), onPressed: () => _search(_q.text), child: Text(tr('Try again'), style: inter(14, 700, color: kLink))),
            ],
            if (showNone)
              Padding(
                key: const ValueKey('pick-none'),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                child: Text(
                  _typedCode
                      ? '${tr('No item in your store has barcode')} $q. ${tr('If you have it under another name, search the name and pick it.')}'
                      : '${tr('No item matches')} “$q”.',
                  style: inter(13.5, 500, height: 1.4),
                ),
              ),
            for (final (i, h) in _items.indexed) ...[if (i > 0) const Divider(height: 1, color: kCardLine), _row(h)],
            if (showCreate) ...[
              if (_items.isNotEmpty) const Divider(height: 1, color: kCardLine),
              Material(
                color: const Color(0xFFF7F8F4),
                child: InkWell(
                  key: const ValueKey('pick-create'),
                  onTap: _creating ? null : _create,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    child: Row(children: [
                      const Icon(LucideIcons.packagePlus, size: 18, color: kLink),
                      const SizedBox(width: 10),
                      Expanded(child: Text(createLabel, style: inter(14, 700, color: kLink))),
                    ]),
                  ),
                ),
              ),
            ],
          ]),
        ),
    ]);
  }
}

/// "Make a barcode?" for an item with none (a new item just saved, or one the store already has): a 200… code from the store's own
/// series (never a GTIN, never in the master library), optionally with its label printed. Answers the item with its new code.
Future<Facts> offerStoreCode(BuildContext context, Facts item, {bool justSaved = false}) async {
  if (item.s('menu_item_id').isEmpty) return item; // a stock-only item: it has no catalogue item to carry a code
  // how many labels to print with it (founder, 31 Oct 2026: not just one); null = not now
  final labels = await showModalBottomSheet<int>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (c) {
      var n = 1;
      return StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(key: const ValueKey('newbc-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(justSaved ? '${item.s('name')} ${tr('is saved')}' : '${tr('Make a barcode for')} ${item.s('name')}', style: inter(18, 800)),
              const SizedBox(height: 4),
              Text('${tr('SKU')} ${item.s('sku')}. ${tr('It has no barcode. A store barcode lets it scan at the Bill and in purchases. It is for this store only.')}',
                  style: inter(13, 500, color: kMuted, height: 1.4)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                decoration: BoxDecoration(color: const Color(0xFFF7F8F4), borderRadius: BorderRadius.circular(14), border: Border.all(color: kCardLine)),
                child: LabelCountStepper(
                  keyPrefix: 'newbc-labels',
                  value: n,
                  hint: n == 0 ? 'No label: print it later from Barcodes.' : 'Printed as soon as the barcode is made.',
                  onChanged: (v) => set(() => n = v),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('newbc-make'),
                onPressed: () => Navigator.pop(c, n),
                icon: Icon(n == 0 ? LucideIcons.barcode : LucideIcons.printer, size: 18),
                label: Text(n == 0 ? tr('Make barcode') : '${tr('Make barcode')} · ${tr('print')} $n ${tr(n == 1 ? 'label' : 'labels')}', style: inter(15, 700, color: Colors.white)),
                style: FilledButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              TextButton(
                key: const ValueKey('newbc-skip'),
                onPressed: () => Navigator.pop(c),
                child: Text(tr('Not now'), style: inter(14.5, 700, color: kMuted)),
              ),
            ]),
          ),
        ),
      );
    },
  );
  if (labels == null || !context.mounted) return item;
  try {
    final bc = await purchaseBarcodes().make(item.s('menu_item_id'));
    if (labels > 0) {
      try {
        await printBarcodeLabels([(itemLabel(bc), labels)]);
      } catch (_) {
        if (context.mounted) showToast(context, tr('The barcode is made. Print its label from Barcodes.'));
      }
    }
    return Facts({...item.raw, 'barcode': bc.barcode, 'barcode_source': bc.barcodeSource ?? 'generated'});
  } catch (e) {
    if (context.mounted) showToast(context, e is PartnerApiException ? e.message : tr(justSaved ? 'The item is saved, but the barcode could not be made. Make it from Barcodes.' : 'The barcode could not be made. Try again, or make it from Barcodes.'));
    return item;
  }
}

/// What the purchase line sheet answers: the quantity in the item's unit and the money of the line, in rupees.
/// [item] is the item as it is now (with its new barcode, when one was made here).
typedef PurchaseLineInput = ({num qty, num rate, num mrp, num disc, num gst, Facts item});

/// Quantity and purchase rate for one item, before it goes on the purchase: the unit it is counted in (kg for loose goods), rate per
/// unit, MRP, discount, GST, the line total, and the last rate it was bought at. [already] is how much of it is on the purchase.
Future<PurchaseLineInput?> showPurchaseLineSheet(BuildContext context, Facts item, {num already = 0}) => showModalBottomSheet<PurchaseLineInput>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _LineSheet(item: item, already: already),
    );

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.item, required this.already});
  final Facts item;
  final num already;
  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late Facts _item = widget.item;
  Facts get i => _item;

  Future<void> _makeCode() async {
    final made = await offerStoreCode(context, _item);
    if (mounted) setState(() => _item = made);
  }
  late final _qty = TextEditingController();
  late final _rate = TextEditingController(text: i.no('cost_minor') == null ? '' : _rupees(i.n('cost_minor') / 100));
  /// MRP-based: the printed MRP. Store-based: the store's own selling price, which stands in for the MRP.
  late PriceBasis _basis = priceBasisOf(i.raw['price_basis'], unit: i.buyUnit);
  late final _mrp = TextEditingController(text: _mrpFor(_basis));

  String _mrpFor(PriceBasis b) {
    final v = b == PriceBasis.store ? (i.no('price_minor') ?? i.no('mrp_minor')) : (i.no('mrp_minor') ?? i.no('price_minor'));
    return v == null ? '' : _rupees(v / 100);
  }

  void _setBasis(PriceBasis b) => setState(() {
        _basis = b;
        _mrp.text = _mrpFor(b);
        _error = null;
      });
  final _disc = TextEditingController();
  late num _gst = gstRates.contains(i.no('gst_pct')) ? i.n('gst_pct') : 0;
  String? _error;

  @override
  void dispose() {
    for (final c in [_qty, _rate, _mrp, _disc]) {
      c.dispose();
    }
    super.dispose();
  }

  num get _total {
    final gross = (_num(_qty.text) ?? 0) * (_num(_rate.text) ?? 0);
    final taxable = gross - gross * (_num(_disc.text) ?? 0) / 100;
    return taxable + taxable * _gst / 100;
  }

  void _add() {
    final q = _num(_qty.text) ?? 0, mrp = _num(_mrp.text) ?? 0, disc = _num(_disc.text) ?? 0, rate = _num(_rate.text);
    final problem = q <= 0
        ? 'Enter the quantity that came.'
        : !i.byMeasure && q != q.roundToDouble()
            ? 'This item is counted in ${buyUnitWord(i.buyUnit)}: enter a whole number.'
            : rate == null
                ? 'Enter the purchase rate.'
                : mrp <= 0
                    ? (_basis == PriceBasis.store ? 'Enter your selling price per ${buyUnitWord(i.buyUnit, 1)}.' : 'Enter the MRP. Stock goes up only with it.')
                    : disc < 0 || disc > 100
                        ? 'The discount is 0 to 100%.'
                        : null;
    if (problem != null) return setState(() => _error = problem);
    Navigator.pop(context, (qty: q, rate: rate!, mrp: mrp, disc: disc, gst: _gst, item: Facts({..._item.raw, 'price_basis': _basis.name})));
  }

  Widget _field(TextEditingController c, String label, {Key? key, String? prefix, String? suffix, bool autofocus = false, bool decimals = true}) => Expanded(
        child: TextField(
          key: key,
          controller: c,
          autofocus: autofocus,
          keyboardType: TextInputType.numberWithOptions(decimal: decimals),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimals ? r'^\d*\.?\d{0,3}' : r'\d*'))],
          onChanged: (_) => setState(() => _error = null),
          style: inter(16, 700),
          decoration: InputDecoration(
            isDense: true,
            labelText: tr(label),
            prefixText: prefix,
            suffixText: suffix,
            labelStyle: inter(12.5, 500, color: kMuted),
            filled: true,
            fillColor: const Color(0xFFF7F8F4),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final unit = i.buyUnit;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(key: const ValueKey('line-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            PurchaseThumb(url: i.s('image_url'), name: i.s('name')),
            const SizedBox(width: 10),
            Expanded(child: Text(i.s('name'), style: inter(17, 800))),
          ]),
          if (i.codeLine.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(i.codeLine, key: const ValueKey('line-codes'), style: inter(12, 500, color: kMuted))),
          // no barcode on the pack (loose or local goods): make the store's own code right here
          if (i.s('barcode').isEmpty && i.s('menu_item_id').isNotEmpty) MakeCodeLink(key: const ValueKey('line-make-code'), onTap: _makeCode),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                i.byMeasure ? '${tr('Stock in')} $unit' : '${tr('Counted in')} ${buyUnitWord(unit)}',
                if (i.no('cost_minor') != null) '${tr('Last bought at')} ${money(i.n('cost_minor'))}/${buyUnitWord(unit, 1)}',
                if (widget.already > 0) '${qtyText(widget.already)} ${buyUnitWord(unit, widget.already)} ${tr('already on this purchase')}',
              ].join(' · '),
              key: const ValueKey('line-facts'),
              style: inter(12, 600, color: kPostedText),
            ),
          ),
          const SizedBox(height: 12),
          PriceBasisPicker(key: const ValueKey('line-basis'), keyPrefix: 'line-basis', value: _basis, onChanged: _setBasis, compact: true),
          const SizedBox(height: 10),
          Row(children: [
            _field(_qty, widget.already > 0 ? 'Add quantity' : 'Quantity', key: const ValueKey('line-qty'), suffix: buyUnitWord(unit), autofocus: true, decimals: i.byMeasure),
            const SizedBox(width: 8),
            _field(_rate, 'Rate per ${buyUnitWord(unit, 1)}', key: const ValueKey('line-rate'), prefix: '₹ '),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _field(_mrp, _basis == PriceBasis.store ? 'Selling price per ${buyUnitWord(unit, 1)}' : 'MRP', key: const ValueKey('line-mrp'), prefix: '₹ '),
            const SizedBox(width: 8),
            _field(_disc, 'Disc %', key: const ValueKey('line-disc')),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<num>(
                key: const ValueKey('line-gst'),
                initialValue: _gst,
                isDense: true,
                isExpanded: true,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: tr('GST'),
                  filled: true,
                  fillColor: const Color(0xFFF7F8F4),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kCardLine)),
                ),
                items: [for (final g in gstRates) DropdownMenuItem(value: g, child: Text('${_rupees(g)}%', style: inter(14, 600)))],
                onChanged: (v) => setState(() => _gst = v ?? 0),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(tr('Line total'), style: inter(14, 600, color: kMuted))),
            Text(_paise(_total), key: const ValueKey('line-total'), style: inter(18, 800)),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr(_error!), key: const ValueKey('line-error'), style: inter(13, 600, color: const Color(0xFFC62828)))),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('line-add'),
            onPressed: _add,
            style: FilledButton.styleFrom(backgroundColor: kPrimary, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text(tr('Add to purchase'), style: inter(15.5, 700, color: Colors.white)),
          ),
        ]),
      ),
    );
  }
}

/// "No barcode · Make barcode": on an item without any barcode.
class MakeCodeLink extends StatelessWidget {
  const MakeCodeLink({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(8)),
            child: Text(tr('No barcode'), style: inter(11.5, 700, color: const Color(0xFFB45309))),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(LucideIcons.barcode, size: 15, color: kLink),
                const SizedBox(width: 5),
                Text(tr('Make barcode'), style: inter(13, 700, color: kLink)),
              ]),
            ),
          ),
        ]),
      );
}
