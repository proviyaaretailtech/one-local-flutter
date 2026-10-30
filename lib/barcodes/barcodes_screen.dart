import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../orders/orders_api.dart' show rupees;
import '../stock/label_pdf.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'barcode_sheets.dart';
import 'barcode_ui.dart';
import 'barcodes_api.dart';

// Side menu → Barcodes (founder's mock-ups, 30 Oct 2026, both sets):
//   home → Create (single item or bulk) · All codes · Loose items · Custom barcode
//   single: select product → its code is made → details
//   bulk:   tick items (search, category) → review → generating (ring) → results → print labels (copies per item)
//   details → print label (Standard / Large, copies, preview); loose items → weigh & print
//   custom: type or make a code → save on an item, or preview → print
//   link an unknown code: pick the product → "Code linked!"
// Every code is this store's own (Master Architecture §2): never a GTIN, never added to the master library.

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

Future<T?> _push<T>(BuildContext context, Widget page) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
Future<T?> _swap<T>(BuildContext context, Widget page) => Navigator.of(context).pushReplacement<T, Object?>(MaterialPageRoute(builder: (_) => page));

InputDecoration _field(String hint, {Widget? prefixIcon, Widget? suffix, String? prefix}) => InputDecoration(
      hintText: hint,
      prefixIcon: prefixIcon,
      prefixText: prefix,
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kBcBorder)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    );

Widget _search(TextEditingController c, String hint, VoidCallback onChanged, {Key? key}) =>
    TextField(key: key, controller: c, decoration: _field(tr(hint), prefixIcon: const Icon(LucideIcons.search, size: 18)), onChanged: (_) => onChanged());

/// 18 · No results: a search that found nothing.
class BcEmpty extends StatelessWidget {
  const BcEmpty({super.key, this.title = 'No results found', this.line = 'Try a different search or check if the item has a barcode.'});
  final String title, line;
  @override
  Widget build(BuildContext context) => Padding(
        key: const ValueKey('bc-empty'),
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kBcBorder)), child: const Icon(LucideIcons.scanBarcode, size: 30, color: kMuted)),
          const SizedBox(height: 14),
          Text(tr(title), style: inter(16, 800)),
          const SizedBox(height: 4),
          Text(tr(line), textAlign: TextAlign.center, style: inter(13, 500, color: kMuted, height: 1.4)),
        ]),
      );
}

/// A row with a label above a value (the details card).
Widget _fact(String label, Widget value) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr(label), style: inter(11.5, 600, color: kMuted)), const SizedBox(height: 2), value]),
    );

Widget _itemHead(BcItem i) => BcCard(
      child: Row(children: [
        BcThumb(i.imageUrl, size: 56),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.name, style: inter(16, 800)), Text(priceLine(i, rupees), style: inter(12.5, 500, color: kMuted))])),
      ]),
    );

/// A copies stepper (−  n  +).
class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged, this.keyPrefix = 'copies'});
  final int value;
  final ValueChanged<int> onChanged;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => Container(
        height: 48,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBcBorder)),
        child: Row(children: [
          IconButton(key: ValueKey('$keyPrefix-less'), onPressed: value > 1 ? () => onChanged(value - 1) : null, icon: const Icon(LucideIcons.minus, size: 16)),
          Expanded(child: Center(child: Text('$value', key: ValueKey('$keyPrefix-value'), style: inter(16, 800)))),
          IconButton(key: ValueKey('$keyPrefix-more'), onPressed: value < 200 ? () => onChanged(value + 1) : null, icon: const Icon(LucideIcons.plus, size: 16)),
        ]),
      );
}

// ---------------------------------------------------------------- 1. home

class BarcodesScreen extends StatelessWidget {
  const BarcodesScreen({super.key, this.api, this.store = ''});
  final BarcodesApi? api;
  final String store;
  static Route<void> route({BarcodesApi? api, String store = ''}) => MaterialPageRoute(builder: (_) => BarcodesScreen(api: api, store: store));

  @override
  Widget build(BuildContext context) {
    final a = api ?? BarcodesApi();
    Widget tile(String key, IconData icon, String title, String line, Widget Function() page) => BcCard(
          key: ValueKey(key),
          onTap: () => _push<void>(context, page()),
          child: SizedBox(
            height: 92,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 22, color: kInk),
              const Spacer(),
              Text(tr(title), style: inter(14, 800)),
              Text(tr(line), maxLines: 2, style: inter(11.5, 500, color: kMuted, height: 1.3)),
            ]),
          ),
        );
    return BcPage(
      title: 'Barcodes',
      subtitle: 'Create, manage and print product barcodes for your store.',
      children: [
        BcCard(
          key: const ValueKey('bc-home-create'),
          color: kBcMint,
          border: const Color(0xFFD6EBC4),
          onTap: () => _push<void>(context, CreateTypeScreen(api: a, store: store)),
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
          child: Column(children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: kBcBorder)),
                child: const Icon(LucideIcons.scanBarcode, size: 40, color: kInk),
              ),
              Positioned(
                right: -8,
                bottom: -8,
                child: Container(width: 28, height: 28, decoration: const BoxDecoration(color: kBcDeep, shape: BoxShape.circle), child: const Icon(LucideIcons.plus, size: 16, color: Colors.white)),
              ),
            ]),
            const SizedBox(height: 18),
            Text(tr('Create Barcode'), style: inter(18, 800)),
            const SizedBox(height: 4),
            Text(tr('Single or bulk generation and printing.'), textAlign: TextAlign.center, style: inter(12.5, 500, color: kMuted)),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: tile('bc-home-all', LucideIcons.box, 'All Codes', 'View & manage existing codes', () => AllCodesScreen(api: a, store: store))),
          const SizedBox(width: 12),
          Expanded(child: tile('bc-home-loose', LucideIcons.scale, 'Loose Items', 'Weigh & print labels', () => AllCodesScreen(api: a, store: store, looseOnly: true))),
        ]),
        const SizedBox(height: 12),
        tile('bc-home-custom', LucideIcons.tag, 'Custom Barcode', 'Create or link a code', () => CustomBarcodeScreen(api: a, store: store)),
      ],
    );
  }
}

// ---------------------------------------------------------------- 2. create: choose type

