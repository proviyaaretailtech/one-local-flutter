import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_nav.dart';
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'catalogue_api.dart';
import 'catalogue_format.dart';
import 'catalogue_widgets.dart';

String _m(num minor) => money(minor, fixed: true);
/// 2024-09-15 -> 15 Sep 2024 (display only).
String _date(String iso) {
  final p = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(iso);
  if (p == null) return iso;
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${int.parse(p.group(3)!)} ${m[int.parse(p.group(2)!) - 1]} ${p.group(1)}';
}

String _errText(Object e) => e is CatalogueApiException ? e.message : 'Could not reach the server. Check the connection and try again.';

void _tab(BuildContext context, String id, {String active = 'bill'}) {
  if (id == active) return;
  switch (id) {
    case 'home':
      HomeNav.go(context, HomeNav.home, 'Home');
    case 'item':
      HomeNav.go(context, HomeNav.items, 'Items');
    case 'bill':
      HomeNav.go(context, HomeNav.bill, 'Bill');
    case 'stock':
      HomeNav.go(context, HomeNav.stock, 'Stock');
    default:
      HomeNav.go(context, null, 'Online orders');
  }
}

// ================================================================ GRN Matching (Figma "02 — GRN Matching")
/// The supplier invoice against what was physically received, row by row. "Review Exceptions" opens the GRN dashboard.
class GrnMatchingScreen extends StatefulWidget {
  const GrnMatchingScreen({super.key, required this.receiptId, this.api});
  final String receiptId;
  final CatalogueApi? api;
  @override
  State<GrnMatchingScreen> createState() => _GrnMatchingState();
}

