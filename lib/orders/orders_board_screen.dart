import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'cart_screen.dart';
import 'order_screen.dart';
import 'order_widgets.dart';
import 'orders_api.dart';
import 'orders_outlet_header.dart';

// Badge and channel colours sampled from the Figma frames (FINAL PARTNER APP, sections E/H; assets/figma_ref_h/Section H Export).
const _blue = Color(0xFF2563EB), _blueBg = Color(0xFFEFF6FF);
const _orange = Color(0xFFEA580C), _orangeBg = Color(0xFFFFF7ED);
const _green = Color(0xFF15803D), _greenBg = Color(0xFFF0FDF4);
const _purple = Color(0xFF7C3AED), _purpleBg = Color(0xFFF5F3FF), _purpleLine = Color(0xFFDDD6FE);
const _zomato = Color(0xFFE23744), _zomatoBg = Color(0xFFFFF1F2);
const _swiggy = Color(0xFFFC8019), _swiggyBg = Color(0xFFFFF7ED);
const _chipLine = Color(0xFFDADCD5);

const _channels = [('all', 'All'), ('dine_in', 'Dine In'), ('takeaway', 'Takeaway'), ('delivery', 'Delivery'), ('zomato', 'Zomato'), ('swiggy', 'Swiggy')];
const _statusLabel = {'new': 'New', 'preparing': 'Preparing', 'ready': 'Ready', 'dispatched': 'Dispatched', 'completed': 'Completed'};

/// Figma "Live orders" / "Hold orders" (the Orders tab). Everything on screen comes from the database (`pos_orders_board`, `pos_hold_list`):
/// the status of each order, its minutes, whether it is delayed, whether Zomato or Swiggy is connected. Resume POS reopens a held bill in the
/// cart as the SAME order; Cancel Order uses the existing cancel rule (a reason). Spec: specs/orders-live-hold/spec.md.
class OrdersBoardScreen extends StatefulWidget {
  const OrdersBoardScreen({super.key, this.api, this.onNavigate, this.onMenu, this.initialTab = 'live', this.poll = const Duration(seconds: 30)});
  final OrdersApi? api;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onMenu;
  final String initialTab;

  /// How often the open tab refreshes itself; [Duration.zero] = never (tests).
  final Duration poll;
  @override
  State<OrdersBoardScreen> createState() => _OrdersBoardScreenState();
}

