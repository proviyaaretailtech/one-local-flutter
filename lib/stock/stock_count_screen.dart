import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../ui/theme.dart';
import 'damage_flow.dart' show problem;
import 'stock_env.dart';
import 'stock_kit.dart';
import '../ui/i18n.dart';

/// Count stock (Stock Audit, J.103 / G.64), kept small: count what is on the shelf, see the difference, finish, then "Fix the
/// difference" sends one correction for approval. A count never changes stock by itself.
class StockCountScreen extends StatefulWidget {
  const StockCountScreen({super.key, required this.env, this.itemId});
  final StockEnv env;
  final String? itemId;
  @override
  State<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends State<StockCountScreen> {
  StockEnv get env => widget.env;
  InvDocument? _doc; // the count being done
  List<Facts>? _open; // counts not finished yet
  final _typed = <String, TextEditingController>{}; // line id → counted
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _typed.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await env.api.documents('audit', statuses: ['draft', 'review'], limit: 10);
      if (mounted) setState(() => _open = rows);
    } catch (e) {
      if (mounted) {
        setState(() => _open = const []);
        showToast(context, problem(e));
      }
    }
  }

  void _show(InvDocument d) {
    for (final c in _typed.values) {
      c.dispose();
    }
    _typed.clear();
    for (final l in d.lines) {
      final counted = l.no('counted_qty');
      _typed[l.s('id')] = TextEditingController(text: counted == null ? '' : qty(counted))..addListener(() => setState(() {}));
    }
    setState(() => _doc = d);
  }

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

  /// A new count: the products picked one by one (or the one this page was opened for).
  Future<void> _start() async {
    final picked = <Facts>[];
    if (widget.itemId != null) {
      picked.add((await env.api.stockDetail(widget.itemId!)).m('item'));
    } else {
      final it = await pickItem(context, env.api);
      if (it == null) return;
      picked.add(it);
    }
    await _run(() async {
      final d = await env.api.createDraft('audit',
          fields: {'title': 'Stock count'}, lines: [for (final it in picked) DraftLine(itemId: it.s('id'), itemName: it.s('name'), sku: it.s('sku'))], key: InventoryApi.newKey());
      _show(await env.api.document(d.id));
    });
  }

  Future<void> _addProduct() async {
    final d = _doc;
    if (d == null) return;
    final it = await pickItem(context, env.api);
    if (it == null || d.lines.any((l) => l.m('item').s('id') == it.s('id'))) return;
    await _run(() async {
      final lines = [..._lines(d), DraftLine(itemId: it.s('id'), itemName: it.s('name'), sku: it.s('sku'))];
      final saved = await env.api.saveDraft(d.id, version: d.version, lines: lines);
      _show(await env.api.document(saved.id));
    });
  }

  List<DraftLine> _lines(InvDocument d) => [
        for (final l in d.lines)
          DraftLine.from(l)..countedQty = num.tryParse(_typed[l.s('id')]?.text.trim() ?? ''),
      ];

  Future<void> _save({bool finish = false}) async {
    final d = _doc;
    if (d == null) return;
    if (finish && _lines(d).any((l) => l.countedQty == null)) return showToast(context, 'Type a count for every product first.');
    await _run(() async {
      var saved = await env.api.saveDraft(d.id, version: d.version, lines: _lines(d));
      if (finish) saved = await env.api.act(saved.id, 'submit', version: saved.version);
      _show(await env.api.document(saved.id));
      if (mounted) showToast(context, finish ? 'Count finished. Fix the difference to correct the stock.' : 'Count saved.');
    });
  }

  /// A finished count goes back to being counted, so its quantities can be changed before the difference is fixed.
  Future<void> _reopen() async {
    final d = _doc;
    if (d == null) return;
    await _run(() async {
      final open = await env.api.act(d.id, 'reopen', version: d.version);
      _show(await env.api.document(open.id));
      if (mounted) showToast(context, 'Change the counts, then Finish count again.');
    });
  }

  /// − / + on a count: one at a time (pieces) or a tenth (kg, litres), never below zero.
  void _step(Facts l, num by) {
    final c = _typed[l.s('id')]!;
    final now = num.tryParse(c.text.trim()) ?? l.n('system_qty');
    final next = (now + by) < 0 ? 0 : now + by;
    c.text = qty(double.parse(next.toStringAsFixed(3)));
  }

  Future<void> _fix() async {
    final d = _doc;
    if (d == null) return;
    await _run(() async {
      final adj = await env.api.adjustmentFromAudit(d.id);
      final sent = await env.api.act(adj.id, 'submit', version: adj.version);
      if (mounted) showToast(context, 'Sent for approval as ${sent.number}. Stock changes once a manager approves it.');
      setState(() => _doc = null);
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) => StockScaffold(
        env: env,
        title: tr('Count stock'),
        line: tr('Count what is on the shelf. The difference is sent to a manager to fix the stock.'),
        onRefresh: _load,
        children: _doc == null ? _list() : _counting(_doc!),
      );

  List<Widget> _list() => [
        InvPrimary(tr('Start a count'), key: const ValueKey('count-start'), busy: _busy, onPressed: _busy ? null : _start),
        const SizedBox(height: 16),
        if (_open == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (_open!.isEmpty)
          StockEmpty(tr('No count in progress'), 'Start a count when you want to check the shelf against the app.', icon: LucideIcons.clipboardCheck)
        else
          for (final r in _open!)
            InvCard(
              key: ValueKey('count-${r.s('id')}'),
              onTap: () => _run(() async => _show(await env.api.document(r.s('id')))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.s('doc_no'), style: inter(15, 700)),
                    Text(r.s('status') == 'review' ? 'Finished · fix the difference' : 'Being counted', style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
                const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
              ]),
            ),
      ];

  List<Widget> _counting(InvDocument d) {
    final open = d.status == 'draft';
    num system = 0, counted = 0;
    for (final l in d.lines) {
      system += l.n('system_qty');
      counted += num.tryParse(_typed[l.s('id')]?.text.trim() ?? '') ?? 0;
    }
    return [
      Row(children: [
        Expanded(child: Text(d.number, style: inter(17, 700))),
        TextButton(onPressed: () => setState(() => _doc = null), child: Text(tr('All counts'), style: inter(13.5, 700, color: kLink))),
      ]),
      const SizedBox(height: 8),
      StockNumbers([StockNumber(qty(system), 'In the app'), StockNumber(qty(counted), 'Counted'), StockNumber(signed(counted - system), 'Difference', color: counted == system ? kPostedText : kRedText)]),
      const SizedBox(height: 12),
      for (final l in d.lines) _line(l, open),
      if (open) ...[
        InvSecondary(tr('Add product'), onPressed: _busy ? null : _addProduct),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: InvSecondary(tr('Save'), onPressed: _busy ? null : () => _save())),
          const SizedBox(width: 10),
          Expanded(child: InvPrimary(tr('Finish count'), key: const ValueKey('count-finish'), busy: _busy, onPressed: _busy ? null : () => _save(finish: true))),
        ]),
      ] else if (d.b('can_draft_adjustment') || d.status == 'review') ...[
        // a finished count can still be corrected before the difference is sent
        if (d.status == 'review') ...[
          InvSecondary(tr('Edit counts'), key: const ValueKey('count-reopen'), onPressed: _busy ? null : _reopen),
          const SizedBox(height: 10),
        ],
        InvPrimary(tr('Fix the difference'), key: const ValueKey('count-fix'), busy: _busy, onPressed: _busy ? null : _fix),
      ],
    ];
  }

  Widget _stepButton(IconData icon, String key, VoidCallback onTap) => Material(
        color: kBg,
        shape: const CircleBorder(),
        child: InkWell(
          key: ValueKey(key),
          customBorder: const CircleBorder(),
          onTap: _busy ? null : onTap,
          child: SizedBox(width: 42, height: 42, child: Icon(icon, size: 18, color: kInk)),
        ),
      );

  Widget _line(Facts l, bool open) {
    final c = _typed[l.s('id')]!;
    final typed = num.tryParse(c.text.trim());
    final diff = typed == null ? null : typed - l.n('system_qty');
    final unit = l.m('item').s('unit');
    final step = const {'kg', 'l', 'litre', 'ltr'}.contains(unit.toLowerCase()) ? 0.1 : 1;
    return InvCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(l.m('item').s('name'), style: inter(15, 700))),
          if (diff != null) StockStatusChip(diff == 0 ? 'healthy' : 'critical', label: diff == 0 ? 'Matches' : signed(diff)),
        ]),
        StockRow(tr('In the app'), '${qty(l.n('system_qty'))} $unit'.trim()),
        if (open)
          // the count, typed or stepped, in the item's unit (0.5 kg, 12 pc)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              _stepButton(LucideIcons.minus, 'count-minus-${l.s('id')}', () => _step(l, -step)),
              const SizedBox(width: 8),
              Expanded(
                child: InvInput(
                  key: ValueKey('count-qty-${l.s('id')}'),
                  controller: c,
                  number: true,
                  label: tr('Counted'),
                  hint: tr('How many did you count?'),
                  suffix: unit.isEmpty
                      ? null
                      : Padding(padding: const EdgeInsets.only(right: 12, top: 13), child: Text(unit, key: ValueKey('count-unit-${l.s('id')}'), style: inter(14, 600, color: kMuted))),
                ),
              ),
              const SizedBox(width: 8),
              _stepButton(LucideIcons.plus, 'count-plus-${l.s('id')}', () => _step(l, step)),
            ]),
          )
        else
          StockRow(tr('Counted'), typed == null ? '—' : '${qty(typed)} $unit'.trim()),
      ]),
    );
  }
}
