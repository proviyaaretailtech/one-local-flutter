import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/net_guard.dart';
import '../home/home_nav.dart';
import '../ui/app_header.dart';
import '../ui/mobile_input.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'rst_money.dart';
import 'rst_money_api.dart';

// Money in, Money out and Transfer for the restaurant (the store's design, 0622). Money in / out: the total for the dates with the number of
// entries, Add money / Pay money, PDF, the method pills and the list. Transfer: a contact, the amount, what it is for, then a UPI app with
// the amount filled in (the owner pays there and says it went through) or card; and moving money between the restaurant's own accounts.

/// What money coming in or going out is for.
const kRmIn = [
  ('sales', 'Sale / counter collection'),
  ('due_received', 'Customer paid due'),
  ('other_income', 'Manual income'),
  ('aggregator_settlement', 'Swiggy / Zomato settlement'),
  ('owner_in', 'Capital infusion'),
  ('other_in', 'Other'),
];
const kRmOut = [
  ('expense', 'Expense'),
  ('purchase', 'Purchase / raw material'),
  ('supplier_payment', 'Supplier payment'),
  ('salary', 'Salary / wages'),
  ('rent', 'Rent'),
  ('owner_out', 'Owner withdrawal'),
  ('refund', 'Refund to customer'),
  ('other_out', 'Other'),
];
const kRmMethods = [('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card'), ('bank', 'Bank')];
const _methodNames = {'cash': 'Cash', 'upi': 'UPI', 'gpay': 'GPay', 'phonepe': 'PhonePe', 'card': 'Card', 'bank': 'Bank', 'online': 'Online'};
const _methodIcons = {
  'cash': LucideIcons.banknote,
  'upi': LucideIcons.smartphone,
  'gpay': LucideIcons.smartphone,
  'phonepe': LucideIcons.smartphone,
  'card': LucideIcons.creditCard,
  'bank': LucideIcons.landmark,
  'online': LucideIcons.globe,
};

String _kindWord(String k) => [...kRmIn, ...kRmOut].where((e) => e.$1 == k).map((e) => e.$2).firstOrNull ?? k;

/// The dates a list can show.
const _ranges = [('today', 'Today'), ('yesterday', 'Yesterday'), ('week', 'Last 7 days'), ('month', 'This month')];

/// Money in or Money out.
class RstMoneyFlowScreen extends StatefulWidget {
  const RstMoneyFlowScreen({super.key, required this.api, required this.direction, this.canRecord = true, this.canVoid = false, this.today, this.sharePdf});
  final RstMoneyApi api;
  final String direction; // in | out
  final bool canRecord, canVoid;
  final DateTime? today;

  /// Hands the PDF over (tests pass their own); by default the share / save sheet.
  final Future<void> Function(Uint8List pdf, String name)? sharePdf;
  @override
  State<RstMoneyFlowScreen> createState() => _RstMoneyFlowScreenState();
}

class _RstMoneyFlowScreenState extends State<RstMoneyFlowScreen> {
  String _range = 'today', _method = 'all';
  Map<String, dynamic>? _d;
  String? _error;

  bool get _in => widget.direction == 'in';