class _OrdersBoardScreenState extends State<OrdersBoardScreen> {
  late final OrdersApi _api = widget.api ?? OrdersApi();
  late String _tab = widget.initialTab;
  String _channel = 'all', _status = 'new', _holdChannel = 'all';
  final _liveQ = TextEditingController(), _holdQ = TextEditingController();
  OrdersBoard? _board;
  HoldList? _holds;
  String? _liveError, _holdError;
  Timer? _debounce, _poll;
  int _liveSeq = 0, _holdSeq = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLive();
    if (_tab == 'hold') _loadHolds();
    if (widget.poll > Duration.zero) _poll = Timer.periodic(widget.poll, (_) => _tab == 'live' ? _loadLive() : _loadHolds());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _poll?.cancel();
    _liveQ.dispose();
    _holdQ.dispose();
    super.dispose();
  }

  Future<void> _loadLive() async {
    final mine = ++_liveSeq;
    try {
      final b = await _api.board(channel: _channel, status: _status, q: _liveQ.text);
      if (!mounted || mine != _liveSeq) return;
      setState(() {
        _board = b;
        _liveError = null;
      });
    } catch (e) {
      if (!mounted || mine != _liveSeq) return;
      setState(() => _liveError = e.toString());
    }
  }

  Future<void> _loadHolds() async {
    final mine = ++_holdSeq;
    try {
      final h = await _api.holds(channel: _holdChannel, q: _holdQ.text);
      if (!mounted || mine != _holdSeq) return;
      setState(() {
        _holds = h;
        _holdError = null;
      });
    } catch (e) {
      if (!mounted || mine != _holdSeq) return;
      setState(() => _holdError = e.toString());
    }
  }

  void _searchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _tab == 'live' ? _loadLive() : _loadHolds());
  }

  void _switchTab(String tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    tab == 'live' ? _loadLive() : _loadHolds();
  }

  void _nav(String id) {
    if (id == 'online') return; // this screen
    if (id == 'bill') {
      _newOrder();
      return;
    }
    if (widget.onNavigate != null) {
      widget.onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  Future<void> _newOrder() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CartScreen(api: _api, onNavigate: widget.onNavigate)));
    if (!mounted) return;
    _loadLive();
    if (_holds != null) _loadHolds();
  }

  Future<void> _openOrder(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(api: _api, orderId: id, onNavigate: widget.onNavigate)));
    if (mounted) _loadLive();
  }

  // ---------------------------------------------------------------- hold actions
  Future<void> _resume(HeldBill h) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final view = await _api.get(h.id);
      if (!mounted) return;
      final lines = [
        for (final i in view.items)
          if ((i['qty'] as num? ?? 0) > 0) CartLine(menuItemId: '${i['menu_item_id']}', name: '${i['name']}', qty: (i['qty'] as num).toInt()),
      ];
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CartScreen(
          api: _api,
          initialLines: lines,
          onNavigate: widget.onNavigate,
          resume: ResumeHold(orderId: h.id, displayNo: h.displayNo, version: view.version ?? h.version, reason: h.reason, hasCoupon: h.hasCoupon),
        ),
      ));
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _loadHolds();
    _loadLive();
  }

  Future<void> _cancel(HeldBill h) async {
    final reason = await showOrderSheet<String>(context, title: 'Cancel #${h.displayNo}?', body: (ctx) => _CancelSheet(bill: h));
    if (reason == null || !mounted) return;
    try {
      await _api.cancel(h.id, reason: reason, version: h.version);
      if (mounted) showToast(context, '#${h.displayNo} cancelled.');
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    }
    if (mounted) _loadHolds();
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final b = _board;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersOutletHeader(name: b?.business ?? '', accepting: b?.accepting, onMenu: widget.onMenu),
        _tabs(),
        Expanded(
          child: Stack(children: [
            RefreshIndicator(
              onRefresh: _tab == 'live' ? _loadLive : _loadHolds,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
                children: _tab == 'live' ? _liveBody() : _holdBody(),
              ),
            ),
            if (_tab == 'live')
              Positioned(
                right: 16,
                bottom: 14,
                child: Material(
                  color: kLime,
                  shape: const StadiumBorder(),
                  elevation: 3,
                  child: InkWell(
                    key: const ValueKey('new-order'),
                    customBorder: const StadiumBorder(),
                    onTap: _newOrder,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(LucideIcons.plus, size: 20, color: kInk),
                        const SizedBox(width: 6),
                        Text('New Order', style: inter(15, 700)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        PosBottomNav(active: 'online', onTap: _nav),
      ]),
    );
  }

  Widget _tabs() => Container(
        color: Colors.white,
        child: Row(children: [
          for (final (id, label) in const [('live', 'Live orders'), ('hold', 'Hold orders')])
            Expanded(
              child: Semantics(
                button: true,
                selected: _tab == id,
                child: InkWell(
                  key: ValueKey('tab-$id'),
                  onTap: () => _switchTab(id),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _tab == id ? kInk : kLine, width: _tab == id ? 3 : 1))),
                    child: Text(label, style: inter(15, _tab == id ? 700 : 500, color: _tab == id ? kInk : kMuted)),
                  ),
                ),
              ),
            ),
        ]),
      );

  Widget _search(TextEditingController c, String hint) => Container(
        height: 46,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: _chipLine)),
        child: Row(children: [
          const SizedBox(width: 14),
          const Icon(LucideIcons.search, size: 16, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: c,
              style: inter(14.5, 400),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(border: InputBorder.none, isCollapsed: true, hintText: hint, hintStyle: inter(14.5, 400, color: kMuted)),
              onChanged: (_) => _searchChanged(),
              onSubmitted: (_) => _tab == 'live' ? _loadLive() : _loadHolds(),
            ),
          ),
        ]),
      );

  Widget _chips<T>(List<(T, String)> items, T selected, ValueChanged<T> onPick, {Color active = kLime, Color activeText = kInk, String keyPrefix = 'chip'}) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (id, label) in items) ...[
            Material(
              color: id == selected ? active : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: id == selected ? active : _chipLine)),
              child: InkWell(
                key: ValueKey('$keyPrefix-$id'),
                customBorder: const StadiumBorder(),
                onTap: () => onPick(id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(label, style: inter(14, id == selected ? 600 : 500, color: id == selected ? activeText : kInk)),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      );

  // ---------------------------------------------------------------- Live orders
  bool get _aggregator => _channel == 'zomato' || _channel == 'swiggy';

  List<Widget> _liveBody() {
    final b = _board;
    final name = _channels.firstWhere((c) => c.$1 == _channel).$2;
    final out = <Widget>[];
    if (_aggregator) {
      out..add(_IntegrationBanner(name: name, state: b?.integration(_channel)))..add(const SizedBox(height: 12));
    }
    out
      ..add(_search(_liveQ, _aggregator ? 'Search $name orders...' : 'Search order or customer...'))
      ..add(const SizedBox(height: 12))
      ..add(_chips(_channels, _channel, (id) {
        setState(() {
          _channel = id;
          if (_status == 'dispatched' && !_showDispatched(id, b)) _status = 'new';
        });
        _loadLive();
      }, keyPrefix: 'channel'))
      ..add(const SizedBox(height: 10));
    if (b != null) {
      final statuses = ['new', 'preparing', 'ready', if (_showDispatched(_channel, b)) 'dispatched', 'completed'];
      out
        ..add(_chips([for (final s in statuses) (s, '${_statusLabel[s]} (${b.count(s)})')], _status, (s) {
          setState(() => _status = s);
          _loadLive();
        }, active: kDark, activeText: Colors.white, keyPrefix: 'status'))
        ..add(const SizedBox(height: 14));
    }
    if (_liveError != null && b == null) return [...out, _ErrorBlock(message: _liveError!, onRetry: _loadLive)];
    if (b == null) return [...out, const SizedBox(height: 60), const Center(child: CircularProgressIndicator(color: kGreenText))];
    final orders = b.orders;
    if (orders.isEmpty) {
      final st = b.integration(_channel);
      if (_aggregator && st != null && !st.online) {
        return [...out, _Empty(icon: LucideIcons.plugZap, title: '$name is not connected', body: 'No $name orders reach One Local yet. They appear here once $name is connected.')];
      }
      if (_liveQ.text.trim().isNotEmpty) return [...out, const _Empty(icon: LucideIcons.searchX, title: 'No orders match', body: 'Try another order number or name.')];
      return [...out, _Empty(icon: LucideIcons.chefHat, title: 'All Caught Up!', body: _emptyBody[_status]!)];
    }
    return [
      ...out,
      for (final o in orders) Padding(padding: const EdgeInsets.only(bottom: 12), child: _LiveCard(order: o, onOpen: () => _openOrder(o.id))),
    ];
  }

  static const _emptyBody = {
    'new': 'No new orders right now.',
    'preparing': 'No orders are currently being prepared.',
    'ready': 'No orders are waiting for pickup.',
    'dispatched': 'No orders are out for delivery.',
    'completed': 'No orders completed today yet.',
  };

  bool _showDispatched(String channel, OrdersBoard? b) =>
      channel == 'delivery' || channel == 'zomato' || channel == 'swiggy' || (channel == 'all' && (b?.count('dispatched') ?? 0) > 0) || _status == 'dispatched';

  // ---------------------------------------------------------------- Hold orders
  List<Widget> _holdBody() {
    final h = _holds;
    final out = <Widget>[
      _chips(_channels, _holdChannel, (id) {
        setState(() => _holdChannel = id);
        _loadHolds();
      }, keyPrefix: 'hold-channel'),
      const SizedBox(height: 12),
    ];
    final oldest = h?.oldest;
    if (oldest != null && oldest['delayed'] == true) {
      out
        ..add(_OldestAlert(text: 'Oldest hold: ${_ago((oldest['minutes'] as num?)?.toInt() ?? 0)} (#${oldest['display_no']}) requires attention.'))
        ..add(const SizedBox(height: 12));
    }
    out
      ..add(_search(_holdQ, 'Search held orders...'))
      ..add(const SizedBox(height: 14));
    if (_holdError != null && h == null) return [...out, _ErrorBlock(message: _holdError!, onRetry: _loadHolds)];
    if (h == null) return [...out, const SizedBox(height: 60), const Center(child: CircularProgressIndicator(color: kGreenText))];
    if (h.holds.isEmpty) {
      return [
        ...out,
        _holdQ.text.trim().isNotEmpty || _holdChannel != 'all'
            ? const _Empty(icon: LucideIcons.searchX, title: 'No held bills match', body: 'Try another search or channel.')
            : const _Empty(icon: LucideIcons.pause, title: 'No bills on hold', body: 'Bills saved with Save & Hold appear here until they are paid or cancelled.'),
      ];
    }
    return [
      ...out,
      for (final b in h.holds)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _HoldCard(bill: b, busy: _busy, onCancel: () => _cancel(b), onResume: () => _resume(b)),
        ),
    ];
  }
}

