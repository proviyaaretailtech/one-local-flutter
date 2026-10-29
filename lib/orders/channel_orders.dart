import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'orders_api.dart';

/// The restaurant Orders tab's channel cards (founder, 27 Oct 2026), like the store's Online order cards: one stacked colour card per
/// source (OneLocal, Swiggy, Zomato, On call delivery) with today's count, total and latest customers; a tap opens that source's list.

/// Each source's look: its gradient, icon, and the colour its name and pill take on the list.
class ChannelLook {
  const ChannelLook(this.from, this.to, this.icon, this.ink);
  final Color from, to, ink;
  final IconData icon;

  static const _looks = {
    'onelocal': ChannelLook(Color(0xFF2F9E0F), Color(0xFF6BD12B), LucideIcons.store, Color(0xFF2F8A0F)),
    'swiggy': ChannelLook(Color(0xFFF46A0A), Color(0xFFFF9A3C), LucideIcons.bike, Color(0xFFE35F00)),
    'zomato': ChannelLook(Color(0xFFCB202D), Color(0xFFF0505C), LucideIcons.utensilsCrossed, Color(0xFFCB202D)),
    'on_call': ChannelLook(Color(0xFF5B21B6), Color(0xFF8B5CF6), LucideIcons.phoneCall, Color(0xFF6D28D9)),
  };
  static ChannelLook of(String key) => _looks[key] ?? const ChannelLook(Color(0xFF374151), Color(0xFF6B7280), LucideIcons.shoppingBag, kInk);
}

/// Each source's logo on a rounded tile: the OneLocal, Swiggy and Zomato logos (assets/channels/), and for On call delivery a drawn
/// phone with a food-cloche bubble. [width] × [height]; the logos are zoomed so their mark fills the tile.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo(this.channel, {super.key, this.width = 52, this.height = 44, this.radius = 12});
  final String channel;
  final double width, height, radius;

  @override
  Widget build(BuildContext context) {
    Widget image(String file, {double zoom = 1, Alignment align = Alignment.center}) => Transform.scale(
          scale: zoom,
          child: Image.asset('assets/channels/$file', fit: BoxFit.cover, alignment: align, width: width, height: height,
              errorBuilder: (_, _, _) => ColoredBox(color: ChannelLook.of(channel).from)),
        );
    final child = switch (channel) {
      'onelocal' => image('onelocal.jpg', zoom: 1.55),
      'swiggy' => image('swiggy.png', zoom: 1.25),
      'zomato' => image('zomato.png', zoom: 1.1),
      _ => ColoredBox(
          color: Colors.white,
          child: Stack(children: [
            Positioned(left: width * 0.14, bottom: height * 0.12, child: Icon(LucideIcons.phone, size: height * 0.52, color: const Color(0xFF3B3B3B))),
            Positioned(
              right: width * 0.12,
              top: height * 0.1,
              child: Container(
                padding: EdgeInsets.all(height * 0.06),
                decoration: BoxDecoration(color: const Color(0xFF3B3B3B), borderRadius: BorderRadius.circular(height * 0.12)),
                child: Icon(LucideIcons.conciergeBell, size: height * 0.28, color: Colors.white),
              ),
            ),
          ]),
        ),
    };
    return Container(
      key: ValueKey('channel-logo-$channel'),
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.5)),
      child: child,
    );
  }
}

/// "New · waiting to accept", "Preparing in kitchen", … for one order's stage on its source.
String channelStageLabel(String stage, String source) => switch (stage) {
      'new' => 'New · waiting to accept',
      'preparing' => 'Preparing in kitchen',
      'ready' => source == 'on_call' ? 'Ready · send it out' : 'Ready · waiting for rider',
      'on_way' => source == 'on_call' ? 'Out for delivery · cash to collect' : 'Out for delivery',
      'delivered' => source == 'swiggy' || source == 'zomato' ? 'Picked up by rider' : 'Delivered',
      _ => stage,
    };

Color _stageColor(String stage) => switch (stage) {
      'new' => const Color(0xFF2563EB),
      'preparing' => const Color(0xFFEA580C),
      'ready' => const Color(0xFF15803D),
      'on_way' => const Color(0xFF7C3AED),
      _ => kMuted,
    };