class _GrnMatchingState extends State<GrnMatchingScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  GrnMatching? _m0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.grnMatching(widget.receiptId);
      if (!mounted) return;
      setState(() {
        _m0 = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  Future<void> _review() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => GrnDashboardScreen(receiptId: widget.receiptId, api: _api)));
    if (mounted) _load();
  }

  Color _bg(GrnRow r) => switch (r.severity) { 'red' => kBadBg, 'amber' => const Color(0xFFFFF8E1), _ => Colors.white };
  Color _fg(GrnRow r) => switch (r.severity) { 'red' => kBadText, 'amber' => const Color(0xFFD97706), _ => kInk };

  Widget _head(String title, String right) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: const BoxDecoration(color: Color(0xFFF6F8FA), borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Row(children: [Expanded(child: Text(title, style: inter(19, 700))), Text(right, style: inter(16, 400, color: kMuted))]),
      );

  Widget _cols(String a, String b, String c) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF1F3F5), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(flex: 5, child: Text(a, style: inter(14, 700, color: kMuted))),
          Expanded(flex: 3, child: Text(b, textAlign: TextAlign.right, style: inter(14, 700, color: kMuted))),
          Expanded(flex: 3, child: Text(c, textAlign: TextAlign.right, style: inter(14, 700, color: kMuted))),
        ]),
      );

  Widget _line(String name, String q, String price, {Color bg = Colors.white, Color fg = kInk, String? note}) => Container(
        margin: const EdgeInsets.fromLTRB(8, 2, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: bg == Colors.white ? const Border(bottom: BorderSide(color: Color(0xFFEFF1F3))) : null),
        child: Row(children: [
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: inter(17, fg == kInk ? 400 : 600, color: fg)),
              if (note != null) Text(note, style: inter(12.5, 700, color: fg)),
            ]),
          ),
          Expanded(flex: 3, child: Text(q, textAlign: TextAlign.right, style: inter(17, fg == kInk ? 400 : 700, color: fg == kInk ? kMuted : fg))),
          Expanded(flex: 3, child: Text(price, textAlign: TextAlign.right, style: inter(17, 700, color: fg))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _m0;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'GRN Matching', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
              if (_error != null && d == null)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))))
              else if (d == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                OrderCardBox(
                  radius: 24,
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${d.docNo} • MATCH INVOICE', style: inter(15, 500, color: kKicker)),
                    const SizedBox(height: 4),
                    Text(d.hasInvoice ? '${d.invoiceNo} • ${d.supplier}' : 'No supplier invoice entered yet • ${d.supplier}', style: inter(19, 500)),
                    const SizedBox(height: 4),
                    Text('Review exceptions before Confirm Receiving.\nNext: GRN Approval/Posting • not posted yet.', style: inter(16, 400, color: kMuted, height: 1.35)),
                  ]),
                ),
                const SizedBox(height: 14),
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE3E5DF))),
                  child: Column(children: [
                    _head('Supplier Invoice', _date(d.invoiceDate)),
                    _cols('Product', 'Qty', 'Unit price'),
                    for (final l in d.invoiceLines) _line(l['name'].toString(), '${qty(l['qty'] as num)} ${l['unit']}', _m((l['unit_price_minor'] as num))),
                    if (d.invoiceLines.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Text('The supplier invoice has not been entered for this receipt.', style: inter(15, 400, color: kMuted))),
                    const SizedBox(height: 8),
                  ]),
                ),
                const SizedBox(height: 14),
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE3E5DF))),
                  child: Column(children: [
                    _head('Physical Receiving Logs', d.operatorName == null ? '' : 'Op: ${d.operatorName}'),
                    _cols('Product', 'Received', 'Unit price'),
                    for (final r in d.rows)
                      if (r.received != null)
                        _line(
                          r.received!['name'].toString(),
                          '${qty(r.received!['qty'] as num)} ${r.received!['unit']}',
                          r.received!['unit_cost_minor'] == null ? (r.state == 'not_on_invoice' || r.state == 'missing' ? '—' : _m(invoiceUnitMinor(r.invoice) ?? 0)) : _m(r.received!['unit_cost_minor'] as num),
                          bg: _bg(r),
                          fg: _fg(r),
                          note: r.state == 'not_on_invoice' ? 'NOT ON INVOICE' : null,
                        )
                      else
                        _line(r.name, '0 ${r.invoice?['unit'] ?? ''}', '—', bg: _bg(r), fg: _fg(r)),
                    const SizedBox(height: 8),
                  ]),
                ),
                const SizedBox(height: 14),
                OrderCardBox(
                  radius: 24,
                  child: Column(children: [
                    Row(children: [
                      // No Spacer: it took a share of the row and cut both counts short on a phone.
                      const Icon(LucideIcons.circleCheck, size: 18, color: kGreenText),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${d.matched} matched shown', style: inter(14, 600), overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      const Icon(LucideIcons.triangleAlert, size: 16, color: kBadText),
                      const SizedBox(width: 6),
                      Text('${d.exceptions} ${d.exceptions == 1 ? 'exception' : 'exceptions'} shown', style: inter(14, 600, color: kBadText)),
                    ]),
                    const SizedBox(height: 12),
                    DarkButton('Review Exceptions', onPressed: _review, height: 58),
                  ]),
                ),
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'bill', onTap: (id) => _tab(context, id)),
      ]),
    );
  }
}

// ================================================================ GRN Dashboard (Figma "01 — GRN Dashboard")
class GrnDashboardScreen extends StatefulWidget {
  const GrnDashboardScreen({super.key, required this.receiptId, this.api});
  final String receiptId;
  final CatalogueApi? api;
  @override
  State<GrnDashboardScreen> createState() => _GrnDashboardState();
}

