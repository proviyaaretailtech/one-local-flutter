import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../orders/orders_api.dart';
import '../sell/sell_widgets.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'day_api.dart';
import 'shift_api.dart';
import 'shift_screens.dart' show CashField;

// Daily operations (founder, 31 Oct 2026): Bill → Daily operations. The store's business day starts by itself at its opening time (or on
// the first POS activity) with yesterday's counted closing cash and closing stock; here a person sees it, corrects the opening cash with a
// reason, counts the drawer at night, and a manager closes the day. Every amount comes from the database; every change is kept.

String _amt(num? v) => v == null ? '—' : rupees(v);

String _dateText(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${w[d.weekday - 1]}, ${d.day} ${m[d.month - 1]} ${d.year}';
}

String _err(Object e) => e is OrdersApiException ? e.message : 'Something went wrong. Check your connection and try again.';

/// The status as a coloured chip: Not started, Started, Provisional, Requires attention, Closed.
class DayStatusChip extends StatelessWidget {
  const DayStatusChip(this.day, {super.key});
  final BusinessDay? day;
  @override
  Widget build(BuildContext context) {
    final s = day?.status;
    final (bg, fg) = switch (s) {
      'started' => (kLimeSoft, kGreenText),
      'provisional' => (const Color(0xFFFFF4E0), const Color(0xFFB45309)),
      'attention' => (const Color(0xFFFDECEC), const Color(0xFFC62828)),
      'closed' => (const Color(0xFFEFF1F5), const Color(0xFF374151)),
      _ => (const Color(0xFFF1F2EE), kMuted),
    };
    return DotChip(day?.statusLabel ?? 'Not started', key: const ValueKey('day-status'), bg: bg, fg: fg);
  }
}

/// A page of Daily operations: the bar, a title with the store, the content.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.sub, required this.children, this.onRefresh});
  final String title, sub;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
      children: [
        SellTitle(title, sub: sub),
        const SizedBox(height: 14),
        ...children,
      ],
    );
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          SellTopBar(onBack: () => Navigator.maybePop(context)),
          Expanded(
            child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
          ),
        ],
      ),
    );
  }
}

Widget _card(List<Widget> children, {Key? key}) => OrderCardBox(
  key: key,
  radius: 22,
  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
);

Widget _line(String k, String v, {bool bold = false, Color? color, Key? key}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    children: [
      Expanded(
        child: Text(tr(k), style: inter(14, bold ? 800 : 500, color: bold ? kInk : kMuted)),
      ),
      Text(
        v,
        key: key,
        style: inter(bold ? 17 : 14.5, bold ? 800 : 700, color: color ?? kInk),
      ),
    ],
  ),
);

/// A short text box (reasons, notes).
Widget _textBox(TextEditingController c, String hint, {Key? key, ValueChanged<String>? onChanged}) => TextField(
  key: key,
  controller: c,
  maxLength: 200,
  onChanged: onChanged,
  style: inter(14.5, 500),
  decoration: InputDecoration(
    hintText: tr(hint),
    counterText: '',
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: kLine),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: kLine),
    ),
  ),
);

/// Daily operations: today's status and the seven parts of the day.
class DailyOpsScreen extends StatefulWidget {
  const DailyOpsScreen({super.key, required this.api, this.storeLine = ''});
  final ShiftApi api;
  final String storeLine;
  @override
  State<DailyOpsScreen> createState() => _DailyOpsScreenState();
}