/// "Accept in 0:42", or "Accept now · late" once the window has passed.
String acceptLabel(int secondsLeft) =>
    secondsLeft > 0 ? 'Accept in ${secondsLeft ~/ 60}:${(secondsLeft % 60).toString().padLeft(2, '0')}' : 'Accept now · late';

/// The four stacked cards, "DELIVERY ORDERS · 12 orders" above them and "Cancelled · 1" under them; and, when [onAutoAccept] is given,
/// the Auto-accept switch. [countdown] is, per source, the seconds the most urgent new order has left to be accepted (0 or less: late);
/// a source in it blinks and shows "Accept in 0:42".
class ChannelStack extends StatelessWidget {
  const ChannelStack({super.key, required this.data, required this.onOpen, this.countdown = const {}, this.onAutoAccept, this.autoBusy = false});
  final ChannelOrders data;
  final ValueChanged<String> onOpen;
  final Map<String, int> countdown;
  final ValueChanged<bool>? onAutoAccept;
  final bool autoBusy;

  /// Off in widget tests: the cards do not pulse (it would keep the test clock busy).
  static bool animate = true;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (onAutoAccept != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(
              color: data.autoAccept ? const Color(0xFFE9F9DC) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: data.autoAccept ? const Color(0xFF8BD45A) : kLine),
            ),
            child: Row(children: [
              Icon(data.autoAccept ? LucideIcons.zap : LucideIcons.zapOff, size: 20, color: data.autoAccept ? const Color(0xFF2F7D00) : kMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Auto-accept orders', style: inter(14.5, 700)),
                  Text(
                    data.autoAccept ? 'On: new orders are accepted as soon as they arrive' : 'Off: accept each new order within ${data.acceptWindow ~/ 60 > 0 && data.acceptWindow % 60 == 0 ? '${data.acceptWindow ~/ 60} minute${data.acceptWindow == 60 ? '' : 's'}' : '${data.acceptWindow} seconds'}',
                    style: inter(11.5, 500, color: kMuted),
                  ),
                ]),
              ),
              Switch(
                key: const ValueKey('auto-accept'),
                value: data.autoAccept,
                activeThumbColor: Colors.white,
                activeTrackColor: const Color(0xFF5FCB1E),
                onChanged: autoBusy ? null : onAutoAccept,
              ),
            ]),
          ),
          const SizedBox(height: 14),
        ],
        Row(children: [
          Expanded(child: Text('DELIVERY ORDERS', style: inter(12, 700, color: kMuted))),
          Text('${data.total} orders today', style: inter(12, 500, color: kMuted)),
        ]),
        const SizedBox(height: 10),
        for (final c in data.channels)
          Padding(padding: const EdgeInsets.only(bottom: 14), child: _StackedCard(channel: c, secondsLeft: countdown[c.key], onTap: () => onOpen(c.key))),
        if (data.cancelled > 0)
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(LucideIcons.circleX, size: 15, color: kMuted),
              const SizedBox(width: 6),
              Text('Cancelled · ${data.cancelled}', key: const ValueKey('channel-cancelled'), style: inter(13.5, 500, color: kMuted)),
            ]),
          ),
      ]);
}

class _StackedCard extends StatefulWidget {
  const _StackedCard({required this.channel, required this.onTap, this.secondsLeft});
  final ChannelSummary channel;
  final VoidCallback onTap;

  /// A new order is waiting: seconds left to accept it (0 or less: late). Null: nothing waiting.
  final int? secondsLeft;
  @override
  State<_StackedCard> createState() => _StackedCardState();
}

