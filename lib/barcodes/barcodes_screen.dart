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

// Side menu → Barcodes (founder's mock-ups, 30 Oct 2026): a home with four ways in (Create, Bulk generate, All codes, Loose items), the bulk
// flow (choose → review → generating → done), each code's details, weigh & print for loose items, a custom barcode, and linking a scanned code
// no item has. Every code is this store's own (Master Architecture §2): never a GTIN, never added to the master library.

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : fallback;

Future<T?> _push<T>(BuildContext context, Widget page) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

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

// ---------------------------------------------------------------- 1. home

class BarcodesScreen extends StatelessWidget {
  const BarcodesScreen({super.key, this.api, this.store = ''});
  final BarcodesApi? api;
  final String store;
  static Route<void> route({BarcodesApi? api, String store = ''}) => MaterialPageRoute(builder: (_) => BarcodesScreen(api: api, store: store));

  @override
  Widget build(BuildContext context) {
    final a = api ?? BarcodesApi();
    Widget tile(String key, IconData icon, String title, String line, Widget Function() page, {bool lead = false}) => BcCard(
          key: ValueKey(key),
          color: lead ? kBcMint : Colors.white,
          onTap: () => _push<void>(context, page()),
          child: SizedBox(
            height: 112,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: lead ? kBcDeep : kBcMint, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: lead ? Colors.white : kBcDeep),
              ),
              const Spacer(),
              Text(tr(title), style: inter(14.5, 800)),
              const SizedBox(height: 2),
              Text(tr(line), maxLines: 2, style: inter(11.5, 500, color: kMuted, height: 1.3)),
            ]),
          ),
        );
    return BcPage(
      title: 'Manage product barcodes',
      subtitle: 'Create, view, and print barcode labels for your store items.',
      trailing: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: kBcBorder)),
        child: const Icon(LucideIcons.scanBarcode, size: 38, color: kInk),
      ),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.08,
          children: [
            tile('bc-home-create', LucideIcons.plus, 'Create Barcode', 'Generate a new barcode for a product', () => CustomBarcodeScreen(api: a, store: store), lead: true),
            tile('bc-home-bulk', LucideIcons.layers, 'Bulk Generate', 'Create codes for multiple items', () => BulkSelectScreen(api: a, store: store)),
            tile('bc-home-all', LucideIcons.tag, 'All Codes', 'View & manage existing codes', () => AllCodesScreen(api: a, store: store)),
            tile('bc-home-loose', LucideIcons.scale, 'Loose Items', 'Weigh & print labels', () => AllCodesScreen(api: a, store: store, looseOnly: true)),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 2–5. bulk generate

class BulkSelectScreen extends StatefulWidget {
  const BulkSelectScreen({super.key, required this.api, this.store = ''});
  final BarcodesApi api;
  final String store;
  @override
  State<BulkSelectScreen> createState() => _BulkSelectScreenState();
}

class _BulkSelectScreenState extends State<BulkSelectScreen> {
  List<BcItem>? _missing;
  String _choice = 'all';
  final _picked = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.list(tab: 'missing').then((r) {
      if (mounted) setState(() => _missing = r.items);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load your items.'));
    });
  }

  List<BcItem> get _chosen => _choice == 'all' ? (_missing ?? const []) : (_missing ?? const []).where((i) => _picked.contains(i.id)).toList();

  Widget _option(String id, IconData icon, String title, String line) => BcCard(
        key: ValueKey('bulk-$id'),
        border: _choice == id ? kBcDeep : null,
        onTap: () => setState(() => _choice = id),
        child: Row(children: [
          Icon(_choice == id ? Icons.radio_button_checked : Icons.radio_button_off, color: _choice == id ? kBcDeep : kMuted, size: 20),
          const SizedBox(width: 12),
          Container(width: 40, height: 40, decoration: BoxDecoration(color: kBcMint, borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 20, color: kBcDeep)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr(title), style: inter(14, 700)), Text(line, style: inter(12, 500, color: kMuted))])),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final m = _missing;
    return BcPage(
      title: 'Bulk Generate Barcodes',
      subtitle: 'Select products and generate barcodes for multiple items at once.',
      bottom: BcCta(
        key: const ValueKey('bulk-continue'),
        label: 'Continue',
        onPressed: _chosen.isEmpty ? null : () => _push<void>(context, BulkReviewScreen(api: widget.api, items: _chosen, store: widget.store)),
      ),
      children: [
        BcCard(
          color: kBcMint,
          border: kBcMint,
          child: Row(children: [
            const Icon(LucideIcons.boxes, size: 44, color: kBcDeep),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Quick & easy'), style: inter(14, 800)),
                const SizedBox(height: 4),
                Text(tr('Generate barcodes for up to 500 items at a time.'), style: inter(12, 500, color: kMuted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Text(tr('Choose items'), style: inter(14, 800)),
        const SizedBox(height: 10),
        if (_error != null) Text(_error!, style: inter(13, 500, color: kError)),
        if (m == null && _error == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (m != null) ...[
          _option('all', LucideIcons.box, 'All products', '(without barcode)\n${m.length} ${m.length == 1 ? 'item' : 'items'}'),
          const SizedBox(height: 10),
          _option('some', LucideIcons.listChecks, 'Selected items', tr('Choose from your product list')),
          if (m.isEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(tr('Every item already has a barcode.'), key: const ValueKey('bulk-none'), style: inter(13, 600, color: kBcDeep))),
          if (_choice == 'some')
            for (final i in m)
              CheckboxListTile(
                key: ValueKey('bulk-pick-${i.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                value: _picked.contains(i.id),
                activeColor: kBcDeep,
                onChanged: (v) => setState(() => v == true ? _picked.add(i.id) : _picked.remove(i.id)),
                secondary: BcThumb(i.imageUrl, size: 40),
                title: Text(i.name, style: inter(14, 700)),
                subtitle: Text(priceLine(i, rupees), style: inter(12, 500, color: kMuted)),
              ),
        ],
      ],
    );
  }
}

Widget _productRow(BcItem i) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        BcThumb(i.imageUrl, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
            Text(priceLine(i, rupees), style: inter(12, 500, color: kMuted)),
          ]),
        ),
        unitTag(i),
      ]),
    );

class BulkReviewScreen extends StatefulWidget {
  const BulkReviewScreen({super.key, required this.api, required this.items, this.store = ''});
  final BarcodesApi api;
  final List<BcItem> items;
  final String store;
  @override
  State<BulkReviewScreen> createState() => _BulkReviewScreenState();
}

class _BulkReviewScreenState extends State<BulkReviewScreen> {
  bool _all = false;
  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    final shown = _all ? widget.items : widget.items.take(3).toList();
    return BcPage(
      title: 'Review & Generate',
      subtitle: 'You are about to generate barcodes for $n ${n == 1 ? 'product' : 'products'}.',
      bottom: BcCta(
        key: const ValueKey('bulk-generate'),
        label: 'Generate Barcodes',
        onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BulkProgressScreen(api: widget.api, items: widget.items, store: widget.store))),
      ),
      children: [
        BcCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Text(tr('Products'), style: inter(14, 800)), const Spacer(), Text('$n ${n == 1 ? 'item' : 'items'}', style: inter(12, 600, color: kMuted))]),
            const SizedBox(height: 6),
            for (final i in shown) _productRow(i),
            if (!_all && n > 3)
              TextButton(
                key: const ValueKey('bulk-more'),
                onPressed: () => setState(() => _all = true),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                child: Text('+ ${n - 3} more ${n - 3 == 1 ? 'item' : 'items'}', style: inter(13, 700, color: kBcDeep)),
              ),
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
                Text(tr('Each store has its own unique codes.'), style: inter(12, 500, color: kMuted)),
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
  // per item: pending / processing / done / failed
  late final _state = {for (final i in widget.items) i.id: 'pending'};
  final _made = <BcItem>[];
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  /// One item at a time, so the list shows each one finishing; a failure is counted and the rest go on.
  Future<void> _run() async {
    for (final i in widget.items) {
      if (!mounted) return;
      setState(() => _state[i.id] = 'processing');
      try {
        _made.add(await widget.api.make(i.id));
        _state[i.id] = 'done';
      } catch (_) {
        _state[i.id] = 'failed';
        _failed++;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BulkDoneScreen(api: widget.api, made: _made, failed: _failed, store: widget.store)));
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length, done = _state.values.where((s) => s == 'done' || s == 'failed').length;
    return BcPage(
      title: '',
      children: [
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: const BoxDecoration(color: kBcMint, shape: BoxShape.circle),
            child: const Icon(LucideIcons.scanBarcode, size: 52, color: kInk),
          ),
        ),
        const SizedBox(height: 16),
        Text(tr('Generating barcodes...'), textAlign: TextAlign.center, style: inter(18, 800)),
        const SizedBox(height: 4),
        Text(tr('This will only take a moment.'), textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: n == 0 ? 1 : done / n, minHeight: 7, color: kBcDeep, backgroundColor: kBcBorder))),
          const SizedBox(width: 10),
          Text('$done / $n', key: const ValueKey('bulk-progress'), style: inter(12.5, 700)),
        ]),
        const SizedBox(height: 14),
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

