import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'bill_api.dart';
import 'table_widgets.dart';

/// Cancel a dish, cancel KOT items, refund and void a restaurant bill (database 0640, founder 2 Nov 2026). The database decides who may do
/// what: a dish already cooking or served, or on a generated bill, needs a manager; a refund needs a manager; a void the owner or an admin.
/// Anyone else's tap becomes a request a manager approves (the screens say so). Every action asks "Are you sure?" first.

const _red = Color(0xFFB91C1C);
const _amber = Color(0xFFB45309);

/// What a reply means, in a sentence for the toast.
String adjustDone(Facts r) => switch (r.s('status')) {
      'requested' => r.b('replayed') ? 'Already asked; waiting for a manager.' : 'Sent to a manager to approve.',
      'cancelled' => 'Cancelled. The bill is now ${money(r.n('new_total'))}.',
      'refunded' => '${money(r.n('amount'))} refunded.',
      'voided' => r.n('refunded') > 0 ? 'Bill voided; ${money(r.n('refunded'))} refunded.' : 'Bill voided.',
      'rejected' => 'Request rejected.',
      _ => 'Done.',
    };

Future<bool> _sure(BuildContext context, {required String title, required String body, String yes = 'Yes'}) async =>
    await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title, style: inter(18, 700)),
        content: Text(body, style: inter(15, 400, color: kMuted)),
        actions: [
          TextButton(key: const ValueKey('adj-sure-no'), onPressed: () => Navigator.pop(c, false), child: const Text('No')),
          TextButton(key: const ValueKey('adj-sure-yes'), onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + MediaQuery.viewInsetsOf(c).bottom),
        child: SafeArea(top: false, child: SingleChildScrollView(child: child)),
      ),
    );

Widget _grip() => Center(
      child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4))),
    );

Widget _reasonField(TextEditingController c, List<String> quick, String prefix, VoidCallback changed) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: ValueKey('$prefix-reason'),
        controller: c,
        maxLength: 200,
        onChanged: (_) => changed(),
        decoration: InputDecoration(labelText: 'Reason', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
      ),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final r in quick)
          ActionChip(
              key: ValueKey('$prefix-reason-$r'),
              label: Text(r, style: inter(12.5, 600)),
              onPressed: () {
                c.text = r;
                changed();
              }),
      ]),
    ]);

String _dish(Facts i) => '${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}';

// ---------------------------------------------------------------- cancel dishes

/// Choose dishes and how many, with a reason; answers true when something was cancelled or asked. [kitchenOnly]: only dishes already on a
/// KOT (the KOT screen's Cancel item).
Future<bool> showCancelItemsSheet(BuildContext context, {required BillApi api, required String orderId, bool kitchenOnly = false}) async {
  final Facts v;
  try {
    v = await api.adjustView(orderId);
  } catch (e) {
    if (context.mounted) showToast(context, sayError(e));
    return false;
  }
  if (!context.mounted) return false;
  if (v.m('can').b('cancel_items') != true) {
    showToast(context, v.m('unavailable').so('cancel_items') ?? 'Dishes cannot be cancelled on this bill.');
    return false;
  }
  final items = v.l('items').where((i) => i.s('status') != 'cancelled' && i.n('qty') > 0 && (!kitchenOnly || i.b('sent'))).toList();
  if (items.isEmpty) {
    showToast(context, kitchenOnly ? 'Nothing on this order\'s KOTs can be cancelled.' : 'Nothing on this order can be cancelled.');
    return false;
  }
  final r = await _sheet<Facts>(context, _CancelSheet(api: api, order: v, items: items, kitchenOnly: kitchenOnly));
  if (r == null) return false;
  if (context.mounted) showToast(context, adjustDone(r));
  return true;
}

class _CancelSheet extends StatefulWidget {
  const _CancelSheet({required this.api, required this.order, required this.items, required this.kitchenOnly});
  final BillApi api;
  final Facts order;
  final List<Facts> items;
  final bool kitchenOnly;
  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  final _pick = <String, int>{};
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error, _key;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  int get _count => _pick.values.fold(0, (s, n) => s + n);
  bool get _needsManager => widget.items.any((i) => (_pick[i.s('id')] ?? 0) > 0 && i.b('needs_manager')) && !widget.order.m('can').b('is_manager');

