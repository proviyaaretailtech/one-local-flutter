import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../sell/sell_widgets.dart';
import '../ui/theme.dart';
import 'shift_api.dart';

String _amountText(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// Rounded ₹ field used by the shift screens (same look as "Amount Received" on the payment screen).
class CashField extends StatelessWidget {
  const CashField({super.key, required this.controller, this.onChanged, this.fieldKey});
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFD9DBD3))),
        child: Row(children: [
          Text('₹', style: inter(22, 800)),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              key: fieldKey,
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              style: inter(22, 800),
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: '0', hintStyle: inter(22, 800, color: kKicker)),
              onChanged: onChanged,
            ),
          ),
        ]),
      );
}

/// Founder Correct Flow S5.1 "Open shift": count the cash in the drawer and open the store's shift, once, before the first bill.
/// The database refuses a second open shift at the same store and, when the store requires it, any bill while no shift is open.
/// Pops `true` once the shift is open.
class OpenShiftScreen extends StatefulWidget {
  const OpenShiftScreen({super.key, required this.api, this.storeLine = 'OneLocal', this.initials = 'RP', this.required = false});
  final ShiftApi api;
  final String storeLine, initials;

  /// The store does not take bills without a shift (the database said so): the screen says it plainly.
  final bool required;
  @override
  State<OpenShiftScreen> createState() => _OpenShiftScreenState();
}

class _OpenShiftScreenState extends State<OpenShiftScreen> {
  final _float = TextEditingController();
  String? _key, _error;
  bool _busy = false;

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final v = num.tryParse(_float.text.trim());
    if (v == null) {
      setState(() => _error = 'Enter the cash in the drawer (0 if it is empty).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _key ??= OrdersApi.newKey(); // a second tap or a retry opens the same shift
    try {
      final s = await widget.api.open(openingFloat: v, key: _key!);
      if (!mounted) return;
      showToast(context, '${s.shiftNo} open with ${rupees(s.openingFloat)} in the drawer.');
      Navigator.of(context).pop(true);
    } on OrdersApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'shift_open') {
        showToast(context, e.message);
        Navigator.of(context).pop(true); // someone else opened it: the till can bill
        return;
      }
      setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = sellErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          SellTopBar(onBack: () => Navigator.maybePop(context), initials: widget.initials),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 16), children: [
              SellTitle('Open shift', sub: widget.storeLine),
              const SizedBox(height: 14),
              if (widget.required) ...[
                const StateNote(tone: 'warn', title: 'Open the shift before the first bill', body: 'This store takes no payment while the cash shift is closed.'),
                const SizedBox(height: 14),
              ],
              OrderCardBox(
                radius: 22,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Kick('Opening cash in the drawer'),
                  const SizedBox(height: 10),
                  CashField(controller: _float, fieldKey: const ValueKey('float-field'), onChanged: (_) => setState(() {})),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final v in const [0, 500, 1000, 2000])
                      ChoiceChip(
                        label: Text(rupees(v)),
                        selected: num.tryParse(_float.text) == v,
                        selectedColor: const Color(0xFF7BEE00),
                        onSelected: (_) => setState(() => _float.text = _amountText(v)),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Text('Count the notes and coins before the first bill. You open the shift once; everyone billing at this store bills into it until it is closed.',
                      style: inter(13, 400, color: kMuted, height: 1.4)),
                ]),
              ),
              if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: inter(13, 500, color: kBadText))],
              const SizedBox(height: 18),
              DarkCta(label: 'Open shift', busy: _busy, onPressed: _open),
            ]),
          ),
        ]),
      );
}