class BulkDoneScreen extends StatelessWidget {
  const BulkDoneScreen({super.key, required this.api, required this.made, required this.failed, this.store = ''});
  final BarcodesApi api;
  final List<BcItem> made;
  final int failed;
  final String store;

  @override
  Widget build(BuildContext context) {
    Widget stat(IconData icon, Color c, int n, String label) => Expanded(
          child: BcCard(
            child: Column(children: [
              Icon(icon, color: c, size: 20),
              const SizedBox(height: 6),
              Text('$n', style: inter(24, 800)),
              Text(tr(label), style: inter(12, 500, color: kMuted)),
            ]),
          ),
        );
    return BcPage(
      title: '',
      children: [
        const SizedBox(height: 10),
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(color: kBcDeep, shape: BoxShape.circle),
            child: const Icon(LucideIcons.check, size: 48, color: Colors.white),
          ),
        ),
        const SizedBox(height: 18),
        Text(tr('Barcodes generated!'), key: const ValueKey('bulk-done'), textAlign: TextAlign.center, style: inter(20, 800)),
        const SizedBox(height: 6),
        Text('${made.length} ${made.length == 1 ? 'product has' : 'products have'} been updated with new barcodes.', textAlign: TextAlign.center, style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 20),
        Row(children: [stat(Icons.check_circle, kBcDeep, made.length, 'Generated'), const SizedBox(width: 12), stat(Icons.error, kError, failed, 'Failed')]),
        const SizedBox(height: 20),
        BcCta(
          key: const ValueKey('bulk-view-all'),
          label: 'View All Codes',
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => AllCodesScreen(api: api, store: store))),
        ),
        const SizedBox(height: 10),
        BcOutline(
          key: const ValueKey('bulk-print'),
          label: 'Print Labels',
          onPressed: made.isEmpty
              ? null
              : () async {
                  try {
                    await printBarcodeLabels([for (final i in made) (itemLabel(i, store: store), 1)]);
                  } catch (_) {
                    if (context.mounted) showToast(context, 'Could not open printing. Try again.');
                  }
                },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 6. all codes (and loose items)

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
        'generated' => _items.where((i) => i.barcode != null && i.barcodeSource == 'generated').toList(),
        'linked' => _items.where((i) => i.barcode != null && i.barcodeSource == 'linked').toList(),
        'custom' => _items.where((i) => i.barcode != null && i.barcodeSource == 'custom').toList(),
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
        TextField(
          key: const ValueKey('codes-search'),
          controller: _q,
          decoration: _field(tr('Search by name, code or PLU'), prefixIcon: const Icon(LucideIcons.search, size: 18)),
          onChanged: (_) {
            _wait?.cancel();
            _wait = Timer(const Duration(milliseconds: 300), _load);
          },
        ),
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
                    selectedColor: kPrimary,
                    backgroundColor: Colors.white,
                    side: BorderSide(color: _filter == id ? kPrimary : kBcBorder),
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
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(tr(widget.looseOnly ? 'No loose items yet. Open an item in All Codes and turn on Sold loose.' : 'No codes match.'),
                key: const ValueKey('codes-empty'), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
          ),
        if (shown.isNotEmpty)
          BcCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Column(children: [
              for (final (n, i) in shown.indexed) ...[
                if (n > 0) const Divider(height: 1, color: kBcBorder),
                InkWell(
                  key: ValueKey('code-${i.id}'),
                  onTap: () => _open(i),
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
                            widget.looseOnly ? 'PLU ${(i.plu ?? 0).toString().padLeft(5, '0')} · ${rupees(i.price)}/kg' : (i.barcode ?? tr('No barcode yet')),
                            style: inter(12, 500, color: i.barcode == null && !widget.looseOnly ? const Color(0xFFB45309) : kMuted),
                          ),
                        ]),
                      ),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        if (widget.looseOnly) const BcTag('Weigh') else sourceTag(i),
                        const SizedBox(height: 6),
                        unitTag(i),
                      ]),
                      const SizedBox(width: 6),
                      const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
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