class _GrnDashboardState extends State<GrnDashboardScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  GrnView? _v;
  String? _error;
  bool _busy = false;
  String? _choice; // accept_claim_credit | accept_as_received
  final _claimRef = TextEditingController(), _evidence = TextEditingController(), _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load(open: true);
  }

  @override
  void dispose() {
    _claimRef.dispose();
    _evidence.dispose();
    _note.dispose();
    super.dispose();
  }

  void _adopt(GrnView v) {
    _v = v;
    _error = null;
    final r = v.resolution;
    _choice = (r['selected'] as String?) ?? _choice ?? (v.options.firstWhere((o) => o['enabled'] == true, orElse: () => const {})['code'] as String?);
    if (r['claim_ref'] != null && _claimRef.text.isEmpty) _claimRef.text = r['claim_ref'].toString();
    if (r['claim_evidence'] != null && _evidence.text.isEmpty) _evidence.text = r['claim_evidence'].toString();
    if (r['note'] != null && _note.text.isEmpty) _note.text = r['note'].toString();
  }

  Future<void> _load({bool open = false}) async {
    try {
      GrnView v;
      if (open) {
        try {
          v = await _api.grnOpen(widget.receiptId);
        } on CatalogueApiException catch (e) {
          if (e.status != 403) rethrow; // a role that may only read opens the existing GRN
          v = await _api.grn(widget.receiptId);
        }
      } else {
        v = await _api.grn(widget.receiptId);
      }
      if (mounted) setState(() => _adopt(v));
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  Future<void> _do(Future<GrnView> Function() call, {String? done}) async {
    setState(() => _busy = true);
    try {
      final v = await call();
      if (!mounted) return;
      setState(() {
        _adopt(v);
        _busy = false;
      });
      if (v.voided) {
        showToast(context, 'The receipt or invoice changed after it was resolved. Resolve the exceptions again.');
      } else if (done != null) {
        showToast(context, done);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, _errText(e));
      if (e is CatalogueApiException && e.stale) _load();
    }
  }

  Future<String?> _askNote(String title, String hint) => showDialog<String>(context: context, builder: (_) => _NoteDialog(title: title, hint: hint));

  // ---------------------------------------------------------------- pieces
  // Long values (24 × ₹30.00 = ₹720.00) wrap onto a second line instead of shrinking to an unreadable size.
  Widget _kv(String k, String v, {Color vc = kInk, double size = 14}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: Text(k, style: inter(size, 400, color: kMuted))),
          const SizedBox(width: 12),
          Expanded(flex: 6, child: Text(v, textAlign: TextAlign.right, style: inter(size, 700, color: vc))),
        ]),
      );

  Widget _tabs() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (label, on) in [('Receiving', false), ('GRN', true), ('Putaway', false), ('Shelf Labels', false)]) ...[
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: on ? null : () => label == 'Receiving' ? HomeNav.go(context, HomeNav.stock, 'Receiving') : showToast(context, '$label is not in this release.'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(color: on ? kLime : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: on ? kLime : const Color(0xFFE3E5DF))),
                child: Text(label, style: inter(16, on ? 700 : 500, color: kDark)),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ]),
      );

  Widget _statusChip(GrnView v) {
    final (label, bg, fg) = switch (v.status) {
      'approved' => ('Approved', kLimeSoft, kGreenText),
      'cancelled' => ('Cancelled', const Color(0xFFEEF1EA), kMuted),
      'approval_due' => ('Approval due', const Color(0xFFEEF1EA), kInk),
      _ => (v.exceptions > 0 && v.resolution['valid'] != true ? 'Review' : 'Ready', const Color(0xFFEEF1EA), kInk),
    };
    return DotChip(label, bg: bg, fg: fg, big: true);
  }

  Widget _lineCard(GrnRow r) {
    final inv = r.invoice, rec = r.received;
    final price = invoiceUnitMinor(inv) ?? (rec?['unit_cost_minor'] as num?) ?? 0;
    final unit = (inv?['unit'] ?? rec?['unit'] ?? 'units').toString();
    final recQty = (rec?['qty'] as num?) ?? 0, rej = (rec?['rejected_qty'] as num?) ?? 0;
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r.name, style: inter(19, 700)),
        Text(_stateText(r), style: inter(14, 400, color: r.severity == 'ok' ? kMuted : (r.severity == 'red' ? kBadText : kWarnText))),
        const SizedBox(height: 8),
        if (inv != null) _kv('Invoice / received', '${qty(inv['qty'] as num)} / ${qty(recQty)} $unit'),
        _kv('Accepted / rejected', '${qty(r.acceptedQty)} / ${qty(rej)} $unit'),
        if (inv != null) _kv('Unit cost (billed, ex tax)', _m(price)),
        if (inv != null) ...[
          const Divider(height: 22, color: Color(0xFFE3E5DF)),
          _kv('Invoice amount', '${qty(inv['qty'] as num)} × ${_m(price)} = ${_m(inv['amount_minor'] as num)}'),
          _kv('Accepted goods value', '${qty(r.acceptedQty)} × ${_m(price)} = ${_m(r.acceptedValueMinor)}'),
          if (r.claimMinor > 0) _kv('Supplier claim', '${qty(r.shortfallQty)} × ${_m(price)} = ${_m(r.claimMinor)}', vc: kBadText),
        ],
      ]),
    );
  }

  String _stateText(GrnRow r) => switch (r.state) {
        'matched' => 'Matches the invoice',
        'short' => 'Received less than invoiced',
        'over' => 'Received more than invoiced',
        'price_diff' => 'Price differs from the invoice',
        'rejected' => 'Some units were rejected',
        'missing' => 'Invoiced but not received',
        _ => 'Received but not on the invoice',
      };

  Widget _field(TextEditingController c, String hint, {bool enabled = true}) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFDADCD5))),
        child: TextField(controller: c, enabled: enabled, style: inter(16, 400), decoration: plainInput.copyWith(hintText: hint, hintStyle: inter(16, 400, color: kMuted))),
      );

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text(t, style: inter(14, 700, color: kMuted)));

  String _optionLabel(Map<String, dynamic> o) => o['code'] == 'accept_claim_credit'
      ? 'Accept ${qty(o['accepted_units'] as num)} · Claim credit for ${qty(o['claim_units'] as num)}'
      : 'Accept ${qty(o['accepted_units'] as num)} as received';

  Widget _resolveCard(GrnView v) {
    final open = v.status == 'matching';
    final valid = v.resolution['valid'] == true;
    final claim = _choice == 'accept_claim_credit';
    final waive = _choice == 'accept_as_received' && v.claimMinor > 0;
    return OrderCardBox(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text('Resolve exceptions', style: inter(19, 700))), DotChip(valid ? 'Resolved' : 'Review', bg: valid ? kLimeSoft : const Color(0xFFEEF1EA), fg: valid ? kGreenText : kInk, big: true)]),
        const SizedBox(height: 10),
        Text('${v.exceptions} ${v.exceptions == 1 ? 'line differs' : 'lines differ'} from the invoice. Choose how to settle ${v.exceptions == 1 ? 'it' : 'them'} before owner approval.', style: inter(16, 400, height: 1.35)),
        _label('Resolution'),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFDADCD5))),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _choice,
              isExpanded: true,
              icon: const Icon(LucideIcons.chevronDown, size: 18),
              style: inter(16, 400),
              items: [for (final o in v.options) DropdownMenuItem(value: o['code'] as String, enabled: o['enabled'] == true, child: Text(_optionLabel(o), style: inter(16, 400, color: o['enabled'] == true ? kInk : kMuted)))],
              onChanged: open ? (c) => setState(() => _choice = c) : null,
            ),
          ),
        ),
        if (claim) ...[
          _label('Supplier claim reference'),
          _field(_claimRef, 'CLM-105', enabled: open),
          _label('Evidence'),
          _field(_evidence, 'Seal inspection · 2 photos', enabled: open),
          const SizedBox(height: 6),
          Text('Claim: ${_m(v.claimMinor)} requested', style: inter(15, 600)),
        ],
        if (waive) ...[_label('Why is the claim of ${_m(v.claimMinor)} waived?'), _field(_note, 'Reason', enabled: open)],
        if (open) ...[
          const SizedBox(height: 14),
          OutlineButton('Save resolution', height: 48, onPressed: _busy || _choice == null ? null : () => _do(() => _api.grnResolve(v.receiptId, version: v.version, resolution: _choice!, claimRef: _claimRef.text, evidence: _evidence.text, note: _note.text), done: 'Resolution saved.')),
        ],
      ]),
    );
  }

  // An invoiced line that never arrived comes back with no item and nothing accepted: nothing would be posted for it, so it is not listed.
  Widget _previewCard(GrnView v) => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Posting preview', style: inter(19, 700)),
          Text('Only on owner approval', style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 8),
          for (final p in v.preview.where((p) => p['name'] != null)) ...[
            Text(p['name'].toString(), style: inter(15, 600)),
            if (p['stock_now'] != null) _kv('Stock', '${qty(p['stock_now'] as num)} → ${qty((p['stock_now'] as num) + (p['accepted_qty'] as num))} ${p['unit'] ?? ''}') else _kv('Added to stock', '+${qty(p['accepted_qty'] as num)} ${p['unit'] ?? ''}'),
            if (((p['rejected_qty'] as num?) ?? 0) > 0) _kv('Rejected · not posted', '${qty(p['rejected_qty'] as num)} ${p['unit'] ?? ''}'),
          ],
          if (v.preview.every((p) => p['name'] == null)) Text('Nothing counted yet.', style: inter(15, 400, color: kMuted)),
          const SizedBox(height: 6),
          Text('Rejected units stay out of stock and are claimed from the supplier. Drafts do not change posted stock.', style: inter(14, 400, color: kMuted, height: 1.35)),
        ]),
      );

  Widget _checklistCard(GrnView v) => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Confirm Receiving & Approval', style: inter(19, 700)),
          const SizedBox(height: 8),
          for (final c in v.checklist)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 24, child: Icon(c['done'] == true ? LucideIcons.check : LucideIcons.circle, size: c['done'] == true ? 18 : 13, color: kInk)),
                const SizedBox(width: 6),
                Expanded(child: Text(_checkText(c), style: inter(16, 400))),
              ]),
            ),
        ]),
      );

  String _checkText(Map<String, dynamic> c) {
    final label = c['label'].toString();
    switch (c['key']) {
      case 'count':
        final by = (c['by'] as Map?)?['name'];
        return by == null ? label : '$label by $by';
      case 'lot':
        final lot = c['detail'], exp = c['expiry_date'];
        return lot == null ? label : '$label · $lot${exp == null ? '' : ' / $exp'}';
      case 'claim':
        return '${_m((c['claim_minor'] as num?) ?? 0)} supplier claim recorded';
      case 'approval':
        return c['done'] == true ? 'Owner approved · stock posted' : 'Owner approval pending • nothing posted';
      default:
        return label;
    }
  }

  Widget _actions(GrnView v) {
    if (v.status == 'approved') return const DarkButton('Approved · stock posted', onPressed: null);
    if (v.status == 'cancelled') return const DarkButton('Receipt cancelled · nothing posted', onPressed: null);
    if (v.status == 'approval_due') {
      return Column(children: [
        if (v.can('can_approve')) DarkButton('Approve and post stock', busy: _busy, onPressed: () => _do(() => _api.grnDecide(v.receiptId, version: v.version, approve: true), done: 'Approved. Stock posted.')) else const DarkButton('Waiting for owner approval', onPressed: null),
        if (v.can('can_reject')) ...[
          const SizedBox(height: 10),
          OutlineButton('Send back', height: 52, onPressed: _busy ? null : () async {
            final note = await _askNote('Why is it sent back?', 'Reason');
            if (note != null) await _do(() => _api.grnDecide(v.receiptId, version: v.version, approve: false, note: note), done: 'Sent back to matching.');
          }),
        ],
      ]);
    }
    return Column(children: [
      DarkButton('Request owner approval', busy: _busy, onPressed: v.can('can_request') ? () => _do(() => _api.grnRequestApproval(v.receiptId, version: v.version), done: 'Approval requested.') : null),
      if (v.blockers.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(v.blockers.join(' '), textAlign: TextAlign.center, style: inter(14, 500, color: kWarnText))),
      if (v.decisionNote != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sent back: ${v.decisionNote}', textAlign: TextAlign.center, style: inter(14, 500, color: kBadText))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final shown = v == null ? const <GrnRow>[] : (v.rows.where((r) => r.state != 'matched').toList().isEmpty ? v.rows.take(1).toList() : v.rows.where((r) => r.state != 'matched').toList());
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'GRN', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
              Row(children: [
                Expanded(child: Text('GRN Dashboard', style: inter(28, 800))),
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => HomeNav.go(context, HomeNav.items, 'Items'),
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(18)), child: Row(children: [const Icon(LucideIcons.camera, size: 18, color: kLime), const SizedBox(width: 10), Text('Items', style: inter(16, 700, color: kLime))])),
                ),
              ]),
              const SizedBox(height: 4),
              Text('Open receipt → Scan/Enter Products → Match Invoice', style: inter(15, 400, color: kMuted)),
              const SizedBox(height: 14),
              _tabs(),
              const SizedBox(height: 14),
              if (_error != null && v == null)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))))
              else if (v == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                OrderCardBox(
                  radius: 24,
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(v.grnNo, style: inter(21, 800)),
                          Text([v.docNo, if (v.poRef.isNotEmpty) v.poRef, if (v.invoiceNo.isNotEmpty) v.invoiceNo].join(' / '), style: inter(15, 400, color: kMuted)),
                        ]),
                      ),
                      _statusChip(v),
                    ]),
                    const SizedBox(height: 8),
                    _kv('Supplier', v.supplier.isEmpty ? '—' : v.supplier),
                    _kv('Approver', [v.approver['name'], if (v.approver['role'] == 'org_owner') 'Owner'].whereType<String>().join(' · ').ifEmpty('—')),
                    _kv('Posting status', v.posted ? 'Posted' : 'Not posted'),
                  ]),
                ),
                const SizedBox(height: 12),
                OutlineButton('Open Receipt', height: 54, onPressed: () => HomeNav.receipt == null ? showToast(context, 'The receipt opens from Stock.') : HomeNav.receipt!(context, v.receiptId)),
                const SizedBox(height: 14),
                OutlineButton('Match against the invoice', height: 48, onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GrnMatchingScreen(receiptId: v.receiptId, api: _api)))),
                const SizedBox(height: 14),
                if (!v.hasInvoice)
                  OrderCardBox(radius: 24, padding: const EdgeInsets.all(18), child: Text('The supplier invoice has not been entered for this receipt yet, so there is nothing to match.', style: inter(16, 400, color: kMuted, height: 1.35)))
                else ...[
                  Padding(padding: const EdgeInsets.only(bottom: 4, left: 4), child: Text('Invoice vs physical receiving', style: inter(14, 700, color: kMuted))),
                  for (final r in shown) Padding(padding: const EdgeInsets.only(bottom: 12), child: _lineCard(r)),
                  if (v.exceptions > 0) ...[_resolveCard(v), const SizedBox(height: 12)],
                ],
                _previewCard(v),
                const SizedBox(height: 12),
                _checklistCard(v),
                const SizedBox(height: 14),
                _actions(v),
                const SizedBox(height: 12),
                Text('Review Exceptions → Confirm Receiving → GRN Approval/Posting\nDrafts do not change posted stock.', style: inter(14, 400, color: kMuted, height: 1.4)),
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: (id) => _tab(context, id, active: 'stock')),
      ]),
    );
  }
}

