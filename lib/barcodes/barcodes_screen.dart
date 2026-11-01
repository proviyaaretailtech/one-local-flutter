import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../orders/orders_api.dart' show rupees;
import '../stock/label_pdf.dart';
import '../ui/barcode_scanner.dart' show scanBarcodeOrType;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'barcode_sheets.dart';
import 'barcode_ui.dart';
import 'barcodes_api.dart';

// Side menu → Barcodes (founder's mock-ups, 30 Oct 2026; one page since 1 Nov 2026):
//   one page: a search bar that lists items as you type (name, code, SKU, PLU) or a scan, All / No barcode / Loose, tick several →
//     make their codes (the ring, then print) or print their labels; tap one → details (make, re-make, sold loose, print) or weigh & print
//   print: one item or many, Standard / Large, copies of each, a preview
//   custom code: type or make a code → save on an item, or print it
//   link a scanned code no item has: pick the product
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


/// The camera (or typing the code) for the search bar's scan button; tests replace it.
Future<String?> Function(BuildContext context) scanForBarcodes = scanBarcodeOrType;

/// A search bar that lists the store's items as you type (name, code, SKU or PLU), from the database. [tab]: all, missing, loose.
mixin _LiveSearch<T extends StatefulWidget> on State<T> {
  final q = TextEditingController();
  Timer? _wait;
  List<BcItem>? items;
  Map<String, int> counts = const {};
  String? loadError;

  BarcodesApi get api;
  String get tab => 'all';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _wait?.cancel();
    q.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final asked = q.text, onTab = tab;
    try {
      final r = await api.list(tab: onTab, q: asked);
      if (!mounted || q.text != asked || tab != onTab) return; // a newer search is on its way
      setState(() {
        items = r.items;
        counts = r.counts;
        loadError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          items ??= const [];
          loadError = _err(e, 'Could not load your items.');
        });
      }
    }
  }

  void _typed() {
    setState(() {});
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 250), load);
  }

  Widget searchBar(String hint, {required String key, VoidCallback? onScan}) => TextField(
        key: ValueKey(key),
        controller: q,
        textInputAction: TextInputAction.search,
        decoration: _field(
          tr(hint),
          prefixIcon: const Icon(LucideIcons.search, size: 18),
          suffix: Row(mainAxisSize: MainAxisSize.min, children: [
            if (q.text.isNotEmpty)
              IconButton(key: ValueKey('$key-clear'), tooltip: tr('Clear'), icon: const Icon(LucideIcons.x, size: 18), onPressed: () {
                q.clear();
                _typed();
              }),
            if (onScan != null) IconButton(key: ValueKey('$key-scan'), tooltip: tr('Scan a barcode'), icon: const Icon(LucideIcons.scanLine, size: 20, color: kInk), onPressed: onScan),
          ]),
        ),
        onChanged: (_) => _typed(),
      );
}

/// One item in a list: photo, name, its code (or "No barcode yet"), price or PLU, and its source tag.
class _ItemRow extends StatelessWidget {
  const _ItemRow(this.i, {super.key, this.onTap, this.leading, this.trailing, this.selected = false});
  final BcItem i;
  final VoidCallback? onTap;
  final Widget? leading, trailing;
  final bool selected;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          color: selected ? kBcMint : null,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(children: [
            ?leading,
            BcThumb(i.imageUrl, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                Text(i.barcode ?? tr('No barcode yet'), style: inter(12, 500, color: i.barcode == null ? const Color(0xFFB45309) : kMuted)),
                Text(i.loose ? 'PLU ${(i.plu ?? 0).toString().padLeft(5, '0')} · ${rupees(i.price)}/kg' : priceLine(i, rupees), style: inter(11.5, 500, color: kMuted)),
              ]),
            ),
            trailing ?? Row(mainAxisSize: MainAxisSize.min, children: [sourceTag(i), const SizedBox(width: 4), const Icon(LucideIcons.chevronRight, size: 18, color: kMuted)]),
          ]),
        ),
      );
}

/// Rows in one card, with a line between them.
Widget _rows(List<Widget> rows) => BcCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Column(children: [
        for (final (n, r) in rows.indexed) ...[if (n > 0) const Divider(height: 1, color: kBcBorder), r],
      ]),
    );

// ---------------------------------------------------------------- the one Barcodes page