// ---------------------------------------------------------------- 7. barcode details

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

  Future<void> _print() async {
    try {
      await printBarcodeLabels([(itemLabel(_item, store: widget.store), 1)]);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    }
  }

  Future<void> _loose(bool v) => _run(() => widget.api.setLoose(_item.id, v), v ? '${_item.name} is now sold loose, by weight.' : '${_item.name} is now sold by the piece.');

  Widget _action(String key, IconData icon, String label, VoidCallback onTap) => Expanded(
        child: BcCard(
          key: ValueKey(key),
          onTap: _busy ? null : onTap,
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(children: [Icon(icon, size: 22, color: kInk), const SizedBox(height: 6), Text(tr(label), style: inter(12.5, 700))]),
        ),
      );

  Widget _fact(String label, Widget value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr(label), style: inter(11.5, 600, color: kMuted)), const SizedBox(height: 2), value]),
      );

  @override
  Widget build(BuildContext context) {
    final i = _item;
    return BcPage(
        title: 'Barcode Details',
        bottom: i.barcode == null
            ? BcCta(key: const ValueKey('details-make'), label: 'Make barcode', busy: _busy, onPressed: () => _run(() => widget.api.make(i.id), 'Barcode made. Scans now find ${i.name}.'))
            : null,
        children: [
          BcCard(child: Row(children: [
            BcThumb(i.imageUrl, size: 60),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.name, style: inter(16, 800)), Text(priceLine(i, rupees), style: inter(12.5, 500, color: kMuted))])),
          ])),
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
              if (i.barcode != null) ...[BarcodeView(i.barcode!, height: 54), const SizedBox(height: 12)],
              _fact('Source', Text(tr(sourceLabel(i)), style: inter(14, 700))),
              if (i.loose) _fact('PLU', Text((i.plu ?? 0).toString().padLeft(5, '0'), style: inter(14, 700))),
              _fact('Selling unit', Text(tr(i.loose ? 'kg (sold loose)' : 'piece / pack'), style: inter(14, 700))),
            ]),
          ),
          const SizedBox(height: 12),
          if (i.barcode != null) ...[
            Row(children: [
              _action('details-print', LucideIcons.printer, 'Print', _print),
              const SizedBox(width: 10),
              _action('details-remake', LucideIcons.refreshCw, 'Re-make', _remake),
            ]),
            const SizedBox(height: 10),
          ],
          BcCard(
            key: const ValueKey('details-loose'),
            onTap: _busy ? null : () => _loose(!i.loose),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            child: Row(children: [
              const Icon(LucideIcons.scale, size: 22, color: kInk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Sold loose'), style: inter(14, 700)),
                  Text(tr(i.loose ? 'Priced per kg, weighed for each customer' : 'Turn on for rice, dal, sugar, vegetables'), style: inter(12, 500, color: kMuted)),
                ]),
              ),
              Switch(value: i.loose, activeTrackColor: kBcDeep, onChanged: _busy ? null : _loose),
            ]),
          ),
          if (i.loose) ...[
            const SizedBox(height: 10),
            BcOutline(key: const ValueKey('details-weigh'), label: 'Weigh & print label', icon: LucideIcons.scale, onPressed: () => _push<void>(context, WeighPrintScreen(api: widget.api, item: i, store: widget.store))),
          ],
        ],
    );
  }
}