  (String, String) get _dates {
    final t = widget.today ?? DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    return switch (_range) {
      'yesterday' => (isoDay(day.subtract(const Duration(days: 1))), isoDay(day.subtract(const Duration(days: 1)))),
      'week' => (isoDay(day.subtract(const Duration(days: 6))), isoDay(day)),
      'month' => (isoDay(DateTime(day.year, day.month)), isoDay(day)),
      _ => (isoDay(day), isoDay(day)),
    };
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (from, to) = _dates;
    try {
      final d = await widget.api.entries(direction: widget.direction, method: _method, from: from, to: to);
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _add() async {
    final saved = await showRmEntrySheet(context, api: widget.api, direction: widget.direction);
    if (saved && mounted) _load();
  }

  Future<void> _pdf() async {
    final d = _d;
    if (d == null) return;
    final rows = (d['rows'] as List? ?? const []).cast<Map>();
    final title = _in ? 'Money in' : 'Money out';
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      build: (_) => [
        pw.Text('${HomeNav.storeName ?? 'Restaurant'} · $title', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('${dayMonth(d['from'] as String?)} – ${dayMonth(d['to'] as String?)} · ${d['count']} entries · Rs ${rs(d['total_minor'] as num?).substring(1)}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: ['Date', 'Entry', 'Method', 'Amount (Rs)'],
          data: [
            for (final r in rows)
              [dayMonth(r['day'] as String?), '${r['title']}${r['party'] == null ? '' : ' · ${r['party']}'}', _methodNames[r['method']] ?? '${r['method'] ?? ''}', rs(r['amount_minor'] as num?).substring(1)],
          ],
        ),
      ],
    ));
    final bytes = await doc.save();
    final name = '${title.toLowerCase().replaceAll(' ', '-')}-${d['from']}-to-${d['to']}.pdf';
    await (widget.sharePdf ?? (b, n) => Printing.sharePdf(bytes: b, filename: n))(bytes, name);
  }

  Future<void> _details(Map<String, dynamic> r) async {
    final removed = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => _EntryDetails(api: widget.api, entry: r, canVoid: widget.canVoid),
    );
    if (removed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final rows = (d?['rows'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final count = (d?['count'] as num?)?.toInt() ?? 0;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: _in ? 'Money in' : 'Money out', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(key: ValueKey('rm-flow-${widget.direction}'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
              RmDarkCard(
                padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(_in ? 'Money in' : 'Money out', style: inter(14, 500, color: const Color(0xFFB8BCC4)))),
                    PopupMenuButton<String>(
                      key: const ValueKey('rm-range'),
                      initialValue: _range,
                      onSelected: (v) {
                        setState(() => _range = v);
                        _load();
                      },
                      itemBuilder: (_) => [for (final (id, label) in _ranges) PopupMenuItem(value: id, child: Text(label, style: inter(14, 600)))],
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(LucideIcons.calendar, size: 15, color: kRmLime),
                          const SizedBox(width: 6),
                          Text(_ranges.firstWhere((r) => r.$1 == _range).$2, style: inter(13, 700, color: Colors.white)),
                          const SizedBox(width: 4),
                          const Icon(LucideIcons.chevronDown, size: 15, color: Colors.white),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(rs(d?['total_minor'] as num?), key: const ValueKey('rm-flow-total'), style: inter(36, 800, color: Colors.white))),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: _in ? kRmLime : const Color(0xFFFF8A80), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 13, color: kRmDeep),
                      const SizedBox(width: 4),
                      Text('$count ${count == 1 ? 'entry' : 'entries'}', key: const ValueKey('rm-flow-count'), style: inter(12, 800, color: kRmDeep)),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: FilledButton(
                        key: ValueKey('rm-${_in ? 'add' : 'pay'}'),
                        style: FilledButton.styleFrom(backgroundColor: kRmLime, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        onPressed: widget.canRecord ? _add : null,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(_in ? 'Add money' : 'Pay money', style: inter(16, 800, color: kRmDeep)),
                          const SizedBox(width: 8),
                          Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 18, color: kRmDeep),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: kRmDeepSoft,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        key: const ValueKey('rm-pdf'),
                        borderRadius: BorderRadius.circular(16),
                        onTap: d == null ? null : _pdf,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                          child: Row(children: [
                            const Icon(LucideIcons.fileDown, size: 18, color: Colors.white),
                            const SizedBox(width: 6),
                            Text('PDF', style: inter(14, 800, color: Colors.white)),
                          ]),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              RmPills(
                keyPrefix: 'rm-method',
                options: const [('all', 'All'), ('cash', 'Cash'), ('upi', 'UPI'), ('card', 'Card')],
                selected: _method,
                onSelect: (m) {
                  setState(() => _method = m);
                  _load();
                },
              ),
              const SizedBox(height: 14),
              Text(_in ? 'Money received' : 'Money paid', style: inter(17, 800)),
              const SizedBox(height: 8),
              if (d == null)
                Padding(
                  padding: const EdgeInsets.all(30),
                  child: Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : Column(children: [
                            Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                            const SizedBox(height: 10),
                            OutlinedButton(onPressed: _load, child: Text('Try again', style: inter(14, 600))),
                          ]),
                  ),
                )
              else if (rows.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 40), child: Center(child: Text('Nothing in these dates.', style: inter(14, 500, color: kMuted))))
              else
                for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 10), child: _row(r)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final method = '${r['method'] ?? ''}';
    final party = (r['party'] as String?)?.trim();
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: ValueKey('rm-row-${r['id']}'),
        borderRadius: BorderRadius.circular(22),
        onTap: () => _details(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: _in ? const Color(0xFFEFF8D6) : const Color(0xFFFFEDEA), borderRadius: BorderRadius.circular(16)),
              child: Icon(_methodIcons[method] ?? LucideIcons.wallet, size: 20, color: _in ? kRmGreen : kRmRed),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 700)),
                const SizedBox(height: 2),
                Text(
                  [_methodNames[method] ?? method, if (party != null && party.isNotEmpty) party, dayMonth(r['day'] as String?)].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: inter(12.5, 500, color: kMuted),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(rs(r['amount_minor'] as num?), style: inter(16, 800)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_in ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 12, color: _in ? kRmGreen : kRmRed),
                const SizedBox(width: 3),
                Text(_in ? 'In' : 'Out', style: inter(12, 700, color: _in ? kRmGreen : kRmRed)),
              ]),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// One entry: what, how, when, the note; entries made here can be removed (with a reason) by someone who may approve money.
class _EntryDetails extends StatefulWidget {
  const _EntryDetails({required this.api, required this.entry, required this.canVoid});
  final RstMoneyApi api;
  final Map<String, dynamic> entry;
  final bool canVoid;
  @override
  State<_EntryDetails> createState() => _EntryDetailsState();
}

class _EntryDetailsState extends State<_EntryDetails> {
  final _reason = TextEditingController();
  bool _removing = false, _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    if (_reason.text.trim().length < 3) return showToast(context, 'Say why it is removed.');
    setState(() => _busy = true);
    try {
      await widget.api.voidEntry('${widget.entry['id']}', _reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showToast(context, errorSentence(e));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    Widget kv(String k, String? v) => v == null || v.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 96, child: Text(k, style: inter(13.5, 500, color: kMuted))),
              Expanded(child: Text(v, style: inter(14, 600))),
            ]),
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${e['title']}', style: inter(18, 800)),
        const SizedBox(height: 4),
        Text(rs(e['amount_minor'] as num?), style: inter(26, 800, color: e['direction'] == 'in' ? kRmGreen : kRmRed)),
        const SizedBox(height: 10),
        kv('Type', _kindWord('${e['kind']}')),
        kv('Method', _methodNames['${e['method']}'] ?? '${e['method'] ?? ''}'),
        kv('Date', dayMonth(e['day'] as String?)),
        kv('With', e['party'] as String?),
        kv('Reference', e['reference'] as String?),
        kv('Note', e['note'] as String?),
        if (e['voidable'] == true && widget.canVoid) ...[
          const SizedBox(height: 12),
          if (_removing) ...[
            TextField(key: const ValueKey('rm-void-reason'), controller: _reason, decoration: const InputDecoration(labelText: 'Why remove it?')),
            const SizedBox(height: 10),
            FilledButton(
              key: const ValueKey('rm-void-confirm'),
              style: FilledButton.styleFrom(backgroundColor: kRmRed, minimumSize: const Size.fromHeight(46)),
              onPressed: _busy ? null : _remove,
              child: Text('Remove entry', style: inter(14, 700, color: Colors.white)),
            ),
          ] else
            OutlinedButton(
              key: const ValueKey('rm-void'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              onPressed: () => setState(() => _removing = true),
              child: Text('Remove this entry', style: inter(14, 700, color: kRmRed)),
            ),
        ] else if (e['voidable'] != true) ...[
          const SizedBox(height: 8),
          Text('Recorded by the bill or another page; change it there.', style: inter(12.5, 500, color: kMuted)),
        ],
      ]),
    );
  }
}