/// Asks for a short reason (sending a GRN back). Owns its text controller so it is disposed with the dialog, not before it.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.title, required this.hint});
  final String title, hint;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();
  bool _empty = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(widget.title, style: inter(18, 700)),
        content: TextField(controller: _c, autofocus: true, maxLength: 200, style: inter(16, 400), decoration: InputDecoration(hintText: widget.hint, errorText: _empty ? 'Say why it is sent back.' : null)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Cancel', style: inter(15, 600, color: kMuted))),
          TextButton(onPressed: () {
                if (_c.text.trim().isEmpty) return setState(() => _empty = true);
                Navigator.of(context).pop(_c.text.trim());
              },
              child: Text('Send back', style: inter(15, 700, color: kBadText))),
        ],
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ================================================================ GRN home (the side menu's GRN entry)
/// The GRN section's first page, in the style of Figma "01 — GRN Dashboard": the receiving flow, the Receiving · GRN · Putaway · Shelf Labels
/// tabs, a count of where receipts stand, and one card per receipt shaped like the dashboard's GRN card. Tapping a card opens its dashboard.
class GrnQueueScreen extends StatefulWidget {
  const GrnQueueScreen({super.key, this.api, this.onReceive});
  final CatalogueApi? api;

  /// Opens Receiving (count a delivery and send it to GRN review). Null: the Stock tab.
  final void Function(BuildContext context)? onReceive;
  @override
  State<GrnQueueScreen> createState() => _GrnQueueState();
}

class _GrnQueueState extends State<GrnQueueScreen> {
  late final CatalogueApi _api = widget.api ?? CatalogueApi();
  List<GrnQueueRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.grnQueue();
      if (!mounted) return;
      setState(() {
        _rows = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  void _receive() => widget.onReceive != null ? widget.onReceive!(context) : HomeNav.go(context, HomeNav.stock, 'Stock');

  Future<void> _open(GrnQueueRow r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => GrnDashboardScreen(receiptId: r.receiptId, api: _api)));
    if (mounted) _load();
  }

  static bool _done(GrnQueueRow r) => r.reviewStatus == 'approved' || r.reviewStatus == 'cancelled';

  String _label(GrnQueueRow r) => switch (r.reviewStatus) {
        'approved' => 'Approved',
        'cancelled' => 'Cancelled',
        'approval_due' => 'Approval due',
        'matching' => r.hasInvoice ? ((r.exceptions ?? 0) > 0 ? '${r.exceptions} to review' : 'Matches') : 'Needs invoice',
        _ => 'Not opened',
      };

  Widget _tabs() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (label, on) in [('Receiving', false), ('GRN', true), ('Putaway', false), ('Shelf Labels', false)]) ...[
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: on ? null : () => label == 'Receiving' ? _receive() : showToast(context, '$label is not in this release.'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: on ? kLime : Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: on ? kLime : const Color(0xFFE3E5DF))),
                child: Text(label, style: inter(14, on ? 700 : 500, color: kDark)),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      );

  Widget _stat(String label, int n, {bool alert = false}) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE3E5DF))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$n', style: inter(24, 800, color: alert && n > 0 ? kWarnText : kInk)),
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k, style: inter(14, 400, color: kMuted)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 600))),
        ]),
      );

  Widget _card(GrnQueueRow r) {
    final refs = [if (r.grnNo.isNotEmpty) r.docNo, if (r.poRef.isNotEmpty) r.poRef, if (r.invoiceNo.isNotEmpty) r.invoiceNo].join(' / ');
    final approved = r.reviewStatus == 'approved';
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _open(r),
      child: OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.grnNo.isEmpty ? r.docNo : r.grnNo, style: inter(18, 800)),
                if (refs.isNotEmpty) Text(refs, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 400, color: kMuted)),
              ]),
            ),
            const SizedBox(width: 8),
            DotChip(_label(r), bg: approved ? kLimeSoft : const Color(0xFFEEF1EA), fg: approved ? kGreenText : kInk),
          ]),
          const SizedBox(height: 8),
          _kv('Supplier', r.supplier.isEmpty ? 'Not entered' : r.supplier),
          _kv('Supplier invoice', r.hasInvoice ? (r.invoiceNo.isEmpty ? 'Entered' : r.invoiceNo) : 'Not entered'),
          _kv('Posting status', approved ? 'Posted' : (r.reviewStatus == 'cancelled' ? 'Nothing posted' : 'Not posted')),
        ]),
      ),
    );
  }

  Widget _group(String title, List<GrnQueueRow> rows) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(title, style: inter(14, 700, color: kMuted))),
        for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 12), child: _card(r)),
      ]);

  Widget _empty() => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(14)),
            child: const Icon(LucideIcons.packageCheck, size: 22, color: kGreenText),
          ),
          const SizedBox(height: 12),
          Text('No receipts waiting for GRN', style: inter(18, 700)),
          const SizedBox(height: 4),
          Text('When a delivery arrives, count it in Receiving and send it to GRN review. It shows up here to match against the supplier invoice.',
              style: inter(14, 400, color: kMuted, height: 1.4)),
          const SizedBox(height: 14),
          for (final (i, step) in const ['Count the delivery in Receiving', 'Match it against the supplier invoice', 'Owner approves · stock is posted'].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0xFFEEF1EA), shape: BoxShape.circle),
                  child: Text('${i + 1}', style: inter(12, 700)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(step, style: inter(14, 500))),
              ]),
            ),
          const SizedBox(height: 6),
          DarkButton('Receive stock', onPressed: _receive),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final review = rows?.where((r) => !_done(r) && r.reviewStatus != 'approval_due').toList() ?? const <GrnQueueRow>[];
    final due = rows?.where((r) => r.reviewStatus == 'approval_due').toList() ?? const <GrnQueueRow>[];
    final done = rows?.where(_done).toList() ?? const <GrnQueueRow>[];
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'GRN', onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
              Text('Goods receipts', style: inter(24, 800)),
              const SizedBox(height: 2),
              Text('Open receipt → Scan/Enter Products → Match Invoice', style: inter(14, 400, color: kMuted)),
              const SizedBox(height: 14),
              _tabs(),
              const SizedBox(height: 14),
              if (_error != null && rows == null)
                Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted))))
              else if (rows == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else ...[
                Row(children: [
                  _stat('To review', review.length, alert: true),
                  const SizedBox(width: 10),
                  _stat('Approval due', due.length, alert: true),
                  const SizedBox(width: 10),
                  _stat('Posted', done.length),
                ]),
                if (rows.isEmpty) ...[const SizedBox(height: 14), _empty()],
                if (review.isNotEmpty) _group('Needs review', review),
                if (due.isNotEmpty) _group('Waiting for owner approval', due),
                if (done.isNotEmpty) _group('Done in the last 30 days', done),
                if (rows.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Drafts do not change posted stock. Stock changes only when the owner approves.', style: inter(13, 400, color: kMuted, height: 1.4)),
                ],
              ],
            ]),
          ),
        ),
        PosBottomNav(active: 'stock', onTap: (id) => _tab(context, id, active: 'stock')),
      ]),
    );
  }
}

/// The billed unit price of one product. When the invoice bills it on several lines at different prices (`price_mixed`), the database
/// sends no single price, so the average (amount / quantity) is shown; the row is a price difference either way.
num? invoiceUnitMinor(Map<String, dynamic>? inv) {
  if (inv == null) return null;
  final p = inv['unit_price_minor'] as num?;
  if (p != null) return p;
  final amount = inv['amount_minor'] as num?, q = inv['qty'] as num?;
  return amount == null || q == null || q == 0 ? null : (amount / q).round();
}