class _DailyOpsScreenState extends State<DailyOpsScreen> {
  DayToday? _today;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.api.dayToday();
      if (mounted)
        setState(() {
          _today = t;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _go(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _today, d = t?.day;
    final needDay = d == null ? () => showToast(context, tr('The day has not started yet.')) : null;
    Widget tile(String id, IconData icon, String title, String sub, VoidCallback? onTap) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OrderCardBox(
        radius: 18,
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: ValueKey('day-tile-$id'),
            leading: CircleAvatar(
              backgroundColor: kLimeSoft,
              child: Icon(icon, size: 19, color: kInk),
            ),
            title: Text(tr(title), style: inter(15.5, 700)),
            subtitle: Text(sub, style: inter(12.5, 500, color: kMuted)),
            trailing: const Icon(LucideIcons.chevronRight, size: 18),
            onTap: onTap,
          ),
        ),
      ),
    );
    return _Page(
      title: 'Daily operations',
      sub: d?.locationName.isNotEmpty == true ? d!.locationName : widget.storeLine,
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the day', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (t == null)
          const SkeletonRows()
        else ...[
          _card([
            Row(
              children: [
                Expanded(child: Text(_dateText(t.date), style: inter(18, 800))),
                DayStatusChip(d),
              ],
            ),
            if (d?.attentionText != null) ...[
              const SizedBox(height: 8),
              Text(
                tr(d!.attentionText!),
                key: const ValueKey('day-attention'),
                style: inter(13.5, 600, color: const Color(0xFFC62828), height: 1.35),
              ),
            ],
            if (d != null && d.opening != null) ...[
              const Divider(height: 22, color: kLine),
              _line('Opening cash', _amt(d.opening)),
              if (!d.closed) _line('Cash expected now', _amt(d.expected), bold: true) else _line('Closing cash (counted)', _amt(d.counted), bold: true),
            ],
          ]),
          const SizedBox(height: 14),
          tile(
            'start',
            LucideIcons.sunrise,
            'Day start',
            d == null ? 'Not started' : '${d.statusLabel} · ${d.startedAt}',
            () => _go(DayStartScreen(api: widget.api, today: t)),
          ),
          tile(
            'opening-stock',
            LucideIcons.packageOpen,
            'Opening stock',
            d == null ? '—' : '${d.stock['opening_items'] ?? 0} items',
            needDay ?? () => _go(DayStockScreen(api: widget.api, day: d!)),
          ),
          tile(
            'opening-cash',
            LucideIcons.wallet,
            'Opening cash',
            d == null
                ? '—'
                : d.opening == null
                ? 'To enter'
                : _amt(d.opening),
            needDay ?? () => _go(OpeningCashScreen(api: widget.api, dayId: d!.id, canManage: t.canManage)),
          ),
          tile(
            'summary',
            LucideIcons.chartColumn,
            'Day summary',
            d == null ? '—' : '${d.bills} cash ${d.bills == 1 ? 'bill' : 'bills'}',
            needDay ?? () => _go(DaySummaryScreen(api: widget.api, dayId: d!.id)),
          ),
          tile(
            'closing-cash',
            LucideIcons.calculator,
            'Closing cash',
            d?.counted == null ? 'Not counted' : 'Counted ${_amt(d!.counted)}',
            needDay ?? () => _go(ClosingCashScreen(api: widget.api, dayId: d!.id)),
          ),
          tile(
            'closing',
            LucideIcons.lock,
            'Day closing',
            d?.closed == true
                ? 'Closed ${d!.closedAt}'
                : t.canManage
                ? 'Close the day'
                : 'A manager closes the day',
            needDay ?? () => _go(DayClosingScreen(api: widget.api, dayId: d!.id, canManage: t.canManage)),
          ),
          tile(
            'reports',
            LucideIcons.history,
            'Previous day reports',
            'Every day, newest first',
            () => _go(PreviousDaysScreen(api: widget.api, canManage: t.canManage)),
          ),
        ],
      ],
    );
  }
}

/// Day start: how and when today started, what it carried, and the way out when the day before was not closed.
class DayStartScreen extends StatefulWidget {
  const DayStartScreen({super.key, required this.api, required this.today});
  final ShiftApi api;
  final DayToday today;
  @override
  State<DayStartScreen> createState() => _DayStartScreenState();
}

class _DayStartScreenState extends State<DayStartScreen> {
  late DayToday _t = widget.today;
  bool _busy = false;