class CreateTypeScreen extends StatelessWidget {
  const CreateTypeScreen({super.key, required this.api, this.store = ''});
  final BarcodesApi api;
  final String store;

  Future<void> _single(BuildContext context) async {
    final item = await _push<BcItem>(context, SelectProductScreen(api: api, title: 'Select Product', tab: 'missing', cta: 'Generate barcode'));
    if (item == null || !context.mounted) return;
    try {
      final made = item.barcode == null ? await api.make(item.id) : item;
      if (context.mounted) await _push<void>(context, BarcodeDetailsScreen(api: api, item: made, store: store));
    } catch (e) {
      if (context.mounted) showToast(context, _err(e, 'Could not make the barcode. Try again.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget choice(String key, IconData icon, String title, String line, VoidCallback onTap, {bool lead = false}) => BcCard(
          key: ValueKey(key),
          color: lead ? kBcMint : Colors.white,
          border: lead ? const Color(0xFFD6EBC4) : null,
          onTap: onTap,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBcBorder)),
              child: Icon(icon, size: 26, color: kInk),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr(title), style: inter(14.5, 800)), const SizedBox(height: 2), Text(tr(line), style: inter(12, 500, color: kMuted, height: 1.35))])),
            const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
          ]),
        );
    return BcPage(
      title: 'Create Barcode',
      subtitle: 'How would you like to create the barcode?',
      children: [
        choice('create-single', LucideIcons.scanBarcode, 'Generate for a Single Item', 'Create a barcode for one product at a time.', () => _single(context)),
        const SizedBox(height: 12),
        choice('create-bulk', LucideIcons.boxes, 'Bulk Generate', 'Create barcodes for multiple items at once.', () => _push<void>(context, BulkSelectScreen(api: api, store: store)), lead: true),
      ],
    );
  }
}

// ---------------------------------------------------------------- 13. select product (single item, saving a code, linking)

/// Pick one of the store's items. [tab]: 'missing' lists the items without a code first, 'all' every item. Answers the item.
class SelectProductScreen extends StatefulWidget {
  const SelectProductScreen({super.key, required this.api, this.title = 'Select Product', this.tab = 'all', this.cta = 'Confirm', this.subtitle});
  final BarcodesApi api;
  final String title, tab, cta;
  final String? subtitle;
  @override
  State<SelectProductScreen> createState() => _SelectProductScreenState();
}

class _SelectProductScreenState extends State<SelectProductScreen> {
  final _q = TextEditingController();
  Timer? _wait;
  List<BcItem>? _items;
  BcItem? _picked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.list(tab: widget.tab, q: _q.text);
      if (mounted) setState(() => _items = r.items);
    } catch (e) {
      if (mounted) {
        setState(() => _items = const []);
        showToast(context, _err(e, 'Could not load your items.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _items;
    return BcPage(
      title: widget.title,
      subtitle: widget.subtitle,
      bottom: BcCta(key: const ValueKey('select-confirm'), label: widget.cta, onPressed: _picked == null ? null : () => Navigator.pop(context, _picked)),
      children: [
        _search(_q, 'Search product...', () {
          _wait?.cancel();
          _wait = Timer(const Duration(milliseconds: 300), _load);
        }, key: const ValueKey('select-search')),
        const SizedBox(height: 12),
        if (list == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (list != null && list.isEmpty)
          BcEmpty(line: widget.tab == 'missing' && _q.text.trim().isEmpty ? 'Every item already has a barcode.' : 'Try a different search or check if the item has a barcode.'),
        if (list != null && list.isNotEmpty)
          BcCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Column(children: [
              for (final (n, i) in list.indexed) ...[
                if (n > 0) const Divider(height: 1, color: kBcBorder),
                InkWell(
                  key: ValueKey('select-${i.id}'),
                  onTap: () => setState(() => _picked = i),
                  child: Container(
                    color: _picked?.id == i.id ? kBcMint : null,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: Row(children: [
                      BcThumb(i.imageUrl, size: 42),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(i.name, style: inter(14, 700)),
                          Text(tr(i.loose ? 'Sold loose' : 'Piece'), style: inter(12, 500, color: kMuted)),
                        ]),
                      ),
                      if (_picked?.id == i.id) const Icon(Icons.check_circle, size: 20, color: kBcDeep),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 3–6. bulk generate

class BulkSelectScreen extends StatefulWidget {
  const BulkSelectScreen({super.key, required this.api, this.store = ''});
  final BarcodesApi api;
  final String store;
  @override
  State<BulkSelectScreen> createState() => _BulkSelectScreenState();
}

class _BulkSelectScreenState extends State<BulkSelectScreen> {
  final _q = TextEditingController();
  List<BcItem>? _items;
  String _cat = '';
  final _picked = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.list(tab: 'missing').then((r) {
      if (mounted) setState(() => _items = r.items);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load your items.'));
    });
  }

  List<BcItem> get _shown {
    final q = _q.text.trim().toLowerCase();
    return (_items ?? const <BcItem>[]).where((i) => (_cat.isEmpty || i.category == _cat) && (q.isEmpty || i.name.toLowerCase().contains(q) || i.sku.toLowerCase().contains(q))).toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _items ?? const <BcItem>[];
    final cats = <String, int>{};
    for (final i in all) {
      if (i.category.isNotEmpty) cats[i.category] = (cats[i.category] ?? 0) + 1;
    }
    final shown = _shown, n = _picked.length;
    return BcPage(
      title: 'Bulk Generate',
      subtitle: 'Choose the items for which you want to generate barcodes.',
      bottom: Row(children: [
        Expanded(
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: kBcMint, borderRadius: BorderRadius.circular(16)),
            child: Text('$n ${n == 1 ? 'item' : 'items'} selected', key: const ValueKey('bulk-count'), style: inter(13.5, 700, color: kBcDeep)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: BcCta(
            key: const ValueKey('bulk-continue'),
            label: 'Generate ($n)',
            onPressed: n == 0 ? null : () => _push<void>(context, BulkReviewScreen(api: widget.api, items: all.where((i) => _picked.contains(i.id)).toList(), store: widget.store)),
          ),
        ),
      ]),
      children: [
        _search(_q, 'Search products...', () => setState(() {}), key: const ValueKey('bulk-search')),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in [('', 'All (${all.length})'), for (final c in cats.entries) (c.key, '${c.key} (${c.value})')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('bulk-cat-${id.isEmpty ? 'all' : id}'),
                  selected: _cat == id,
                  showCheckmark: false,
                  selectedColor: kBcDeep,
                  backgroundColor: Colors.white,
                  side: BorderSide(color: _cat == id ? kBcDeep : kBcBorder),
                  labelStyle: inter(12.5, 700, color: _cat == id ? Colors.white : kInk),
                  label: Text(label),
                  onSelected: (_) => setState(() => _cat = id),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        if (_error != null) Text(_error!, style: inter(13, 500, color: kError)),
        if (_items == null && _error == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (_items != null && shown.isEmpty)
          BcEmpty(title: all.isEmpty ? 'All set' : 'No results found', line: all.isEmpty ? 'Every item already has a barcode.' : 'Try a different search or category.'),
        if (shown.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('bulk-select-all'),
              onPressed: () => setState(() => shown.every((i) => _picked.contains(i.id)) ? _picked.removeAll(shown.map((i) => i.id)) : _picked.addAll(shown.map((i) => i.id))),
              child: Text(tr(shown.every((i) => _picked.contains(i.id)) ? 'Clear all' : 'Select all'), style: inter(13, 700, color: kBcDeep)),
            ),
          ),
          BcCard(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(children: [
              for (final (k, i) in shown.indexed) ...[
                if (k > 0) const Divider(height: 1, color: kBcBorder),
                CheckboxListTile(
                  key: ValueKey('bulk-pick-${i.id}'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  value: _picked.contains(i.id),
                  activeColor: kBcDeep,
                  onChanged: (v) => setState(() => v == true ? _picked.add(i.id) : _picked.remove(i.id)),
                  title: Text(i.name, style: inter(14, 700)),
                  subtitle: Text(priceLine(i, rupees), style: inter(12, 500, color: kMuted)),
                  secondary: BcThumb(i.imageUrl, size: 40),
                ),
              ],
            ]),
          ),
        ],
      ],
    );
  }
}

class BulkReviewScreen extends StatelessWidget {
  const BulkReviewScreen({super.key, required this.api, required this.items, this.store = ''});
  final BarcodesApi api;
  final List<BcItem> items;
  final String store;

  @override
  Widget build(BuildContext context) {
    final n = items.length;
    return BcPage(
      title: 'Review & Generate',
      subtitle: 'You are about to generate barcodes for $n ${n == 1 ? 'item' : 'items'}.',
      bottom: BcCta(key: const ValueKey('bulk-generate'), label: 'Generate', onPressed: () => _swap<void>(context, BulkProgressScreen(api: api, items: items, store: store))),
      children: [
        BcCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            for (final (k, i) in items.indexed) ...[
              if (k > 0) const Divider(height: 1, color: kBcBorder),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  BcThumb(i.imageUrl, size: 48),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.name, style: inter(14, 700)), Text(priceLine(i, rupees), style: inter(12, 500, color: kMuted))])),
                  unitTag(i),
                ]),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 14),
        BcCard(
          color: kBcMint,
          border: kBcMint,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(LucideIcons.shieldCheck, size: 20, color: kBcDeep),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr("Barcodes will be created using your store's code range (20-29)."), style: inter(13, 600, height: 1.35)),
                const SizedBox(height: 4),
                Text(tr('Each item will get a unique code.'), style: inter(12, 500, color: kMuted)),
              ]),
            ),
          ]),
        ),
      ],
    );
  }
}