// ---------------------------------------------------------------- 8. weigh & print (loose items)

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
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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

// ---------------------------------------------------------------- 9. custom barcode (Create Barcode)

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

  Future<void> _print() async {
    if (!await _check() || !mounted) return;
    final price = num.tryParse(_price.text.trim());
    try {
      await printBarcodeLabels([
        (LabelData(name: _name.text.trim().isEmpty ? _text : _name.text.trim(), priceMinor: ((price ?? 0) * 100).round(), code: _text, systemCode: _text, store: widget.store), _copies),
      ]);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open printing. Try again.');
    }
  }

  Future<void> _save() async {
    if (!await _check() || !mounted) return;
    final saved = await _push<BcItem>(context, LinkCodeScreen(api: widget.api, code: _text, custom: true));
    if (saved != null && mounted) showToast(context, '$_text saved on ${saved.name}. Scans now find it.');
  }

  @override
  Widget build(BuildContext context) => BcPage(
        title: 'Custom Barcode',
        bottom: Row(children: [
          Expanded(child: BcOutline(key: const ValueKey('custom-save'), label: 'Save', icon: LucideIcons.save, onPressed: _save)),
          const SizedBox(width: 10),
          Expanded(child: BcCta(key: const ValueKey('custom-print'), label: 'Print', icon: LucideIcons.printer, onPressed: _print)),
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Center(child: Text(tr(label), style: inter(13, 700, color: _mode == id ? Colors.white : kInk))),
                      ),
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
                TextField(key: const ValueKey('custom-price'), controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _field('50', prefix: '₹ ')),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Copies'), style: inter(13, 700)),
                const SizedBox(height: 6),
                Container(
                  height: 50,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBcBorder)),
                  child: Row(children: [
                    IconButton(key: const ValueKey('custom-less'), onPressed: _copies > 1 ? () => setState(() => _copies--) : null, icon: const Icon(LucideIcons.minus, size: 16)),
                    Expanded(child: Center(child: Text('$_copies', key: const ValueKey('custom-copies'), style: inter(16, 800)))),
                    IconButton(key: const ValueKey('custom-more'), onPressed: _copies < 200 ? () => setState(() => _copies++) : null, icon: const Icon(LucideIcons.plus, size: 16)),
                  ]),
                ),
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
                  ]),
          ),
        ],
      );
}