  Future<void> _refresh() async {
    try {
      final t = await widget.api.dayToday(start: false);
      if (mounted) setState(() => _t = t);
    } catch (_) {}
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final t = await widget.api.dayToday(trigger: 'manual');
      if (mounted) setState(() => _t = t);
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final d = _t.day;
    final prev = d?.prev;
    return _Page(
      title: 'Day start',
      sub: _dateText(_t.date),
      children: [
        if (d == null)
          StateCard(
            icon: LucideIcons.sunrise,
            title: 'Not started',
            body: 'The day starts by itself at your opening time${_t.opensAt == null ? '' : ' (${_t.opensAt!.substring(0, 5)})'}, or at the first bill.',
            primary: _t.canCount ? 'Start day now' : null,
            onPrimary: _busy ? null : _start,
          )
        else ...[
          _card([
            Row(
              children: [
                Expanded(child: Text(tr('Today'), style: inter(17, 800))),
                DayStatusChip(d),
              ],
            ),
            const SizedBox(height: 8),
            _line('Started', d.startedAt),
            _line('How', switch (d.trigger) {
              'opening_time' => tr('At the opening time'),
              'manual' => tr('Started by hand'),
              _ => tr('At the first POS activity'),
            }),
            if (_t.opensAt != null) _line('Opening time', _t.opensAt!.substring(0, 5)),
            const Divider(height: 22, color: kLine),
            _line('Carried from the day before', _amt(d.carried)),
            _line('Opening cash', _amt(d.opening), bold: true),
            if (d.openingSource != null)
              _line('From', switch (d.openingSource) {
                'carried' => tr('Counted closing cash'),
                'provisional' => tr('Provisional opening'),
                _ => tr('Entered by hand'),
              }),
            _line('Opening stock', '${d.stock['opening_items'] ?? 0} ${tr('items')}'),
            if ((d.stock['moved_since_last_close'] ?? 0) as num > 0) _line('Moved since the last close', '${d.stock['moved_since_last_close']} ${tr('items')}'),
          ]),
          const SizedBox(height: 14),
          if (prev != null)
            _card([
              Text(tr('The day before'), style: inter(15, 800)),
              const SizedBox(height: 6),
              _line(
                _dateText('${prev['business_date']}'),
                '${prev['status']}' == 'closed' ? tr('Closed') : tr('Not closed'),
                color: '${prev['status']}' == 'closed' ? kGreenText : const Color(0xFFC62828),
              ),
              if ('${prev['status']}' == 'closed') _line('Counted closing cash', _amt(prev['counted_cash'] as num?)),
            ]),
          if (d.attentionText != null) ...[
            const SizedBox(height: 14),
            _card([
              Text(tr(d.attentionText!), style: inter(14, 600, height: 1.35)),
              const SizedBox(height: 12),
              if (d.attention == 'previous_not_closed' && prev != null)
                OutlinedButton(
                  key: const ValueKey('day-close-previous'),
                  onPressed: () => _open(DayClosingScreen(api: widget.api, dayId: '${prev['id']}', canManage: _t.canManage)),
                  child: Text(tr('Count and close the day before')),
                ),
              const SizedBox(height: 8),
              DarkCta(
                key: const ValueKey('day-open-provisional'),
                label: tr(d.attention == 'previous_not_closed' ? 'Open today provisionally' : 'Enter the opening cash'),
                onPressed: () => _open(OpeningCashScreen(api: widget.api, dayId: d.id, canManage: _t.canManage)),
              ),
            ]),
          ],
        ],
      ],
    );
  }
}

/// Opening stock (or closing): the snapshot item by item, with what moved since the day before closed.
class DayStockScreen extends StatefulWidget {
  const DayStockScreen({super.key, required this.api, required this.day, this.kind = 'opening'});
  final ShiftApi api;
  final BusinessDay day;
  final String kind;
  @override
  State<DayStockScreen> createState() => _DayStockScreenState();
}