class BulkProgressScreen extends StatefulWidget {
  const BulkProgressScreen({super.key, required this.api, required this.items, this.store = ''});
  final BarcodesApi api;
  final List<BcItem> items;
  final String store;
  @override
  State<BulkProgressScreen> createState() => _BulkProgressScreenState();
}

class _BulkProgressScreenState extends State<BulkProgressScreen> {
  late final _state = {for (final i in widget.items) i.id: 'pending'}; // pending / processing / done / failed
  final _made = <BcItem>[];
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  /// One item at a time, so each row shows it finishing; a failure is noted and the rest go on.
  Future<void> _run() async {
    for (final i in widget.items) {
      if (!mounted) return;
      setState(() => _state[i.id] = 'processing');
      try {
        _made.add(await widget.api.make(i.id));
        _state[i.id] = 'done';
      } catch (_) {
        _state[i.id] = 'failed';
      }
    }
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length, done = _state.values.where((s) => s == 'done' || s == 'failed').length;
    final failed = _state.values.where((s) => s == 'failed').length;
    return BcPage(
      title: _finished ? 'Barcodes generated' : 'Generating barcodes...',
      subtitle: _finished ? (failed == 0 ? 'Every item has its new code.' : '$failed could not be made; try them again from Bulk Generate.') : 'This may take a moment.',
      bottom: BcCta(
        key: const ValueKey('bulk-view-results'),
        label: 'View Results',
        onPressed: _finished ? () => _swap<void>(context, BulkResultsScreen(api: widget.api, made: _made, store: widget.store)) : null,
      ),
      children: [
        Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(child: CircularProgressIndicator(value: n == 0 ? 1 : done / n, strokeWidth: 8, color: kBcDeep, backgroundColor: kBcBorder)),
              Text('$done/$n', key: const ValueKey('bulk-progress'), style: inter(22, 800)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Text(tr('Items processed'), textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 18),
        BcCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            for (final i in widget.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  switch (_state[i.id]) {
                    'done' => const Icon(Icons.check_circle, size: 20, color: kBcDeep),
                    'failed' => const Icon(Icons.error, size: 20, color: kError),
                    'processing' => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kBcDeep)),
                    _ => const Icon(Icons.radio_button_unchecked, size: 20, color: Color(0xFFC4C8BF)),
                  },
                  const SizedBox(width: 12),
                  Expanded(child: Text(i.name, style: inter(13.5, 600))),
                  if (_state[i.id] == 'done') const Icon(LucideIcons.check, size: 14, color: kBcDeep),
                  const SizedBox(width: 4),
                  Text(
                    tr(switch (_state[i.id]) { 'done' => 'Done', 'failed' => 'Failed', 'processing' => 'Processing...', _ => 'Pending' }),
                    style: inter(12, 600, color: _state[i.id] == 'done' ? kBcDeep : _state[i.id] == 'failed' ? kError : kMuted),
                  ),
                ]),
              ),
          ]),
        ),
      ],
    );
  }
}