InputDecoration _field(String label, {String? prefix}) => InputDecoration(
      labelText: label,
      prefixText: prefix,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kLine)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kLine)),
    );

/// Add money (in) or Pay money (out): the amount, what it is for, how, with whom, a note. True when saved.
Future<bool> showRmEntrySheet(BuildContext context,
    {required RstMoneyApi api, required String direction, String? kind, String? party, String? reference, num? amountMinor}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _EntrySheet(api: api, direction: direction, kind: kind, party: party, reference: reference, amountMinor: amountMinor),
  );
  return saved == true;
}

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.api, required this.direction, this.kind, this.party, this.reference, this.amountMinor});
  final RstMoneyApi api;
  final String direction;
  final String? kind, party, reference;
  final num? amountMinor;
  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late final _amount = TextEditingController(text: widget.amountMinor == null ? '' : (widget.amountMinor! / 100).toStringAsFixed(widget.amountMinor! % 100 == 0 ? 0 : 2));
  late final _party = TextEditingController(text: widget.party ?? '');
  final _what = TextEditingController(), _note = TextEditingController();
  late String _kind = widget.kind ?? (widget.direction == 'in' ? 'other_income' : 'expense');
  String _method = 'cash';
  final String _key = RstMoneyApi.newKey();
  bool _busy = false;

  bool get _in => widget.direction == 'in';
  bool get _other => _kind == 'other_in' || _kind == 'other_out';

  @override
  void dispose() {
    for (final c in [_amount, _party, _what, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final paise = paiseOf(_amount.text);
    if (paise == null) return showToast(context, 'Enter the amount.');
    if (_other && _what.text.trim().isEmpty) return showToast(context, 'Say what it was for.');
    if (_kind == 'due_received' && _party.text.trim().isEmpty) return showToast(context, 'Say who paid the due.');
    setState(() => _busy = true);
    try {
      await widget.api.record({
        'direction': widget.direction,
        'kind': _kind,
        'category': _other ? _what.text.trim() : _kindWord(_kind),
        'method': _method,
        'amount_minor': paise,
        'party': _party.text.trim(),
        'reference': widget.reference,
        'note': _note.text.trim(),
      }, key: _key);
      if (!mounted) return;
      showToast(context, _in ? '${rs(paise)} added to Money in.' : '${rs(paise)} saved in Money out.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showToast(context, errorSentence(e));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final kinds = _in ? kRmIn : kRmOut;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_in ? 'Add money' : 'Pay money', style: inter(20, 800)),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('rm-entry-amount'),
            controller: _amount,
            autofocus: widget.amountMinor == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: rupeeFormatters,
            style: inter(20, 800),
            decoration: _field('Amount', prefix: '₹ '),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('rm-entry-kind'),
            initialValue: _kind,
            isExpanded: true,
            decoration: _field(_in ? 'Money in for' : 'Money out for'),
            items: [for (final (id, label) in kinds) DropdownMenuItem(value: id, child: Text(label, overflow: TextOverflow.ellipsis, style: inter(14.5, 600)))],
            onChanged: widget.kind != null ? null : (v) => setState(() => _kind = v ?? _kind),
          ),
          if (_other) ...[
            const SizedBox(height: 12),
            TextField(key: const ValueKey('rm-entry-what'), controller: _what, maxLength: 60, decoration: _field('What it was for')),
          ],
          const SizedBox(height: 12),
          Text('How', style: inter(13, 700, color: kMuted)),
          const SizedBox(height: 6),
          RmPills(keyPrefix: 'rm-entry-method', options: kRmMethods, selected: _method, onSelect: (m) => setState(() => _method = m)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rm-entry-party'),
            controller: _party,
            maxLength: 60,
            readOnly: widget.party != null && widget.party!.isNotEmpty,
            decoration: _field(_in ? 'From (optional)' : 'Paid to (optional)'),
          ),
          TextField(key: const ValueKey('rm-entry-note'), controller: _note, maxLength: 300, decoration: _field('Note (optional)')),
          const SizedBox(height: 6),
          FilledButton(
            key: const ValueKey('rm-entry-save'),
            style: FilledButton.styleFrom(backgroundColor: kRmDeep, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: _busy ? null : _save,
            child: Text(_in ? 'Save money in' : 'Save money out', style: inter(15, 800, color: kRmLime)),
          ),
        ]),
      ),
    );
  }
}