String _ago(int minutes) => minutes < 60 ? '$minutes min ago' : '${minutes ~/ 60} h ${minutes % 60} min ago';

String _clock(DateTime? t) {
  if (t == null) return '';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "New (5m)", "Preparing (12m)", "Delayed (28m)", "Completed" — the label of the database's status and minutes.
(String, Color, Color) liveBadge(LiveOrder o) {
  if (o.delayed) return ('Delayed (${o.minutes}m)', kBadText, kBadBg);
  return switch (o.status) {
    'new' => ('New (${o.minutes}m)', _blue, _blueBg),
    'preparing' => ('Preparing (${o.minutes}m)', _orange, _orangeBg),
    'ready' => ('Ready (${o.minutes}m)', _green, _greenBg),
    'dispatched' => ('Dispatched (${o.minutes}m)', _purple, _purpleBg),
    _ => ('Completed', kMuted, const Color(0xFFF3F4F6)),
  };
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.fg, this.bg);
  final String label;
  final Color fg, bg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: fg.withValues(alpha: 0.55))),
        child: Text(label, style: inter(12.5, 600, color: fg)),
      );
}

class _ChannelTag extends StatelessWidget {
  const _ChannelTag(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (label) { 'Zomato' => (_zomato, _zomatoBg), 'Swiggy' => (_swiggy, _swiggyBg), _ => (kGreenText, kChipGreen) };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4), border: Border.all(color: fg)),
      child: Text(label, style: inter(11.5, 600, color: fg)),
    );
  }
}