// ---------------------------------------------------------------- 10. link an unknown barcode

/// A code no item has (scanned on the Bill, or a custom one being saved): pick the item it belongs to; it is saved for this store only.
/// Answers the item it was saved on.
class LinkCodeScreen extends StatefulWidget {
  const LinkCodeScreen({super.key, required this.api, required this.code, this.custom = false});
  final BarcodesApi api;
  final String code;

  /// A code the vendor made (saved as "custom"), not one found on a pack.
  final bool custom;
  @override
  State<LinkCodeScreen> createState() => _LinkCodeScreenState();
}

class _LinkCodeScreenState extends State<LinkCodeScreen> {
  final _q = TextEditingController();
  Timer? _wait;
  List<BcItem> _items = const [];
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
      if (mounted) showToast(context, _err(e, 'Could not load your items.'));
    }
  }

  Future<void> _link({bool replace = false}) async {
    final i = _picked;
    if (i == null) return;
    setState(() => _busy = true);
    try {
      final saved = widget.custom
          ? (await widget.api.custom(code: widget.code, itemId: i.id, replace: replace)).item ?? i
          : await widget.api.link(i.id, widget.code, replace: replace);
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      if (!replace && e is PartnerApiException && e.status == 409 && e.message.contains('already has the barcode')) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('Replace its barcode?')),
            content: Text('${i.name} has the code ${i.barcode}. Use ${widget.code} instead?'),
            actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Keep it'))), FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Replace')))],
          ),
        );
        if (ok == true && mounted) return _link(replace: true);
      } else {
        showToast(context, _err(e, 'Could not save the code. Try again.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => BcPage(
        title: widget.custom ? 'Save on a product' : 'Link Unknown Barcode',
        bottom: BcCta(key: const ValueKey('link-confirm'), label: 'Link to product', busy: _busy, onPressed: _picked == null ? null : _link),
        children: [
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(color: kBcMint, shape: BoxShape.circle),
              child: const Icon(LucideIcons.scanBarcode, size: 36, color: kBcDeep),
            ),
          ),
          const SizedBox(height: 12),
          Text(tr(widget.custom ? 'Which product gets this code?' : 'No item found for this code'), textAlign: TextAlign.center, style: inter(16, 800)),
          const SizedBox(height: 4),
          Text(widget.code, key: const ValueKey('link-code'), textAlign: TextAlign.center, style: inter(14, 600, color: kMuted).copyWith(letterSpacing: 0.6)),
          const SizedBox(height: 4),
          Text(tr('Saved for your store only.'), textAlign: TextAlign.center, style: inter(12, 500, color: kMuted)),
          const SizedBox(height: 16),
          Text(tr('Link it to an existing product'), style: inter(13, 700)),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('link-search'),
            controller: _q,
            decoration: _field(tr('Search product name or code'), prefixIcon: const Icon(LucideIcons.search, size: 18)),
            onChanged: (_) {
              _wait?.cancel();
              _wait = Timer(const Duration(milliseconds: 300), _load);
            },
          ),
          const SizedBox(height: 14),
          Text(tr('Select product'), style: inter(13, 700)),
          const SizedBox(height: 6),
          if (_items.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('No items match.'), textAlign: TextAlign.center, style: inter(13, 500, color: kMuted))),
          if (_items.isNotEmpty)
            BcCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Column(children: [
                for (final (n, i) in _items.indexed) ...[
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
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(i.name, style: inter(14, 700)),
                            Text(tr(i.loose ? 'Loose' : 'Piece'), style: inter(12, 500, color: kMuted)),
                          ]),
                        ),
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