/// Pay a supplier invoice, or a purchase bill saved from Received, from Dues: the amount (what is left by default) and how.
Future<bool> showRmInvoicePaySheet(BuildContext context, {required RstMoneyApi api, required Map<String, dynamic> invoice}) async {
  final amount = TextEditingController(text: (((invoice['left_minor'] as num?) ?? 0) / 100).toStringAsFixed(((invoice['left_minor'] as num?) ?? 0) % 100 == 0 ? 0 : 2));
  var method = 'bank';
  final key = RstMoneyApi.newKey();
  final saved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (c) => StatefulBuilder(
      builder: (c, set) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(c).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Pay ${invoice['name']}', style: inter(20, 800)),
          Text('${invoice['kind'] == 'purchase_bill' ? 'Purchase bill' : 'Invoice'}${invoice['reference'] == null ? '' : ' ${invoice['reference']}'} · ${rs(invoice['left_minor'] as num?)} left',
              style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          TextField(key: const ValueKey('rm-invoice-amount'), controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: rupeeFormatters, decoration: _field('Amount', prefix: '₹ ')),
          const SizedBox(height: 12),
          RmPills(keyPrefix: 'rm-invoice-method', options: kRmMethods, selected: method, onSelect: (m) => set(() => method = m)),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('rm-invoice-save'),
            style: FilledButton.styleFrom(backgroundColor: kRmDeep, minimumSize: const Size.fromHeight(52)),
            onPressed: () async {
              final paise = paiseOf(amount.text);
              if (paise == null) return showToast(c, 'Enter the amount.');
              try {
                if (invoice['kind'] == 'purchase_bill') {
                  await api.payBill('${invoice['bill_receipt_id']}', paise, method, key: key);
                } else {
                  await api.payInvoice('${invoice['invoice_id']}', paise, method, key: key);
                }
                if (c.mounted) Navigator.pop(c, true);
              } catch (e) {
                if (c.mounted) showToast(c, errorSentence(e));
              }
            },
            child: Text('Save payment', style: inter(15, 800, color: kRmLime)),
          ),
        ]),
      ),
    ),
  );
  return saved == true;
}

