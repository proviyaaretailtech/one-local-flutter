import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../catalogue/catalogue_api.dart';
import '../catalogue/quick_add_screen.dart';
import '../catalogue/grn_screens.dart' show GrnDashboardScreen;
import '../stock/lot_labels_screen.dart' show offerLotLabels;
import '../ui/purchase_steps.dart';
import '../ui/theme.dart';
import 'document_flow.dart';
import 'inv_env.dart';
import 'inventory_api.dart';
import 'inventory_widgets.dart';
import '../ui/i18n.dart';

/// Step 3 after counting: the supplier's bill is matched on its own page (it replaces this one). Tests replace it.
void Function(BuildContext context, String receiptId) openMatchBill = (context, receiptId) =>
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => GrnDashboardScreen(receiptId: receiptId)));

/// A product that is not in the shop yet, made while receiving (founder, 26 Oct 2026): Quick add without "In stock now", since the
/// receipt note counts it. Answers the new stock item (id, name, System Code), or null when closed. Tests replace it.
Future<Facts?> Function(BuildContext context) newItemForReceiving = (context) async {
  final made = await Navigator.of(context).push<CatItem>(MaterialPageRoute(builder: (_) => QuickAddScreen(api: CatalogueApi(), receiving: true)));
  final inv = made?.raw['inventory_item_id']?.toString();
  if (made == null || inv == null) return null;
  return Facts({'id': inv, 'name': made.name, 'sku': made.sku});
};

/// A receipt note (Figma "Receiving", founder's receiving rules of 26 Oct 2026): count a delivery, with or without a purchase order.
/// Items can be added that were not ordered, or that are not in the shop yet (+ New item); damaged units are marked per line; lines
/// that differ from the order are flagged. Drafts never change stock; "Send to check" then the approver posting it does, and the
/// whole lot's labels come next.
class ReceivingScreen extends StatefulWidget {
  const ReceivingScreen({super.key, required this.env, this.documentId, this.startNew = false});
  final InvEnv env;
  final String? documentId;