  void _set(String id, int n) => setState(() {
        _key = null; // a different choice is a different request
        if (n <= 0) {
          _pick.remove(id);
        } else {
          _pick[id] = n;
        }
      });

  Future<void> _go() async {
    if (_count == 0) return setState(() => _error = 'Choose a dish to cancel.');
    if (_reason.text.trim().length < 3) return setState(() => _error = 'Say why (3 characters or more).');
    final what = [for (final i in widget.items) if ((_pick[i.s('id')] ?? 0) > 0) '${_pick[i.s('id')]}× ${_dish(i)}'].join(', ');
    final kitchen = widget.items.any((i) => (_pick[i.s('id')] ?? 0) > 0 && i.b('sent'));
    final ok = await _sure(context,
        title: _needsManager ? 'Ask a manager to cancel?' : 'Are you sure you want to cancel?',
        body: '$what.${kitchen ? ' The kitchen is told to stop.' : ''}${_needsManager ? ' A manager approves before it comes off the bill.' : ''}',
        yes: _needsManager ? 'Yes, ask' : 'Yes, cancel');
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.cancelItems(widget.order.s('id'), Map.of(_pick), reason: _reason.text, key: _key ??= BillApi.newKey());
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = sayError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _grip(),
        Row(children: [
          const Icon(LucideIcons.circleX, size: 20, color: _red),
          const SizedBox(width: 8),
          Expanded(child: Text('${widget.kitchenOnly ? 'Cancel KOT item' : 'Cancel item'} · ${widget.order.s('display_no')}', style: inter(19, 800))),
        ]),
        Text('Choose the dishes and how many. The bill, tax and charges follow.', style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 10),
        for (final (n, i) in widget.items.indexed) _line(n, i),
        const SizedBox(height: 10),
        _reasonField(_reason, const ['Added by mistake', 'Guest changed mind', 'Out of stock', 'Taking too long', 'Wrong dish'], 'cancel', () => setState(() => _error = null)),
        if (_needsManager)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('A dish being cooked or served, or a billed one, needs a manager: this will be sent for approval.',
                key: const ValueKey('cancel-needs-manager'), style: inter(13, 600, color: _amber)),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('cancel-error'), style: inter(14, 500, color: kError))),
        const SizedBox(height: 12),
        LimeButton(
          _count == 0 ? 'Choose a dish' : '${_needsManager ? 'Ask to cancel' : 'Cancel'} $_count ${_count == 1 ? 'dish' : 'dishes'}',
          key: const ValueKey('cancel-go'),
          busy: _busy,
          onPressed: _busy || _count == 0 ? null : _go,
        ),
      ]);

  Widget _line(int n, Facts i) {
    final id = i.s('id'), max = i.n('qty').toInt(), got = _pick[id] ?? 0;
    final where = !i.b('sent')
        ? 'Not sent to kitchen'
        : [if (i.no('kot_no') != null) 'KOT ${i.n('kot_no').toInt()}', switch (i.s('status')) { 'preparing' => 'Cooking', 'ready' => 'Ready', 'delivered' => 'Served', _ => 'Waiting' }].join(' · ');
    return Container(
      key: ValueKey('cancel-line-$n'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: got > 0 ? const Color(0xFFFFF1F2) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: got > 0 ? const Color(0xFFFCA5A5) : const Color(0xFFE5E7EB)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$max× ${_dish(i)}', style: inter(15, 700)),
            Text('$where${i.n('cancelled_qty') > 0 ? ' · ${i.n('cancelled_qty').toInt()} cancelled before' : ''}',
                style: inter(12.5, 500, color: i.b('needs_manager') ? _amber : kMuted)),
          ]),
        ),
        IconButton(key: ValueKey('cancel-minus-$n'), onPressed: got == 0 ? null : () => _set(id, got - 1), icon: const Icon(LucideIcons.minus, size: 18)),
        SizedBox(width: 26, child: Text('$got', key: ValueKey('cancel-qty-$n'), textAlign: TextAlign.center, style: inter(16, 800))),
        IconButton(key: ValueKey('cancel-plus-$n'), onPressed: got >= max ? null : () => _set(id, got + 1), icon: const Icon(LucideIcons.plus, size: 18)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- payment details: refund, void, history, requests

/// Payment details of one bill (founder: Billing → Void bill / Refund; Payment details → refund history; Order history → cancelled items):
/// what was paid, refunded and can still be refunded, every payment and refund, the dishes cancelled and the requests waiting.
class BillMoneyScreen extends StatefulWidget {
  const BillMoneyScreen({super.key, required this.api, required this.orderId});
  final BillApi api;
  final String orderId;

  static Route<bool> route(BillApi api, String orderId) => MaterialPageRoute(builder: (_) => BillMoneyScreen(api: api, orderId: orderId));

  @override
  State<BillMoneyScreen> createState() => _BillMoneyScreenState();
}

class _BillMoneyScreenState extends State<BillMoneyScreen> {
  Facts? _v;
  String? _error;
  bool _busy = false, _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.api.adjustView(widget.orderId);
      if (mounted) {
        setState(() {
          _v = v;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  void _off(String key) => showToast(context, _v?.m('unavailable').so(key) ?? 'Not available on this bill.');

  Future<void> _after(Future<Facts?> Function() run) async {
    setState(() => _busy = true);
    try {
      final r = await run();
      if (r != null) {
        _changed = true;
        if (mounted) showToast(context, adjustDone(r));
      }
    } catch (e) {
      if (mounted) showToast(context, sayError(e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _decide(Facts q, bool approve) => _after(() async {
        final ok = await _sure(context,
            title: approve ? 'Approve this request?' : 'Reject this request?',
            body: '${q.s('message')}\nAsked by ${q.so('asked_by') ?? 'staff'}.${approve ? ' It is done now, in your name.' : ''}',
            yes: approve ? 'Yes, approve' : 'Yes, reject');
        if (!ok) return null;
        return widget.api.decide(q.s('request_id'), approve: approve);
      });

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final can = v?.m('can');
    final m = v?.m('money');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            AppHeader(title: 'Payment details', back: true, backKey: const ValueKey('adj-back'), under: v == null ? null : Text('Bill ${v.s('display_no')}${v.so('table_label') == null ? '' : ' · Table ${v.s('table_label')}'}', style: inter(13.5, 400, color: kMuted))),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 30), children: [
                  if (v == null && _error == null) tablesLoading(),
                  if (_error != null) TablesError(_error!, onRetry: _load),
                  if (v != null && m != null) ...[
                    _summary(v, m),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: _action('Refund', 'refund', LucideIcons.undo2, const Color(0xFF2563EB), can!, () => _after(() => _refund(v)))),
                      const SizedBox(width: 10),
                      Expanded(child: _action('Void bill', 'void', LucideIcons.ban, _red, can, () => _after(() => _void(v)))),
                      const SizedBox(width: 10),
                      Expanded(child: _action('Cancel item', 'cancel_items', LucideIcons.circleX, _amber, can, () async {
                        if (await showCancelItemsSheet(context, api: widget.api, orderId: widget.orderId)) _changed = true;
                        await _load();
                      })),
                    ]),
                    if (v.l('requests').isNotEmpty) ...[_title('Waiting for approval'), for (final (n, q) in v.l('requests').indexed) _request(n, q)],
                    if (v.mo('void') != null) ...[
                      _title('Void'),
                      _row(LucideIcons.ban, 'Voided by ${v.m('void').so('by') ?? 'staff'}${v.m('void').so('approved_by') == null ? '' : ', approved by ${v.m('void').s('approved_by')}'}',
                          '${v.m('void').so('reason') ?? ''} · ${_when(v.m('void').so('at'))}', v.m('void').n('refunded') > 0 ? '−${money(v.m('void').n('refunded'))}' : null, key: const ValueKey('adj-void')),
                    ],
                    _title('Payments'),
                    if (v.l('payments').isEmpty) _empty('No payment yet.'),
                    for (final (n, p) in v.l('payments').indexed)
                      _row(LucideIcons.wallet, methodName(p.s('method')), [if ((p.so('by') ?? '').isNotEmpty) p.s('by'), _when(p.so('at')), if ((p.so('reference') ?? '').isNotEmpty) p.s('reference')].join(' · '),
                          money(p.n('amount')), key: ValueKey('adj-pay-$n')),
                    _title('Refund history'),
                    if (v.l('refunds').isEmpty) _empty('No refunds on this bill.'),
                    for (final (n, r) in v.l('refunds').indexed)
                      _row(LucideIcons.undo2, '${methodName(r.s('method'))} · ${r.s('reason')}',
                          [
                            'By ${r.so('by') ?? 'staff'}',
                            if ((r.so('asked_by') ?? '').isNotEmpty) 'asked by ${r.s('asked_by')}',
                            _when(r.so('at')),
                            'Ref ${r.s('id').substring(0, 8)}',
                          ].join(' · '),
                          '−${money(r.n('amount'))}',
                          key: ValueKey('adj-refund-$n')),
                    _title('Cancelled items'),
                    if (v.l('cancelled_items').isEmpty) _empty('No dishes cancelled.'),
                    for (final (n, c) in v.l('cancelled_items').indexed)
                      _row(LucideIcons.circleX, '${c.n('qty').toInt()}× ${_dish(c)}${c.no('kot_no') != null ? ' · KOT ${c.s('kot_no')}' : ''}',
                          [c.s('reason'), 'by ${c.so('by') ?? 'staff'}', if ((c.so('approved_by') ?? '').isNotEmpty) 'approved by ${c.s('approved_by')}', _when(c.so('at'))].join(' · '),
                          '−${money(c.n('value'))}',
                          key: ValueKey('adj-cancelled-$n')),
                  ],
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  static String _when(String? at) {
    final d = at == null ? null : DateTime.tryParse(at)?.toLocal();
    if (d == null) return '';
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  static const _statusNames = {
    'unpaid': ('Not paid', kMuted),
    'part_paid': ('Part paid', _amber),
    'paid': ('Paid', Color(0xFF15803D)),
    'partly_refunded': ('Partly refunded', _amber),
    'refunded': ('Refunded', _red),
  };

  Widget _summary(Facts v, Facts m) {
    final (label, tint) = v.s('status') == 'cancelled' ? ('Void', _red) : (_statusNames[m.s('payment_status')] ?? (m.s('payment_status'), kMuted));
    Widget line(String a, num b, {bool strong = false, Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(a, style: inter(14.5, strong ? 800 : 500, color: strong ? kInk : kMuted))),
            Text(money(b), key: key, style: inter(15, strong ? 800 : 700)),
          ]),
        );
    return Container(
      key: const ValueKey('adj-summary'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Bill ${v.s('display_no')}', style: inter(17, 800))),
          Container(
            key: const ValueKey('adj-status'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: tint.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
            child: Text(label, style: inter(12.5, 800, color: tint)),
          ),
        ]),
        const SizedBox(height: 8),
        line('Bill total', m.n('total')),
        line('Paid', m.n('paid'), key: const ValueKey('adj-paid')),
        if (m.n('on_credit') > 0) line('On credit', m.n('on_credit')),
        line('Refunded', m.n('refunded'), key: const ValueKey('adj-refunded')),
        const Divider(),
        line('Can still be refunded', m.n('refundable'), strong: true, key: const ValueKey('adj-refundable')),
      ]),
    );
  }

  Widget _action(String label, String key, IconData icon, Color tint, Facts can, VoidCallback run) {
    final on = can.b(key) == true;
    return Opacity(
      opacity: on ? 1 : .45,
      child: OutlinedButton.icon(
        key: ValueKey('adj-$key'),
        style: OutlinedButton.styleFrom(
          foregroundColor: tint,
          side: BorderSide(color: tint.withValues(alpha: .4)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _busy ? null : () => on ? run() : _off(key),
        icon: Icon(icon, size: 18),
        label: Text(label, style: inter(13.5, 800, color: tint)),
      ),
    );
  }

  Widget _title(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(t, style: inter(15, 800)));
  Widget _empty(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: Text(t, style: inter(13.5, 500, color: kMuted)));

  Widget _row(IconData icon, String title, String sub, String? amount, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14.5, 700)),
              if (sub.isNotEmpty) Text(sub, style: inter(12.5, 500, color: kMuted)),
            ]),
          ),
          if (amount != null) Text(amount, style: inter(14.5, 800)),
        ]),
      );

  Widget _request(int n, Facts q) => Container(
        key: ValueKey('adj-request-$n'),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFCD34D))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(q.s('message'), style: inter(14, 700)),
          Text('Asked by ${q.so('asked_by') ?? 'staff'} · ${_when(q.so('at'))}', style: inter(12.5, 500, color: kMuted)),
          if (q.b('may_decide'))
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(key: ValueKey('adj-reject-$n'), onPressed: _busy ? null : () => _decide(q, false), child: Text('Reject', style: inter(14, 800, color: _red))),
              TextButton(key: ValueKey('adj-approve-$n'), onPressed: _busy ? null : () => _decide(q, true), child: Text('Approve', style: inter(14, 800, color: const Color(0xFF15803D)))),
            ])
          else
            Padding(padding: const EdgeInsets.only(top: 4, bottom: 4), child: Text('Waiting for ${q.s('action') == 'void' ? 'the owner or an admin' : 'a manager'}.', style: inter(12.5, 600, color: _amber))),
        ]),
      );

  Future<Facts?> _refund(Facts v) => _sheet<Facts>(context, _MoneySheet(api: widget.api, order: v, voiding: false));
  Future<Facts?> _void(Facts v) => _sheet<Facts>(context, _MoneySheet(api: widget.api, order: v, voiding: true));
}