class _DayStockScreenState extends State<DayStockScreen> {
  List<DayStockLine>? _rows;
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
      final r = await widget.api.dayStock(widget.day.id, kind: widget.kind, q: _q.text);
      if (mounted)
        setState(() {
          _rows = r;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  String _qty(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return _Page(
      title: widget.kind == 'opening' ? 'Opening stock' : 'Closing stock',
      sub: _dateText(widget.day.date),
      onRefresh: _load,
      children: [
        TextField(
          key: const ValueKey('stock-search'),
          controller: _q,
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            prefixIcon: const Icon(LucideIcons.search, size: 18),
            hintText: tr('Search an item'),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: const BorderSide(color: kLine),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the stock', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (rows == null)
          const SkeletonRows()
        else if (rows.isEmpty)
          StateCard(
            icon: LucideIcons.packageOpen,
            title: 'No stock',
            body: widget.kind == 'opening' ? 'No item had stock when the day started.' : 'The day is not closed yet.',
          )
        else
          _card([
            Text(
              '${rows.length} ${tr(rows.length == 1 ? 'item' : 'items')} · ${tr('as at')} ${widget.kind == 'opening' ? widget.day.startedAt : widget.day.closedAt}',
              style: inter(12.5, 600, color: kMuted),
            ),
            for (final r in rows) ...[
              const Divider(height: 16, color: kLine),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name, style: inter(14.5, 700)),
                        Text(
                          [
                            if (r.sku.isNotEmpty) r.sku,
                            if (r.moved != null && r.moved != 0) '${r.moved! > 0 ? '+' : ''}${_qty(r.moved!)} ${tr('since the last close')}',
                          ].join(' · '),
                          style: inter(12, 500, color: r.moved != null && r.moved != 0 ? const Color(0xFFB45309) : kMuted),
                        ),
                      ],
                    ),
                  ),
                  Text('${_qty(r.onHand)} ${r.unit}', style: inter(15, 800)),
                ],
              ),
            ],
          ]),
      ],
    );
  }
}

/// Opening cash: the amount and where it came from; a change needs a reason and keeps the old amount. A manager's change applies at
/// once; anyone else's waits for a manager, who approves or rejects it here.
class OpeningCashScreen extends StatefulWidget {
  const OpeningCashScreen({super.key, required this.api, required this.dayId, required this.canManage});
  final ShiftApi api;
  final String dayId;
  final bool canManage;
  @override
  State<OpeningCashScreen> createState() => _OpeningCashScreenState();
}