class _NoteBox extends StatelessWidget {
  const _NoteBox(this.note);
  final String? note;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE2E3DD))),
        child: Text('Order note · ${note ?? 'No custom note'}', style: inter(12, 500, color: kMuted)),
      );
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.order, required this.onOpen});
  final LiveOrder order;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final o = order;
    final (label, fg, bg) = liveBadge(o);
    final tag = o.channelTag;
    final number = '#${o.externalId ?? o.displayNo}';
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFECEDE8))),
      child: InkWell(
        key: ValueKey('live-${o.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: tag != null ? Align(alignment: Alignment.centerLeft, child: _ChannelTag(tag)) : Text(number, style: inter(18, 700))),
              Text(_clock(o.placedAt), style: inter(13.5, 400, color: kMuted)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(o.customer, style: inter(17, 700), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (tag != null) Text(number, style: inter(15, 700)),
            ]),
            if (o.table != null) Text('Table ${o.table}', style: inter(13, 500, color: kMuted)),
            const SizedBox(height: 3),
            Text(o.items, style: inter(14, 400, color: kMuted), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            _NoteBox(o.note),
            const Divider(height: 22, color: kLine),
            Row(children: [
              Text(rupees(o.total), style: inter(19, 800, color: const Color(0xFF3DB800))),
              const Spacer(),
              _Badge(label, fg, bg),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _IntegrationBanner extends StatelessWidget {
  const _IntegrationBanner({required this.name, required this.state});
  final String name;
  final ChannelState? state;
  @override
  Widget build(BuildContext context) {
    final (fg, bg) = name == 'Zomato' ? (_zomato, _zomatoBg) : (_swiggy, _swiggyBg);
    final online = state?.online == true;
    return Container(
      key: const ValueKey('integration-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: fg)),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fg, borderRadius: BorderRadius.circular(6)),
          child: Text(name[0], style: inter(14, 800, color: Colors.white)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$name Integration', style: inter(15, 700, color: fg)),
            if (!online) Text(state?.reason == 'paused' ? 'Paused' : 'Not connected', style: inter(12, 500, color: kMuted)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(color: online ? _greenBg : const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
          child: Text(online ? 'ONLINE' : 'OFFLINE', style: inter(11.5, 700, color: online ? _green : kMuted)),
        ),
      ]),
    );
  }
}

class _OldestAlert extends StatelessWidget {
  const _OldestAlert({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('oldest-hold'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarnBg, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFF59E0B))),
        child: Row(children: [
          const Icon(LucideIcons.triangleAlert, size: 20, color: kWarnText),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: inter(14, 600, color: kWarnText))),
        ]),
      );
}

class _HoldCard extends StatelessWidget {
  const _HoldCard({required this.bill, required this.busy, required this.onCancel, required this.onResume});
  final HeldBill bill;
  final bool busy;
  final VoidCallback onCancel, onResume;
  @override
  Widget build(BuildContext context) {
    final b = bill;
    return OrderCardBox(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '#${b.displayNo}', style: inter(17, 700)),
              TextSpan(text: '  (${b.source})', style: inter(13.5, 500, color: kMuted)),
            ])),
          ),
          const SizedBox(width: 8),
          b.delayed ? _Badge('Delayed (${b.minutes}m)', kBadText, kBadBg) : _Badge('New', _blue, _blueBg),
        ]),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: _purpleBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: _purpleLine)),
          child: Text(b.reason ?? 'No hold reason recorded', style: inter(13.5, 500, color: b.reason == null ? kMuted : _purple)),
        ),
        const SizedBox(height: 10),
        Text(b.items, style: inter(14, 400, color: kMuted)),
        const SizedBox(height: 10),
        _NoteBox(b.note),
        const SizedBox(height: 4),
        Text('Held ${_ago(b.minutes)} · ${rupees(b.total)}', style: inter(12, 400, color: kMuted)),
        const Divider(height: 22, color: kLine),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 46,
              child: OutlinedButton(
                key: ValueKey('cancel-${b.id}'),
                onPressed: busy ? null : onCancel,
                style: OutlinedButton.styleFrom(side: const BorderSide(color: _chipLine), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Text('Cancel Order', style: inter(15, 600, color: kBadText)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 46,
              child: FilledButton(
                key: ValueKey('resume-${b.id}'),
                onPressed: busy ? null : onResume,
                style: FilledButton.styleFrom(backgroundColor: kLime, foregroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                child: Text('Resume POS', style: inter(15, 700)),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// Asks why the held bill is cancelled (the existing rule: a reason of at least 3 characters); returns it, or null when kept.
class _CancelSheet extends StatefulWidget {
  const _CancelSheet({required this.bill});
  final HeldBill bill;
  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  final _reason = TextEditingController();
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _reason.text.trim().length >= 3;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('No payment was taken. The bill stays in the order history as cancelled.', style: inter(13.5, 400, color: kMuted)),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('cancel-reason'),
        controller: _reason,
        maxLength: 200,
        decoration: const InputDecoration(hintText: 'Reason (for example: customer left)'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 8),
      DarkCta(label: 'Cancel bill', onPressed: ok ? () => Navigator.pop(context, _reason.text.trim()) : null),
      const SizedBox(height: 6),
      UnderLink('Keep on hold', onTap: () => Navigator.pop(context)),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 50),
        child: Column(children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: const Color(0xFFECEDE8))),
            child: Icon(icon, size: 40, color: const Color(0xFF3DB800)),
          ),
          const SizedBox(height: 18),
          Text(title, style: inter(17, 700), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text(body, style: inter(13.5, 400, color: kMuted), textAlign: TextAlign.center)),
        ]),
      );
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(children: [
          Text(message, textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
          const SizedBox(height: 12),
          SmallPill('Try again', onTap: onRetry),
        ]),
      );
}