/// Refund (amount, how it goes back, reason) or Void (reason, and how money taken goes back). The amounts are checked again by the database.
class _MoneySheet extends StatefulWidget {
  const _MoneySheet({required this.api, required this.order, required this.voiding});
  final BillApi api;
  final Facts order;
  final bool voiding;
  @override
  State<_MoneySheet> createState() => _MoneySheetState();
}

class _MoneySheetState extends State<_MoneySheet> {
  final _amount = TextEditingController(), _reason = TextEditingController();
  String? _method, _error, _key;
  bool _busy = false;

  Facts get _m => widget.order.m('money');
  num get _left => _m.n('refundable');
  num get _typed => num.tryParse(_amount.text.trim()) ?? 0;
  bool get _mgr => widget.order.m('can').b('is_manager');
  bool get _owner => widget.order.m('can').b('is_owner');
  bool get _asks => widget.voiding ? !_owner : !_mgr;

  @override
  void initState() {
    super.initState();
    if (!widget.voiding) _amount.text = _plain(_left);
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  static String _plain(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);

  Future<void> _go() async {
    final needMethod = !widget.voiding || _left > 0;
    if (!widget.voiding && _typed <= 0) return setState(() => _error = 'Enter the amount to refund.');
    if (!widget.voiding && _typed > _left + .005) return setState(() => _error = 'At most ${money(_left)} can be refunded on this bill.');
    if (needMethod && _method == null) return setState(() => _error = 'Choose how the money goes back.');
    if (_reason.text.trim().length < 3) return setState(() => _error = 'Say why (3 characters or more).');
    final ok = await _sure(context,
        title: widget.voiding
            ? (_asks ? 'Ask the owner to void this bill?' : 'Are you sure you want to void this bill?')
            : (_asks ? 'Ask a manager to refund ${money(_typed)}?' : 'Are you sure you want to refund ${money(_typed)}?'),
        body: widget.voiding
            ? 'Bill ${widget.order.s('display_no')} is cancelled${_left > 0 ? ' and ${money(_left)} goes back by ${methodName(_method!)}' : ''}. This cannot be undone.'
            : '${money(_typed)} goes back by ${methodName(_method!)}. ${money(_left - _typed)} can still be refunded after this.',
        yes: _asks ? 'Yes, ask' : (widget.voiding ? 'Yes, void' : 'Yes, refund'));
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = _key ??= BillApi.newKey();
      final r = widget.voiding
          ? await widget.api.voidBill(widget.order.s('id'), reason: _reason.text, method: _left > 0 ? _method : null, key: key)
          : await widget.api.refund(widget.order.s('id'), amount: _typed, method: _method!, reason: _reason.text, key: key);
      if (mounted) Navigator.of(context).pop(r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = sayError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.voiding;
    void changed() => setState(() {
          _error = null;
          _key = null;
        });
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _grip(),
      Row(children: [
        Icon(v ? LucideIcons.ban : LucideIcons.undo2, size: 20, color: v ? _red : const Color(0xFF2563EB)),
        const SizedBox(width: 8),
        Expanded(child: Text('${v ? 'Void bill' : 'Refund'} · ${widget.order.s('display_no')}', style: inter(19, 800))),
      ]),
      Text(
          v
              ? (_left > 0 ? 'Paid ${money(_m.n('paid'))}; ${money(_left)} goes back to the guest, then the bill is cancelled.' : 'Nothing was paid; the bill is cancelled.')
              : 'Paid ${money(_m.n('paid'))} · refunded ${money(_m.n('refunded'))} · up to ${money(_left)} can be refunded.',
          key: const ValueKey('money-note'),
          style: inter(13, 500, color: kMuted)),
      const SizedBox(height: 12),
      if (!v) ...[
        TextField(
          key: const ValueKey('money-amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          onChanged: (_) => changed(),
          style: inter(26, 800),
          decoration: InputDecoration(prefixText: '₹ ', hintText: '0', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 8, children: [
            ActionChip(
                key: const ValueKey('money-full'),
                label: Text('Full ${money(_left)}', style: inter(13, 700)),
                onPressed: () {
                  _amount.text = _plain(_left);
                  changed();
                }),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      if (!v || _left > 0) ...[
        Text('Money goes back by', style: inter(13.5, 700)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final mth in const ['cash', 'upi', 'card', 'other'])
            ChoiceChip(
              key: ValueKey('money-method-$mth'),
              label: Text(methodName(mth), style: inter(13.5, 700, color: _method == mth ? kLimeBtn : kInk)),
              selected: _method == mth,
              showCheckmark: false,
              selectedColor: kInk,
              backgroundColor: Colors.white,
              onSelected: (_) => setState(() {
                _method = mth;
                changed();
              }),
            ),
        ]),
        const SizedBox(height: 12),
      ],
      _reasonField(_reason, v ? const ['Wrong bill', 'Guest left', 'Duplicate bill', 'Billed to wrong table'] : const ['Food quality', 'Wrong dish served', 'Overcharged', 'Goodwill'], 'money', changed),
      if (_asks)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(v ? 'Only the owner or an admin voids a bill: this will be sent to them to approve.' : 'Only a manager gives a refund: this will be sent to a manager to approve.',
              key: const ValueKey('money-asks'), style: inter(13, 600, color: _amber)),
        ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const ValueKey('money-error'), style: inter(14, 500, color: kError))),
      const SizedBox(height: 12),
      LimeButton(
        _asks ? (v ? 'Ask to void' : 'Ask for refund') : (v ? 'Void bill' : 'Refund ${_typed > 0 ? money(_typed) : ''}'.trim()),
        key: const ValueKey('money-go'),
        busy: _busy,
        onPressed: _busy ? null : _go,
      ),
    ]);
  }
}

/// Every request waiting in this business (managers approve or reject here; the others see what they asked).
class AdjustRequestsScreen extends StatefulWidget {
  const AdjustRequestsScreen({super.key, required this.api});
  final BillApi api;
  @override
  State<AdjustRequestsScreen> createState() => _AdjustRequestsScreenState();
}

class _AdjustRequestsScreenState extends State<AdjustRequestsScreen> {
  List<Facts>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.api.requests();
      if (mounted) {
        setState(() {
          _list = l;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sayError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            AppHeader(title: 'Approvals', back: true, backKey: const ValueKey('req-back'), under: Text('Cancels, refunds and voids waiting', style: inter(13.5, 400, color: kMuted))),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 30), children: [
                  if (_list == null && _error == null) tablesLoading(),
                  if (_error != null) TablesError(_error!, onRetry: _load),
                  if (_list != null && _list!.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text('Nothing is waiting.', style: inter(15, 500, color: kMuted)))),
                  for (final (n, q) in (_list ?? const <Facts>[]).indexed)
                    Card(
                      key: ValueKey('req-$n'),
                      elevation: 0,
                      color: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE5E7EB))),
                      child: ListTile(
                        title: Text('Bill ${q.s('display_no')}${q.so('table_label') == null ? '' : ' · Table ${q.s('table_label')}'}', style: inter(15, 800)),
                        subtitle: Text('${q.s('message')}\nAsked by ${q.so('asked_by') ?? 'staff'}', style: inter(13, 500, color: kMuted)),
                        isThreeLine: true,
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () async {
                          await Navigator.of(context).push(BillMoneyScreen.route(widget.api, q.s('order_id')));
                          await _load();
                        },
                      ),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      );
}