// ------------------------------------------------------------------------------------------------------------------- transfer
/// A person to pay: name, phone, UPI ID.
class RmContact {
  const RmContact({this.id, required this.name, this.phone = '', this.upiId = ''});
  final String? id;
  final String name, phone, upiId;
  factory RmContact.of(Map m) => RmContact(id: m['id'] as String?, name: '${m['name'] ?? ''}', phone: '${m['phone'] ?? ''}', upiId: '${m['upi_id'] ?? ''}');
}

/// The UPI payment link for an app: GPay (tez://), PhonePe (phonepe://) or any UPI app (upi://).
Uri upiPayLink(String app, {required String upiId, required String name, required int amountMinor, String note = ''}) {
  final q = {'pa': upiId, 'pn': name, 'am': (amountMinor / 100).toStringAsFixed(2), 'cu': 'INR', if (note.isNotEmpty) 'tn': note};
  final query = q.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  return Uri.parse('${switch (app) {
    'gpay' => 'tez://upi/pay',
    'phonepe' => 'phonepe://pay',
    _ => 'upi://pay',
  }}?$query');
}

const _transferFor = [('supplier_payment', 'Supplier payment'), ('salary', 'Salary / wages'), ('rent', 'Rent'), ('expense', 'Expense'), ('owner_out', 'Owner withdrawal'), ('other_out', 'Other')];

class RstTransferScreen extends StatefulWidget {
  const RstTransferScreen({super.key, required this.api, this.openUrl});
  final RstMoneyApi api;
  final Future<bool> Function(Uri url)? openUrl;
  @override
  State<RstTransferScreen> createState() => _RstTransferScreenState();
}

