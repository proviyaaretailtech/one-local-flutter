import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'document_flow.dart';
import 'inventory_api.dart';
import 'inventory_dashboard.dart';
import 'inventory_widgets.dart';

/// Figma "Receiving": verify a delivery before the goods-received note is approved. Counts, rejects with a reason, the supplier lot and expiry,
/// and a reconciliation. Drafts never change stock; "Send to GRN Review" then the approver posting it does.
class ReceivingScreen extends StatefulWidget {
  const ReceivingScreen({super.key, required this.env, this.documentId});
  final InvEnv env;
  final String? documentId;
  @override
  State<ReceivingScreen> createState() => _ReceivingScreenState();
}

class _ReceivingScreenState extends State<ReceivingScreen> {
  InvEnv get env => widget.env;
  late final DocFlow _f = DocFlow(env, 'receipt');
  final _scan = TextEditingController();
  final _supplier = TextEditingController();
  final _po = TextEditingController();
  final _invoice = TextEditingController();
  final _search = TextEditingController();
  List<DraftLine> _lines = [];
  int _sel = 0;
  String _tab = 'receiving';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _f.load(id: widget.documentId, open: const ['draft', 'review']);
    if (!mounted) return;
    _adopt();
    setState(() => _loaded = true);
  }

  void _adopt() {
    final d = _f.doc;
    if (d == null) return;
    _lines = d.lines.map(DraftLine.from).toList();
    _sel = _sel.clamp(0, _lines.isEmpty ? 0 : _lines.length - 1);
    _supplier.text = d.s('supplier_name');
    _po.text = d.s('po_ref');
    _invoice.text = d.s('invoice_ref');
    _tab = d.status == 'draft' ? 'receiving' : 'grn';
  }

  bool get _editable => _f.doc == null || _f.doc!.status == 'draft';

  Map<String, Object?> get _fields => {'supplier_name': _supplier.text.trim(), 'po_ref': _po.text.trim(), 'invoice_ref': _invoice.text.trim()};

  Future<bool> _save({String? done}) => _f.run(context, () => setState(() {}), () async {
        await _f.save(fields: _fields, lines: _lines);
        _adopt();
      }, done: done);

  Future<void> _submit() async {
    if (_lines.isEmpty) return showToast(context, 'Add at least one item first.');
    final ok = await _f.run(context, () => setState(() {}), () async {
      await _f.save(fields: _fields, lines: _lines);
      await _f.act('submit');
      _adopt();
    }, done: 'Sent to GRN review. Stock changes when the receipt is posted.');
    if (ok && mounted) setState(() {});
  }

  Future<void> _addItem({String? query}) async {
    Facts? item;
    if (query != null && query.trim().isNotEmpty) {
      final r = await _f.env.api.stock(q: query.trim(), pageSize: 2);
      final items = r.l('items');
      if (items.length == 1) item = items.first;
    }
    if (!mounted) return;
    item ??= await pickItem(context, env.api);
    if (item == null) return;
    setState(() {
      _lines.add(DraftLine(itemId: item!.s('id'), itemName: item.s('name'), sku: item.s('sku'), qty: 1, rejectedQty: 0));
      _sel = _lines.length - 1;
      _scan.clear();
    });
  }

  Future<void> _rejects(DraftLine l) async {
    final reasons = _f.options?.m('reasons').ls('reject') ?? const <String>[];
    num q = l.rejectedQty ?? 0;
    String? reason = l.rejectReason;
    final r = await showModalBottomSheet<(num, String?)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Rejected quantity / reason', style: inter(18, 700)),
            const InvLabel('Rejected units'),
            InvStepper(value: q, label: 'rejected quantity', onChanged: (v) => set(() => q = v.clamp(0, l.qty ?? 0))),
            const InvLabel('Reason'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final x in reasons)
                ChoiceChip(label: Text(x, style: inter(13, 500)), selected: reason == x, selectedColor: kLimeH, onSelected: (_) => set(() => reason = x)),
            ]),
            const SizedBox(height: 14),
            InvPrimary('Done', onPressed: () => Navigator.pop(ctx, (q, q > 0 ? reason : null))),
          ]),
        ),
      ),
    );
    if (r == null) return;
    if (r.$1 > 0 && r.$2 == null) {
      if (mounted) showToast(context, 'Choose a reason for the rejected units.');
      return;
    }
    setState(() {
      l.rejectedQty = r.$1;
      l.rejectReason = r.$2;
    });
  }

  Future<void> _lot(DraftLine l) async {
    final code = TextEditingController(text: l.lotCode ?? '');
    DateTime? exp = l.expiryDate;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New supplier lot / expiry', style: inter(18, 700)),
            const InvLabel('Lot code'),
            InvInput(controller: code, hint: 'CC-C'),
            const InvLabel('Expiry date'),
            InvPickBox(
              value: exp == null ? 'Choose a date' : dayMonth(exp!, year: true),
              semantic: 'Expiry date',
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(context: ctx, initialDate: exp ?? now.add(const Duration(days: 30)), firstDate: now.subtract(const Duration(days: 30)), lastDate: now.add(const Duration(days: 3650)));
                if (d != null) set(() => exp = d);
              },
            ),
            const SizedBox(height: 14),
            InvPrimary('Done', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    if (ok == true) {
      setState(() {
        l.lotCode = code.text.trim().isEmpty ? null : code.text.trim();
        l.expiryDate = exp;
      });
    }
  }

  @override
  Widget build(BuildContext context) => InvScaffold(env: env, onRefresh: _init, children: [
        const InvTitle('Receiving', subtitle: 'Verify physical deliveries before goods received note approval'),
        InvChips(active: _tab, onTap: _setTab, items: const [('receiving', 'Receiving', null), ('grn', 'GRN', null), ('putaway', 'Putaway', null)]),
        InvInput(controller: _search, hint: 'Search supplier, batch, invoice…', prefixIcon: LucideIcons.search, onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        if (!_loaded && _f.error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
        if (_f.error != null) ...[
          InvCard(child: Text(_f.error!, style: inter(13.5, 400, color: kRedText))),
          InvSecondary('Try again', onPressed: _init),
        ],
        if (_loaded && _f.error == null) ..._body(),
      ]);

  void _setTab(String id) {
    if (id == 'putaway') return env.later(context, 'Putaway');
    setState(() => _tab = id);
  }

  List<Widget> _body() {
    final d = _f.doc;
    final q = _search.text.trim().toLowerCase();
    final shown = _f.history.where((h) =>
        h.s('status') != 'posted' && h.s('status') != 'cancelled' && h.s('id') != d?.id &&
        (q.isEmpty || '${h.s('doc_no')} ${h.s('supplier_name')} ${h.s('invoice_ref')} ${h.s('po_ref')}'.toLowerCase().contains(q)));
    final prev = _f.history.where((h) => h.s('status') == 'posted' && (q.isEmpty || '${h.s('doc_no')} ${h.s('supplier_name')} ${h.s('invoice_ref')}'.toLowerCase().contains(q)));
    final inReview = d != null && d.status == 'review';
    final tabMatches = d == null ? true : (_tab == 'grn') == inReview;
    return [
      if (d == null || !tabMatches) ...docEmpty(_tab == 'grn' ? 'No receipt is waiting in GRN review.' : 'No receipt is open. Start one when a delivery arrives.',
          action: 'Scan / Enter Items', onAction: () async {
        _f.startNew();
        _lines = [];
        await _addItem();
        if (mounted) setState(() {});
      }),
      if (d != null && tabMatches) ..._receipt(d),
      for (final h in shown) DocHistoryCard(row: h, subtitle: h.s('supplier_name'), trailing: h.s('invoice_ref'), action: 'Open', onTap: () => _openOther(h.s('id'))),
      if (prev.isNotEmpty) const InvSection('Previous completed receipt'),
      for (final h in prev.take(3))
        InvCard(
          onTap: () => _openOther(h.s('id')),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(h.s('doc_no'), style: inter(16, 700))), InvDotChip.doc('receipt', 'posted')]),
            const SizedBox(height: 8),
            Text(h.s('supplier_name').isEmpty ? h.s('first_item') : h.s('supplier_name'), style: inter(15, 600)),
            Text('${h.s('invoice_ref').isEmpty ? '' : 'Invoice: ${h.s('invoice_ref')} | '}${h.t('posted_at') == null ? '' : '${dayMonth(h.t('posted_at')!)}, ${hm(h.t('posted_at')!)}'}', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text('Expected: ${qty(h.m('totals').n('expected'))} u | Received: ${qty(h.m('totals').n('received'))} u', style: inter(13, 400, color: kMuted))),
              Text('View Receipt', style: inter(13.5, 700, color: kLink)),
            ]),
          ]),
        ),
      InvFootnote(at: DateTime.now()),
    ];
  }

  Future<void> _openOther(String id) async {
    await _f.run(context, () => setState(() {}), () async {
      await _f.open(id);
      _adopt();
    });
  }

  List<Widget> _receipt(InvDocument d) {
    final editable = _editable;
    final expected = _lines.fold<num>(0, (a, l) => a + (l.expectedQty ?? 0));
    final hasExpected = _lines.any((l) => l.expectedQty != null);
    final received = _lines.fold<num>(0, (a, l) => a + (l.qty ?? 0));
    final rejected = _lines.fold<num>(0, (a, l) => a + (l.rejectedQty ?? 0));
    final accepted = received - rejected;
    final totals = d.raw['lines'] == null ? null : d;
    final cur = _lines.isEmpty ? null : _lines[_sel.clamp(0, _lines.length - 1)];
    final unit = cur == null ? 'unit' : (d.lines.where((x) => x.m('item').s('id') == cur.itemId).firstOrNull?.m('item').s('unit') ?? 'unit');
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d.number}${_supplier.text.trim().isEmpty ? '' : ' · ${_supplier.text.trim()}'}', style: inter(16.5, 700)),
              Text([if (_po.text.isNotEmpty) _po.text, if (_invoice.text.isNotEmpty) _invoice.text, if (d.t('created_at') != null) 'Today, ${hm(d.t('created_at')!)}'].join(' • '),
                  style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvDotChip.doc('receipt', d.status),
        ]),
        const SizedBox(height: 8),
        InvKV('Expected shipment', hasExpected ? units(expected) : '–'),
        InvKV('Received physical count', units(received)),
        InvKV('Accepted / rejected quarantine', '${qty(accepted)} / ${units(rejected)}'),
        InvKV('Quantity still to receive', hasExpected ? units((expected - received).clamp(0, double.infinity)) : '–'),
        if (_lines.isNotEmpty)
          InvNote(received >= expected && hasExpected
              ? 'Receipt complete.${rejected > 0 ? ' ${qty(rejected)} ${rejected == 1 ? 'unit is' : 'units are'} rejected; keep ${rejected == 1 ? 'it' : 'them'} in inbound quarantine, separate from current damaged stock.' : ''}'
              : 'Count what arrived, then send the receipt to GRN review.'),
      ])),
      if (editable) ...[
        if (_lines.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 8, children: [
              for (var i = 0; i < _lines.length; i++)
                ChoiceChip(label: Text(_lines[i].itemName, style: inter(13, 500)), selected: i == _sel, selectedColor: kLimeH, onSelected: (_) => setState(() => _sel = i)),
            ]),
          ),
        if (cur != null) _inspect(cur, unit),
      ],
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InvCardHead('Receipt reconciliation'),
        Row(children: [Expanded(child: Text('Product', style: inter(12.5, 400))), Text('Received / Accepted', style: inter(12.5, 400))]),
        const SizedBox(height: 6),
        for (final l in _lines)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: kGreyBg, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Expanded(child: Text(l.itemName, style: inter(14.5, 700, color: kAmberText))),
              Text(units(l.qty), style: inter(14, 700, color: kAmberText)),
              const SizedBox(width: 14),
              Text(units((l.qty ?? 0) - (l.rejectedQty ?? 0)), style: inter(14, 700, color: kAmberText)),
            ]),
          ),
        if (_lines.isEmpty) Text('Nothing counted yet.', style: inter(13.5, 400, color: kMuted)),
        if (_lines.isNotEmpty)
          InvNote('Do not sell these goods yet. Current available stock does not change until posting.'),
      ])),
      if (totals != null && d.status == 'review' && d.can('post'))
        InvPrimary('Post Receipt', busy: _f.busy, onPressed: () => _f.run(context, () => setState(() {}), () async {
              await _f.act('post');
              _adopt();
            }, done: 'Receipt posted. The accepted units are now in stock.')),
      if (d.status == 'review' && d.can('return')) InvSecondary('Return to Draft', onPressed: () => _f.run(context, () => setState(() {}), () async {
            await _f.act('return');
            _adopt();
          })),
      if (editable) ...[
        InvPrimary('Send to GRN Review', busy: _f.busy, onPressed: _submit),
        InvSecondary('Scan / Enter Items', onPressed: _addItem),
        InvSecondary('Review Discrepancies · ${qty(rejected)} ${rejected == 1 ? 'reject' : 'rejects'}', onPressed: () => _discrepancies(rejected)),
        InvSecondary('Save Draft', onPressed: () => _save(done: 'Draft saved.')),
      ],
    ];
  }

  void _discrepancies(num rejected) {
    final rows = _lines.where((l) => (l.rejectedQty ?? 0) > 0 || (l.expectedQty != null && l.expectedQty != l.qty)).toList();
    showOrderlessSheet(
      context,
      'Discrepancies',
      rows.isEmpty
          ? [Text('Everything counted matches what was expected.', style: inter(14, 400, color: kMuted))]
          : [
              for (final l in rows)
                InvKV(l.itemName, [
                  if ((l.rejectedQty ?? 0) > 0) '${qty(l.rejectedQty)} rejected · ${l.rejectReason ?? ''}',
                  if (l.expectedQty != null && l.expectedQty != l.qty) 'expected ${qty(l.expectedQty)}, got ${qty(l.qty)}',
                ].join(' · ')),
            ],
    );
  }

  Widget _inspect(DraftLine l, String unit) => InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InvCardHead('Count and inspect', subtitle: '${l.itemName} • ${l.sku}'),
        const InvLabel('Scan barcode / SKU'),
        SizedBox(
          height: 46,
          child: TextField(
            controller: _scan,
            style: inter(15, 400),
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => _addItem(query: v),
            decoration: InputDecoration(
              hintText: l.sku,
              hintStyle: inter(15, 400, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
            ),
          ),
        ),
        const InvLabel('Received quantity (units)'),
        InvStepper(value: l.qty ?? 0, label: 'received quantity', onChanged: (v) => setState(() {
          l.qty = v;
          if ((l.rejectedQty ?? 0) > v) l.rejectedQty = v;
        })),
        const InvLabel('Rejected quantity / reason'),
        InvPickBox(value: (l.rejectedQty ?? 0) > 0 ? '${qty(l.rejectedQty)} · ${l.rejectReason ?? 'Choose a reason'}' : 'None rejected', onTap: () => _rejects(l)),
        const InvLabel('New supplier lot / expiry'),
        InvPickBox(
            value: l.lotCode == null && l.expiryDate == null ? 'Add lot and expiry' : '${l.lotCode ?? '–'} / ${l.expiryDate == null ? '–' : dayMonth(l.expiryDate!, year: true)}',
            chevron: false,
            onTap: () => _lot(l)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text('Accepted = received − rejected', style: inter(13.5, 400, color: kMuted))),
          Text('${qty(l.qty)} − ${qty(l.rejectedQty ?? 0)} = ${qty((l.qty ?? 0) - (l.rejectedQty ?? 0))}', style: inter(14, 700)),
        ]),
      ]));
}

/// Small info sheet with rows.
void showOrderlessSheet(BuildContext context, String title, List<Widget> rows) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: inter(18, 700)),
          const SizedBox(height: 10),
          ...rows,
          const SizedBox(height: 10),
          InvPrimary('Close', onPressed: () => Navigator.pop(ctx)),
        ]),
      ),
    ),
  );
}