/// Side menu → Barcodes: search (or scan) any item, filter All / No barcode / Loose, tap one for its details, or tick several to make
/// their codes or print their labels.
class BarcodesScreen extends StatefulWidget {
  const BarcodesScreen({super.key, this.api, this.store = ''});
  final BarcodesApi? api;
  final String store;
  static Route<void> route({BarcodesApi? api, String store = ''}) => MaterialPageRoute(builder: (_) => BarcodesScreen(api: api, store: store));
  @override
  State<BarcodesScreen> createState() => _BarcodesScreenState();
}

class _BarcodesScreenState extends State<BarcodesScreen> with _LiveSearch {
  @override
  late final BarcodesApi api = widget.api ?? BarcodesApi();
  String _filter = 'all'; // all · missing · loose (the database's tabs)
  final _ticked = <String, BcItem>{};

  @override
  String get tab => _filter;

  void _setFilter(String id) {
    setState(() => _filter = id);
    load();
  }

  Future<void> _open(Widget page) async {
    await _push<void>(context, page);
    if (mounted) load(); // it may have a new code, or be sold loose now
  }

  void _openItem(BcItem i) =>
      _open(_filter == 'loose' ? WeighPrintScreen(api: api, item: i, store: widget.store) : BarcodeDetailsScreen(api: api, item: i, store: widget.store));

  Future<void> _ticks(Widget page) async {
    await _push<void>(context, page);
    if (!mounted) return;
    setState(_ticked.clear);
    load();
  }