class _StackedCardState extends State<_StackedCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_StackedCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Blinks while a new order waits; faster in the last 10 seconds.
  void _sync() {
    final waiting = widget.secondsLeft != null && ChannelStack.animate;
    final fast = waiting && widget.secondsLeft! <= 10;
    _pulse.duration = Duration(milliseconds: fast ? 350 : 700);
    if (waiting && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (waiting && fast) {
      _pulse.repeat(reverse: true);
    } else if (!waiting && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.channel;
    final left = widget.secondsLeft;
    final look = ChannelLook.of(c.key);
    final behind = c.count >= 3 ? 2 : c.count >= 2 ? 1 : 0; // paper behind: more orders, a thicker stack
    final who = c.names.isEmpty ? 'No orders yet today' : c.names.join(', ');
    final sub = c.count == 0 ? who : c.fresh > 0 ? '${c.fresh} new · $who' : c.open > 0 ? '${c.open} open · $who' : 'All done · $who';
    final urgent = left != null && left <= 10;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Container(
        decoration: left == null
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: (urgent ? const Color(0xFFFF2D2D) : look.to).withValues(alpha: 0.25 + 0.55 * _pulse.value),
                    blurRadius: 6 + 14 * _pulse.value,
                    spreadRadius: 1 + 3 * _pulse.value,
                  ),
                ],
              ),
        child: child,
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = behind; i > 0; i--)
          Positioned(
            left: 10.0 * i,
            right: 10.0 * i,
            top: -6.0 * i,
            height: 40,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(colors: [look.from.withValues(alpha: 0.75 - 0.2 * i), look.to.withValues(alpha: 0.75 - 0.2 * i)]),
              ),
            ),
          ),
        Material(
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          elevation: 2,
          shadowColor: look.from.withValues(alpha: 0.4),
          child: Ink(
            decoration: BoxDecoration(gradient: LinearGradient(colors: [look.from, look.to])),
            child: InkWell(
              key: ValueKey('channel-card-${c.key}'),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 16, 10, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    ChannelLogo(c.key),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${c.label} · ${c.count}', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 800, color: Colors.white)),
                        const SizedBox(height: 2),
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 500, color: Colors.white.withValues(alpha: 0.92))),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Text(rupees(c.total), key: ValueKey('channel-total-${c.key}'), style: inter(18, 800, color: Colors.white)),
                    const Icon(LucideIcons.chevronRight, size: 20, color: Colors.white),
                  ]),
                  if (left != null) ...[
                    const SizedBox(height: 10),
                    // the accept timer: white, red in the last 10 seconds and once late
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        key: ValueKey('channel-timer-${c.key}'),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: urgent ? const Color(0xFFFF2D2D) : Colors.white, borderRadius: BorderRadius.circular(999)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(LucideIcons.timer, size: 15, color: urgent ? Colors.white : look.ink),
                          const SizedBox(width: 5),
                          Text(acceptLabel(left), style: inter(13, 800, color: urgent ? Colors.white : look.ink)),
                        ]),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// One source's orders: back, "Swiggy · 3", a pill per source to switch, and the order cards (tap to open, ⌄ for the dishes).
class ChannelOrdersList extends StatefulWidget {
  const ChannelOrdersList({super.key, required this.data, required this.channel, required this.onChannel, required this.onBack, required this.onOpenOrder, this.secondsLeft, this.onAccept, this.accepting = const {}, this.onDeliver, this.onUpdateCustomer, this.delivering = const {}, this.focusId});

  /// An order to open, highlight and scroll to (Delivery status from its page).
  final String? focusId;

  /// Delivery updates (0619): move an order on (ready / out / delivered), and WhatsApp the customer where it is.
  final void Function(ChannelOrder order, String step)? onDeliver;
  final ValueChanged<ChannelOrder>? onUpdateCustomer;
  final Set<String> delivering;
  final ChannelOrders data;

  /// Seconds a new order has left to be accepted (0 or less: late); null for an order that is not new.
  final int? Function(ChannelOrder order)? secondsLeft;
  final ValueChanged<ChannelOrder>? onAccept;
  final Set<String> accepting;
  final String channel;
  final ValueChanged<String> onChannel;
  final VoidCallback onBack;
  final ValueChanged<String> onOpenOrder;
  @override
  State<ChannelOrdersList> createState() => _ChannelOrdersListState();
}

class _ChannelOrdersListState extends State<ChannelOrdersList> {
  final _open = <String>{};