/// 6 · The codes just made, with their source; from here, print them all.
class BulkResultsScreen extends StatelessWidget {
  const BulkResultsScreen({super.key, required this.api, required this.made, this.store = ''});
  final BarcodesApi api;
  final List<BcItem> made;
  final String store;

  @override
  Widget build(BuildContext context) => BcPage(
        title: 'Barcode Results',
        subtitle: '${made.length} ${made.length == 1 ? 'item has' : 'items have'} new barcodes.',
        bottom: BcCta(
          key: const ValueKey('bulk-print'),
          label: 'Print Labels',
          icon: LucideIcons.printer,
          onPressed: made.isEmpty ? null : () => _push<void>(context, BulkPrintScreen(items: made, store: store)),
        ),
        children: [
          if (made.isEmpty) const BcEmpty(title: 'No codes made', line: 'Nothing was generated. Try again from Bulk Generate.'),
          if (made.isNotEmpty) _CodeList(items: made, onTap: (i) => _push<void>(context, BarcodeDetailsScreen(api: api, item: i, store: store))),
        ],
      );
}

/// Rows of items with their code, source and unit.
class _CodeList extends StatelessWidget {
  const _CodeList({required this.items, required this.onTap, this.loose = false});
  final List<BcItem> items;
  final ValueChanged<BcItem> onTap;
  final bool loose;
  @override
  Widget build(BuildContext context) => BcCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Column(children: [
          for (final (n, i) in items.indexed) ...[
            if (n > 0) const Divider(height: 1, color: kBcBorder),
            InkWell(
              key: ValueKey('code-${i.id}'),
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  BcThumb(i.imageUrl, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                      const SizedBox(height: 2),
                      Text(
                        loose ? 'PLU ${(i.plu ?? 0).toString().padLeft(5, '0')} · ${rupees(i.price)}/kg' : (i.barcode ?? tr('No barcode yet')),
                        style: inter(12, 500, color: i.barcode == null && !loose ? const Color(0xFFB45309) : kMuted),
                      ),
                      if (!loose) Text(i.loose ? '${rupees(i.price)}/kg · ${tr('loose')}' : tr('Piece'), style: inter(11.5, 500, color: kMuted)),
                    ]),
                  ),
                  if (loose) const BcTag('Weigh') else sourceTag(i),
                  const SizedBox(width: 6),
                  const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                ]),
              ),
            ),
          ],
        ]),
      );
}

// ---------------------------------------------------------------- 7. all codes (and loose items)

class AllCodesScreen extends StatefulWidget {
  const AllCodesScreen({super.key, required this.api, this.store = '', this.looseOnly = false});
  final BarcodesApi api;
  final String store;
  final bool looseOnly;
  @override
  State<AllCodesScreen> createState() => _AllCodesScreenState();
}

class _AllCodesScreenState extends State<AllCodesScreen> {
  final _q = TextEditingController();
  Timer? _wait;
  List<BcItem> _items = const [];
  String _filter = 'all';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await widget.api.list(tab: widget.looseOnly ? 'loose' : 'all', q: _q.text);
      if (mounted) setState(() => _items = r.items);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load the codes.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<BcItem> get _shown => switch (_filter) {
        'generated' || 'linked' || 'custom' => _items.where((i) => i.barcode != null && i.barcodeSource == _filter).toList(),
        'none' => _items.where((i) => i.barcode == null).toList(),
        _ => _items,
      };

  Future<void> _open(BcItem i) async {
    await _push<void>(context, widget.looseOnly ? WeighPrintScreen(api: widget.api, item: i, store: widget.store) : BarcodeDetailsScreen(api: widget.api, item: i, store: widget.store));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return BcPage(
      title: widget.looseOnly ? 'Loose Items' : 'All Codes',
      subtitle: widget.looseOnly ? 'Sold by weight. Tap one to weigh a pack and print its label.' : null,
      children: [
        _search(_q, 'Search by name, code or PLU', () {
          _wait?.cancel();
          _wait = Timer(const Duration(milliseconds: 300), _load);
        }, key: const ValueKey('codes-search')),
        if (!widget.looseOnly) ...[
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (id, label) in const [('all', 'All'), ('generated', 'Generated'), ('linked', 'Linked'), ('custom', 'Custom'), ('none', 'No barcode')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('codes-filter-$id'),
                    selected: _filter == id,
                    showCheckmark: false,
                    selectedColor: kBcDeep,
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _filter == id ? kBcDeep : kBcBorder),
                    labelStyle: inter(12.5, 700, color: _filter == id ? Colors.white : kInk),
                    label: Text(tr(label)),
                    onSelected: (_) => setState(() => _filter = id),
                  ),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (_error != null) Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))),
        if (!_loading && _error == null && shown.isEmpty)
          widget.looseOnly && _q.text.trim().isEmpty
              ? const BcEmpty(title: 'No loose items yet', line: 'Open an item in All Codes and turn on Sold loose.')
              : const BcEmpty(),
        if (shown.isNotEmpty) _CodeList(items: shown, loose: widget.looseOnly, onTap: _open),
      ],
    );
  }
}

// ---------------------------------------------------------------- 7/9. barcode details

class BarcodeDetailsScreen extends StatefulWidget {
  const BarcodeDetailsScreen({super.key, required this.api, required this.item, this.store = ''});
  final BarcodesApi api;
  final BcItem item;
  final String store;
  @override
  State<BarcodeDetailsScreen> createState() => _BarcodeDetailsScreenState();
}

class _BarcodeDetailsScreenState extends State<BarcodeDetailsScreen> {
  late BcItem _item = widget.item;
  bool _busy = false;