class _OpeningCashScreenState extends State<OpeningCashScreen> {
  BusinessDay? _d;
  String? _error;
  final _amount = TextEditingController(), _reason = TextEditingController();
  String? _key; // one tap's key, kept for a retry after a dropped connection
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dayGet(widget.dayId);
      if (mounted)
        setState(() {
          _d = d;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _save() async {
    final d = _d!;
    final amount = num.tryParse(_amount.text.trim());
    if (amount == null || amount < 0) return showToast(context, tr('Enter the opening cash (0 or more).'));
    if (_reason.text.trim().length < 3) return showToast(context, tr('Give a reason (3 to 200 characters).'));
    setState(() => _busy = true);
    _key ??= OrdersApi.newKey();
    try {
      final r = await widget.api.dayOpening(d.id, amount: amount, reason: _reason.text, key: _key!, version: d.version);
      _key = null;
      if (!mounted) return;
      _amount.clear();
      _reason.clear();
      setState(() => _d = r);
      showToast(context, tr(r.raw['pending'] == true ? 'Sent to a manager to approve.' : 'Opening cash saved.'));
    } catch (e) {
      if (e is OrdersApiException && e.status >= 400 && e.status < 500) _key = null; // refused: a new tap is a new intent; offline or a server error keeps the key for the retry // refused: a new tap is a new intent; a dropped connection keeps the key
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(DayCashChange c, bool approve) async {
    try {
      final r = await widget.api.dayDecide(c.id, approve: approve);
      if (mounted) setState(() => _d = r);
    } catch (e) {
      if (mounted) showToast(context, _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final provisional = d?.attention == 'previous_not_closed' && d?.opening == null;
    return _Page(
      title: 'Opening cash',
      sub: d == null ? '' : _dateText(d.date),
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the day', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (d == null)
          const SkeletonRows()
        else ...[
          _card([
            _line('Opening cash', _amt(d.opening), bold: true, key: const ValueKey('opening-now')),
            _line('Carried from the day before', _amt(d.carried)),
            if (d.openingSource != null)
              _line('From', switch (d.openingSource) {
                'carried' => tr('Counted closing cash'),
                'provisional' => tr('Provisional opening'),
                _ => tr('Entered by hand'),
              }),
            if (d.attentionText != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr(d.attentionText!), style: inter(13, 600, color: const Color(0xFFC62828))),
              ),
          ]),
          if (!d.closed) ...[
            const SizedBox(height: 14),
            _card([
              Text(tr(d.opening == null ? (provisional ? 'Open provisionally' : 'Enter the opening cash') : 'Correct the opening cash'), style: inter(16, 800)),
              const SizedBox(height: 4),
              Text(
                tr(
                  provisional
                      ? 'The day before is not closed. A manager may open today with the cash in the drawer; the day stays marked provisional.'
                      : widget.canManage
                      ? 'The old amount is kept with your reason.'
                      : 'A manager approves the change before it counts.',
                ),
                style: inter(12.5, 500, color: kMuted, height: 1.35),
              ),
              const SizedBox(height: 12),
              CashField(controller: _amount, fieldKey: const ValueKey('opening-amount')),
              const SizedBox(height: 10),
              _textBox(_reason, 'Reason (needed)', key: const ValueKey('opening-reason')),
              const SizedBox(height: 12),
              DarkCta(
                key: const ValueKey('opening-save'),
                label: tr(
                  _busy
                      ? 'Saving…'
                      : widget.canManage
                      ? 'Save opening cash'
                      : 'Send for approval',
                ),
                onPressed: _busy ? null : _save,
              ),
            ]),
          ],
          if (d.changes.any((c) => c.kind != 'closing_count')) ...[
            const SizedBox(height: 14),
            _card([
              Text(tr('Changes'), style: inter(15, 800)),
              for (final c in d.changes.where((c) => c.kind != 'closing_count')) ...[
                const Divider(height: 18, color: kLine),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr(c.kindLabel), style: inter(14, 700)),
                          Text(
                            '${c.original == null ? '' : '${_amt(c.original)} → '}${_amt(c.revised)} · ${c.by} · ${c.at}',
                            style: inter(12, 500, color: kMuted),
                          ),
                          if (c.reason != null) Text(c.reason!, style: inter(12.5, 500)),
                        ],
                      ),
                    ),
                    DotChip(
                      c.pending
                          ? 'Waiting'
                          : c.approval == 'rejected'
                          ? 'Rejected'
                          : 'Approved',
                      bg: c.pending
                          ? const Color(0xFFFFF4E0)
                          : c.approval == 'rejected'
                          ? const Color(0xFFFDECEC)
                          : kLimeSoft,
                      fg: c.pending
                          ? const Color(0xFFB45309)
                          : c.approval == 'rejected'
                          ? const Color(0xFFC62828)
                          : kGreenText,
                    ),
                  ],
                ),
                if (c.pending && widget.canManage)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(key: ValueKey('change-reject-${c.id}'), onPressed: () => _decide(c, false), child: Text(tr('Reject'))),
                      TextButton(key: ValueKey('change-approve-${c.id}'), onPressed: () => _decide(c, true), child: Text(tr('Approve'))),
                    ],
                  ),
              ],
            ]),
          ],
        ],
      ],
    );
  }
}