  /// all | pending (not yet delivered) | on_way | delivered
  String _show = 'all';
  final _focusKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _focus();
  }

  @override
  void didUpdateWidget(ChannelOrdersList old) {
    super.didUpdateWidget(old);
    if (widget.focusId != old.focusId) _focus();
  }

  /// The focused order: opened, every order shown, and scrolled into view once drawn.
  void _focus() {
    final id = widget.focusId;
    if (id == null) return;
    _open.add(id);
    _show = 'all';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _focusKey.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300), alignment: 0.2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final c = d.channels.where((x) => x.key == widget.channel).firstOrNull;
    final all = d.orders.where((o) => o.source == widget.channel).toList();
    bool shows(ChannelOrder o) => switch (_show) {
          'pending' => o.stage != 'delivered',
          'on_way' => o.stage == 'on_way',
          'delivered' => o.stage == 'delivered',
          _ => true,
        };
    final orders = [for (final o in all) if (shows(o)) o];
    // the delivery filter: what still needs doing, what is on the road, what is done
    final aggregator = widget.channel == 'swiggy' || widget.channel == 'zomato';
    final counts = {
      'pending': all.where((o) => o.stage != 'delivered').length,
      'on_way': all.where((o) => o.stage == 'on_way').length,
      'delivered': all.where((o) => o.stage == 'delivered').length,
    };
    Widget filter(String k, String label) => Expanded(
          child: Material(
            key: ValueKey('deliver-filter-$k'),
            color: _show == k ? kInk : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: _show == k ? kInk : kLine)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _show = _show == k ? 'all' : k),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(children: [
                  Text('${counts[k]}', style: inter(17, 800, color: _show == k ? Colors.white : kInk)),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600, color: _show == k ? Colors.white : kMuted)),
                ]),
              ),
            ),
          ),
        );
    final look = ChannelLook.of(widget.channel);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: kLine)),
          child: InkWell(
            key: const ValueKey('channel-back'),
            customBorder: const CircleBorder(),
            onTap: widget.onBack,
            child: const Padding(padding: EdgeInsets.all(10), child: Icon(LucideIcons.arrowLeft, size: 20, color: kInk)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c?.label ?? widget.channel} · ${orders.length}', key: const ValueKey('channel-title'), style: inter(19, 800)),
            Text(c == null || c.open == 0 ? 'Nothing open right now' : '${c.open} open · ${rupees(c.total)} today', style: inter(13, 400, color: kMuted)),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      // the sources as their logos only (founder, 28 Oct 2026), all four in view
      Row(children: [
        for (final x in d.channels) Expanded(child: Center(child: _Pill(channel: x, selected: x.key == widget.channel, onTap: () => widget.onChannel(x.key)))),
      ]),
      const SizedBox(height: 12),
      if (all.isNotEmpty && widget.onDeliver != null) ...[
        Row(children: [
          filter('pending', 'Not delivered'),
          const SizedBox(width: 6),
          if (!aggregator) ...[filter('on_way', 'Out for delivery'), const SizedBox(width: 6)],
          filter('delivered', aggregator ? 'Picked up' : 'Delivered'),
        ]),
        const SizedBox(height: 12),
      ],
      if (orders.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(child: Text(all.isEmpty ? 'No ${c?.label ?? ''} orders today yet.' : 'No orders here.', style: inter(14.5, 500, color: kMuted))),
        ),
      for (final o in orders)
        Container(
          key: o.id == widget.focusId ? _focusKey : null,
          margin: const EdgeInsets.only(bottom: 12),
          // the order brought here by Delivery status: a ring round it
          decoration: o.id == widget.focusId
              ? BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: look.ink, width: 2.5))
              : null,
          child: _OrderCard(
            order: o,
            ink: look.ink,
            secondsLeft: o.stage == 'new' ? widget.secondsLeft?.call(o) : null,
            accepting: widget.accepting.contains(o.id),
            onAccept: o.stage == 'new' && widget.onAccept != null ? () => widget.onAccept!(o) : null,
            open: _open.contains(o.id),
            onTap: () => widget.onOpenOrder(o.id),
            onToggle: () => setState(() => _open.contains(o.id) ? _open.remove(o.id) : _open.add(o.id)),
            onDeliver: widget.onDeliver == null ? null : (step) => widget.onDeliver!(o, step),
            onUpdateCustomer: widget.onUpdateCustomer == null ? null : () => widget.onUpdateCustomer!(o),
            delivering: widget.delivering.contains(o.id),
          ),
        ),
    ]);
  }
}