  Future<void> _run(Future<BcItem> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      final i = await f();
      if (!mounted) return;
      setState(() => _item = i);
      showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remake() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Make a new code?')),
        content: Text(tr('The old code stops working. Reprint the labels on the shelf after.')),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep it'))), FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Re-make')))],
      ),
    );
    if (ok == true && mounted) await _run(() => widget.api.make(_item.id, replace: true), 'New code made. Reprint the labels.');
  }

  Future<void> _loose(bool v) => _run(() => widget.api.setLoose(_item.id, v), v ? '${_item.name} is now sold loose, by weight.' : '${_item.name} is now sold by the piece.');

  Widget _action(String key, IconData icon, String label, VoidCallback onTap, {bool on = false}) => Expanded(
        child: BcCard(
          key: ValueKey(key),
          color: on ? kBcMint : Colors.white,
          onTap: _busy ? null : onTap,
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(children: [Icon(icon, size: 20, color: on ? kBcDeep : kInk), const SizedBox(height: 6), Text(tr(label), style: inter(12, 700, color: on ? kBcDeep : kInk))]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final i = _item;
    return BcPage(
      title: 'Barcode Details',
      bottom: i.barcode == null
          ? BcCta(key: const ValueKey('details-make'), label: 'Make barcode', busy: _busy, onPressed: () => _run(() => widget.api.make(i.id), 'Barcode made. Scans now find ${i.name}.'))
          : BcCta(key: const ValueKey('details-print-label'), label: 'Print label', icon: LucideIcons.printer, onPressed: () => _push<void>(context, PrintLabelScreen(item: i, store: widget.store))),
      children: [
        _itemHead(i),
        const SizedBox(height: 12),
        BcCard(
          color: const Color(0xFFF7F9F3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _fact(
              'Barcode',
              Row(children: [
                Expanded(child: Text(i.barcode ?? tr('No barcode yet'), key: const ValueKey('details-code'), style: inter(15, 800).copyWith(letterSpacing: 0.6))),
                if (i.barcode != null)
                  IconButton(
                    key: const ValueKey('details-copy'),
                    tooltip: tr('Copy'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(LucideIcons.copy, size: 18, color: kMuted),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: i.barcode!));
                      showToast(context, 'Code copied.');
                    },
                  ),
              ]),
            ),
            _fact('Source', Text(tr(sourceLabel(i)), style: inter(14, 700))),
            if (i.loose) _fact('PLU', Text((i.plu ?? 0).toString().padLeft(5, '0'), style: inter(14, 700))),
            _fact('Selling unit', Text(tr(i.loose ? 'kg (sold loose)' : 'piece / pack'), style: inter(14, 700))),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          if (i.barcode != null) ...[
            _action('details-print', LucideIcons.printer, 'Print', () => _push<void>(context, PrintLabelScreen(item: i, store: widget.store))),
            const SizedBox(width: 8),
            _action('details-remake', LucideIcons.refreshCw, 'Re-make', _remake),
            const SizedBox(width: 8),
          ],
          _action('details-loose', LucideIcons.scale, i.loose ? 'Sold loose: on' : 'Sold loose', () => _loose(!i.loose), on: i.loose),
        ]),
        if (i.loose) ...[
          const SizedBox(height: 10),
          BcOutline(key: const ValueKey('details-weigh'), label: 'Weigh & print label', icon: LucideIcons.scale, onPressed: () => _push<void>(context, WeighPrintScreen(api: widget.api, item: i, store: widget.store))),
        ],
        if (i.barcode != null) ...[
          const SizedBox(height: 16),
          Text(tr('Label preview'), style: inter(13, 700)),
          const SizedBox(height: 6),
          BcCard(child: Column(children: [
            BarcodeView(i.barcode!, height: 50),
            const SizedBox(height: 6),
            Text(i.name, style: inter(12.5, 600, color: kMuted)),
            Text(i.loose ? '${rupees(i.price)}/kg' : rupees(i.price), style: inter(16, 800)),
          ])),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- 16. print label (options) · 17. bulk print

/// One item's label: Standard (50 × 30 mm) or Large (3 × 2 in), how many copies, a preview, print.
class PrintLabelScreen extends StatefulWidget {
  const PrintLabelScreen({super.key, required this.item, this.store = ''});
  final BcItem item;
  final String store;
  @override
  State<PrintLabelScreen> createState() => _PrintLabelScreenState();
}

class _PrintLabelScreenState extends State<PrintLabelScreen> {
  bool _large = false;
  int _copies = 1;
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await printBarcodeLabels([(itemLabel(widget.item, store: widget.store), _copies)], size: _large ? LabelSize.medium : LabelSize.product);
      if (mounted) showToast(context, '$_copies ${_copies == 1 ? 'label' : 'labels'} sent to print.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    return BcPage(
      title: 'Print Label',
      bottom: BcCta(key: const ValueKey('print-label-go'), label: 'Print', icon: LucideIcons.printer, busy: _busy, onPressed: _print),
      children: [
        _itemHead(i),
        const SizedBox(height: 16),
        Text(tr('Label type'), style: inter(13, 700)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBcBorder)),
          child: Row(children: [
            for (final (large, label, line) in const [(false, 'Standard', '50 × 30 mm'), (true, 'Large', '3 × 2 in')])
              Expanded(
                child: Material(
                  color: _large == large ? kPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  child: InkWell(
                    key: ValueKey('print-type-${large ? 'large' : 'standard'}'),
                    borderRadius: BorderRadius.circular(11),
                    onTap: () => setState(() => _large = large),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Column(children: [
                        Text(tr(label), style: inter(13, 700, color: _large == large ? Colors.white : kInk)),
                        Text(line, style: inter(10.5, 500, color: _large == large ? Colors.white70 : kMuted)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        Text(tr('Copies'), style: inter(13, 700)),
        const SizedBox(height: 6),
        _Stepper(value: _copies, onChanged: (v) => setState(() => _copies = v)),
        const SizedBox(height: 16),
        Text(tr('Label preview'), style: inter(13, 700)),
        const SizedBox(height: 6),
        BcCard(child: Column(children: [
          if (i.barcode != null) BarcodeView(i.barcode!, height: _large ? 70 : 50),
          const SizedBox(height: 6),
          Text(i.name, style: inter(12.5, 600, color: kMuted)),
          Text(i.loose ? '${rupees(i.price)}/kg' : rupees(i.price), style: inter(16, 800)),
        ])),
      ],
    );
  }
}

/// 17 · Labels for several items at once, the same number of copies each.
class BulkPrintScreen extends StatefulWidget {
  const BulkPrintScreen({super.key, required this.items, this.store = ''});
  final List<BcItem> items;
  final String store;
  @override
  State<BulkPrintScreen> createState() => _BulkPrintScreenState();
}

class _BulkPrintScreenState extends State<BulkPrintScreen> {
  int _copies = 1;
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await printBarcodeLabels([for (final i in widget.items) (itemLabel(i, store: widget.store), _copies)]);
      if (mounted) showToast(context, '${widget.items.length * _copies} labels sent to print.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    return BcPage(
      title: 'Print Labels',
      subtitle: '$n ${n == 1 ? 'item' : 'items'} selected',
      bottom: BcCta(key: const ValueKey('bulk-print-go'), label: 'Print Labels', icon: LucideIcons.printer, busy: _busy, onPressed: _print),
      children: [
        BcCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Column(children: [
            for (final (k, i) in widget.items.indexed) ...[
              if (k > 0) const Divider(height: 1, color: kBcBorder),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  BcThumb(i.imageUrl, size: 42),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.name, style: inter(14, 700)), Text(i.barcode ?? '', style: inter(12, 500, color: kMuted))])),
                ]),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        Text(tr('Copies per item'), style: inter(13, 700)),
        const SizedBox(height: 6),
        _Stepper(value: _copies, onChanged: (v) => setState(() => _copies = v), keyPrefix: 'bulk-copies'),
      ],
    );
  }
}

// ---------------------------------------------------------------- 8/9. weigh & print (loose items)

class WeighPrintScreen extends StatefulWidget {
  const WeighPrintScreen({super.key, required this.api, required this.item, this.store = ''});
  final BarcodesApi api;
  final BcItem item;
  final String store;
  @override
  State<WeighPrintScreen> createState() => _WeighPrintScreenState();
}

class _WeighPrintScreenState extends State<WeighPrintScreen> {
  final _kg = TextEditingController(text: '1.000');
  bool _busy = false;
  WeighLabel? _label; // the code for the weight shown, from the database
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  int? get _grams {
    final v = double.tryParse(_kg.text.trim());
    if (v == null || v <= 0) return null;
    final g = (v * 1000).round();
    return g < 1 || g > 99999 ? null : g;
  }

  num get _amount => ((widget.item.price * (_grams ?? 0) / 1000) * 100).round() / 100;

  void _set(String kg) {
    _kg.text = kg;
    _changed();
  }

  void _changed() {
    setState(() => _label = null);
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 350), _refresh);
  }

  /// The real weigh-label code for this weight (21 + PLU + grams + check), for the preview and the print.
  Future<void> _refresh() async {
    final g = _grams;
    if (g == null) return;
    try {
      final l = await widget.api.weighLabel(widget.item.id, g);
      if (mounted && _grams == g) setState(() => _label = l);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not make the label.'));
    }
  }

  Future<void> _print() async {
    final g = _grams;
    if (g == null) return showToast(context, 'Enter the weight in kg, from 0.001 to 99.999.');
    setState(() => _busy = true);
    try {
      final l = _label ?? await widget.api.weighLabel(widget.item.id, g);
      await printBarcodeLabels([
        (LabelData(name: '${widget.item.name} · ${l.weightText}', priceMinor: (l.amount * 100).round(), code: l.code, systemCode: 'PLU ${l.plu ?? ''} · ${rupees(l.pricePerKg)}/kg', unit: 'pack', store: widget.store), 1),
      ]);
      if (mounted) showToast(context, 'Label for ${l.weightText} sent to print.');
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not print the label. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item, g = _grams;
    return BcPage(
      title: 'Weigh & Print Label',
      bottom: BcCta(key: const ValueKey('weigh-print-label'), label: 'Print label', busy: _busy, onPressed: _print),
      children: [
        BcCard(child: Row(children: [
          BcThumb(i.imageUrl, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.name, style: inter(16, 800)),
              Text('${rupees(i.price)}/kg · PLU ${(i.plu ?? _label?.plu ?? 0).toString().padLeft(5, '0')}', style: inter(12.5, 500, color: kMuted)),
            ]),
          ),
        ])),
        const SizedBox(height: 16),
        Text(tr('Select weight'), style: inter(14, 800)),
        const SizedBox(height: 8),
        // one row of five, sharing the width (as in the mock-up)
        Row(children: [
          for (final (n, (label, kg)) in const [('250 g', '0.250'), ('500 g', '0.500'), ('1 kg', '1.000'), ('2 kg', '2.000'), ('5 kg', '5.000')].indexed) ...[
            if (n > 0) const SizedBox(width: 6),
            Expanded(
              child: Material(
                color: _kg.text == kg ? kBcLime : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: _kg.text == kg ? kBcLime : kBcBorder)),
                child: InkWell(
                  key: ValueKey('weigh-chip-$kg'),
                  customBorder: const StadiumBorder(),
                  onTap: () => _set(kg),
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Center(child: Text(label, maxLines: 1, style: inter(12.5, 700)))),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 16),
        Text(tr('Custom weight'), style: inter(14, 800)),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('weigh-custom'),
          controller: _kg,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}(\.\d{0,3})?'))],
          style: inter(16, 700),
          decoration: _field('1.250').copyWith(suffixText: 'kg'),
          onChanged: (_) => _changed(),
        ),
        const SizedBox(height: 12),
        BcCard(
          color: const Color(0xFFF7F9F3),
          child: Row(children: [
            Text(tr('Total amount'), style: inter(13, 600, color: kMuted)),
            const Spacer(),
            Text(g == null ? '—' : rupees(_amount), key: const ValueKey('weigh-total'), style: inter(20, 800)),
          ]),
        ),
        const SizedBox(height: 16),
        Text(tr('Label preview'), style: inter(14, 800)),
        const SizedBox(height: 8),
        BcCard(
          child: _label == null
              ? SizedBox(height: 110, child: Center(child: g == null ? Text(tr('Enter a weight'), style: inter(13, 500, color: kMuted)) : const CircularProgressIndicator(strokeWidth: 2)))
              : Column(children: [
                  BarcodeView(_label!.code, height: 50),
                  const SizedBox(height: 8),
                  Text('${i.name} · ${_label!.weightText}', style: inter(12.5, 600, color: kMuted)),
                  Text(rupees(_label!.amount), key: const ValueKey('weigh-label-amount'), style: inter(18, 800)),
                ]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 10–11. custom barcode

class CustomBarcodeScreen extends StatefulWidget {
  const CustomBarcodeScreen({super.key, required this.api, this.store = ''});
  final BarcodesApi api;
  final String store;
  @override
  State<CustomBarcodeScreen> createState() => _CustomBarcodeScreenState();
}

class _CustomBarcodeScreenState extends State<CustomBarcodeScreen> {
  String _mode = 'type';
  final _code = TextEditingController(), _name = TextEditingController(), _price = TextEditingController();
  int _copies = 1;
  bool _busy = false;
  String? _error;

  String get _text => _code.text.trim();

  Future<void> _makeOne() async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.custom();
      if (mounted) {
        setState(() {
          _code.text = r.code;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not make a code. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The database checks a typed code (its shape, the weigh-label range) and says which item has it already.
  Future<bool> _check() async {
    if (_text.isEmpty) {
      setState(() => _error = tr(_mode == 'type' ? 'Type a code first.' : 'Tap Make one for me first.'));
      return false;
    }
    try {
      final r = await widget.api.custom(code: _text);
      if (!mounted) return false;
      setState(() => _error = r.usedBy == null ? null : 'Already on ${r.usedBy}.');
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'That code cannot be used.'));
      return false;
    }
  }

  LabelData get _labelData =>
      LabelData(name: _name.text.trim().isEmpty ? _text : _name.text.trim(), priceMinor: ((num.tryParse(_price.text.trim()) ?? 0) * 100).round(), code: _text, systemCode: _text, store: widget.store);

  Future<void> _preview() async {
    if (!await _check() || !mounted) return;
    await _push<void>(context, CustomPreviewScreen(label: _labelData, price: num.tryParse(_price.text.trim()), copies: _copies));
  }

  /// Save on item: pick the product, the code is saved on it (as "custom"), then the linked screen.
  Future<void> _save() async {
    if (!await _check() || !mounted) return;
    final item = await _push<BcItem>(context, SelectProductScreen(api: widget.api, title: 'Select Product', subtitle: 'Which product gets $_text?', cta: 'Confirm'));
    if (item == null || !mounted) return;
    try {
      final saved = (await widget.api.custom(code: _text, itemId: item.id)).item ?? item;
      if (mounted) await _push<void>(context, LinkDoneScreen(code: _text, item: saved));
    } on PartnerApiException catch (e) {
      if (!mounted) return;
      if (e.status == 409 && e.message.contains('already has the barcode')) {
        final ok = await _confirmReplace(context, item, _text);
        if (ok && mounted) {
          final saved = (await widget.api.custom(code: _text, itemId: item.id, replace: true)).item ?? item;
          if (mounted) await _push<void>(context, LinkDoneScreen(code: _text, item: saved));
        }
      } else {
        showToast(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) => BcPage(
        title: 'Custom Barcode',
        bottom: Column(mainAxisSize: MainAxisSize.min, children: [
          BcCta(key: const ValueKey('custom-save'), label: 'Save on item', onPressed: _save),
          const SizedBox(height: 8),
          BcOutline(key: const ValueKey('custom-print'), label: 'Print label', onPressed: _preview),
        ]),
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBcBorder)),
            child: Row(children: [
              for (final (id, label) in const [('type', 'Type code'), ('make', 'Make one for me')])
                Expanded(
                  child: Material(
                    color: _mode == id ? kPrimary : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      key: ValueKey('custom-mode-$id'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () {
                        setState(() => _mode = id);
                        if (id == 'make' && _text.isEmpty) _makeOne();
                      },
                      child: Padding(padding: const EdgeInsets.symmetric(vertical: 11), child: Center(child: Text(tr(label), style: inter(13, 700, color: _mode == id ? Colors.white : kInk)))),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          Text(tr('Enter barcode'), style: inter(13, 700)),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('custom-code'),
            controller: _code,
            readOnly: _mode == 'make',
            textCapitalization: TextCapitalization.characters,
            decoration: _field(
              '1234567890123',
              suffix: _busy
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : _mode == 'make'
                      ? IconButton(key: const ValueKey('custom-again'), tooltip: tr('Make another'), icon: const Icon(LucideIcons.refreshCw, size: 18), onPressed: _makeOne)
                      : _text.isEmpty
                          ? null
                          : IconButton(icon: const Icon(LucideIcons.x, size: 18), onPressed: () => setState(_code.clear)),
            ).copyWith(errorText: _error),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 14),
          Text(tr('Product name (optional)'), style: inter(13, 700)),
          const SizedBox(height: 6),
          TextField(key: const ValueKey('custom-name'), controller: _name, decoration: _field(tr('Custom Item')), onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Price (optional)'), style: inter(13, 700)),
                const SizedBox(height: 6),
                TextField(key: const ValueKey('custom-price'), controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _field('50', prefix: '₹ '), onChanged: (_) => setState(() {})),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Copies'), style: inter(13, 700)),
                const SizedBox(height: 6),
                _Stepper(value: _copies, onChanged: (v) => setState(() => _copies = v), keyPrefix: 'custom'),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Text(tr('Label preview'), style: inter(13, 700)),
          const SizedBox(height: 6),
          BcCard(
            child: _text.isEmpty
                ? SizedBox(height: 90, child: Center(child: Text(tr('Your barcode shows here'), style: inter(13, 500, color: kMuted))))
                : Column(children: [
                    BarcodeView(_text, height: 50),
                    if (_name.text.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_name.text.trim(), style: inter(13, 700))),
                    if (num.tryParse(_price.text.trim()) != null) Text(rupees(num.parse(_price.text.trim())), style: inter(15, 800)),
                  ]),
          ),
        ],
      );
}

/// 11 · The label as it will print, with Edit (back) and Print.
class CustomPreviewScreen extends StatefulWidget {
  const CustomPreviewScreen({super.key, required this.label, required this.copies, this.price});
  final LabelData label;
  final int copies;
  final num? price;
  @override
  State<CustomPreviewScreen> createState() => _CustomPreviewScreenState();
}

class _CustomPreviewScreenState extends State<CustomPreviewScreen> {
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await printBarcodeLabels([(widget.label, widget.copies)]);
      if (mounted) showToast(context, '${widget.copies} ${widget.copies == 1 ? 'label' : 'labels'} sent to print.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => BcPage(
        title: 'Custom Barcode',
        bottom: Row(children: [
          Expanded(child: BcOutline(key: const ValueKey('preview-edit'), label: 'Edit', icon: LucideIcons.pencil, onPressed: () => Navigator.pop(context))),
          const SizedBox(width: 10),
          Expanded(child: BcCta(key: const ValueKey('preview-print'), label: 'Print', icon: LucideIcons.printer, busy: _busy, onPressed: _print)),
        ]),
        children: [
          BcCard(child: BarcodeView(widget.label.code, height: 80)),
          const SizedBox(height: 14),
          BcCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _fact('Product name', Text(widget.label.name, style: inter(14, 700))),
              if (widget.price != null) _fact('Price', Text(rupees(widget.price!), style: inter(14, 700))),
              _fact('Copies', Text('${widget.copies}', key: const ValueKey('preview-copies'), style: inter(14, 700))),
            ]),
          ),
        ],
      );
}

Future<bool> _confirmReplace(BuildContext context, BcItem i, String code) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Replace its barcode?')),
        content: Text('${i.name} has the code ${i.barcode ?? ''}. Use $code instead?'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep it'))), FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Replace')))],
      ),
    ) ==
    true;

// ---------------------------------------------------------------- 12–14. link an unknown barcode

/// 12 · A scanned code no item has: pick the product (13), it is saved for this store only, then "Code linked!" (14). Answers the item.
class LinkCodeScreen extends StatefulWidget {
  const LinkCodeScreen({super.key, required this.api, required this.code});
  final BarcodesApi api;
  final String code;
  @override
  State<LinkCodeScreen> createState() => _LinkCodeScreenState();
}

class _LinkCodeScreenState extends State<LinkCodeScreen> {
  final _q = TextEditingController();
  Timer? _wait;
  List<BcItem>? _items;
  BcItem? _picked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.list(tab: 'all', q: _q.text);
      if (mounted) setState(() => _items = r.items);
    } catch (e) {
      if (mounted) {
        setState(() => _items = const []);
        showToast(context, _err(e, 'Could not load your items.'));
      }
    }
  }

  Future<void> _link() async {
    var i = _picked;
    i ??= await _push<BcItem>(context, SelectProductScreen(api: widget.api, title: 'Select Product', cta: 'Confirm'));
    if (i == null || !mounted) return;
    setState(() => _busy = true);
    try {
      BcItem saved;
      try {
        saved = await widget.api.link(i.id, widget.code);
      } on PartnerApiException catch (e) {
        if (!(e.status == 409 && e.message.contains('already has the barcode')) || !mounted) rethrow;
        if (!await _confirmReplace(context, i, widget.code)) return;
        saved = await widget.api.link(i.id, widget.code, replace: true);
      }
      if (!mounted) return;
      await _push<void>(context, LinkDoneScreen(code: widget.code, item: saved));
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save the code. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _items;
    return BcPage(
      title: 'Link Unknown Barcode',
      bottom: BcCta(key: const ValueKey('link-confirm'), label: 'Link to product', busy: _busy, onPressed: _link),
      children: [
        BcCard(
          color: const Color(0xFFF7F9F3),
          child: Row(children: [
            const Icon(LucideIcons.scanBarcode, size: 30, color: kInk),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Scanned code'), style: inter(12, 600, color: kMuted)),
                Text(widget.code, key: const ValueKey('link-code'), style: inter(16, 800).copyWith(letterSpacing: 0.6)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFFFF1F0), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFBD5D2))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(LucideIcons.circleAlert, size: 18, color: kError),
            const SizedBox(width: 10),
            Expanded(child: Text(tr('No item found for this code. Link it to an existing product in your store.'), style: inter(12.5, 600, color: kError, height: 1.35))),
          ]),
        ),
        const SizedBox(height: 14),
        _search(_q, 'Search product name or code', () {
          _wait?.cancel();
          _wait = Timer(const Duration(milliseconds: 300), _load);
        }, key: const ValueKey('link-search')),
        const SizedBox(height: 10),
        if (list == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (list != null && list.isEmpty) const BcEmpty(),
        if (list != null && list.isNotEmpty)
          BcCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Column(children: [
              for (final (n, i) in list.indexed) ...[
                if (n > 0) const Divider(height: 1, color: kBcBorder),
                InkWell(
                  key: ValueKey('link-item-${i.id}'),
                  onTap: () => setState(() => _picked = i),
                  child: Container(
                    color: _picked?.id == i.id ? kBcMint : null,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: Row(children: [
                      BcThumb(i.imageUrl, size: 40),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.name, style: inter(14, 700)), Text(tr(i.loose ? 'Sold loose' : 'Piece'), style: inter(12, 500, color: kMuted))])),
                      Icon(_picked?.id == i.id ? Icons.check_circle : LucideIcons.chevronRight, size: 18, color: _picked?.id == i.id ? kBcDeep : kMuted),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}

/// 14 · "Code linked!": the code and the product it is on now.
class LinkDoneScreen extends StatelessWidget {
  const LinkDoneScreen({super.key, required this.code, required this.item});
  final String code;
  final BcItem item;
  @override
  Widget build(BuildContext context) => BcPage(
        title: '',
        bottom: BcCta(key: const ValueKey('link-done'), label: 'Done', onPressed: () => Navigator.pop(context)),
        children: [
          const SizedBox(height: 20),
          Center(
            child: Container(width: 84, height: 84, decoration: const BoxDecoration(color: kBcDeep, shape: BoxShape.circle), child: const Icon(LucideIcons.check, size: 42, color: Colors.white)),
          ),
          const SizedBox(height: 18),
          Text(tr('Code linked!'), key: const ValueKey('link-success'), textAlign: TextAlign.center, style: inter(20, 800)),
          const SizedBox(height: 6),
          Text('$code has been linked to ${item.name}${item.loose ? ' (Sold loose)' : ''}.', textAlign: TextAlign.center, style: inter(13, 500, color: kMuted, height: 1.4)),
          const SizedBox(height: 20),
          BcCard(child: Row(children: [
            BcThumb(item.imageUrl, size: 48),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, style: inter(14, 700)), Text(tr(item.loose ? 'Sold loose' : 'Piece'), style: inter(12, 500, color: kMuted))])),
          ])),
        ],
      );
}