  /// + Add Purchase: a new receipt note, even when another one is still being counted.
  final bool startNew;
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
  bool _loaded = false;
  bool _new = false; // a new receipt note, not saved yet

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _f.load(id: widget.documentId, open: widget.startNew ? const [] : const ['draft', 'review']);
    if (!mounted) return;
    if (widget.startNew && _f.doc == null) _new = true;
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
    }, done: 'Counted. Now match the supplier bill.');
    if (!ok || !mounted) return;
    setState(() {});
    final id = _f.doc?.id;
    if (id != null) openMatchBill(context, id); // step 3
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
      final at = _lines.indexWhere((l) => l.itemId == item!.s('id'));
      if (at >= 0) {
        _lines[at].qty = (_lines[at].qty ?? 0) + 1; // scanned again: one more
        _sel = at;
      } else {
        _lines.add(DraftLine(itemId: item!.s('id'), itemName: item.s('name'), sku: item.s('sku'), qty: 1, rejectedQty: 0));
        _sel = _lines.length - 1;
      }
      _scan.clear();
    });
  }

  /// + New item: a product the shop does not have yet, added to the lot.
  Future<void> _newItem() async {
    final item = await newItemForReceiving(context);
    if (item == null || !mounted) return;
    setState(() {
      _lines.add(DraftLine(itemId: item.s('id'), itemName: item.s('name'), sku: item.s('sku'), qty: 1, rejectedQty: 0));
      _sel = _lines.length - 1;
    });
    showToast(context, '${item.s('name')} added to the shop and to this receipt note.');
  }

  /// This note came from a purchase order: its lines carry what was ordered.
  bool get _fromOrder => _lines.any((l) => l.expectedQty != null);

  /// How a line differs from the order: not ordered, short or extra (null when it matches, or there is no order).
  String? _vsOrder(DraftLine l) {
    if (!_fromOrder) return null;
    final e = l.expectedQty, q = l.qty ?? 0;
    if (e == null) return tr('Not on order');
    if (q < e) return '${tr('Short')} ${qty(e - q)}';
    if (q > e) return '${tr('Extra')} ${qty(q - e)}';
    return null;
  }

  String _flags(DraftLine l) => [if (_vsOrder(l) != null) _vsOrder(l)!, if ((l.rejectedQty ?? 0) > 0) '${qty(l.rejectedQty)} ${tr('damaged')}'].join(' · ');

  Future<void> _rejects(DraftLine l) async {
    final reasons = ['Damaged', ...?_f.options?.m('reasons').ls('reject').where((x) => x != 'Damaged')];
    num q = l.rejectedQty ?? 0;
    String? reason = l.rejectReason ?? 'Damaged';
    final r = await showModalBottomSheet<(num, String?)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Damaged'), style: inter(18, 700)),
            InvLabel(tr('Damaged units')),
            InvStepper(value: q, label: 'damaged quantity', onChanged: (v) => set(() => q = v.clamp(0, l.qty ?? 0))),
            InvLabel(tr('Reason')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final x in reasons)
                ChoiceChip(label: Text(x, style: inter(13, 500)), selected: reason == x, selectedColor: kLimeH, onSelected: (_) => set(() => reason = x)),
            ]),
            const SizedBox(height: 14),
            InvPrimary(tr('Done'), onPressed: () => Navigator.pop(ctx, (q, q > 0 ? reason : null))),
          ]),
        ),
      ),
    );
    if (r == null) return;
    if (r.$1 > 0 && r.$2 == null) {
      if (mounted) showToast(context, 'Choose what is wrong with the damaged units.');
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
            Text(tr('New supplier lot / expiry'), style: inter(18, 700)),
            InvLabel(tr('Lot code')),
            InvInput(controller: code, hint: 'CC-C'),
            InvLabel(tr('Expiry date')),
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
            InvPrimary(tr('Done'), onPressed: () => Navigator.pop(ctx, true)),
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
        // no tab strip (founder, 26 Oct 2026): checking, putaway and labels are buttons on the delivery once it is counted
        const PurchaseSteps(2),
        InvTitle(tr('Receive goods'), subtitle: tr('Count what arrived, mark anything damaged, then match the supplier bill.')),
        InvInput(controller: _search, hint: tr('Search supplier, batch, invoice…'), prefixIcon: LucideIcons.search, onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        if (!_loaded && _f.error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk))),
        if (_f.error != null) ...[
          InvCard(child: Text(_f.error!, style: inter(13.5, 400, color: kRedText))),
          InvSecondary(tr('Try again'), onPressed: _init),
        ],
        if (_loaded && _f.error == null) ..._body(),
      ]);

  List<Widget> _body() {
    final d = _f.doc;
    final q = _search.text.trim().toLowerCase();
    final shown = _f.history.where((h) =>
        h.s('status') != 'posted' && h.s('status') != 'cancelled' && h.s('id') != d?.id &&
        (q.isEmpty || '${h.s('doc_no')} ${h.s('supplier_name')} ${h.s('invoice_ref')} ${h.s('po_ref')}'.toLowerCase().contains(q)));
    final prev = _f.history.where((h) => h.s('status') == 'posted' && (q.isEmpty || '${h.s('doc_no')} ${h.s('supplier_name')} ${h.s('invoice_ref')}'.toLowerCase().contains(q)));
    return [
      if (d == null && _new) ..._receipt(null),
      if (d == null && !_new) ...docEmpty('No delivery is open. Start one when a delivery arrives.',
          action: tr('Scan / Enter Items'), onAction: () async {
        _f.startNew();
        _lines = [];
        await _addItem();
        if (mounted) setState(() {});
      }),
      if (d != null) ..._receipt(d),
      // the other receipt notes are listed on Purchase; this only shows them when opened on its own
      if (!_listed) for (final h in shown) DocHistoryCard(row: h, subtitle: h.s('supplier_name'), trailing: h.s('invoice_ref'), action: tr('Open'), onTap: () => _openOther(h.s('id'))),
      if (!_listed && prev.isNotEmpty) const InvSection('Previous completed receipt'),
      if (!_listed) for (final h in prev.take(3))
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
              Text(tr('View Receipt'), style: inter(13.5, 700, color: kLink)),
            ]),
          ]),
        ),
      InvFootnote(at: DateTime.now()),
    ];
  }

  bool get _listed => widget.startNew || widget.documentId != null;

  Future<void> _openOther(String id) async {
    await _f.run(context, () => setState(() {}), () async {
      await _f.open(id);
      _adopt();
    });
  }

  List<Widget> _receipt(InvDocument? d) {
    final editable = _editable;
    final expected = _lines.fold<num>(0, (a, l) => a + (l.expectedQty ?? 0));
    final hasExpected = _lines.any((l) => l.expectedQty != null);
    final received = _lines.fold<num>(0, (a, l) => a + (l.qty ?? 0));
    final rejected = _lines.fold<num>(0, (a, l) => a + (l.rejectedQty ?? 0));
    final accepted = received - rejected;
    final totals = d?.raw['lines'] == null ? null : d;
    final cur = _lines.isEmpty ? null : _lines[_sel.clamp(0, _lines.length - 1)];
    final unit = cur == null || d == null ? 'unit' : (d.lines.where((x) => x.m('item').s('id') == cur.itemId).firstOrNull?.m('item').s('unit') ?? 'unit');
    return [
      InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d?.number ?? tr('New receipt note')}${_supplier.text.trim().isEmpty ? '' : ' · ${_supplier.text.trim()}'}', style: inter(16.5, 700)),
              Text([if (_po.text.isNotEmpty) _po.text, if (_invoice.text.isNotEmpty) _invoice.text, if (d?.t('created_at') != null) 'Today, ${hm(d!.t('created_at')!)}'].join(' • '),
                  style: inter(12.5, 400, color: kMuted)),
            ]),
          ),
          InvDotChip.doc('receipt', d?.status ?? 'draft'),
        ]),
        if (editable) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: InvInput(key: const ValueKey('receiving-supplier'), controller: _supplier, hint: tr('Supplier'), onChanged: (_) => setState(() {}))),
            const SizedBox(width: 8),
            Expanded(child: InvInput(key: const ValueKey('receiving-invoice'), controller: _invoice, hint: tr('Invoice no.'), onChanged: (_) => setState(() {}))),
          ]),
        ],
        const SizedBox(height: 8),
        InvKV('Expected shipment', hasExpected ? units(expected) : '–'),
        InvKV('Received physical count', units(received)),
        InvKV('Good / damaged', '${qty(accepted)} / ${units(rejected)}'),
        InvKV('Quantity still to receive', hasExpected ? units((expected - received).clamp(0, double.infinity)) : '–'),
        if (_lines.isNotEmpty)
          InvNote(received >= expected && hasExpected
              ? 'Receipt complete.${rejected > 0 ? ' ${qty(rejected)} ${rejected == 1 ? 'unit is' : 'units are'} damaged; keep ${rejected == 1 ? 'it' : 'them'} aside, separate from the stock you sell.' : ''}'
              : 'Count what arrived, then send it to be checked.'),
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
        InvCardHead(tr('Receipt reconciliation')),
        Row(children: [Expanded(child: Text(tr('Product'), style: inter(12.5, 400))), Text(tr('Received / Good'), style: inter(12.5, 400))]),
        const SizedBox(height: 6),
        for (final l in _lines)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: kGreyBg, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.itemName, style: inter(14.5, 700, color: kAmberText)),
                  if (_flags(l).isNotEmpty) Text(_flags(l), key: ValueKey('receiving-flag-${l.itemId}'), style: inter(12, 600, color: kRedText)),
                ]),
              ),
              Text(units(l.qty), style: inter(14, 700, color: kAmberText)),
              const SizedBox(width: 14),
              Text(units((l.qty ?? 0) - (l.rejectedQty ?? 0)), style: inter(14, 700, color: kAmberText)),
            ]),
          ),
        if (_lines.isEmpty) Text(tr('Nothing counted yet.'), style: inter(13.5, 400, color: kMuted)),
        if (_lines.isNotEmpty)
          InvNote(tr('Do not sell these goods yet. Current available stock does not change until posting.')),
      ])),
      if (totals != null && totals.status == 'review' && totals.can('post'))
        InvPrimary(tr('Post Receipt'), busy: _f.busy, onPressed: () => _f.run(context, () => setState(() {}), () async {
              await _f.act('post');
              _adopt();
            }, done: 'Receipt posted. The good units are now in stock.').then((ok) {
              if (ok && mounted && _f.doc != null) offerLotLabels(context, _f.doc!.id);
            })),
      if (d != null && d.status == 'review' && d.can('return')) InvSecondary(tr('Return to Draft'), onPressed: () => _f.run(context, () => setState(() {}), () async {
            await _f.act('return');
            _adopt();
          })),
      if (editable) ...[
        Row(children: [
          Expanded(child: InvSecondary(tr('Scan / add item'), key: const ValueKey('receiving-add'), onPressed: _addItem)),
          const SizedBox(width: 8),
          Expanded(child: InvSecondary(tr('+ New item'), key: const ValueKey('receiving-new-item'), onPressed: _newItem)),
        ]),
        InvPrimary(tr('Done counting · Match bill'), key: const ValueKey('receiving-done'), busy: _f.busy, onPressed: _submit),
        if (_lines.isNotEmpty) InvSecondary('${tr('Differences')} · ${_lines.where((l) => _flags(l).isNotEmpty).length}', onPressed: () => _discrepancies(rejected)),
        InvSecondary(tr('Save Draft'), onPressed: () => _save(done: 'Draft saved.')),
      ],
    ];
  }

  void _discrepancies(num rejected) {
    final rows = _lines.where((l) => _flags(l).isNotEmpty).toList();
    showOrderlessSheet(
      context,
      'Discrepancies',
      rows.isEmpty
          ? [Text(tr('Everything counted matches the order.'), style: inter(14, 400, color: kMuted))]
          : [
              for (final l in rows)
                InvKV(l.itemName, [
                  if ((l.rejectedQty ?? 0) > 0) '${qty(l.rejectedQty)} damaged · ${l.rejectReason ?? ''}',
                  if (_fromOrder && l.expectedQty == null) 'not on the order',
                  if (l.expectedQty != null && l.expectedQty != l.qty) 'ordered ${qty(l.expectedQty)}, got ${qty(l.qty)}',
                ].join(' · ')),
            ],
    );
  }

  Widget _inspect(DraftLine l, String unit) => InvCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InvCardHead(tr('Count and inspect'), subtitle: '${l.itemName} • ${l.sku}'),
        InvLabel(tr('Scan barcode / System Code')),
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
        InvLabel(tr('Received quantity (units)')),
        InvStepper(value: l.qty ?? 0, label: 'received quantity', onChanged: (v) => setState(() {
          l.qty = v;
          if ((l.rejectedQty ?? 0) > v) l.rejectedQty = v;
        })),
        InvLabel(tr('Damaged')),
        InvPickBox(key: const ValueKey('receiving-damaged'), value: (l.rejectedQty ?? 0) > 0 ? '${qty(l.rejectedQty)} · ${l.rejectReason ?? 'Damaged'}' : tr('None damaged'), onTap: () => _rejects(l)),
        InvLabel(tr('New supplier lot / expiry')),
        InvPickBox(
            value: l.lotCode == null && l.expiryDate == null ? 'Add lot and expiry' : '${l.lotCode ?? '–'} / ${l.expiryDate == null ? '–' : dayMonth(l.expiryDate!, year: true)}',
            chevron: false,
            onTap: () => _lot(l)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(tr('Good = received − damaged'), style: inter(13.5, 400, color: kMuted))),
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
          InvPrimary(tr('Close'), onPressed: () => Navigator.pop(ctx)),
        ]),
      ),
    ),
  );
}
