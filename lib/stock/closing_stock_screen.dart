import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../api/live_sync.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'damage_flow.dart' show problem;
import 'prices_common.dart' show loadAllStock;
import 'stock_env.dart';
import 'stock_kit.dart';

/// Hands an .xlsx over (tests replace it): a save dialog on a phone or computer, a download in the browser.
Future<void> Function(Uint8List bytes, String name) saveSpreadsheet = (bytes, name) async {
  await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
};

/// Closing stock (founder, 29 Oct 2026: "closing stock should be enterable in the tabular format … exportable in Excel"): every stock item
/// in one table — item, unit, what the app has, the count typed in, the difference — with a search and All / Counted / Differences. The
/// counts are one stock count (an audit): Save keeps them, Finish count closes it, Fix the difference sends one correction for approval,
/// and Edit counts opens a finished one again. Export Excel writes the table as an .xlsx.
class ClosingStockScreen extends StatefulWidget {
  const ClosingStockScreen({super.key, required this.env, this.today});
  final StockEnv env;
  final DateTime? today;
  @override
  State<ClosingStockScreen> createState() => _ClosingStockScreenState();
}

class _ClosingStockScreenState extends State<ClosingStockScreen> {
  // KOT, KDS, orders and stock in step: re-read when the business's live channel says so (lib/api/live_sync.dart)
  late final VoidCallback _live;