/// The cash of a day, line by line: Opening + Cash sales + Other cash in − Cash refunds − Expenses − Deposits / withdrawals − Other out.
Widget dayCashCard(BusinessDay d) => _card(key: const ValueKey('day-cash'), [
  Text(tr('Drawer cash'), style: inter(15, 800)),
  const SizedBox(height: 4),
  _line('Opening cash', _amt(d.opening)),
  _line('+ Cash sales (${d.bills} ${d.bills == 1 ? 'bill' : 'bills'})', _amt(d.cashSales)),
  _line('+ Other cash in', _amt(d.otherIn)),
  _line('− Cash refunds', _amt(d.refunds)),
  _line('− Cash expenses', _amt(d.expenses)),
  _line('− Deposits / withdrawals', _amt(d.deposits)),
  _line('− Other cash out', _amt(d.otherOut)),
  const Divider(height: 18, color: kLine),
  _line(d.closed ? 'Expected at close' : 'Expected now', _amt(d.expected), bold: true, key: const ValueKey('day-expected')),
  if (d.counted != null) ...[
    _line('Counted', _amt(d.counted)),
    _line('Difference', _amt(d.variance), color: (d.variance ?? 0) == 0 ? kGreenText : const Color(0xFFC62828)),
    if (d.varianceReason != null) Text(d.varianceReason!, style: inter(12.5, 500, color: kMuted)),
  ],
]);

/// Day summary: the drawer cash, the other ways money came in (never in the drawer), the stock and the changes.
class DaySummaryScreen extends StatefulWidget {
  const DaySummaryScreen({super.key, required this.api, required this.dayId});
  final ShiftApi api;
  final String dayId;
  @override
  State<DaySummaryScreen> createState() => _DaySummaryScreenState();
}

class _DaySummaryScreenState extends State<DaySummaryScreen> {
  BusinessDay? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dayGet(widget.dayId);
      if (mounted)
        setState(() {
          _d = d;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return _Page(
      title: 'Day summary',
      sub: d == null ? '' : _dateText(d.date),
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the day', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (d == null)
          const SkeletonRows()
        else ...[
          Row(
            children: [
              Expanded(
                child: Text('${tr('Started')} ${d.startedAt}${d.closed ? ' · ${tr('closed')} ${d.closedAt}' : ''}', style: inter(13, 600, color: kMuted)),
              ),
              DayStatusChip(d),
            ],
          ),
          const SizedBox(height: 10),
          dayCashCard(d),
          const SizedBox(height: 14),
          _card([
            Text(tr('Not in the drawer'), style: inter(15, 800)),
            Text(tr('UPI, card and online payments are kept apart from the cash.'), style: inter(12, 500, color: kMuted)),
            if (d.otherMethods.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('None yet.'), style: inter(13, 500, color: kMuted)),
              ),
            for (final e in d.otherMethods.entries) _line(e.key == 'upi' ? 'UPI' : '${e.key[0].toUpperCase()}${e.key.substring(1)}', _amt(e.value)),
          ]),
          const SizedBox(height: 14),
          _card([
            Text(tr('Stock'), style: inter(15, 800)),
            _line('Opening stock', '${d.stock['opening_items'] ?? 0} ${tr('items')}'),
            _line('Moved since the last close', '${d.stock['moved_since_last_close'] ?? 0} ${tr('items')}'),
            _line('Closing stock', d.closed ? '${d.stock['closing_items'] ?? 0} ${tr('items')}' : tr('At day closing')),
          ]),
          if (d.changes.isNotEmpty) ...[
            const SizedBox(height: 14),
            _card([
              Text(tr('Cash changes'), style: inter(15, 800)),
              for (final c in d.changes) _line('${tr(c.kindLabel)} · ${c.at}', '${c.original == null ? '' : '${_amt(c.original)} → '}${_amt(c.revised)}'),
            ]),
          ],
        ],
      ],
    );
  }
}

/// Closing cash: count the drawer; the expected cash and the difference show as the count is typed; a difference needs a reason.
class ClosingCashScreen extends StatefulWidget {
  const ClosingCashScreen({super.key, required this.api, required this.dayId});
  final ShiftApi api;
  final String dayId;
  @override
  State<ClosingCashScreen> createState() => _ClosingCashScreenState();
}