/// One source in the switcher: its logo only, named for screen readers. The chosen one is ringed in the source's colour; the others fade.
class _Pill extends StatelessWidget {
  const _Pill({required this.channel, required this.selected, required this.onTap});
  final ChannelSummary channel;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final look = ChannelLook.of(channel.key);
    return Semantics(
      button: true,
      selected: selected,
      label: '${channel.label}, ${channel.count} orders',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: selected ? 1 : 0.55,
        child: InkWell(
          key: ValueKey('channel-pill-${channel.key}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? look.ink : Colors.transparent, width: 2.4),
              boxShadow: selected ? [BoxShadow(color: look.ink.withValues(alpha: .25), blurRadius: 10, offset: const Offset(0, 3))] : null,
            ),
            child: ChannelLogo(channel.key, width: 60, height: 46, radius: 12),
          ),
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.ink, required this.open, required this.onTap, required this.onToggle, this.secondsLeft, this.onAccept, this.accepting = false, this.onDeliver, this.onUpdateCustomer, this.delivering = false});
  final ChannelOrder order;
  final void Function(String step)? onDeliver;
  final VoidCallback? onUpdateCustomer;
  final bool delivering;
  final int? secondsLeft;
  final VoidCallback? onAccept;
  final bool accepting;
  final Color ink;
  final bool open;
  final VoidCallback onTap, onToggle;

  /// The steps an order goes through after it is accepted: Kitchen → Ready → Out → Delivered (Swiggy / Zomato: … → Ready → Picked up).
  List<(String, String)> get _steps => order.aggregatorRider
      ? const [('preparing', 'Kitchen'), ('ready', 'Ready'), ('delivered', 'Picked up')]
      : const [('preparing', 'Kitchen'), ('ready', 'Ready'), ('on_way', 'Out'), ('delivered', 'Delivered')];

  /// The next step's button: (step sent to the server, label, icon); null once delivered.
  (String, String, IconData)? get _next => switch (order.stage) {
        'preparing' => ('ready', 'Mark ready', LucideIcons.packageCheck),
        'ready' => order.aggregatorRider ? ('delivered', 'Picked up by rider', LucideIcons.bike) : ('out', 'Out for delivery', LucideIcons.bike),
        'on_way' => ('delivered', 'Delivered', LucideIcons.circleCheck),
        _ => null,
      };

  Widget _delivery(BuildContext context) {
    final o = order;
    final steps = _steps;
    final at = steps.indexWhere((s) => s.$1 == o.stage);
    final next = _next;
    const done = Color(0xFF15803D);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 6, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // the tracker: a dot per step, filled up to where it is
        Row(key: ValueKey('deliver-track-${o.displayNo}'), children: [
          for (final (i, s) in steps.indexed) ...[
            if (i > 0) Expanded(child: Container(height: 2, color: i <= at ? done : kLine)),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: i <= at ? done : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: i <= at ? done : const Color(0xFFC9CDC4), width: 2),
                ),
                child: i < at || o.stage == 'delivered' ? const Icon(LucideIcons.check, size: 9, color: Colors.white) : null,
              ),
              const SizedBox(height: 3),
              Text(s.$2, style: inter(10.5, i == at ? 800 : 500, color: i <= at ? kInk : kMuted)),
            ]),
          ],
        ]),
        // who is taking it, and when it should arrive
        if (o.stage == 'on_way' && (o.riderName != null || o.riderPhone != null || o.etaMinutes != null)) ...[
          const SizedBox(height: 8),
          Row(key: ValueKey('deliver-rider-${o.displayNo}'), children: [
            const Icon(LucideIcons.bike, size: 15, color: kMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [if (o.riderName != null) o.riderName!, if (o.riderPhone != null) '+91 ${o.riderPhone}', if (o.etaMinutes != null) 'about ${o.etaMinutes} min'].join(' · '),
                style: inter(12.5, 600, color: kInk),
              ),
            ),
          ]),
        ],
        if (next != null || (onUpdateCustomer != null && !o.aggregatorRider && (o.phone ?? '').isNotEmpty)) ...[
          const SizedBox(height: 10),
          Row(children: [
            if (next != null)
              Expanded(
                child: FilledButton.icon(
                  key: ValueKey('deliver-${next.$1}-${o.displayNo}'),
                  style: FilledButton.styleFrom(backgroundColor: ink, minimumSize: const Size.fromHeight(40), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: delivering ? null : () => onDeliver!(next.$1),
                  icon: delivering
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(next.$3, size: 16),
                  label: Text(next.$2, style: inter(13.5, 800, color: Colors.white)),
                ),
              ),
            // the customer hears where their order is (OneLocal and phone orders; Swiggy and Zomato tell theirs)
            if (onUpdateCustomer != null && !o.aggregatorRider && (o.phone ?? '').isNotEmpty) ...[
              if (next != null) const SizedBox(width: 8),
              Tooltip(
                message: 'Update the customer on WhatsApp',
                child: OutlinedButton.icon(
                  key: ValueKey('deliver-notify-${o.displayNo}'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), side: const BorderSide(color: Color(0xFF25D366)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: onUpdateCustomer,
                  icon: const Icon(LucideIcons.messageCircle, size: 16, color: Color(0xFF15803D)),
                  label: Text('Update', style: inter(13, 700, color: const Color(0xFF15803D))),
                ),
              ),
            ],
          ]),
        ],
      ]),
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _when(DateTime? t) {
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${t.day} ${_months[t.month - 1]} ${t.year} · $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final tag = switch (o.source) {
      'swiggy' => 'Swiggy${o.ref == null ? '' : ' #${o.ref}'}',
      'zomato' => 'Zomato${o.ref == null ? '' : ' #${o.ref}'}',
      'onelocal' => 'OneLocal app',
      _ => 'Phone order',
    };
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: ink.withValues(alpha: 0.35), width: 1.3)),
      child: InkWell(
        key: ValueKey('channel-order-${o.displayNo}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(o.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 800, color: ink)),
                  const SizedBox(height: 2),
                  Text('#${o.displayNo} · ${_when(o.placedAt)}', style: inter(12.5, 400, color: kMuted)),
                ]),
              ),
              Padding(padding: const EdgeInsets.only(right: 6), child: Text(rupees(o.total), style: inter(18, 800))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: _stageColor(o.stage), shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Expanded(child: Text(channelStageLabel(o.stage, o.source), key: ValueKey('channel-stage-${o.displayNo}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 600))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: ink.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(tag, style: inter(12, 600, color: ink)),
              ),
              IconButton(
                key: ValueKey('channel-expand-${o.displayNo}'),
                visualDensity: VisualDensity.compact,
                onPressed: onToggle,
                icon: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: kMuted),
              ),
            ]),
            // a new order: its accept timer and Accept
            if (onAccept != null) ...[
              const SizedBox(height: 4),
              Row(children: [
                if (secondsLeft != null)
                  Expanded(
                    child: Row(children: [
                      Icon(LucideIcons.timer, size: 15, color: secondsLeft! <= 10 ? const Color(0xFFD1213B) : ink),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(acceptLabel(secondsLeft!), key: ValueKey('channel-accept-in-${o.displayNo}'),
                            style: inter(13, 800, color: secondsLeft! <= 10 ? const Color(0xFFD1213B) : ink)),
                      ),
                    ]),
                  )
                else
                  const Spacer(),
                FilledButton.icon(
                  key: ValueKey('channel-accept-${o.displayNo}'),
                  style: FilledButton.styleFrom(backgroundColor: ink, visualDensity: VisualDensity.compact, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: accepting ? null : onAccept,
                  icon: accepting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(LucideIcons.check, size: 16),
                  label: Text('Accept', style: inter(13.5, 800, color: Colors.white)),
                ),
              ]),
            ],
            // the delivery update (0619): where it is, the rider, and the next step
            if (onDeliver != null && o.stage != 'new') _delivery(context),
            if (open) ...[
              const Divider(height: 14, color: kLine),
              Text(o.items.isEmpty ? 'No dishes' : o.items, style: inter(14, 500)),
              if (o.phone != null && o.phone!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Phone ${o.phone}', style: inter(13, 400, color: kMuted))),
            ],
          ]),
        ),
      ),
    );
  }
}