  StockEnv get env => widget.env;
  List<Facts>? _items;
  InvDocument? _doc; // the count in progress, if any
  final _typed = <String, TextEditingController>{}; // item id → counted
  final _search = TextEditingController();
  String _q = '', _show = 'all';
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _live = LiveSync.watch({'stock'}, () {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    for (final c in _typed.values) {
      c.dispose();
    }
    _search.dispose();
    _live();
    super.dispose();
  }

  TextEditingController _box(String itemId) => _typed.putIfAbsent(itemId, () => TextEditingController()..addListener(() => setState(() {})));

  Future<void> _load() async {
    try {
      final all = await loadAllStock(env.api);
      final open = await env.api.documents('audit', statuses: ['draft', 'review'], limit: 1);
      final doc = open.isEmpty ? null : await env.api.document(open.first.s('id'));
      if (!mounted) return;
      setState(() {
        _items = all.items;
        _doc = doc;
        _error = null;
        for (final l in doc?.lines ?? const <Facts>[]) {
          final counted = l.no('counted_qty');
          if (counted != null) _box(l.m('item').s('id')).text = qty(counted);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// What the app has for an item: the count's own figure once it is on the count, else the stock list's.
  num _system(Facts it) {
    final line = _doc?.lines.where((l) => l.m('item').s('id') == it.s('id')).firstOrNull;
    return line?.no('system_qty') ?? (it.n('available') + it.n('reserved') + it.n('damaged'));
  }

  num? _counted(Facts it) => num.tryParse(_typed[it.s('id')]?.text.trim() ?? '');

  bool get _open => _doc == null || _doc!.status == 'draft';

  List<Facts> get _rows => [
        for (final it in _items ?? const <Facts>[])
          if ((_q.isEmpty || '${it.s('name')} ${it.s('sku')} ${it.s('category')}'.toLowerCase().contains(_q.toLowerCase())) &&
              (_show == 'all' ||
                  (_show == 'counted' && _counted(it) != null) ||
                  (_show == 'diff' && _counted(it) != null && _counted(it) != _system(it))))
            it,
      ];

  List<DraftLine> get _lines => [
        for (final it in _items ?? const <Facts>[])
          if (_counted(it) != null) DraftLine(itemId: it.s('id'), itemName: it.s('name'), sku: it.s('sku'), countedQty: _counted(it)),
      ];

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showToast(context, problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool finish = false}) async {
    final lines = _lines;
    if (lines.isEmpty) return showToast(context, 'Type the closing stock of at least one item.');
    await _run(() async {
      var d = _doc == null
          ? await env.api.createDraft('audit', fields: {'title': 'Closing stock'}, lines: lines, key: InventoryApi.newKey())
          : await env.api.saveDraft(_doc!.id, version: _doc!.version, lines: lines);
      if (finish) d = await env.api.act(d.id, 'submit', version: d.version);
      final fresh = await env.api.document(d.id);
      if (!mounted) return;
      setState(() => _doc = fresh);
      showToast(context, finish ? 'Closing stock finished (${lines.length} items). Fix the difference to correct the stock.' : 'Closing stock saved (${lines.length} items).');
    });
  }

  Future<void> _reopen() => _run(() async {
        final open = await env.api.act(_doc!.id, 'reopen', version: _doc!.version);
        final fresh = await env.api.document(open.id);
        if (mounted) setState(() => _doc = fresh);
      });

  Future<void> _fix() => _run(() async {
        final adj = await env.api.adjustmentFromAudit(_doc!.id);
        final sent = await env.api.act(adj.id, 'submit', version: adj.version);
        if (!mounted) return;
        showToast(context, 'Sent for approval as ${sent.number}. Stock changes once a manager approves it.');
        for (final c in _typed.values) {
          c.clear();
        }
        setState(() => _doc = null);
        await _load();
      });

  Future<void> _export() async {
    final t = widget.today ?? DateTime.now();
    final day = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    final rows = <List<Object?>>[
      // the same order as the table: the count right after the item
      ['Item', 'Code', 'Category', 'Closing stock (counted)', 'Unit', 'In the app', 'Difference'],
      for (final it in _items ?? const <Facts>[])
        [
          it.s('name'), it.s('sku'), it.s('category'), _counted(it), it.s('unit'), _system(it),
          _counted(it) == null ? null : num.parse((_counted(it)! - _system(it)).toStringAsFixed(3)),
        ],
    ];
    try {
      await saveSpreadsheet(buildXlsx('Closing stock $day', rows, widths: const [28, 14, 16, 22, 8, 12, 12]), 'closing-stock-$day.xlsx');
      if (mounted) showToast(context, 'Closing stock exported: closing-stock-$day.xlsx');
    } catch (e) {
      if (mounted) showToast(context, 'Could not save the Excel file. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final rows = _rows;
    final counted = (items ?? const <Facts>[]).where((it) => _counted(it) != null).length;
    final diffs = (items ?? const <Facts>[]).where((it) => _counted(it) != null && _counted(it) != _system(it)).length;
    return StockScaffold(
      env: env,
      title: 'Closing stock',
      line: 'Type what is on the shelf for each item. The difference is sent to a manager to fix the stock.',
      onRefresh: _load,
      children: [
        if (items == null)
          _error == null
              ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    Text(problem(_error!), textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                    const SizedBox(height: 10),
                    InvSecondary('Try again', onPressed: _load),
                  ]),
                )
        else ...[
          StockNumbers([
            StockNumber('${items.length}', 'Items'),
            StockNumber('$counted', 'Counted'),
            StockNumber('$diffs', 'Differences', color: diffs == 0 ? kPostedText : kRedText),
          ]),
          if (_doc != null) ...[
            const SizedBox(height: 8),
            Text('${_doc!.number} · ${_open ? 'being counted' : 'finished · fix the difference or edit the counts'}', key: const ValueKey('cs-doc'),
                style: inter(12.5, 600, color: kMuted)),
          ],
          const SizedBox(height: 12),
          InvInput(key: const ValueKey('cs-search'), controller: _search, hint: 'Search item, code or category', prefixIcon: LucideIcons.search,
              onChanged: (v) => setState(() => _q = v.trim())),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            for (final (k, label) in [('all', 'All'), ('counted', 'Counted ($counted)'), ('diff', 'Differences ($diffs)')])
              ChoiceChip(
                key: ValueKey('cs-show-$k'),
                label: Text(label, style: inter(13, 700, color: _show == k ? Colors.white : kInk)),
                selected: _show == k,
                selectedColor: kInk,
                backgroundColor: Colors.white,
                showCheckmark: false,
                onSelected: (_) => setState(() => _show = k),
              ),
          ]),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                key: const ValueKey('cs-table'),
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF3F4EE)),
                headingTextStyle: inter(12.5, 700, color: kMuted),
                dataTextStyle: inter(13.5, 500),
                dataRowMinHeight: 52,
                dataRowMaxHeight: 60,
                columnSpacing: 18,
                horizontalMargin: 12,
                columns: const [
                  // the count right after the item, so it is in view without scrolling (founder, 29 Oct 2026)
                  DataColumn(label: Text('Item', key: ValueKey('cs-col-item'))),
                  DataColumn(label: Text('Closing stock', key: ValueKey('cs-col-count'))),
                  DataColumn(label: Text('Unit', key: ValueKey('cs-col-unit'))),
                  DataColumn(label: Text('In the app', key: ValueKey('cs-col-system')), numeric: true),
                  DataColumn(label: Text('Difference', key: ValueKey('cs-col-diff')), numeric: true),
                ],
                rows: [
                  for (final it in rows)
                    DataRow(key: ValueKey('cs-row-${it.s('id')}'), cells: [
                      DataCell(ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(it.s('name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700)),
                          Text(it.s('sku'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 500, color: kMuted)),
                        ]),
                      )),
                      DataCell(SizedBox(
                        width: 92,
                        child: _open
                            ? TextField(
                                key: ValueKey('cs-count-${it.s('id')}'),
                                controller: _box(it.s('id')),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                textAlign: TextAlign.right,
                                style: inter(14, 700),
                                decoration: InputDecoration(
                                  hintText: '—',
                                  isDense: true,
                                  filled: true,
                                  fillColor: const Color(0xFFF8F9F4),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kLine)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: kLine)),
                                ),
                              )
                            : Text(_counted(it) == null ? '—' : qty(_counted(it)!), textAlign: TextAlign.right, style: inter(14, 700)),
                      )),
                      DataCell(Text(it.s('unit'), style: inter(13, 500, color: kMuted))),
                      DataCell(Text(qty(_system(it)), key: ValueKey('cs-system-${it.s('id')}'))),
                      DataCell(Builder(builder: (_) {
                        final c = _counted(it);
                        if (c == null) return Text('—', style: inter(13, 500, color: kMuted));
                        final d = c - _system(it);
                        return Text(d == 0 ? 'Matches' : signed(d), key: ValueKey('cs-diff-${it.s('id')}'),
                            style: inter(13, 700, color: d == 0 ? kPostedText : kRedText));
                      })),
                    ]),
                ],
              ),
            ),
          ),
          if (rows.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Center(child: Text('Nothing here.', style: inter(14, 500, color: kMuted)))),
          const SizedBox(height: 14),
          if (_open)
            Row(children: [
              Expanded(child: InvSecondary('Save', key: const ValueKey('cs-save'), onPressed: _busy ? null : () => _save())),
              const SizedBox(width: 10),
              Expanded(child: InvPrimary('Finish count', key: const ValueKey('cs-finish'), busy: _busy, onPressed: _busy ? null : () => _save(finish: true))),
            ])
          else ...[
            InvSecondary('Edit counts', key: const ValueKey('cs-reopen'), onPressed: _busy ? null : _reopen),
            const SizedBox(height: 10),
            InvPrimary('Fix the difference', key: const ValueKey('cs-fix'), busy: _busy, onPressed: _busy ? null : _fix),
          ],
          const SizedBox(height: 10),
          InvSecondary('Export Excel', key: const ValueKey('cs-export'), onPressed: _busy ? null : _export),
        ],
      ],
    );
  }
}