class _RstTransferScreenState extends State<RstTransferScreen> {
  RmContact? _to;
  String _how = 'upi'; // upi | card
  String _kind = 'supplier_payment';
  final _amount = TextEditingController(), _note = TextEditingController();
  String _key = RstMoneyApi.newKey();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final c = await showModalBottomSheet<RmContact>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ContactPicker(api: widget.api),
    );
    if (c != null && mounted) setState(() => _to = c);
  }

  Future<void> _editContact() async {
    final c = await editRmContact(context, widget.api, contact: _to);
    if (c != null && mounted) setState(() => _to = c);
  }

  bool _ready() {
    if (_to == null) {
      showToast(context, 'Select who you are paying.');
      return false;
    }
    if (paiseOf(_amount.text) == null) {
      showToast(context, 'Enter the amount.');
      return false;
    }
    return true;
  }

  Future<void> _record(String method, {String reference = ''}) async {
    final paise = paiseOf(_amount.text)!;
    setState(() => _busy = true);
    try {
      await widget.api.record({
        'direction': 'out',
        'kind': _kind,
        'category': _transferFor.firstWhere((f) => f.$1 == _kind).$2,
        'method': method,
        'amount_minor': paise,
        'party': _to!.name,
        'party_phone': _to!.phone,
        'reference': reference,
        'note': _note.text.trim(),
      }, key: _key);
      _key = RstMoneyApi.newKey(); // the next payment is a new one
      if (!mounted) return;
      showToast(context, '${rs(paise)} to ${_to!.name} saved in Money out.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _payUpi(String app) async {
    if (!_ready()) return;
    if (_to!.upiId.isEmpty) {
      showToast(context, "Add the contact's UPI ID first.");
      return _editContact();
    }
    final link = upiPayLink(app, upiId: _to!.upiId, name: _to!.name, amountMinor: paiseOf(_amount.text)!, note: _note.text.trim());
    final opened = await (widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(link);
    if (!mounted) return;
    if (!opened) {
      showToast(context, 'Could not open the UPI app. Pay from the app on your phone.');
      return;
    }
    final utr = TextEditingController();
    final paid = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Did the payment of ${rs(paiseOf(_amount.text))} to ${_to!.name} go through?', style: inter(17, 700)),
        content: TextField(key: const ValueKey('rm-utr'), controller: utr, decoration: const InputDecoration(labelText: 'UTR / reference (optional)')),
        actions: [
          TextButton(key: const ValueKey('rm-not-paid'), onPressed: () => Navigator.pop(c, false), child: Text('No', style: inter(14, 600))),
          TextButton(key: const ValueKey('rm-paid'), onPressed: () => Navigator.pop(c, true), child: Text('Yes, record it', style: inter(14, 700, color: kRmGreen))),
        ],
      ),
    );
    if (paid == true && mounted) await _record(app == 'any' ? 'upi' : app, reference: utr.text.trim());
  }

  Future<void> _move() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _MoveSheet(api: widget.api),
    );
    if (saved == true && mounted) showToast(context, 'Saved.');
  }

  /// A box on the dark card: dark-soft fill, white text, grey label (the Money page's look).
  InputDecoration _dark(String label, {String? prefix}) => InputDecoration(
        labelText: label,
        labelStyle: inter(14, 500, color: const Color(0xFFB8BCC4)),
        floatingLabelStyle: inter(13, 600, color: kRmLime),
        prefixText: prefix,
        prefixStyle: inter(16, 700, color: Colors.white),
        counterStyle: inter(11, 500, color: const Color(0xFF8A8F98)),
        filled: true,
        fillColor: kRmDeepSoft,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: kRmLime, width: 1.4)),
      );

  /// GPay, PhonePe, Other UPI app: dark rows with a lime icon tile and an arrow, like the OneLocal wallet's View.
  Widget _payRow(String app, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: kRmDeep,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('rm-pay-$app'),
            onTap: _busy ? null : () => _payUpi(app),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: kRmLime, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(LucideIcons.smartphone, size: 18, color: kRmDeep),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(label, style: inter(15.5, 700, color: Colors.white))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Pay', style: inter(12.5, 700, color: kRmLime)),
                    const SizedBox(width: 4),
                    const Icon(LucideIcons.arrowUpRight, size: 14, color: kRmLime),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final to = _to;
    // UPI / Card: lime when chosen (like Transfer on the Money page), dark-soft otherwise
    Widget toggle(String id, String label, IconData icon) => Expanded(
          child: Material(
            color: _how == id ? kRmLime : kRmDeepSoft,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: ValueKey('rm-how-$id'),
              borderRadius: BorderRadius.circular(18),
              onTap: () => setState(() => _how = id),
              child: SizedBox(
                height: 52,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, size: 18, color: _how == id ? kRmDeep : Colors.white),
                  const SizedBox(width: 8),
                  Text(label, style: inter(15, 800, color: _how == id ? kRmDeep : Colors.white)),
                ]),
              ),
            ),
          ),
        );
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        AppHeader(title: 'Transfer', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: ListView(key: const ValueKey('rm-transfer-page'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
            // who, how much, for what: one dark card with rings
            RmDarkCard(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Pay a contact', style: inter(13.5, 500, color: const Color(0xFFB8BCC4))),
                const SizedBox(height: 10),
                Material(
                  color: kRmDeepSoft,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    key: const ValueKey('rm-contact'),
                    borderRadius: BorderRadius.circular(18),
                    onTap: _choose,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                      child: Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: to == null ? const Color(0xFF3A3F47) : kRmLime, borderRadius: BorderRadius.circular(12)),
                          child: to == null
                              ? const Icon(LucideIcons.userRound, size: 18, color: Colors.white)
                              : Center(child: Text(to.name.trim().isEmpty ? '?' : to.name.trim()[0].toUpperCase(), style: inter(16, 800, color: kRmDeep))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: to == null
                              ? Text('Select a contact', style: inter(15.5, 600, color: const Color(0xFFB8BCC4)))
                              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(to.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 800, color: Colors.white)),
                                  Text(to.upiId.isEmpty ? 'No UPI ID yet' : to.upiId,
                                      style: inter(12.5, 500, color: to.upiId.isEmpty ? const Color(0xFFFF8A80) : const Color(0xFFB8BCC4))),
                                ]),
                        ),
                        if (to != null)
                          IconButton(key: const ValueKey('rm-contact-edit'), tooltip: 'Edit contact', onPressed: _editContact, icon: const Icon(LucideIcons.pencil, size: 17, color: Colors.white)),
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(color: kRmLime, borderRadius: BorderRadius.circular(12)),
                          child: const Icon(LucideIcons.userPlus, size: 17, color: kRmDeep),
                        ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    flex: 4,
                    child: TextField(
                      key: const ValueKey('rm-transfer-amount'),
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: rupeeFormatters,
                      cursorColor: kRmLime,
                      style: inter(18, 800, color: Colors.white),
                      decoration: _dark('Amount', prefix: '₹ '),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 5,
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('rm-transfer-for'),
                      initialValue: _kind,
                      isExpanded: true,
                      dropdownColor: kRmDeep,
                      iconEnabledColor: kRmLime,
                      decoration: _dark('For'),
                      selectedItemBuilder: (_) => [for (final (_, label) in _transferFor) Align(alignment: Alignment.centerLeft, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 700, color: Colors.white)))],
                      items: [
                        for (final (id, label) in _transferFor)
                          DropdownMenuItem(value: id, child: Text(label, overflow: TextOverflow.ellipsis, style: inter(14.5, 700, color: Colors.white))),
                      ],
                      onChanged: (v) => setState(() => _kind = v ?? _kind),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('rm-transfer-note'),
                  controller: _note,
                  maxLength: 300,
                  cursorColor: kRmLime,
                  style: inter(15, 600, color: Colors.white),
                  decoration: _dark('Note (optional)'),
                ),
                const SizedBox(height: 4),
                Row(children: [toggle('upi', 'UPI', LucideIcons.smartphone), const SizedBox(width: 10), toggle('card', 'Card', LucideIcons.creditCard)]),
              ]),
            ),
            const SizedBox(height: 16),
            if (_how == 'upi') ...[
              Text('Pay through', style: inter(15, 800)),
              const SizedBox(height: 10),
              _payRow('gpay', 'GPay'),
              _payRow('phonepe', 'PhonePe'),
              _payRow('any', 'Other UPI app'),
              const SizedBox(height: 2),
              Text('The app opens with the amount filled in. After you pay, come back and say it went through, and it is saved in Money out.',
                  style: inter(12.5, 500, color: kMuted, height: 1.4)),
            ] else ...[
              Text('Pay on the card machine, then save it here. It is saved in Money out.', style: inter(12.5, 500, color: kMuted, height: 1.4)),
              const SizedBox(height: 10),
              FilledButton(
                key: const ValueKey('rm-pay-card'),
                style: FilledButton.styleFrom(backgroundColor: kRmLime, minimumSize: const Size.fromHeight(54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                onPressed: _busy ? null : () => _ready() ? _record('card') : null,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('Save card payment', style: inter(15.5, 800, color: kRmDeep)),
                  const SizedBox(width: 8),
                  const Icon(LucideIcons.arrowUpRight, size: 18, color: kRmDeep),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            // moving between the restaurant's own accounts: the lime strip and dark body of the OneLocal wallet card
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('rm-move'),
                borderRadius: BorderRadius.circular(kRmRadius),
                onTap: _move,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(kRmRadius),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      color: kRmLime,
                      padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
                      child: Row(children: [
                        const Icon(LucideIcons.arrowLeftRight, size: 16, color: kRmDeep),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Move money', style: inter(13.5, 800, color: kRmDeep))),
                        Text('Between your accounts', style: inter(11.5, 600, color: kRmDeep)),
                      ]),
                    ),
                    Container(
                      color: kRmDeep,
                      padding: const EdgeInsets.fromLTRB(18, 13, 14, 14),
                      child: Row(children: [
                        Expanded(child: Text('Cash · UPI · Bank', style: inter(15, 700, color: Colors.white))),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(color: kRmDeepSoft, borderRadius: BorderRadius.circular(40)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('Move', style: inter(12.5, 700, color: kRmLime)),
                            const SizedBox(width: 4),
                            const Icon(LucideIcons.arrowUpRight, size: 14, color: kRmLime),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Add or change a contact: name, phone (+91) and UPI ID. The saved contact, or null.
Future<RmContact?> editRmContact(BuildContext context, RstMoneyApi api, {RmContact? contact}) {
  final name = TextEditingController(text: contact?.name ?? ''), phone = TextEditingController(text: localMobile(contact?.phone)),
      upi = TextEditingController(text: contact?.upiId ?? '');
  return showModalBottomSheet<RmContact>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(c).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(contact?.id == null ? 'New contact' : 'Edit contact', style: inter(20, 800)),
        const SizedBox(height: 14),
        TextField(key: const ValueKey('rm-contact-name'), controller: name, maxLength: 60, decoration: _field('Name')),
        TextField(key: const ValueKey('rm-contact-phone'), controller: phone, keyboardType: TextInputType.phone, inputFormatters: mobileFormatters, decoration: _field('Mobile (optional)', prefix: kMobilePrefix)),
        const SizedBox(height: 12),
        TextField(key: const ValueKey('rm-contact-upi'), controller: upi, decoration: _field('UPI ID (like name@okaxis)')),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('rm-contact-save'),
          style: FilledButton.styleFrom(backgroundColor: kRmDeep, minimumSize: const Size.fromHeight(52)),
          onPressed: () async {
            if (name.text.trim().isEmpty) return showToast(c, 'Enter a name.');
            try {
              final saved = await api.saveContact(id: contact?.id, name: name.text.trim(), phone: phone.text.trim().isEmpty ? '' : '+91${phone.text.trim()}', upiId: upi.text.trim());
              if (c.mounted) Navigator.pop(c, RmContact.of(saved));
            } catch (e) {
              if (c.mounted) showToast(c, errorSentence(e));
            }
          },
          child: Text('Save contact', style: inter(15, 800, color: kRmLime)),
        ),
      ]),
    ),
  );
}

/// Saved contacts and people money was recorded with; search; New contact.
class _ContactPicker extends StatefulWidget {
  const _ContactPicker({required this.api});
  final RstMoneyApi api;
  @override
  State<_ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<_ContactPicker> {
  Map<String, dynamic>? _d;
  String? _error;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.contacts(q: _q.text);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _new([RmContact? from]) async {
    final c = await editRmContact(context, widget.api, contact: from);
    if (c != null && mounted) Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final saved = (_d?['saved'] as List? ?? const []).cast<Map>();
    final recent = (_d?['recent'] as List? ?? const []).cast<Map>();
    return SizedBox(
      height: MediaQuery.of(context).size.height * .75,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Pay to', style: inter(20, 800)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('rm-contact-search'),
            controller: _q,
            onChanged: (_) => _load(),
            decoration: _field('Search name, mobile or UPI ID').copyWith(prefixIcon: const Icon(LucideIcons.search, size: 18)),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('rm-contact-new'),
            onPressed: _new,
            icon: const Icon(LucideIcons.userPlus, size: 18, color: kRmGreen),
            label: Text('New contact', style: inter(14, 700, color: kRmGreen)),
          ),
          Expanded(
            child: _d == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!, style: inter(14, 500, color: kMuted)))
                : ListView(children: [
                    for (final c in saved)
                      ListTile(
                        key: ValueKey('rm-contact-${c['name']}'),
                        leading: const CircleAvatar(backgroundColor: Color(0xFFEFF8D6), child: Icon(LucideIcons.userRound, size: 18, color: kRmGreen)),
                        title: Text('${c['name']}', style: inter(15, 700)),
                        subtitle: Text('${c['upi_id']}'.isEmpty ? 'No UPI ID yet' : '${c['upi_id']}', style: inter(12.5, 500, color: kMuted)),
                        onTap: () => Navigator.pop(context, RmContact.of(c)),
                      ),
                    if (recent.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Suppliers and people you paid', style: inter(12.5, 700, color: kMuted))),
                    for (final c in recent)
                      ListTile(
                        key: ValueKey('rm-contact-${c['name']}'),
                        leading: const CircleAvatar(backgroundColor: Color(0xFFF1F2EE), child: Icon(LucideIcons.userRound, size: 18, color: kMuted)),
                        title: Text('${c['name']}', style: inter(15, 700)),
                        subtitle: Text('Add their UPI ID', style: inter(12.5, 500, color: kMuted)),
                        onTap: () => _new(RmContact(name: '${c['name']}', phone: '${c['phone'] ?? ''}')),
                      ),
                    if (saved.isEmpty && recent.isEmpty)
                      Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('No contacts yet. Add one.', style: inter(14, 500, color: kMuted)))),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// Move money between the restaurant's own accounts: cash to bank, UPI to bank, …
class _MoveSheet extends StatefulWidget {
  const _MoveSheet({required this.api});
  final RstMoneyApi api;
  @override
  State<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<_MoveSheet> {
  String _from = 'cash', _to = 'bank';
  final _amount = TextEditingController();
  final String _key = RstMoneyApi.newKey();
  bool _busy = false;
  static const _accounts = [('cash', 'Cash drawer'), ('upi', 'UPI'), ('bank', 'Bank')];

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final paise = paiseOf(_amount.text);
    if (paise == null) return showToast(context, 'Enter the amount.');
    if (_from == _to) return showToast(context, 'Choose two different accounts.');
    setState(() => _busy = true);
    try {
      await widget.api.record({'direction': 'move', 'from_account': _from, 'to_account': _to, 'amount_minor': paise}, key: _key);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showToast(context, errorSentence(e));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Move money', style: inter(20, 800)),
          Text('Between your own accounts, like cash deposited in the bank.', style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          Text('From', style: inter(13, 700, color: kMuted)),
          const SizedBox(height: 6),
          RmPills(keyPrefix: 'rm-move-from', options: _accounts, selected: _from, onSelect: (v) => setState(() => _from = v)),
          const SizedBox(height: 12),
          Text('To', style: inter(13, 700, color: kMuted)),
          const SizedBox(height: 6),
          RmPills(keyPrefix: 'rm-move-to', options: _accounts, selected: _to, onSelect: (v) => setState(() => _to = v)),
          const SizedBox(height: 12),
          TextField(key: const ValueKey('rm-move-amount'), controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: rupeeFormatters, decoration: _field('Amount', prefix: '₹ ')),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('rm-move-save'),
            style: FilledButton.styleFrom(backgroundColor: kRmDeep, minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _save,
            child: Text('Move money', style: inter(15, 800, color: kRmLime)),
          ),
        ]),
      );
}