class _ClosingCashScreenState extends State<ClosingCashScreen> {
  BusinessDay? _d;
  String? _error;
  final _count = TextEditingController(), _reason = TextEditingController();
  String? _key;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _count.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dayGet(widget.dayId);
      if (mounted)
        setState(() {
          _d = d;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  num? get _counted => num.tryParse(_count.text.trim());
  num? get _diff => _counted == null || _d == null ? null : _counted! - _d!.expected;

  Future<void> _save() async {
    final d = _d!, counted = _counted;
    if (counted == null || counted < 0) return showToast(context, tr('Enter the cash counted in the drawer.'));
    if ((_diff ?? 0) != 0 && _reason.text.trim().length < 3) return showToast(context, tr('The count is not what is expected: give a reason.'));
    setState(() => _busy = true);
    _key ??= OrdersApi.newKey();
    try {
      final r = await widget.api.dayCount(d.id, counted: counted, reason: _reason.text, key: _key!);
      _key = null;
      if (!mounted) return;
      setState(() => _d = r);
      showToast(context, tr('Cash count saved. A manager closes the day.'));
    } catch (e) {
      if (e is OrdersApiException && e.status >= 400 && e.status < 500)
        _key = null; // refused: a new tap is a new intent; offline or a server error keeps the key for the retry
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d, diff = _diff;
    return _Page(
      title: 'Closing cash',
      sub: d == null ? '' : _dateText(d.date),
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the day', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (d == null)
          const SkeletonRows()
        else ...[
          dayCashCard(d),
          if (!d.closed) ...[
            const SizedBox(height: 14),
            _card([
              Text(tr(d.counted == null ? 'Count the drawer' : 'Count again'), style: inter(16, 800)),
              const SizedBox(height: 10),
              CashField(controller: _count, fieldKey: const ValueKey('count-amount'), onChanged: (_) => setState(() {})),
              if (diff != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    diff == 0 ? tr('Matches the expected cash.') : '${diff > 0 ? tr('Extra') : tr('Short')} ${rupees(diff.abs())}',
                    key: const ValueKey('count-variance'),
                    style: inter(14, 700, color: diff == 0 ? kGreenText : const Color(0xFFC62828)),
                  ),
                ),
              if (diff != null && diff != 0) ...[
                const SizedBox(height: 10),
                _textBox(_reason, 'Why is it different? (needed)', key: const ValueKey('count-reason')),
              ],
              const SizedBox(height: 12),
              DarkCta(
                key: const ValueKey('count-save'),
                label: tr(_busy ? 'Saving…' : 'Save cash count'),
                onPressed: _busy || d.opening == null ? null : _save,
              ),
              if (d.opening == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tr('Enter the opening cash first.'), style: inter(12.5, 600, color: const Color(0xFFC62828))),
                ),
            ]),
          ],
        ],
      ],
    );
  }
}

/// Day closing: a manager finalizes the counted cash and closes the day; tomorrow opens with this counted cash.
class DayClosingScreen extends StatefulWidget {
  const DayClosingScreen({super.key, required this.api, required this.dayId, required this.canManage});
  final ShiftApi api;
  final String dayId;
  final bool canManage;
  @override
  State<DayClosingScreen> createState() => _DayClosingScreenState();
}