/// Founder Correct Flow S6.6 "Close shift": what the drawer should hold (read from the store's payments and refunds by the database),
/// cash in and out, the count, the difference with a reason, close. A difference above the store's limit waits for another manager's
/// approval; managers see those shifts here and approve them. Without an open shift it offers to open one.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key, required this.api, this.storeLine = 'OneLocal', this.initials = 'RP'});
  final ShiftApi api;
  final String storeLine, initials;
  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  ShiftApi get api => widget.api;
  ShiftState? _state;
  List<TillShift> _history = const [];
  TillShift? _closed; // the shift this screen just closed (its result card)
  String? _error, _closeKey;
  final _counted = TextEditingController(), _reason = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await api.current();
      List<TillShift> h = const [];
      try {
        h = await api.history(limit: 5);
      } catch (_) {/* the history is a convenience; the drawer is what matters */}
      if (mounted) {
        setState(() {
          _state = s;
          _history = h;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = sellErrorText(e));
    }
  }

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showToast(context, sellErrorText(e)); // the database's sentence: no reason, too much out, only a manager ...
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openShift() async {
    final opened = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => OpenShiftScreen(api: api, storeLine: widget.storeLine, initials: widget.initials, required: _state?.requireOpenShift == true)));
    if (opened == true && mounted) {
      setState(() => _closed = null);
      await _load();
    }
  }

  Future<void> _cashMove(TillShift s, String kind) async {
    final amount = TextEditingController(), reason = TextEditingController();
    final key = OrdersApi.newKey();
    final go = await showOrderSheet<bool>(
      context,
      title: kind == 'in' ? 'Cash in' : 'Cash out',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(kind == 'in' ? 'Cash put into the drawer (change from the bank, a top-up).' : 'Cash taken out of the drawer (paid a courier, moved to the safe).',
            style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        CashField(controller: amount, fieldKey: const ValueKey('move-amount')),
        const SizedBox(height: 10),
        TextField(key: const ValueKey('move-reason'), controller: reason, decoration: const InputDecoration(hintText: 'Reason')),
        const SizedBox(height: 16),
        DarkCta(label: kind == 'in' ? 'Add cash in' : 'Take cash out', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (go != true || !mounted) return;
    final v = num.tryParse(amount.text.trim());
    if (v == null || v <= 0) {
      showToast(context, 'Enter the amount.');
      return;
    }
    await _guard(() async {
      await api.cashMove(s.id, kind: kind, amount: v, reason: reason.text.trim(), key: key);
      if (mounted) showToast(context, '${kind == 'in' ? 'Cash in' : 'Cash out'} ${rupees(v)} recorded.');
      await _load();
    });
  }

  Future<void> _close(TillShift s) async {
    final counted = num.tryParse(_counted.text.trim());
    if (counted == null) {
      showToast(context, 'Enter the cash you counted in the drawer.');
      return;
    }
    _closeKey ??= OrdersApi.newKey();
    await _guard(() async {
      final c = await api.close(s.id, counted: counted, reason: _reason.text, key: _closeKey!, version: s.version);
      _closeKey = null;
      _counted.clear();
      _reason.clear();
      if (mounted) setState(() => _closed = c);
      await _load();
    });
  }

  Future<void> _approve(TillShift s) async {
    final note = TextEditingController();
    final go = await showOrderSheet<bool>(
      context,
      title: 'Approve ${s.shiftNo}',
      body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Difference ${_signed(s.variance ?? 0)} · ${s.varianceReason ?? ''}', style: inter(13, 400, color: kMuted)),
        const SizedBox(height: 12),
        TextField(key: const ValueKey('approve-note'), controller: note, decoration: const InputDecoration(hintText: 'Your note (what you checked)')),
        const SizedBox(height: 16),
        DarkCta(label: 'Approve difference', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    );
    if (go != true || !mounted) return;
    await _guard(() async {
      await api.approve(s.id, note: note.text.trim());
      if (mounted) showToast(context, '${s.shiftNo} approved and closed.');
      await _load();
    });
  }

  static String _signed(num v) => v == 0 ? rupees(0) : v > 0 ? '+${rupees(v)}' : '−${rupees(-v)}';

  @override
  Widget build(BuildContext context) {
    final st = _state;
    final s = st?.shift;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        SellTopBar(onBack: () => Navigator.maybePop(context), initials: widget.initials),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 24), children: [
              SellTitle('Cash shift', sub: st == null ? widget.storeLine : st.locationName),
              const SizedBox(height: 14),
              if (_error != null)
                StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the shift', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
              else if (st == null)
                const SkeletonRows()
              else ...[
                if (_closed != null) ...[_resultCard(_closed!), const SizedBox(height: 14)],
                if (s == null)
                  StateCard(
                    icon: LucideIcons.wallet,
                    title: 'No shift open',
                    body: st.requireOpenShift ? 'This store takes no payment until a shift is open.' : 'Open a shift to count the drawer at the end of the day.',
                    primary: 'Open shift',
                    onPrimary: _busy ? null : _openShift,
                  )
                else ...[
                  _drawerCard(s),
                  const SizedBox(height: 14),
                  _movesCard(s),
                  const SizedBox(height: 14),
                  _closeCard(s, st),
                ],
                if (st.canApprove && st.pendingApproval.isNotEmpty) ...[const SizedBox(height: 14), _approvalsCard(st.pendingApproval)],
                if (_history.isNotEmpty) ...[const SizedBox(height: 14), _historyCard()],
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _drawerCard(TillShift s) {
    final methods = s.salesByMethod;
    return OrderCardBox(
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s.shiftNo, style: inter(18, 800))),
          const DotChip('Open', bg: kLimeSoft, fg: kGreenText),
        ]),
        const SizedBox(height: 2),
        Text('Opened ${s.openedAt} · ${s.bills} ${s.bills == 1 ? 'bill' : 'bills'}', style: inter(13, 400, color: kMuted)),
        const Divider(height: 22, color: kLine),
        KeyValue('Opening cash', rupees(s.openingFloat), size: 14),
        KeyValue('Cash sales', '+${rupees(s.cashSales)}', size: 14),
        if (s.cashIn > 0) KeyValue('Cash in', '+${rupees(s.cashIn)}', size: 14),
        if (s.cashOut > 0) KeyValue('Cash out', '−${rupees(s.cashOut)}', size: 14),
        if (s.cashRefunds > 0) KeyValue('Cash refunds', '−${rupees(s.cashRefunds)}', size: 14, valueColor: kBadText),
        const Divider(height: 22, color: kLine),
        Row(children: [
          Text('Expected in drawer', style: inter(16, 800)),
          const Spacer(),
          Text(rupees(s.expectedCash), key: const ValueKey('expected-cash'), style: inter(24, 800, color: kGreenText)),
        ]),
        if (methods.keys.any((m) => m != 'cash')) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in methods.entries) TagChip('${const {'cash': 'Cash', 'upi': 'UPI', 'card': 'Card', 'wallet': 'Wallet', 'other': 'Other'}[e.key] ?? e.key} ${rupees(e.value)}', bg: kSoftField, fg: kInk),
          ]),
          const SizedBox(height: 4),
          Text('UPI and card are not in the drawer; they are shown for the day\'s total.', style: inter(12, 400, color: kKicker)),
        ],
      ]),
    );
  }

  Widget _movesCard(TillShift s) => OrderCardBox(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kick('Cash in / out'),
          const SizedBox(height: 6),
          if (s.cashMoves.isEmpty) Text('Nothing put in or taken out yet.', style: inter(13, 400, color: kMuted)),
          for (final m in s.cashMoves)
            KeyValue('${m['kind'] == 'in' ? 'In' : 'Out'} · ${m['reason']}', '${m['kind'] == 'in' ? '+' : '−'}${rupees((m['amount'] ?? 0) as num)}', size: 13.5),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: LightCta(label: 'Cash in', icon: LucideIcons.plus, onPressed: _busy ? null : () => _cashMove(s, 'in'))),
            const SizedBox(width: 10),
            Expanded(child: LightCta(label: 'Cash out', icon: LucideIcons.minus, onPressed: _busy ? null : () => _cashMove(s, 'out'))),
          ]),
        ]),
      );

  Widget _closeCard(TillShift s, ShiftState st) {
    final counted = num.tryParse(_counted.text.trim());
    final diff = counted == null ? null : ((counted - s.expectedCash) * 100).round() / 100; // shown while typing; the database works it out again on close
    return OrderCardBox(
      radius: 22,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Kick('Count and close'),
        const SizedBox(height: 10),
        Text('Cash counted in the drawer', style: inter(13, 600, color: kMuted)),
        const SizedBox(height: 6),
        CashField(controller: _counted, fieldKey: const ValueKey('counted-field'), onChanged: (_) => setState(() {})),
        if (diff != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Text('Difference', style: inter(15, 500, color: kMuted)),
            const Spacer(),
            Text(_signed(diff), style: inter(20, 800, color: diff == 0 ? kGreenText : kBadText)),
          ]),
        ],
        if (diff != null && diff != 0) ...[
          const SizedBox(height: 10),
          TextField(key: const ValueKey('variance-reason'), controller: _reason, maxLength: 200, decoration: const InputDecoration(hintText: 'Why is the count different? (required)')),
          Text(diff.abs() > st.varianceLimit ? 'Above ${rupees(st.varianceLimit)}: another manager approves it before the shift is closed.' : 'Within the store limit of ${rupees(st.varianceLimit)}.',
              style: inter(12.5, 500, color: diff.abs() > st.varianceLimit ? kWarnText : kMuted)),
        ],
        const SizedBox(height: 14),
        DarkCta(label: 'Close shift', busy: _busy, onPressed: () => _close(s)),
      ]),
    );
  }

  Widget _resultCard(TillShift c) => StateNote(
        tone: c.pendingApproval ? 'warn' : 'info',
        title: c.pendingApproval ? '${c.shiftNo} is waiting for a manager' : '${c.shiftNo} closed',
        body: 'Expected ${rupees(c.expectedCash)} · counted ${rupees(c.countedCash ?? 0)} · difference ${_signed(c.variance ?? 0)}'
            '${c.varianceReason == null ? '' : ' (${c.varianceReason})'}'
            '${c.pendingApproval ? '. The difference is above the store limit; another manager approves it.' : '.'}',
      );

  Widget _approvalsCard(List<TillShift> list) => OrderCardBox(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kick('Waiting for your approval'),
          for (final s in list) ...[
            const SizedBox(height: 8),
            Text('${s.shiftNo} · closed ${s.closedAt}', style: inter(14, 700)),
            Text('Expected ${rupees(s.expectedCash)} · counted ${rupees(s.countedCash ?? 0)} · ${_signed(s.variance ?? 0)}', style: inter(13, 400, color: kMuted)),
            if (s.varianceReason != null) Text('Reason: ${s.varianceReason}', style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 8),
            DarkCta(label: 'Approve ${s.shiftNo}', onPressed: _busy ? null : () => _approve(s)),
          ],
        ]),
      );

  Widget _historyCard() => OrderCardBox(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kick('Recent shifts'),
          const SizedBox(height: 6),
          for (final h in _history)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text('${h.shiftNo} · ${h.openedAt}', style: inter(13.5, 600))),
                Text(h.isOpen ? 'Open' : '${h.statusLabel} · ${_signed(h.variance ?? 0)}', style: inter(12.5, 500, color: h.pendingApproval ? kWarnText : kMuted)),
              ]),
            ),
        ]),
      );
}