  /// Scan a code: its item's details; a code no item has: link it to one.
  Future<void> _scan() async {
    final code = (await scanForBarcodes(context))?.trim() ?? '';
    if (code.isEmpty || !mounted) return;
    try {
      final r = await api.resolve(code);
      if (mounted) _openItem(r.item);
    } on PartnerApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        await _open(LinkCodeScreen(api: api, code: code));
      } else {
        showToast(context, e.message);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not look up that code. Try again.');
    }
  }

  Widget _empty() {
    final searching = q.text.trim().isNotEmpty;
    if (searching && _filter != 'all') {
      return Column(children: [
        const BcEmpty(line: 'Nothing found under this filter.'),
        TextButton(key: const ValueKey('bc-search-all'), onPressed: () => _setFilter('all'), child: Text(tr('Search all items'), style: inter(13.5, 700, color: kBcDeep))),
      ]);
    }
    if (!searching && _filter == 'missing') return const BcEmpty(title: 'All set', line: 'Every item already has a barcode.');
    if (!searching && _filter == 'loose') return const BcEmpty(title: 'No loose items yet', line: 'Open an item and turn on Sold loose.');
    if (!searching) return const BcEmpty(title: 'No items yet', line: 'Add items to your catalogue first.');
    return const BcEmpty();
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final ticked = _ticked.values.toList();
    final toMake = ticked.where((i) => i.barcode == null).toList(), toPrint = ticked.where((i) => i.barcode != null).toList();
    final allTicked = list != null && list.isNotEmpty && list.every((i) => _ticked.containsKey(i.id));
    String n(int k, String one, String many) => '$k ${k == 1 ? one : many}';
    return BcPage(
      title: 'Barcodes',
      subtitle: 'Search any item to make, link or print its barcode.',
      trailing: TextButton.icon(
        key: const ValueKey('bc-custom'),
        onPressed: () => _open(CustomBarcodeScreen(api: api, store: widget.store)),
        icon: const Icon(LucideIcons.tag, size: 16, color: kBcDeep),
        label: Text(tr('Custom code'), style: inter(13, 700, color: kBcDeep)),
      ),
      bottom: ticked.isEmpty
          ? null
          : Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(n(ticked.length, 'item selected', 'items selected'), key: const ValueKey('bc-count'), style: inter(13, 700, color: kBcDeep)),
                const Spacer(),
                TextButton(key: const ValueKey('bc-clear'), onPressed: () => setState(_ticked.clear), child: Text(tr('Clear'), style: inter(13, 700, color: kMuted))),
              ]),
              Row(children: [
                if (toMake.isNotEmpty)
                  Expanded(
                    child: BcCta(
                      key: const ValueKey('bc-make'),
                      label: 'Make ${n(toMake.length, 'code', 'codes')}',
                      onPressed: () => _ticks(BulkProgressScreen(api: api, items: toMake, store: widget.store)),
                    ),
                  ),
                if (toMake.isNotEmpty && toPrint.isNotEmpty) const SizedBox(width: 10),
                if (toPrint.isNotEmpty)
                  Expanded(
                    child: toMake.isEmpty
                        ? BcCta(key: const ValueKey('bc-print'), label: 'Print ${n(toPrint.length, 'label', 'labels')}', icon: LucideIcons.printer, onPressed: () => _ticks(PrintLabelsScreen(items: toPrint, store: widget.store)))
                        : BcOutline(key: const ValueKey('bc-print'), label: 'Print ${toPrint.length}', icon: LucideIcons.printer, onPressed: () => _ticks(PrintLabelsScreen(items: toPrint, store: widget.store))),
                  ),
              ]),
            ]),
      children: [
        searchBar('Search name, code, SKU or PLU', key: 'bc-search', onScan: _scan),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in const [('all', 'All'), ('missing', 'No barcode'), ('loose', 'Loose')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('bc-filter-$id'),
                  selected: _filter == id,
                  showCheckmark: false,
                  selectedColor: kBcDeep,
                  backgroundColor: Colors.white,
                  side: BorderSide(color: _filter == id ? kBcDeep : kBcBorder),
                  labelStyle: inter(12.5, 700, color: _filter == id ? Colors.white : kInk),
                  label: Text('${tr(label)} (${counts[id] ?? 0})'),
                  onSelected: (_) => _setFilter(id),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        if (loadError != null) Padding(padding: const EdgeInsets.all(12), child: Text(loadError!, textAlign: TextAlign.center, style: inter(13, 500, color: kError))),
        if (list == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (list != null && list.isEmpty && loadError == null) _empty(),
        if (list != null && list.isNotEmpty) ...[
          Row(children: [
            Text(q.text.trim().isEmpty ? n(list.length, 'item', 'items') : n(list.length, 'match', 'matches'), key: const ValueKey('bc-shown'), style: inter(12.5, 600, color: kMuted)),
            const Spacer(),
            TextButton(
              key: const ValueKey('bc-select-all'),
              onPressed: () => setState(() => allTicked ? _ticked.removeWhere((id, _) => list.any((i) => i.id == id)) : _ticked.addAll({for (final i in list) i.id: i})),
              child: Text(tr(allTicked ? 'Clear all' : 'Select all'), style: inter(13, 700, color: kBcDeep)),
            ),
          ]),
          _rows([
            for (final i in list)
              _ItemRow(
                i,
                key: ValueKey('bc-item-${i.id}'),
                selected: _ticked.containsKey(i.id),
                onTap: () => _openItem(i),
                leading: SizedBox(
                  width: 36,
                  child: Checkbox(
                    key: ValueKey('bc-tick-${i.id}'),
                    value: _ticked.containsKey(i.id),
                    activeColor: kBcDeep,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => v == true ? _ticked[i.id] = i : _ticked.remove(i.id)),
                  ),
                ),
              ),
          ]),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- making several codes (the ring)

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
      subtitle: _finished ? (failed == 0 ? 'Every item has its new code.' : '$failed could not be made; tick them again to retry.') : 'This may take a moment.',
      bottom: Row(children: [
        Expanded(child: BcOutline(key: const ValueKey('bulk-done'), label: 'Done', onPressed: _finished ? () => Navigator.pop(context) : null)),
        const SizedBox(width: 10),
        Expanded(
          child: BcCta(
            key: const ValueKey('bulk-print'),
            label: 'Print labels',
            icon: LucideIcons.printer,
            onPressed: _finished && _made.isNotEmpty
                ? () => _swap<void>(context, PrintLabelsScreen(items: _made, store: widget.store, subtitle: '${_made.length} ${_made.length == 1 ? 'item has' : 'items have'} new barcodes.'))
                : null,
          ),
        ),
      ]),
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

// ---------------------------------------------------------------- barcode details

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
          : BcCta(key: const ValueKey('details-print-label'), label: 'Print label', icon: LucideIcons.printer, onPressed: () => _push<void>(context, PrintLabelsScreen(items: [i], store: widget.store))),
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
            _action('details-print', LucideIcons.printer, 'Print', () => _push<void>(context, PrintLabelsScreen(items: [i], store: widget.store))),
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

// ---------------------------------------------------------------- print labels (one item or many)

/// Labels for one item or several: Standard (50 × 30 mm) or Large (3 × 2 in), copies of each, a preview, print.
class PrintLabelsScreen extends StatefulWidget {
  const PrintLabelsScreen({super.key, required this.items, this.store = '', this.subtitle});
  final List<BcItem> items;
  final String store;
  final String? subtitle;
  @override
  State<PrintLabelsScreen> createState() => _PrintLabelsScreenState();
}

class _PrintLabelsScreenState extends State<PrintLabelsScreen> {
  bool _large = false;
  int _copies = 1;
  bool _busy = false;

  List<BcItem> get _coded => widget.items.where((i) => i.barcode != null).toList();

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await printBarcodeLabels([for (final i in _coded) (itemLabel(i, store: widget.store), _copies)], size: _large ? LabelSize.medium : LabelSize.product);
      final n = _coded.length * _copies;
      if (mounted) showToast(context, '$n ${n == 1 ? 'label' : 'labels'} sent to print.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _coded, one = items.length == 1, first = items.firstOrNull;
    return BcPage(
      title: one ? 'Print Label' : 'Print Labels',
      subtitle: widget.subtitle ?? (one ? null : '${items.length} items'),
      bottom: BcCta(key: const ValueKey('print-label-go'), label: 'Print', icon: LucideIcons.printer, busy: _busy, onPressed: items.isEmpty ? null : _print),
      children: [
        if (one) _itemHead(first!) else _rows([for (final i in items) _ItemRow(i, trailing: const SizedBox.shrink())]),
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
        Text(tr(one ? 'Copies' : 'Copies of each'), style: inter(13, 700)),
        const SizedBox(height: 6),
        _Stepper(value: _copies, onChanged: (v) => setState(() => _copies = v)),
        if (first != null) ...[
          const SizedBox(height: 16),
          Text(tr('Label preview'), style: inter(13, 700)),
          const SizedBox(height: 6),
          BcCard(child: Column(children: [
            BarcodeView(first.barcode!, height: _large ? 70 : 50),
            const SizedBox(height: 6),
            Text(first.name, style: inter(12.5, 600, color: kMuted)),
            Text(first.loose ? '${rupees(first.price)}/kg' : rupees(first.price), style: inter(16, 800)),
          ])),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- weigh & print (loose items)

class WeighPrintScreen extends StatefulWidget {
  const WeighPrintScreen({super.key, required this.api, required this.item, this.store = ''});
  final BarcodesApi api;
  final BcItem item;
  final String store;
  @override
  State<WeighPrintScreen> createState() => _WeighPrintScreenState();
}

class _WeighPrintScreenState extends State<WeighPrintScreen> {
  final _kg = TextEditingController(text: '1');
  String _unit = 'kg'; // g or kg: the switch beside the custom weight
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

  int? get _grams => gramsOf(_kg.text, _unit);

  num get _amount => ((widget.item.price * (_grams ?? 0) / 1000) * 100).round() / 100;

  /// A quick weight: 250 g and 500 g in grams, whole kilos in kg.
  void _set(int grams) {
    _unit = grams < 1000 ? 'g' : 'kg';
    _kg.text = weightFor(grams, _unit);
    _changed();
  }

  /// g ↔ kg: the weight typed stays the same weight.
  void _setUnit(String u) {
    if (u == _unit) return;
    final g = _grams;
    _unit = u;
    _kg.text = g == null ? '' : weightFor(g, u);
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
    if (g == null) return showToast(context, _unit == 'g' ? 'Enter the weight in grams, from 1 to 99999.' : 'Enter the weight in kg, from 0.001 to 99.999.');
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
          for (final (n, (label, key, grams)) in const [('250 g', '0.250', 250), ('500 g', '0.500', 500), ('1 kg', '1.000', 1000), ('2 kg', '2.000', 2000), ('5 kg', '5.000', 5000)].indexed) ...[
            if (n > 0) const SizedBox(width: 6),
            Expanded(
              child: Material(
                color: _grams == grams ? kBcLime : Colors.white,
                shape: StadiumBorder(side: BorderSide(color: _grams == grams ? kBcLime : kBcBorder)),
                child: InkWell(
                  key: ValueKey('weigh-chip-$key'),
                  customBorder: const StadiumBorder(),
                  onTap: () => _set(grams),
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
          keyboardType: TextInputType.numberWithOptions(decimal: _unit == 'kg'),
          inputFormatters: weightFormatters(_unit),
          style: inter(16, 700),
          decoration: _field(_unit == 'g' ? '300' : '1.250', suffix: WeightUnitSwitch(unit: _unit, onChanged: _setUnit, keyPrefix: 'weigh-custom-unit'))
              .copyWith(suffixIconConstraints: const BoxConstraints(minHeight: 40)),
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

// ---------------------------------------------------------------- custom barcode

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
  bool _busy = false, _printing = false;
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

  Future<void> _print() async {
    if (!await _check() || !mounted) return;
    setState(() => _printing = true);
    try {
      await printBarcodeLabels([(_labelData, _copies)]);
      if (mounted) showToast(context, '$_copies ${_copies == 1 ? 'label' : 'labels'} sent to print.');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  void _saved(BcItem item) {
    showToast(context, '$_text saved on ${item.name}.');
    Navigator.pop(context);
  }

  /// Save on item: pick the product, the code is saved on it (as "custom"), then the linked screen.
  Future<void> _save() async {
    if (!await _check() || !mounted) return;
    final item = await _push<BcItem>(context, PickProductScreen(api: widget.api, subtitle: 'Which product gets $_text?'));
    if (item == null || !mounted) return;
    try {
      final saved = (await widget.api.custom(code: _text, itemId: item.id)).item ?? item;
      if (mounted) _saved(saved);
    } on PartnerApiException catch (e) {
      if (!mounted) return;
      if (e.status == 409 && e.message.contains('already has the barcode')) {
        final ok = await _confirmReplace(context, item, _text);
        if (ok && mounted) {
          final saved = (await widget.api.custom(code: _text, itemId: item.id, replace: true)).item ?? item;
          if (mounted) _saved(saved);
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
          BcOutline(key: const ValueKey('custom-print'), label: _printing ? 'Printing...' : 'Print label', icon: LucideIcons.printer, onPressed: _printing ? null : _print),
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

// ---------------------------------------------------------------- pick a product (saving a custom code, linking a scanned one)

/// The live search list to pick one item from; the picked row is tinted and ticked.
Widget _pickList(List<BcItem>? list, BcItem? picked, ValueChanged<BcItem> onPick, {required String keyPrefix}) {
  if (list == null) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)));
  if (list.isEmpty) return const BcEmpty(line: 'Try a different name, code or SKU.');
  return _rows([
    for (final i in list)
      _ItemRow(
        i,
        key: ValueKey('$keyPrefix-${i.id}'),
        selected: picked?.id == i.id,
        onTap: () => onPick(i),
        trailing: picked?.id == i.id ? const Icon(Icons.check_circle, size: 20, color: kBcDeep) : const Icon(LucideIcons.circle, size: 18, color: Color(0xFFC4C8BF)),
      ),
  ]);
}

/// Pick one of the store's items. Answers the item.
class PickProductScreen extends StatefulWidget {
  const PickProductScreen({super.key, required this.api, this.title = 'Select Product', this.subtitle, this.cta = 'Confirm'});
  final BarcodesApi api;
  final String title, cta;
  final String? subtitle;
  @override
  State<PickProductScreen> createState() => _PickProductScreenState();
}

class _PickProductScreenState extends State<PickProductScreen> with _LiveSearch {
  @override
  BarcodesApi get api => widget.api;
  BcItem? _picked;

  @override
  Widget build(BuildContext context) => BcPage(
        title: widget.title,
        subtitle: widget.subtitle,
        bottom: BcCta(key: const ValueKey('pick-confirm'), label: widget.cta, onPressed: _picked == null ? null : () => Navigator.pop(context, _picked)),
        children: [
          searchBar('Search name, code or SKU', key: 'pick-search'),
          const SizedBox(height: 12),
          _pickList(items, _picked, (i) => setState(() => _picked = i), keyPrefix: 'pick'),
        ],
      );
}

/// A scanned code no item has: pick the product and it is saved on it, for this store only. Answers the item.
class LinkCodeScreen extends StatefulWidget {
  const LinkCodeScreen({super.key, required this.api, required this.code});
  final BarcodesApi api;
  final String code;
  @override
  State<LinkCodeScreen> createState() => _LinkCodeScreenState();
}

class _LinkCodeScreenState extends State<LinkCodeScreen> with _LiveSearch {
  @override
  BarcodesApi get api => widget.api;
  BcItem? _picked;
  bool _busy = false;

  Future<void> _link() async {
    final i = _picked;
    if (i == null) return showToast(context, 'Pick the product first.');
    setState(() => _busy = true);
    try {
      BcItem saved;
      try {
        saved = await api.link(i.id, widget.code);
      } on PartnerApiException catch (e) {
        if (!(e.status == 409 && e.message.contains('already has the barcode')) || !mounted) rethrow;
        if (!await _confirmReplace(context, i, widget.code)) return;
        saved = await api.link(i.id, widget.code, replace: true);
      }
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save the code. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => BcPage(
        title: 'Link Barcode',
        subtitle: 'No item has this code yet. Pick the product it belongs to.',
        bottom: BcCta(key: const ValueKey('link-confirm'), label: 'Link to product', busy: _busy, onPressed: _picked == null ? null : _link),
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
          const SizedBox(height: 12),
          searchBar('Search name, code or SKU', key: 'link-search'),
          const SizedBox(height: 12),
          _pickList(items, _picked, (i) => setState(() => _picked = i), keyPrefix: 'link-item'),
        ],
      );
}