class _DayClosingScreenState extends State<DayClosingScreen> {
  BusinessDay? _d;
  String? _error;
  final _note = TextEditingController();
  String? _key;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.dayGet(widget.dayId);
      if (mounted)
        setState(() {
          _d = d;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _close() async {
    final d = _d!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Close the day?')),
        content: Text('${tr('Counted cash')} ${_amt(d.counted)}. ${tr('Tomorrow opens with this amount. A closed day cannot change.')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Not yet'))),
          TextButton(key: const ValueKey('close-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Close the day'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    _key ??= OrdersApi.newKey();
    try {
      final r = await widget.api.dayClose(d.id, note: _note.text, key: _key!, version: d.version);
      _key = null;
      if (!mounted) return;
      setState(() => _d = r);
      showToast(context, tr('Day closed.'));
    } catch (e) {
      if (e is OrdersApiException && e.status >= 400 && e.status < 500)
        _key = null; // refused: a new tap is a new intent; offline or a server error keeps the key for the retry
      if (mounted) showToast(context, _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _count() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClosingCashScreen(api: widget.api, dayId: widget.dayId),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return _Page(
      title: 'Day closing',
      sub: d == null ? '' : _dateText(d.date),
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the day', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (d == null)
          const SkeletonRows()
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(d.closed ? '${tr('Closed')} ${d.closedAt}' : tr('Open'), style: inter(13.5, 700, color: kMuted)),
              ),
              DayStatusChip(d),
            ],
          ),
          const SizedBox(height: 10),
          dayCashCard(d),
          const SizedBox(height: 14),
          if (d.closed)
            _card([_line('Closing stock', '${d.stock['closing_items'] ?? 0} ${tr('items')}'), if (d.closeNote != null) _line('Note', d.closeNote!)])
          else if (d.counted == null)
            StateCard(
              icon: LucideIcons.calculator,
              title: 'Count the cash first',
              body: 'Count the drawer in Closing cash, then close the day.',
              primary: 'Closing cash',
              onPrimary: _count,
            )
          else if (!widget.canManage)
            StateCard(icon: LucideIcons.lock, title: 'A manager closes the day', body: 'Your count is saved. A manager checks it and closes the day.')
          else
            _card([
              Text(tr('Close the day'), style: inter(16, 800)),
              Text(
                tr('The expected cash is worked out again to this moment. The closing stock is kept.'),
                style: inter(12.5, 500, color: kMuted, height: 1.35),
              ),
              if (d.pendingChanges.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(tr('An opening-cash change is waiting for approval.'), style: inter(13, 600, color: const Color(0xFFC62828))),
                ),
              const SizedBox(height: 10),
              _textBox(
                _note,
                (d.variance ?? 0) != 0 && d.varianceReason == null ? 'Reason for the difference (needed)' : 'Note (optional)',
                key: const ValueKey('close-note'),
              ),
              const SizedBox(height: 12),
              DarkCta(key: const ValueKey('close-go'), label: tr(_busy ? 'Closing…' : 'Close the day'), onPressed: _busy ? null : _close),
              TextButton(onPressed: _count, child: Text(tr('Count again'))),
            ]),
        ],
      ],
    );
  }
}

/// Previous day reports: every day of the store, newest first; one opens its summary.
class PreviousDaysScreen extends StatefulWidget {
  const PreviousDaysScreen({super.key, required this.api, required this.canManage});
  final ShiftApi api;
  final bool canManage;
  @override
  State<PreviousDaysScreen> createState() => _PreviousDaysScreenState();
}

class _PreviousDaysScreenState extends State<PreviousDaysScreen> {
  List<BusinessDay>? _days;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.dayList();
      if (mounted)
        setState(() {
          _days = r;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    return _Page(
      title: 'Previous day reports',
      sub: '',
      onRefresh: _load,
      children: [
        if (_error != null)
          StateCard(icon: LucideIcons.wifiOff, title: 'Could not load the days', body: _error!, primary: 'Try again', onPrimary: _load, danger: true)
        else if (days == null)
          const SkeletonRows()
        else if (days.isEmpty)
          const StateCard(icon: LucideIcons.history, title: 'No days yet', body: 'Each day appears here once it starts.')
        else
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OrderCardBox(
                radius: 18,
                child: InkWell(
                  key: ValueKey('report-${d.date}'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => d.closed
                          ? DaySummaryScreen(api: widget.api, dayId: d.id)
                          : DayClosingScreen(api: widget.api, dayId: d.id, canManage: widget.canManage),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(_dateText(d.date), style: inter(15.5, 800))),
                          DayStatusChip(d),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _line('Opening cash', _amt(d.opening)),
                      _line(d.closed ? 'Expected at close' : 'Expected now', _amt(d.expected)),
                      if (d.counted != null) _line('Counted', _amt(d.counted)),
                      if (d.variance != null && d.variance != 0) _line('Difference', _amt(d.variance), color: const Color(0xFFC62828)),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
