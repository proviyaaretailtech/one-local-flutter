import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart' show typeSize;
import 'guest_api.dart';

/// The guest's own screens, laid out after the founder's design boards (specs/guest-experience-v2 "Vinii Bistro", and
/// specs/guest-experience-builder "The Windough" bakery): a welcome, dine-in or pre-order, an optional table budget, "What are you in the mood
/// for?", the swipe deck with the budget ring (right adds, left skips, up opens the details) or a list with the chef's picks, dish details,
/// "Added to your order", the order, review and notes, and "Order sent" with what the staff did with it; or, for a pre-order, a pickup day
/// and time, a name and a mobile number, and its tracking.
/// One set of screens for every way in ([GuestGateway]): the QR web page on the customer's phone, "Hand to guest" on the staff phone, and
/// the brand page / public menu link (no table: dine-in means scanning the table's code; pre-orders go through [GuestApp.preorders]).
/// The restaurant's published page ([GuestExperience]) sets the colours, the font and which screens come in which order; from an older server
/// with none, every restaurant gets neon green on black and the first order (welcome, budget, moods, menu).
/// The screens hold no business rule: what may be ordered, the prices, the pickup times and every limit come from the database. The budget is
/// a helper kept on this phone only (never on the staff phone, never sent); the total shown is the restaurant's estimate and the bill is
/// made by the restaurant.
/// Part 2 (specs/guest-experience-builder/spec-part2-live-orders.md, contract C): with [orders], a table QR order and a brand-page pre-order
/// go to the customer server and the page follows the order's stages (sent, accepted, preparing, on hold, restaurant paused, ready, served,
/// bill ready, paid, declined) and asks for the bill; with [feed], "Live mode" shows what other tables are ordering (dishes and tables only)
/// and what is trending; the restaurant's live offers can be applied as a code.
class GuestApp extends StatefulWidget {
  const GuestApp({
    super.key,
    required this.gateway,
    this.onExit,
    this.pollEvery = const Duration(seconds: 10),
    this.preorders,
    this.track,
    this.onTrackLink,
    this.experience,
    this.orders,
    this.feed,
    this.prefs,
    this.storeLink,
    this.stagePollEvery = const Duration(seconds: 4),
    this.feedEvery = const Duration(seconds: 6),
  });
  final GuestGateway gateway;

  /// Hand to guest: give the phone back to the staff screens. Null on the web page.
  final VoidCallback? onExit;
  final Duration pollEvery;

  /// The brand page's pre-order door; null on a table QR and with Hand to guest, which order at the table.
  final PreorderDoor? preorders;

  /// A pre-order's tracking token from the page address (`?track=`): the page opens on that pre-order.
  final String? track;

  /// Hears a new pre-order's tracking token, so the web page can keep it in its address (a reload or a shared link reopens the tracking).
  final ValueChanged<String>? onTrackLink;

  /// Shown instead of the published page (the restaurant's own preview in the builder).
  final GuestExperience? experience;

  /// The customer server's order door (contract A). Null: orders go through the POS guest door as before (table QR `send`, brand page
  /// `preorder`), and Hand to guest always places at once.
  final WebOrderDoor? orders;

  /// The restaurant's live order feed (contract B); null = no Live mode.
  final LiveFeedDoor? feed;

  /// This browser's little memory: whether Live mode is on. Memory only when null.
  final GuestPrefs? prefs;

  /// The restaurant's store link from the page address (brand page). A table QR page uses the one its visit answers with, when there is one.
  final String? storeLink;

  /// How often a sent web order's stage is asked for (until it is paid, declined or cancelled), and the live feed.
  final Duration stagePollEvery;
  final Duration feedEvery;

  @override
  State<GuestApp> createState() => _GuestAppState();
}

enum _Phase { loading, failed, ended, welcome, mode, scan, slot, budget, moods, menu, added, order, review, sent, bill, preReview, preSent, live }

class _GuestAppState extends State<GuestApp> {
  GuestGateway get g => widget.gateway;

  /// The restaurant's page; null from an older server.
  GuestExperience? get exp => widget.experience ?? _menu?.experience;

  /// No table here: the brand page (`onelocal.co/<store link>`) or the public menu link.
  bool get card => g is MenuCardGateway;

  /// The guest chose a pre-order for pickup (or the page offers nothing else).
  bool preorder = false;

  /// Read the menu, nothing to order: no table and no pre-order (dine-in from the brand page means scanning the table's code).
  bool get browse => card && !preorder;

  /// Hand to guest: the staff phone. No budget there (it is a guest's own helper on their own phone), no offer codes, and the order goes to
  /// the kitchen at once.
  bool get staff => !g.waitsForStaff && !card;

  /// Orders go to the customer server (contract A), not through the POS guest door.
  bool get viaCustomer => widget.orders != null && !staff;

  late final GuestPrefs _prefs = widget.prefs ?? MemoryGuestPrefs();

  /// The restaurant's store link: from the page address (brand page), else from the table QR visit.
  String? get slug => widget.storeLink ?? _visit?.storeLink;

  _Phase _phase = _Phase.loading;
  GuestVisit? _visit;
  GuestMenu? _menu;
  String? _error;
  final _cart = <GuestLine>[];
  Facts? _last;
  List<Facts> _requests = const [];
  Timer? _poll;

  /// The table's budget (a helper on this phone only; never sent anywhere). Null = no budget set.
  num? budget;
  int people = 2;

  /// The category the deck starts from ("What are you in the mood for?"); null = all dishes.
  String? mood;
  int _moodPick = 0; // a new pick starts a fresh deck; visiting the order and coming back keeps the deck where it was
  GuestItem? _justAdded;

  // ---- the pre-order (brand page)
  PreorderSlots? slots;

  /// The picked pickup time, exactly as the restaurant's slots wrote it.
  String? pickupAt;
  String preName = '', prePhone = '', preNote = '';

  /// The sent pre-order as its tracking last answered, and the token that tracks it.
  Facts? _pre;
  String? _track;
  Timer? _prePoll;
  bool _badTrack = false; // the tracking link did not open; the brand page itself did

  // ---- web orders (contract A): every order this page sent or opened, by its tracking token, oldest first
  final _web = <String, WebOrder>{};
  final _webLines = <String, List<({String name, int qty})>>{}; // what was sent, shown until the first status answers with the lines
  final _webPickup = <String, String>{}; // a pickup's time as the slot picker wrote it
  String? _shown; // the order the stage screen shows
  Timer? _webPoll;
  bool _webBusy = false;
  bool _webOffline = false; // the last check did not get through; the next tick tries again
  WebOrder? get shownOrder => _shown == null ? null : _web[_shown];
  static bool _isTrack(String k) => RegExp(r'^[0-9a-f]{36}$').hasMatch(k);

  // ---- the restaurant's offers: the one the guest applied goes with the order as its code; the bill decides what it takes off
  GuestOffer? coupon;
  List<GuestOffer> get offers => _menu?.offers ?? const [];
  bool get canApplyOffers => viaCustomer && !browse;
  String? get couponCode => canApplyOffers ? coupon?.code : null;

  /// Puts [o]'s code in the order (null takes it out). Nothing is checked here: the restaurant's bill decides what it takes off.
  void applyOffer(GuestOffer? o) => setState(() => coupon = o);

  // ---- Live mode (contract B): new orders of other tables as a short toast each, one after another, and a banner when a dish trends
  late bool live = _prefs.read(_liveKey) != '0';
  static const _liveKey = 'ol_guest_live';
  bool get liveAvailable => widget.feed != null && slug != null;
  Timer? _feedPoll;
  bool _feedBusy = false;
  bool _feedPrimed = false; // the first read only learns what was already there: nothing ordered before the page opened pops up
  final _seen = <({String sig, DateTime at})>[];
  var _streaksSeen = <String, int>{};
  final _toasts = <String>[];
  String? _toast;
  Timer? _toastTimer;
  String? _streak;
  Timer? _streakTimer;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _prePoll?.cancel();
    _webPoll?.cancel();
    _feedPoll?.cancel();
    _toastTimer?.cancel();
    _streakTimer?.cancel();
    super.dispose();
  }

  void go(_Phase p) => setState(() => _phase = p);

  // ---- what the restaurant's page says (each with the first behaviour when there is no page)
  Facts _props(String type) => exp?.props(type) ?? const Facts({});
  bool get ringOn => _props('swipe').raw['budget_ring'] != false;
  bool get fullCards => _props('swipe').s('card_style') == 'full';
  bool get showEta => _props('tracking').raw['show_eta'] != false;
  bool get billSplit => _props('bill').b('split');
  bool get billFeedback => _props('bill').raw['feedback'] != false;

  _Look? _look;
  GuestExperience? _lookFrom;
  _Look get look {
    final e = exp;
    if (_look == null || !identical(e, _lookFrom)) {
      _lookFrom = e;
      _look = e == null ? _Look.neon : _Look.of(e.theme);
    }
    return _look!;
  }

  /// The ways in this page offers. A pre-order needs the order-mode switch, the pre-order block and the brand page's door; a page always has
  /// one way in, and a table QR always orders at the table.
  ({bool dine, bool pre}) get modes {
    final e = exp;
    if (e == null) return (dine: true, pre: false);
    final m = e.props('order_mode');
    final pre = widget.preorders != null && m.b('pre_order') && e.on('preorder');
    return (dine: !pre || !card || m.b('dine_in'), pre: pre);
  }

  /// The screens up to the menu, in the restaurant's order (switched-on blocks only), then the menu itself. Without a page: welcome, budget
  /// and moods on a table, straight to the menu on the public menu link.
  List<_Phase> get steps {
    final e = exp;
    if (e == null) {
      return card
          ? const [_Phase.menu]
          : staff
          ? const [_Phase.welcome, _Phase.moods, _Phase.menu]
          : const [_Phase.welcome, _Phase.budget, _Phase.moods, _Phase.menu];
    }
    final m = modes;
    return [
      for (final b in e.blocks.where((b) => b.enabled))
        ...switch (b.type) {
          'welcome' => [_Phase.welcome],
          'order_mode' => [if (m.dine && m.pre) _Phase.mode, if (preorder) _Phase.slot else if (card) _Phase.scan],
          'budget' => [if (!card && !preorder && !staff) _Phase.budget],
          'categories' => [_Phase.moods],
          _ => const <_Phase>[],
        },
      _Phase.menu,
    ];
  }

  /// The step before the one showing, or null on the first.
  _Phase? get previous {
    final s = steps, i = s.indexOf(_phase);
    return i > 0 ? s[i - 1] : null;
  }

  void back() => go(previous ?? steps.first);

  void next() {
    final s = steps, i = s.indexOf(_phase);
    go(i >= 0 && i + 1 < s.length ? s[i + 1] : _Phase.menu);
  }

  /// "How would you like to enjoy ...?": a pre-order picks its pickup time next; dine-in orders at the table, or (brand page) scans its code.
  void choose({required bool pre}) {
    preorder = pre;
    final s = steps, i = s.indexOf(_Phase.mode);
    go(i >= 0 && i + 1 < s.length ? s[i + 1] : _Phase.menu);
  }

  Future<void> _open() async {
    setState(() => _phase = _Phase.loading);
    final token = widget.preorders == null && !viaCustomer ? null : widget.track;
    GuestVisit? v;
    try {
      v = await g.open();
    } catch (e) {
      // a tracking link still shows its pre-order when the page itself is not available
      if (token == null) {
        _fail(e);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _visit = v ?? _visit;
      _menu = v?.menu ?? _menu;
      preorder = modes.pre && !modes.dine;
      if (token == null) _phase = steps.first;
    });
    _startFeed();
    if (token != null) await (viaCustomer ? _openWebTrack(token) : _openPreorder(token));
  }

  // ---- web orders (contract A)

  /// Sends [order] to the customer server; the page then follows its stages, with the token in the page address.
  Future<void> placeWeb(WebOrderRequest order, String key) async {
    final o = await widget.orders!.place(order, key: key);
    if (!mounted) return;
    final id = o.track ?? 'order:${o.id}';
    setState(() {
      _web
        ..remove(id)
        ..[id] = o;
      _webLines[id] = [for (final l in order.lines) (name: l.item.name, qty: l.qty)];
      if (order.pickupAt != null) _webPickup[id] = order.pickupAt!;
      _shown = id;
      _cart.clear();
      coupon = null;
      _webOffline = false;
      _phase = _Phase.live;
    });
    if (o.track != null) widget.onTrackLink?.call(o.track!);
    await _refreshWeb();
  }

  /// Asks where every order still on its way is; stops when they are all paid, declined or cancelled.
  Future<void> _refreshWeb() async {
    if (_webBusy) return;
    final open = [for (final e in _web.entries) if (!e.value.done && _isTrack(e.key)) e.key];
    if (open.isEmpty) return _followWeb();
    _webBusy = true;
    var failed = false;
    for (final t in open) {
      try {
        final o = await widget.orders!.status(t);
        if (!mounted) return;
        setState(() => _web[t] = o);
      } catch (_) {
        failed = true; // tried again on the next tick
      }
    }
    _webBusy = false;
    if (!mounted) return;
    if (failed != _webOffline) setState(() => _webOffline = failed);
    _followWeb();
  }

  void _followWeb() {
    if (!_web.entries.any((e) => !e.value.done && _isTrack(e.key))) {
      _webPoll?.cancel();
      _webPoll = null;
      return;
    }
    _webPoll ??= Timer.periodic(widget.stagePollEvery, (_) => _refreshWeb());
  }

  /// Opened from a tracking link (`?track=`): straight to that order. A link from before (a POS pre-order's) still opens there.
  Future<void> _openWebTrack(String token) async {
    try {
      final o = await widget.orders!.status(token);
      if (!mounted) return;
      setState(() {
        _web[token] = o;
        _shown = token;
        _phase = _Phase.live;
      });
      _followWeb();
    } catch (e) {
      if (widget.preorders != null) return _openPreorder(token);
      _badTrack = _menu != null;
      _fail(e);
    }
  }

  /// "Get the bill": the restaurant makes it once every dish is ready or served. Answers a sentence to show when there is no bill yet.
  Future<String?> askBill() async {
    final t = _shown;
    if (t == null || !_isTrack(t)) return 'Please ask a member of staff for the bill.';
    try {
      final o = await widget.orders!.bill(t);
      if (!mounted) return null;
      setState(() {
        _web[t] = o;
        if (o.bill != null) _phase = _Phase.bill;
      });
      _followWeb();
      return o.bill == null ? 'Your bill can be made once every dish is ready or served.' : null;
    } catch (e) {
      return e is GuestApiException ? e.message : 'Could not ask for the bill. Please try again.';
    }
  }

  // ---- Live mode (contract B)

  void _startFeed() {
    _feedPoll?.cancel();
    _feedPoll = null;
    if (!live || !liveAvailable) return;
    _feedPrimed = false;
    _feedTick();
    _feedPoll = Timer.periodic(widget.feedEvery, (_) => _feedTick());
  }

  Future<void> _feedTick() async {
    final s = slug, door = widget.feed;
    if (s == null || door == null || !live || _feedBusy) return;
    _feedBusy = true;
    GuestFeed f;
    try {
      f = await door.feed(s);
    } catch (_) {
      return; // a missed read is tried again on the next tick
    } finally {
      _feedBusy = false;
    }
    if (!mounted || !live) return;
    // a feed line has no id: the same dish, quantity and table at about the same moment is the same order
    final now = DateTime.now();
    _seen.removeWhere((x) => now.difference(x.at) > const Duration(minutes: 25));
    final fresh = <({int ago, String text})>[];
    for (final i in f.items) {
      final at = now.subtract(Duration(seconds: i.secondsAgo));
      final sig = '${i.name}|${i.qty}|${i.table ?? ''}|${i.category ?? ''}';
      if (_seen.any((x) => x.sig == sig && x.at.difference(at).abs() <= const Duration(seconds: 15))) continue;
      _seen.add((sig: sig, at: at));
      if (_feedPrimed) fresh.add((ago: i.secondsAgo, text: feedLine(i.qty, i.name, i.table)));
    }
    String? banner;
    for (final st in [...f.streaks]..sort((a, b) => b.count.compareTo(a.count))) {
      final was = _streaksSeen['${st.kind}|${st.name}'];
      if (was == null || st.count > was) banner ??= st.kind == 'dish' ? '${st.count} tables ordered ${st.name}' : '${st.count} ${st.name} ordered';
    }
    _streaksSeen = {for (final st in f.streaks) '${st.kind}|${st.name}': st.count};
    _feedPrimed = true;
    fresh.sort((a, b) => b.ago.compareTo(a.ago)); // the oldest first
    for (final x in fresh) {
      _queueToast(x.text);
    }
    if (banner != null) _showStreak(banner);
  }

  /// "1 Butter Chicken ordered on Table 10"; "1 Butter Chicken just ordered" without a table. Never a name, a phone or an amount.
  String feedLine(int qty, String dish, String? table) {
    if (table == null) return '$qty $dish just ordered';
    final word = _menu?.tableWord ?? 'Table';
    return '$qty $dish ordered on ${table.toLowerCase().startsWith(word.toLowerCase()) ? table : '$word $table'}';
  }

  void _queueToast(String text) {
    _toasts.add(text);
    while (_toasts.length > 5) {
      _toasts.removeAt(0); // a burst does not keep the page busy for minutes
    }
    if (_toast == null && _toastTimer == null) _nextToast();
  }

  /// One toast at a time: about 2 s each, a short gap, then the next.
  void _nextToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    if (!mounted) return;
    if (_toasts.isEmpty) {
      if (_toast != null) setState(() => _toast = null);
      return;
    }
    setState(() => _toast = _toasts.removeAt(0));
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _toast = null);
      _toastTimer = Timer(const Duration(milliseconds: 350), _nextToast);
    });
  }

  void _showStreak(String text) {
    _streakTimer?.cancel();
    setState(() => _streak = text);
    _streakTimer = Timer(const Duration(seconds: 4), () {
      _streakTimer = null;
      if (mounted) setState(() => _streak = null);
    });
  }

  /// The "Live mode" switch: off stops the feed and its toasts; the choice is kept on this browser.
  void setLive(bool on) {
    _prefs.write(_liveKey, on ? '1' : '0');
    _toastTimer?.cancel();
    _toastTimer = null;
    _streakTimer?.cancel();
    _streakTimer = null;
    setState(() {
      live = on;
      _toasts.clear();
      _toast = null;
      _streak = null;
    });
    if (on) {
      _startFeed();
    } else {
      _feedPoll?.cancel();
      _feedPoll = null;
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      if (e is GuestApiException && e.sessionEnded) {
        _phase = _Phase.ended;
      } else {
        _phase = _Phase.failed;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      }
    });
  }

  int get _count => _cart.fold(0, (a, l) => a + l.qty);
  num get _total => _cart.fold<num>(0, (a, l) => a + l.item.price * l.qty);
  int qtyOf(GuestItem i) => _cart.where((l) => l.item.id == i.id).firstOrNull?.qty ?? 0;

  /// Adds one of [item] (up to 20 of a dish: the database's limit, said here so the button stops in time).
  void add(GuestItem item, [int n = 1]) {
    if (browse) return;
    setState(() {
      final line = _cart.where((l) => l.item.id == item.id).firstOrNull;
      if (line == null) {
        _cart.add(GuestLine(item, n.clamp(1, 20)));
      } else {
        line.qty = (line.qty + n).clamp(1, 20);
      }
    });
  }

  void remove(GuestItem item) {
    setState(() {
      final line = _cart.where((l) => l.item.id == item.id).firstOrNull;
      if (line == null) return;
      if (line.qty <= 1) {
        _cart.remove(line);
      } else {
        line.qty--;
      }
    });
  }

  Future<void> _refreshStatus() async {
    if (!g.waitsForStaff) return;
    try {
      final r = await g.status();
      if (mounted) setState(() => _requests = r);
    } catch (e) {
      if (e is GuestApiException && e.sessionEnded) {
        _poll?.cancel();
        _fail(e);
      }
    }
  }

  void _sent(Facts result) {
    setState(() {
      _last = result;
      _cart.clear();
      _phase = _Phase.sent;
    });
    if (g.waitsForStaff) {
      _refreshStatus();
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollEvery, (_) => _refreshStatus());
    }
  }

  /// A pre-order is followed until the restaurant has declined it or it is done.
  static bool _preDone(Facts r) => r.s('status') == 'declined' || const {'served', 'cancelled'}.contains(GuestTrack.of(r)?.stage);

  void _followPre() {
    _prePoll?.cancel();
    if (_track != null && _pre != null && !_preDone(_pre!)) _prePoll = Timer.periodic(widget.pollEvery, (_) => _refreshPre());
  }

  Future<void> _refreshPre() async {
    final t = _track;
    if (t == null) return;
    try {
      final r = await widget.preorders!.track(t);
      if (!mounted) return;
      setState(() => _pre = r);
      if (_preDone(r)) _prePoll?.cancel();
    } catch (_) {
      // a missed check is tried again on the next tick
    }
  }

  /// Opened from a tracking link: straight to that pre-order.
  Future<void> _openPreorder(String token) async {
    try {
      final r = await widget.preorders!.track(token);
      if (!mounted) return;
      setState(() {
        _track = token;
        _pre = r;
        _phase = _Phase.preSent;
      });
      _followPre();
    } catch (e) {
      _badTrack = _menu != null;
      _fail(e);
    }
  }

  /// The restaurant has the pre-order: its tracking from now on, with the token in the page address.
  void _preSent(Facts r) {
    final token = r.so('track') ?? '';
    setState(() {
      _pre = r;
      if (token.isNotEmpty) _track = token;
      _cart.clear();
      _phase = _Phase.preSent;
    });
    if (token.isNotEmpty) widget.onTrackLink?.call(token);
    _followPre();
  }

  Future<void> _openItem(GuestItem item) async {
    final k = look;
    final n = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: k.card,
      clipBehavior: Clip.antiAlias, // the photo runs edge to edge under the rounded top
      barrierLabel: 'Close the dish details',
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _LookScope(
        look: k,
        child: _ItemSheet(item: item, inCart: qtyOf(item), browse: browse),
      ),
    );
    if (n == null || !mounted) return;
    add(item, n);
    setState(() {
      _justAdded = item;
      _phase = _Phase.added;
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = look;
    return _LookScope(
      look: k,
      child: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.fromSeed(seedColor: k.accent, brightness: k.dark ? Brightness.dark : Brightness.light, surface: k.bg),
          scaffoldBackgroundColor: k.bg,
          textSelectionTheme: TextSelectionThemeData(cursorColor: k.accent),
        ),
        child: Scaffold(
          key: const ValueKey('guest-app'),
          backgroundColor: k.bg,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // the menu stays mounted (hidden) while the guest looks at their order, so the deck keeps its place
                if (_menu != null &&
                    const {_Phase.menu, _Phase.added, _Phase.order, _Phase.review, _Phase.sent, _Phase.bill, _Phase.preReview, _Phase.preSent, _Phase.live}
                        .contains(_phase))
                  Offstage(
                    offstage: _phase != _Phase.menu,
                    child: TickerMode(
                      enabled: _phase == _Phase.menu,
                      child: _MenuView(key: ValueKey('menu-$_moodPick'), app: this),
                    ),
                  ),
                // each screen eases in over the one before (a fade and a short rise); no vibration anywhere, so it is the same on the web
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(position: Tween(begin: const Offset(0, 0.025), end: Offset.zero).animate(a), child: child),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey('phase-${_phase.name}'),
                    child: _phase == _Phase.menu ? const SizedBox.shrink() : ColoredBox(color: k.bg, child: _screen(k)),
                  ),
                ),
                if (!const {_Phase.loading, _Phase.failed, _Phase.ended}.contains(_phase))
                  Positioned(
                    top: 6,
                    left: 14,
                    right: 14,
                    child: IgnorePointer(child: _LiveOverlay(toast: live ? _toast : null, streak: live ? _streak : null)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _screen(_Look k) => switch (_phase) {
    _Phase.loading => Center(
      child: CircularProgressIndicator(key: const ValueKey('guest-loading'), color: k.accent),
    ),
    _Phase.failed => _Message(
      key: const ValueKey('guest-failed'),
      icon: Icons.storefront_outlined,
      title: 'Not available right now',
      body: _error ?? '',
      action: _badTrack ? 'See the menu' : 'Try again',
      onAction: _badTrack ? () => go(steps.first) : _open,
      exit: widget.onExit,
    ),
    _Phase.ended => _Message(
      key: const ValueKey('guest-ended'),
      icon: Icons.qr_code_2_rounded,
      title: 'Please scan the table code again',
      body: 'This visit has ended or the table code was changed. Scan the code on your table to order.',
      exit: widget.onExit,
    ),
    _Phase.welcome => _Welcome(app: this),
    _Phase.mode => _OrderMode(app: this),
    _Phase.scan => _ScanToOrder(app: this),
    _Phase.slot => _SlotPicker(app: this),
    _Phase.budget => _BudgetSetup(app: this),
    _Phase.moods => _Moods(app: this),
    _Phase.menu => const SizedBox(),
    _Phase.added => _Added(app: this),
    _Phase.order => _OrderView(app: this),
    _Phase.review => _Review(app: this),
    _Phase.sent => _SentView(app: this),
    _Phase.bill => _BillView(app: this),
    _Phase.preReview => _PreReview(app: this),
    _Phase.preSent => _PreSent(app: this),
    _Phase.live => shownOrder == null ? const SizedBox() : _StageView(app: this),
  };
}

// ---- the look: the restaurant's own colours and font (its published experience), or neon green on black (founder's "Vinii Bistro" board)
// when the server sends none. Veg, non-veg and the bestseller amber mean the same thing on every page, so they never change.
const _veg = Color(0xFF22C55E);
const _nonVeg = Color(0xFFEF4444);
const _amber = Color(0xFFF59E0B);
const _onAmber = Color(0xFF111111);

class _Look {
  const _Look({
    required this.bg,
    required this.card,
    required this.card2,
    required this.line,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.art,
    this.dark = true,
    this.serif = false,
  });
  final Color bg, card, card2, line, ink, muted, accent, onAccent;

  /// The two colours behind a dish with no photo.
  final (Color, Color) art;
  final bool dark;

  /// Headings in a serif ("Bakery warm"). No serif font is bundled: where the device has none (the web page) they fall back to Inter.
  final bool serif;

  static const neon = _Look(
    bg: Color(0xFF0A0A0A),
    card: Color(0xFF161616),
    card2: Color(0xFF1F1F1F),
    line: Color(0xFF2A2A2A),
    ink: Colors.white,
    muted: Color(0xFF9CA3AF),
    accent: Color(0xFF8CFF2E),
    onAccent: Color(0xFF0A0A0A),
    art: (Color(0xFF2B4A12), Color(0xFF101A08)),
  );

  /// The restaurant's theme; the second card colour, the lines and the no-photo colours come from its own five.
  factory _Look.of(GuestTheme t) => _Look(
    bg: t.background,
    card: t.surface,
    card2: Color.alphaBlend(t.text.withValues(alpha: 0.06), t.surface),
    line: Color.alphaBlend(t.text.withValues(alpha: 0.13), t.background),
    ink: t.text,
    muted: t.muted,
    accent: t.accent,
    onAccent: t.accentText,
    art: (Color.alphaBlend(t.accent.withValues(alpha: 0.45), t.surface), Color.alphaBlend(t.accent.withValues(alpha: 0.15), t.background)),
    dark: t.dark,
    serif: t.serif,
  );

  /// Words on a dish photo (under its dark shade) stay light on every page; the price keeps the accent only where the accent is light.
  Color get onPhoto => Colors.white;
  Color get photoAccent => dark ? accent : Colors.white;

  /// "Waiting for ..." in amber, a deeper amber on a light page so it stays readable.
  Color get waiting => dark ? _amber : const Color(0xFFB45309);

  /// Text in the page's font: display sizes (24 and up) in the restaurant's serif when it chose one.
  TextStyle t(double size, FontWeight w, {Color? color, double? height}) => TextStyle(
    fontFamily: serif && size >= 24 ? 'serif' : 'Inter',
    fontFamilyFallback: serif && size >= 24 ? const ['Inter'] : null,
    fontSize: typeSize(size),
    fontWeight: w,
    color: color ?? ink,
    height: height,
  );
}

class _LookScope extends InheritedWidget {
  const _LookScope({required this.look, required super.child});
  final _Look look;
  @override
  bool updateShouldNotify(_LookScope old) => old.look != look;
}

_Look _lookOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_LookScope>()?.look ?? _Look.neon;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "9:00 AM".
String _clock(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

/// A pickup time on the restaurant's clock: "Sat, 16 Sep · 9:00 AM".
String _pickupLabel(String iso, String? timezone) {
  final t = guestWallTime(iso, timezone);
  return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} · ${_clock(t)}';
}

/// "₹120" or "₹120.50".
String guestMoney(num v) {
  final whole = v == v.roundToDouble();
  final s = whole ? v.round().toString() : v.toStringAsFixed(2);
  final parts = s.split('.');
  final digits = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return '₹$digits${parts.length > 1 ? '.${parts[1]}' : ''}';
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {super.key, required this.onTap, this.filled = true, this.busy = false, this.trailing});
  final String label;
  final VoidCallback? onTap;
  final IconData? trailing;
  final bool filled;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final bg = filled ? k.accent : Colors.transparent;
    final fg = filled ? k.onAccent : k.ink;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: onTap == null && filled ? bg.withValues(alpha: 0.4) : bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: busy ? null : onTap,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: filled
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: k.ink.withValues(alpha: 0.7), width: 1.4),
                  ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: Text(label, style: k.t(16, FontWeight.w700, color: fg)),
                      ),
                      if (trailing != null) ...[const SizedBox(width: 8), Icon(trailing, size: 20, color: fg)],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _BackBar extends StatelessWidget {
  const _BackBar({this.onBack, this.title, this.action});
  final VoidCallback? onBack;
  final String? title;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              key: const ValueKey('back'),
              tooltip: 'Back',
              onPressed: onBack,
              icon: Icon(Icons.arrow_back_rounded, color: k.ink),
            )
          else
            const SizedBox(width: 12),
          if (title != null) Expanded(child: Text(title!, style: k.t(19, FontWeight.w800))) else const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.title, required this.body, this.action, this.onAction, this.exit});
  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? exit;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: k.muted),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: k.t(22, FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: k.t(15, FontWeight.w400, color: k.muted, height: 1.4),
            ),
            const SizedBox(height: 24),
            if (action != null) _Pill(action!, key: const ValueKey('guest-retry'), onTap: onAction),
            if (exit != null) ...[const SizedBox(height: 12), _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: exit)],
          ],
        ),
      ),
    );
  }
}

/// Board 1, "Welcome / Landing" (the restaurant's welcome block): its picture (or a dish photo) behind, the restaurant and outlet, the table on a
/// table QR, its headline and line, and its button.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final visit = app._visit!;
    final m = visit.menu;
    final w = app._props('welcome');
    final brand = m.brandName.isEmpty ? visit.business : m.brandName;
    final table = '${m.tableWord} ${visit.tableLabel}';
    final photo = app.exp?.welcomeImageUrl ?? m.items.where((i) => i.imageUrl != null).firstOrNull?.imageUrl;
    // words sit on the photo's dark shade; a light page with no photo stays plain
    final onPhoto = photo != null && !k.dark;
    final ink = onPhoto ? k.onPhoto : k.ink;
    final muted = onPhoto ? Colors.white.withValues(alpha: 0.82) : k.muted;
    final headAccent = photo != null ? k.photoAccent : k.accent;
    final headline = (w.so('headline') ?? '').trim();
    final words = headline.split(RegExp(r'\s+'));
    // the Bistro board's headline ends in the accent ("... when you explore it.")
    final (lead, tail) = app.exp == null
        ? ('Food looks better\nwhen you ', 'explore it.')
        : words.length >= 4
        ? ('${words.sublist(0, words.length - 2).join(' ')} ', words.sublist(words.length - 2).join(' '))
        : (headline.isEmpty ? 'Welcome' : headline, '');
    return Stack(
      fit: StackFit.expand,
      children: [
        if (photo != null) Image.network(photo, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
        if (photo != null || k.dark)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [const Color(0x66000000), const Color(0x99000000), (k.dark ? k.bg : Colors.black).withValues(alpha: 0.95)],
                stops: const [0, 0.45, 0.8],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: k.accent, borderRadius: BorderRadius.circular(12)),
                    alignment: Alignment.center,
                    child: Text(brand.isEmpty ? '?' : brand.characters.first.toUpperCase(), style: k.t(22, FontWeight.w900, color: k.onAccent)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(brand, key: const ValueKey('guest-brand'), maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(17, FontWeight.w800, color: ink)),
                        Row(
                          children: [
                            Icon(Icons.location_on_rounded, size: 14, color: headAccent),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(visit.outlet, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(13, FontWeight.w500, color: muted)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (app.widget.onExit != null)
                    TextButton(
                      key: const ValueKey('guest-exit'),
                      onPressed: app.widget.onExit,
                      child: Text('Back to staff', style: k.t(14, FontWeight.w600, color: headAccent)),
                    ),
                ],
              ),
              const Spacer(),
              if (!app.card)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: headAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: headAccent.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    visit.areaName == null || visit.areaName!.isEmpty ? table : '$table · ${visit.areaName}',
                    key: const ValueKey('guest-table'),
                    style: k.t(14, FontWeight.w700, color: headAccent),
                  ),
                ),
              const SizedBox(height: 16),
              Text.rich(
                key: const ValueKey('guest-headline'),
                TextSpan(
                  children: [
                    TextSpan(text: lead, style: k.t(38, FontWeight.w800, color: ink, height: 1.12)),
                    if (tail.isNotEmpty) TextSpan(text: tail, style: k.t(38, FontWeight.w800, color: headAccent, height: 1.12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                m.items.isEmpty
                    ? (app.card ? 'The menu is empty right now. Please check again later.' : 'Nothing can be ordered right now. Please ask the staff.')
                    : (w.s('subtext').trim().isNotEmpty
                          ? w.s('subtext').trim()
                          : m.tagline ??
                                (app.staff
                                    ? 'Swipe through dishes and order together. Pay at the table when you are done.'
                                    : 'Swipe through dishes, set a budget, and order together. Pay at the table when you are done.')),
                style: k.t(15, FontWeight.w400, color: muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: _Pill(
                  (w.so('cta_label') ?? '').trim().isEmpty ? 'Start exploring' : w.s('cta_label').trim(),
                  key: const ValueKey('guest-start'),
                  trailing: Icons.arrow_forward_rounded,
                  onTap: m.items.isEmpty ? null : app.next,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Bakery board 3, "How would you like to enjoy (the restaurant)?": dine-in or a pre-order, with the restaurant's own names for them. Shown only when
/// the page offers both.
class _OrderMode extends StatelessWidget {
  const _OrderMode({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final p = app._props('order_mode');
    final m = app._menu!;
    final brand = m.brandName.isEmpty ? app._visit!.business : m.brandName;
    String label(String key, String fallback) => (p.so(key) ?? '').trim().isEmpty ? fallback : p.s(key).trim();
    Widget choice(String key, String title, String line, IconData icon, VoidCallback onTap) => Semantics(
      button: true,
      label: title,
      child: Material(
        color: k.card,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), border: Border.all(color: k.line)),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(icon, color: k.accent, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: k.t(20, FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(line, style: k.t(14, FontWeight.w500, color: k.muted, height: 1.35)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: k.accent, shape: BoxShape.circle),
                  child: Icon(Icons.arrow_forward_rounded, size: 20, color: k.onAccent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      key: const ValueKey('order-mode'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: app.previous == null ? null : app.back),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
          child: Text('How would you like to enjoy $brand?', style: k.t(28, FontWeight.w800, height: 1.15)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: choice(
            'mode-dine-in',
            label('dine_in_label', 'Dine-in'),
            app.card ? 'Scan the QR code on your table to order' : 'Order fresh at your table',
            Icons.restaurant_rounded,
            () => app.choose(pre: false),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: choice(
            'mode-pre-order',
            label('pre_order_label', 'Pre-order'),
            'Pick a day and time, and collect it ready',
            Icons.shopping_bag_outlined,
            () => app.choose(pre: true),
          ),
        ),
      ],
    );
  }
}

/// Dine-in from the brand page: ordering happens at the table, through its own QR code (so the order reaches the right table). The menu can
/// still be read.
class _ScanToOrder extends StatelessWidget {
  const _ScanToOrder({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Column(
      key: const ValueKey('brand-scan-qr'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: app.previous == null ? null : app.back),
        const Spacer(),
        Icon(Icons.qr_code_scanner_rounded, size: 72, color: k.accent),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text('Scan the QR code on your table to order', textAlign: TextAlign.center, style: k.t(26, FontWeight.w800, height: 1.2)),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            "Every table has its own code. Scan it with your phone's camera and your order goes straight to the staff.",
            textAlign: TextAlign.center,
            style: k.t(15, FontWeight.w400, color: k.muted, height: 1.4),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
          child: _Pill('Browse the menu', key: const ValueKey('scan-browse'), trailing: Icons.arrow_forward_rounded, onTap: app.next),
        ),
      ],
    );
  }
}

/// Board 2, "Party & Budget Setup": a total budget and how many people share it, in the range the restaurant's budget block sets (and
/// without the split when it says so). Kept on this phone only; "Skip" orders without one.
class _BudgetSetup extends StatefulWidget {
  const _BudgetSetup({required this.app});
  final _GuestAppState app;
  @override
  State<_BudgetSetup> createState() => _BudgetSetupState();
}

class _BudgetSetupState extends State<_BudgetSetup> {
  late final Facts _p = widget.app._props('budget');
  late final double _min = (_p.no('min') ?? 500).toDouble();
  late final double _max = math.max((_p.no('max') ?? 20000).toDouble(), _min + 100);
  late final bool _split = _p.raw['split'] != false;

  /// About 40 stops along the slider, each a round amount (₹500 steps for ₹500 to ₹20,000).
  late final int _stops = () {
    final step = const [50, 100, 250, 500, 1000, 2500, 5000, 10000].firstWhere((s) => (_max - _min) / s <= 40, orElse: () => 10000);
    return math.max(1, ((_max - _min) / step).round());
  }();
  late double _budget = (widget.app.budget ?? _p.no('default') ?? 3000).toDouble().clamp(_min, _max);
  late int _people = widget.app.people;

  void _done(bool keep) {
    final app = widget.app;
    app.budget = keep ? _budget : null;
    app.people = _people;
    app.next();
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(
          onBack: widget.app.previous == null ? null : widget.app.back,
          action: TextButton(
            key: const ValueKey('budget-skip'),
            onPressed: () => _done(false),
            child: Text('Skip', style: k.t(15, FontWeight.w600, color: k.muted)),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
            children: [
              Text('Dining with friends?', style: k.t(30, FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Set a budget to stay on track. We will show your progress as you order. Only you see it.',
                style: k.t(15, FontWeight.w400, color: k.muted, height: 1.4),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: k.card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: k.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total budget', style: k.t(14, FontWeight.w500, color: k.muted)),
                    const SizedBox(height: 6),
                    Text(guestMoney(_budget.round()), key: const ValueKey('budget-amount'), style: k.t(36, FontWeight.w800)),
                    SliderTheme(
                      data: SliderTheme.of(context)
                          .copyWith(activeTrackColor: k.accent, inactiveTrackColor: k.line, thumbColor: k.accent, overlayColor: k.accent.withValues(alpha: 0.15)),
                      child: Slider(
                        key: const ValueKey('budget-slider'),
                        min: _min,
                        max: _max,
                        divisions: _stops,
                        value: _budget,
                        onChanged: (v) => setState(() => _budget = v),
                      ),
                    ),
                    Row(
                      children: [
                        Text(guestMoney(_min), style: k.t(13, FontWeight.w500, color: k.muted)),
                        const Spacer(),
                        Text(guestMoney(_max), style: k.t(13, FontWeight.w500, color: k.muted)),
                      ],
                    ),
                  ],
                ),
              ),
              if (_split) ...[
                const SizedBox(height: 14),
                Container(
                  key: const ValueKey('budget-split'),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: k.card,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: k.line),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Split between', style: k.t(14, FontWeight.w500, color: k.muted)),
                            const SizedBox(height: 6),
                            Text('$_people ${_people == 1 ? 'person' : 'people'}', style: k.t(18, FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(
                              '${guestMoney((_budget / _people).round())} per person',
                              key: const ValueKey('budget-per-person'),
                              style: k.t(14, FontWeight.w500, color: k.accent),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(color: k.card2, borderRadius: BorderRadius.circular(14)),
                        child: Row(
                          children: [
                            IconButton(
                              key: const ValueKey('budget-people-minus'),
                              tooltip: 'One person fewer',
                              onPressed: _people > 1 ? () => setState(() => _people--) : null,
                              icon: Icon(Icons.remove_rounded, color: k.ink),
                            ),
                            Text('$_people', style: k.t(18, FontWeight.w800)),
                            IconButton(
                              key: const ValueKey('budget-people-plus'),
                              tooltip: 'One more person',
                              onPressed: _people < 30 ? () => setState(() => _people++) : null,
                              icon: Icon(Icons.add_rounded, color: k.ink),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
          child: _Pill('Save & continue', key: const ValueKey('budget-save'), trailing: Icons.arrow_forward_rounded, onTap: () => _done(true)),
        ),
      ],
    );
  }
}

/// Board 3, "Category Selection": "What are you in the mood for?" — every category with a dish photo, and All dishes.
class _Moods extends StatelessWidget {
  const _Moods({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final menu = app._menu!;
    GuestItem? cover(String? cat) =>
        menu.items.where((i) => (cat == null || i.categoryId == cat) && i.imageUrl != null).firstOrNull ??
        menu.items.where((i) => cat == null || i.categoryId == cat).firstOrNull;
    final tiles = <(String?, String)>[(null, 'All dishes'), for (final c in menu.categories) (c.id, c.name)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: app.previous == null ? null : app.back),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
          child: Text('What are you in the mood for?', style: k.t(28, FontWeight.w800, height: 1.15)),
        ),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
            children: [
              for (final (id, name) in tiles)
                Semantics(
                  button: true,
                  label: name,
                  child: InkWell(
                    key: ValueKey(id == null ? 'mood-all' : 'mood-$id'),
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      app.mood = id;
                      app._moodPick++;
                      app.next();
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: id == null ? k.accent : k.line, width: id == null ? 1.6 : 1),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (cover(id) != null) _Art(item: cover(id)!, radius: 0, label: name.characters.first.toUpperCase()),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xCC000000)]),
                            ),
                          ),
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: k.t(16, FontWeight.w800, color: k.onPhoto)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The budget ring of boards 4-8: spent of budget, the share used, red past the budget.
class _BudgetRing extends StatelessWidget {
  const _BudgetRing({required this.spent, required this.budget});
  static const size = 46.0;
  final num spent;
  final num budget;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final share = budget <= 0 ? 0.0 : (spent / budget).toDouble();
    final over = share > 1;
    return Row(
      key: const ValueKey('budget-ring'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _RingPainter(share.clamp(0, 1), over ? _nonVeg : k.accent, k.line)),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${guestMoney(spent)} / ${guestMoney(budget)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(15, FontWeight.w800)),
              Text(
                over ? 'Over budget by ${guestMoney(spent - budget)}' : '${(share * 100).round()}% used',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: k.t(12.5, FontWeight.w500, color: over ? _nonVeg : k.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.share, this.color, this.track);
  final double share;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(3, 3, size.width - 6, size.height - 6);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * share,
      false,
      base
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share || old.color != color || old.track != track;
}

/// Board 4, "Swipe Browse": the deck (or the list), the budget ring, categories underneath, and the order bar. The restaurant's highlights
/// (bakery board 14, "Chef's picks" and "Limited today") lead the list and have their own chip.
class _MenuView extends StatefulWidget {
  const _MenuView({super.key, required this.app});
  final _GuestAppState app;
  @override
  State<_MenuView> createState() => _MenuViewState();
}

class _MenuViewState extends State<_MenuView> {
  bool _swipe = true;
  bool _vegOnly = false;
  late String? _category = widget.app.mood;
  String _q = '';
  int _deckStart = 0;
  static const _picksChip = '\u0000picks'; // the "Chef's picks" chip, never a category id

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final app = widget.app;
    final menu = app._menu!;
    // the restaurant's picks and today's limited dishes, as far as they are on the menu right now
    final h = app.exp?.on('highlights') == true ? app._props('highlights') : null;
    List<GuestItem> chosen(String key) => [for (final id in h?.ls(key) ?? const <String>[]) ?menu.byId(id)];
    final picks = chosen('pick_ids'), limited = chosen('limited_ids');
    final picked = {for (final i in [...picks, ...limited]) i.id};
    String title(String key, String fallback) => (h?.so(key) ?? '').trim().isEmpty ? fallback : h!.s(key).trim();
    final items = menu.items.where((i) => !_vegOnly || i.veg).toList();
    final shown = items
        .where((i) => _category == null || (_category == _picksChip ? picked.contains(i.id) : i.categoryId == _category))
        .where((i) => _swipe || _q.isEmpty || i.name.toLowerCase().contains(_q.toLowerCase()) || (i.description ?? '').toLowerCase().contains(_q.toLowerCase()))
        .toList();
    final rails = !_swipe && _category == null && _q.isEmpty && !_vegOnly;
    final ring = app.budget != null && !app.card && !app.preorder && app.ringOn;
    final tight = ring || app.liveAvailable || app._web.isNotEmpty || app._requests.isNotEmpty || app._pre != null;
    Widget chip(String label, bool on, VoidCallback tap, Key key) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: on,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(999),
          onTap: tap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: on ? k.accent : k.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? k.accent : k.line),
            ),
            child: Text(label, style: k.t(14, FontWeight.w700, color: on ? k.onAccent : k.ink)),
          ),
        ),
      ),
    );
    final cats = SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          chip(
            'Veg only',
            _vegOnly,
            () => setState(() {
              _vegOnly = !_vegOnly;
              _deckStart++;
            }),
            const ValueKey('veg-only'),
          ),
          chip(
            'All',
            _category == null,
            () => setState(() {
              _category = null;
              _deckStart++;
            }),
            const ValueKey('cat-all'),
          ),
          if (picked.isNotEmpty)
            chip(
              title('picks_title', "Chef's picks"),
              _category == _picksChip,
              () => setState(() {
                _category = _picksChip;
                _deckStart++;
              }),
              const ValueKey('cat-picks'),
            ),
          for (final c in menu.categories)
            chip(
              c.name,
              _category == c.id,
              () => setState(() {
                _category = c.id;
                _deckStart++;
              }),
              ValueKey('cat-${c.id}'),
            ),
        ],
      ),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          child: Row(
            children: [
              if (app.previous == null)
                const SizedBox(width: 10)
              else
                IconButton(
                  key: const ValueKey('menu-back'),
                  tooltip: 'Back',
                  onPressed: app.back,
                  icon: Icon(Icons.arrow_back_rounded, color: k.ink),
                ),
              Expanded(
                child: ring
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: _BudgetRing(spent: app._total, budget: app.budget!),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            menu.brandName.isEmpty ? app._visit!.business : menu.brandName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: k.t(18, FontWeight.w800),
                          ),
                          Text(
                            app.preorder
                                ? (app.pickupAt == null ? 'Pre-order' : 'Pickup ${_pickupLabel(app.pickupAt!, app.slots?.timezone)}')
                                : app.card
                                ? app._visit!.outlet
                                : '${menu.tableWord} ${app._visit!.tableLabel}',
                            key: const ValueKey('menu-subtitle'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: k.t(13, FontWeight.w500, color: k.muted),
                          ),
                        ],
                      ),
              ),
              if (app._requests.isNotEmpty || app._web.isNotEmpty)
                IconButton(
                  key: const ValueKey('menu-orders'),
                  tooltip: 'Your orders',
                  onPressed: () => app.go(app._web.isNotEmpty ? _Phase.live : _Phase.sent),
                  icon: Icon(Icons.receipt_long_rounded, color: k.accent),
                ),
              if (app.liveAvailable) ...[_LiveSwitch(app: app), const SizedBox(width: 6)],
              if (app._pre != null)
                IconButton(
                  key: const ValueKey('menu-preorder'),
                  tooltip: 'Your pre-order',
                  onPressed: () => app.go(_Phase.preSent),
                  icon: Icon(Icons.receipt_long_rounded, color: k.accent),
                ),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: k.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: k.line),
                ),
                child: Row(
                  children: [
                    for (final (key, label, icon, on) in [
                      ('mode-swipe', 'Swipe', Icons.style_rounded, _swipe),
                      ('mode-list', 'List', Icons.view_list_rounded, !_swipe),
                    ])
                      Semantics(
                        button: true,
                        selected: on,
                        label: tight ? label : null,
                        child: InkWell(
                          key: ValueKey(key),
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => setState(() => _swipe = key == 'mode-swipe'),
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: tight ? 9 : 14, vertical: tight ? 6 : 8),
                            decoration: BoxDecoration(color: on ? k.accent : null, borderRadius: BorderRadius.circular(999)),
                            // a crowded header (budget ring, Live, your orders) shows the two as icons
                            child: tight
                                ? ExcludeSemantics(child: Icon(icon, size: 20, color: on ? k.onAccent : k.muted))
                                : Text(label, style: k.t(13, FontWeight.w700, color: on ? k.onAccent : k.muted)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (app.offers.isNotEmpty) _OffersStrip(app: app),
        if (!_swipe) ...[
          cats,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const ValueKey('menu-search'),
              style: k.t(15, FontWeight.w500),
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: InputDecoration(
                hintText: 'Search the menu',
                hintStyle: k.t(15, FontWeight.w400, color: k.muted),
                prefixIcon: Icon(Icons.search_rounded, color: k.muted),
                filled: true,
                fillColor: k.card,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: k.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: k.line),
                ),
              ),
            ),
          ),
        ],
        Expanded(
          child: _swipe
              ? _Deck(
                  key: ValueKey('deck-$_vegOnly-$_category-$_deckStart'),
                  items: shown,
                  onAdd: (i) => app.add(i),
                  onDetails: app._openItem,
                  onList: () => setState(() => _swipe = false),
                  onRestart: () => setState(() => _deckStart++),
                  browse: app.browse,
                  full: app.fullCards,
                )
              : shown.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_rounded, size: 40, color: k.muted),
                      const SizedBox(height: 10),
                      Text(menu.items.isEmpty ? 'No dishes to show right now.' : 'No dishes match.', style: k.t(15, FontWeight.w500, color: k.muted)),
                      if (menu.items.isNotEmpty && (_vegOnly || _category != null)) ...[
                        const SizedBox(height: 14),
                        _Pill(
                          'Show every dish',
                          key: const ValueKey('menu-reset'),
                          filled: false,
                          onTap: () => setState(() {
                            _vegOnly = false;
                            _category = null;
                            _deckStart++;
                          }),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (rails && picks.isNotEmpty)
                      _Rail(key: const ValueKey('highlights-picks'), prefix: 'pick', title: title('picks_title', "Chef's picks"), items: picks, onOpen: app._openItem),
                    if (rails && limited.isNotEmpty)
                      _Rail(
                        key: const ValueKey('highlights-limited'),
                        prefix: 'limited',
                        title: title('limited_title', 'Limited today'),
                        until: h?.so('limited_until'),
                        items: limited,
                        onOpen: app._openItem,
                      ),
                    for (final (n, i) in shown.indexed) ...[
                      if (n > 0) const SizedBox(height: 10),
                      _ListRow(
                        item: i,
                        qty: app.qtyOf(i),
                        onAdd: () => app.add(i),
                        onRemove: () => app.remove(i),
                        onOpen: () => app._openItem(i),
                        browse: app.browse,
                      ),
                    ],
                  ],
                ),
        ),
        if (_swipe) cats,
        if (!app.browse && app._count > 0)
          _OrderBar(app: app)
        else if (app.browse && app.exp != null)
          Padding(
            key: const ValueKey('browse-scan-note'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_scanner_rounded, size: 18, color: k.muted),
                const SizedBox(width: 8),
                Flexible(child: Text('Scan the QR code on your table to order', style: k.t(13.5, FontWeight.w600, color: k.muted))),
              ],
            ),
          )
        else
          const SizedBox(height: 10),
      ],
    );
  }
}

/// "View order" at the foot of the menu: how many dishes and the estimated total.
class _OrderBar extends StatelessWidget {
  const _OrderBar({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Semantics(
        button: true,
        label: 'View order',
        child: Material(
          color: k.accent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            key: const ValueKey('cart-bar'),
            borderRadius: BorderRadius.circular(18),
            onTap: () => app.go(_Phase.order),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: k.onAccent, borderRadius: BorderRadius.circular(999)),
                    child: Text('${app._count}', style: k.t(14, FontWeight.w800, color: k.accent)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      app._count == 1 ? '1 dish · ${guestMoney(app._total)}' : '${app._count} dishes · ${guestMoney(app._total)}',
                      style: k.t(15, FontWeight.w700, color: k.onAccent),
                    ),
                  ),
                  Text('View order', style: k.t(15, FontWeight.w800, color: k.onAccent)),
                  Icon(Icons.arrow_forward_rounded, color: k.onAccent, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VegMark extends StatelessWidget {
  const _VegMark(this.veg);
  final bool veg;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: veg ? 'Vegetarian' : 'Non-vegetarian',
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: veg ? _veg : _nonVeg, width: 1.6),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: veg ? _veg : _nonVeg, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.icon, this.color, this.fill});
  final String text;
  final IconData? icon;

  /// The page's text and second card colour when not given.
  final Color? color;
  final Color? fill;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final color = this.color ?? k.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: fill ?? k.card2, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Text(text, style: k.t(12.5, FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

List<Widget> _tagsOf(GuestItem i) => [
  if (i.recommended) const _Tag('Bestseller', icon: Icons.star_rounded, color: _onAmber, fill: _amber),
  _Tag(i.veg ? 'Veg' : 'Non-veg', color: i.veg ? _veg : _nonVeg),
  for (final t in i.tags) _Tag(t),
];

/// The dish's photo, or its initial on the page's accent shades when it has none (never stock art).
class _Art extends StatelessWidget {
  const _Art({required this.item, this.radius = 18, this.label});
  final GuestItem item;
  final double radius;

  /// What the tile says when there is no photo (a category tile shows the category's letter, not its first dish's).
  final String? label;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final fallback = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [k.art.$1, k.art.$2]),
      ),
      alignment: Alignment.center,
      child: FractionallySizedBox(
        widthFactor: 0.4,
        heightFactor: 0.4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 88, maxHeight: 88),
          child: FittedBox(
            child: Text(label ?? (item.name.isEmpty ? '?' : item.name.characters.first.toUpperCase()), style: k.t(56, FontWeight.w900, color: k.dark ? k.accent : k.onAccent)),
          ),
        ),
      ),
    );
    if (item.imageUrl == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        item.imageUrl!,
        fit: BoxFit.cover,
        semanticLabel: item.name,
        errorBuilder: (_, _, _) => fallback,
        // the photo fades in over the dish's colours instead of popping in
        frameBuilder: (_, child, frame, sync) => sync
            ? child
            : Stack(
                fit: StackFit.expand,
                children: [
                  fallback,
                  AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 280), curve: Curves.easeOut, child: child),
                ],
              ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.item, required this.qty, required this.onAdd, required this.onRemove});
  final GuestItem item;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    if (qty == 0) {
      return Semantics(
        button: true,
        label: 'Add ${item.name}',
        child: Material(
          color: k.accent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: ValueKey('add-${item.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text('ADD', style: k.t(14, FontWeight.w800, color: k.onAccent)),
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: k.card2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: k.accent, width: 1.4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('minus-${item.id}'),
            tooltip: 'One less ${item.name}',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: Icon(Icons.remove_rounded, size: 18, color: k.ink),
          ),
          Text('$qty', key: ValueKey('qty-${item.id}'), style: k.t(15, FontWeight.w800)),
          IconButton(
            key: ValueKey('plus-${item.id}'),
            tooltip: 'One more ${item.name}',
            visualDensity: VisualDensity.compact,
            onPressed: qty >= 20 ? null : onAdd,
            icon: Icon(Icons.add_rounded, size: 18, color: k.ink),
          ),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.item, required this.qty, required this.onAdd, required this.onRemove, required this.onOpen, this.browse = false});
  final GuestItem item;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  final bool browse;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Material(
      color: k.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: ValueKey('row-${item.id}'),
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(width: 76, height: 76, child: _Art(item: item, radius: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _VegMark(item.veg),
                        const SizedBox(width: 6),
                        if (item.recommended) Text('Bestseller', style: k.t(12, FontWeight.w700, color: _amber)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(item.name, style: k.t(16, FontWeight.w700)),
                    if (item.description != null)
                      Text(
                        item.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: k.t(13, FontWeight.w400, color: k.muted),
                      ),
                    const SizedBox(height: 4),
                    Text(guestMoney(item.price), style: k.t(15, FontWeight.w800, color: k.accent)),
                  ],
                ),
              ),
              if (!browse) ...[const SizedBox(width: 8), _Stepper(item: item, qty: qty, onAdd: onAdd, onRemove: onRemove)],
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the restaurant's highlights ("Chef's picks", "Limited today" with the time it ends): its dishes side by side, each opening its
/// details.
class _Rail extends StatelessWidget {
  const _Rail({super.key, required this.prefix, required this.title, required this.items, required this.onOpen, this.until});
  final String prefix;
  final String title;
  final List<GuestItem> items;
  final ValueChanged<GuestItem> onOpen;

  /// "HH:MM" today, as the restaurant set it.
  final String? until;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
            child: Row(
              children: [
                Expanded(child: Text(title, style: k.t(18, FontWeight.w800))),
                if ((until ?? '').isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: _nonVeg.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                    child: Text('Ends at $until', key: const ValueKey('limited-until'), style: k.t(12.5, FontWeight.w700, color: _nonVeg)),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 196,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, n) {
                final i = items[n];
                return Semantics(
                  button: true,
                  label: i.name,
                  child: Material(
                    color: k.card,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      key: ValueKey('$prefix-${i.id}'),
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => onOpen(i),
                      child: SizedBox(
                        width: 150,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(height: 122, width: double.infinity, child: _Art(item: i, radius: 14)),
                              const SizedBox(height: 8),
                              Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(14.5, FontWeight.w700)),
                              Text(guestMoney(i.price), style: k.t(14, FontWeight.w800, color: k.accent)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Boards 4-5: one dish at a time. Right adds it, left skips it, up opens its details; the buttons underneath do the same, so the deck also
/// works without swiping (screen readers, a mouse). On the public menu link both directions just show the next dish.
class _Deck extends StatefulWidget {
  const _Deck({
    super.key,
    required this.items,
    required this.onAdd,
    required this.onDetails,
    required this.onList,
    required this.onRestart,
    this.browse = false,
    this.full = false,
  });
  final List<GuestItem> items;
  final ValueChanged<GuestItem> onAdd;
  final ValueChanged<GuestItem> onDetails;
  final VoidCallback onList;
  final VoidCallback onRestart;
  final bool browse;

  /// The restaurant's "full" card style: one dish at a time, edge to edge (otherwise the stack with the next card behind).
  final bool full;
  @override
  State<_Deck> createState() => _DeckState();
}

class _DeckState extends State<_Deck> {
  int _i = 0;
  Offset _drag = Offset.zero;
  static const _throw = 110.0;

  GuestItem? get _top => _i < widget.items.length ? widget.items[_i] : null;

  void _next({required bool added}) {
    final top = _top;
    if (top == null) return;
    if (added) widget.onAdd(top);
    setState(() {
      _i++;
      _drag = Offset.zero;
    });
  }

  void _end(DragEndDetails d) {
    final top = _top;
    if (top == null) return;
    if (_drag.dx > _throw) {
      _next(added: true);
    } else if (_drag.dx < -_throw) {
      _next(added: false);
    } else if (_drag.dy < -_throw) {
      setState(() => _drag = Offset.zero);
      widget.onDetails(top);
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final top = _top;
    if (top == null) {
      return Center(
        key: const ValueKey('deck-done'),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.items.isEmpty ? 'No dishes to show.' : "You've seen every dish", style: k.t(20, FontWeight.w800)),
              const SizedBox(height: 18),
              if (widget.items.isNotEmpty) _Pill('Start again', key: const ValueKey('deck-restart'), filled: false, onTap: widget.onRestart),
              const SizedBox(height: 10),
              _Pill('See the list', key: const ValueKey('deck-list'), onTap: widget.onList),
            ],
          ),
        ),
      );
    }
    final next = _i + 1 < widget.items.length ? widget.items[_i + 1] : null;
    final b = widget.browse;
    final full = widget.full;
    final hint = _drag.dx > 40
        ? (b ? 'NEXT' : 'ADD')
        : _drag.dx < -40
        ? (b ? 'NEXT' : 'SKIP')
        : _drag.dy < -40
        ? 'DETAILS'
        : null;
    final card = GestureDetector(
      key: const ValueKey('deck-card'),
      onPanUpdate: (d) => setState(() => _drag += d.delta),
      onPanEnd: _end,
      onTap: () => widget.onDetails(top),
      child: Transform.translate(
        offset: _drag,
        child: Transform.rotate(
          angle: _drag.dx / 900,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _DeckCard(item: top, top: true, full: full),
              if (hint != null)
                Positioned(
                  top: 24,
                  left: _drag.dx > 40 ? 24 : null,
                  right: _drag.dx < -40 ? 24 : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: k.bg.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: hint == 'SKIP' ? _nonVeg : k.accent, width: 2),
                    ),
                    child: Text(hint, style: k.t(18, FontWeight.w900, color: hint == 'SKIP' ? _nonVeg : k.accent)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final hintColor = full ? Colors.white.withValues(alpha: 0.85) : k.muted;
    final buttons = Padding(
      padding: full ? const EdgeInsets.fromLTRB(24, 0, 24, 18) : const EdgeInsets.fromLTRB(24, 6, 24, 8),
      child: Row(
        children: [
          if (!b)
            _Round(key: const ValueKey('deck-skip'), icon: Icons.close_rounded, label: 'Skip ${top.name}', color: _nonVeg, onTap: () => _next(added: false))
          else
            const SizedBox(width: 62),
          Expanded(
            child: Column(
              children: [
                IconButton(
                  key: const ValueKey('deck-info'),
                  tooltip: 'Details of ${top.name}',
                  onPressed: () => widget.onDetails(top),
                  icon: Icon(Icons.keyboard_arrow_up_rounded, color: hintColor, size: 28),
                ),
                Text(
                  b ? 'Swipe for the next dish' : 'Swipe right to add',
                  textAlign: TextAlign.center,
                  style: k.t(12.5, FontWeight.w600, color: hintColor),
                ),
              ],
            ),
          ),
          _Round(
            key: const ValueKey('deck-add'),
            icon: b ? Icons.arrow_forward_rounded : Icons.favorite_rounded,
            label: b ? 'Next dish' : 'Add ${top.name}',
            color: k.accent,
            filled: true,
            onTap: () => _next(added: !b),
          ),
        ],
      ),
    );
    // bakery board 15, "Fullscreen swipe mode": one dish edge to edge, the buttons on the photo
    if (full) {
      return Stack(
        key: const ValueKey('deck-full'),
        fit: StackFit.expand,
        children: [
          card,
          Positioned(left: 0, right: 0, bottom: 0, child: buttons),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (next != null)
                  Transform.translate(
                    offset: const Offset(16, -10),
                    child: Transform.rotate(
                      angle: 0.05,
                      child: Opacity(opacity: 0.55, child: _DeckCard(item: next)),
                    ),
                  ),
                card,
              ],
            ),
          ),
        ),
        buttons,
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({super.key, required this.icon, required this.label, required this.color, required this.onTap, this.filled = false});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: filled ? color : color.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 62, height: 62, child: Icon(icon, size: 30, color: filled ? k.onAccent : Colors.white)),
        ),
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.item, this.top = false, this.full = false});
  final GuestItem item;
  final bool top;
  final bool full;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Container(
      decoration: full
          ? BoxDecoration(color: k.card)
          : BoxDecoration(
              color: k.card,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: top ? k.accent.withValues(alpha: 0.55) : k.line, width: top ? 1.4 : 1),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))],
            ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Art(item: item, radius: 0),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
                stops: [0, 0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: full ? 116 : 20, // the full card's buttons sit on the photo
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, key: top ? const ValueKey('deck-name') : null, style: k.t(26, FontWeight.w800, color: k.onPhoto)),
                const SizedBox(height: 4),
                Text(guestMoney(item.price), style: k.t(22, FontWeight.w800, color: k.photoAccent)),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: _tagsOf(item)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Board 6 / bakery board 5, dish details (swipe up, or tap a dish): the photo edge to edge with the name and price on it, the tags, the
/// description, the time to prepare, then the quantity and Add. Pops with the quantity to add (null = closed).
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item, required this.inCart, this.browse = false});
  final GuestItem item;
  final int inCart;
  final bool browse;
  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  int _n = 1;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final i = widget.item;
    final room = 20 - widget.inCart;
    final screen = MediaQuery.sizeOf(context);
    final photo = math.min(420.0, screen.height * 0.46);
    return ConstrainedBox(
      key: const ValueKey('item-detail'),
      constraints: BoxConstraints(maxHeight: screen.height * 0.92),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: photo,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Art(item: i, radius: 0),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x59000000), Color(0x00000000), Color(0x00000000), Color(0xD9000000)],
                      stops: [0, 0.22, 0.55, 1],
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(4))),
                  ),
                ),
                Positioned(
                  top: 18,
                  left: 14,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: const CircleBorder(),
                    child: IconButton(
                      key: const ValueKey('detail-close'),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 18,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(i.name, key: const ValueKey('detail-name'), style: k.t(28, FontWeight.w800, color: k.onPhoto, height: 1.1)),
                      ),
                      const SizedBox(width: 12),
                      Text(guestMoney(i.price), style: k.t(24, FontWeight.w800, color: k.photoAccent)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _VegMark(i.veg),
                      ..._tagsOf(i),
                      if (i.prepMinutes > 0) _Tag('About ${i.prepMinutes} min', icon: Icons.schedule_rounded),
                    ],
                  ),
                  if (i.description != null) ...[const SizedBox(height: 12), Text(i.description!, style: k.t(15, FontWeight.w400, color: k.muted, height: 1.5))],
                ],
              ),
            ),
          ),
          if (!widget.browse)
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(color: k.card2, borderRadius: BorderRadius.circular(999)),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('detail-minus'),
                          tooltip: 'One less',
                          onPressed: _n > 1 ? () => setState(() => _n--) : null,
                          icon: Icon(Icons.remove_rounded, color: k.ink),
                        ),
                        Text('$_n', key: const ValueKey('detail-qty'), style: k.t(18, FontWeight.w800)),
                        IconButton(
                          key: const ValueKey('detail-plus'),
                          tooltip: 'One more',
                          onPressed: _n < room ? () => setState(() => _n++) : null,
                          icon: Icon(Icons.add_rounded, color: k.ink),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Pill(
                      room <= 0 ? '20 is the most' : 'Add · ${guestMoney(i.price * _n)}',
                      key: const ValueKey('detail-add'),
                      onTap: room <= 0 ? null : () => Navigator.of(context).pop(_n),
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox(height: 18),
        ],
      ),
    );
  }
}

/// Board 7, "Added to your order!": the dish, then View order or Keep exploring.
class _Added extends StatelessWidget {
  const _Added({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final item = app._justAdded!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (app.budget != null && app.ringOn)
            Center(
              child: _BudgetRing(spent: app._total, budget: app.budget!),
            ),
          const Spacer(),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: k.accent,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: k.accent.withValues(alpha: 0.4), blurRadius: 30)],
              ),
              child: Icon(Icons.check_rounded, size: 48, color: k.onAccent),
            ),
          ),
          const SizedBox(height: 18),
          Text('Added to your order!', key: const ValueKey('added-title'), textAlign: TextAlign.center, style: k.t(26, FontWeight.w800)),
          const SizedBox(height: 18),
          Center(
            child: Container(
              width: 220,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: k.card,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: k.line),
              ),
              child: Column(
                children: [
                  SizedBox(height: 140, child: _Art(item: item, radius: 16)),
                  const SizedBox(height: 10),
                  Text(item.name, textAlign: TextAlign.center, style: k.t(17, FontWeight.w800)),
                  Text('${app.qtyOf(item)} × ${guestMoney(item.price)}', style: k.t(15, FontWeight.w700, color: k.accent)),
                ],
              ),
            ),
          ),
          const Spacer(),
          _Pill('View order (${app._count})', key: const ValueKey('added-view-order'), onTap: () => app.go(_Phase.order)),
          const SizedBox(height: 10),
          _Pill('Keep exploring', key: const ValueKey('added-keep'), filled: false, onTap: () => app.go(_Phase.menu)),
        ],
      ),
    );
  }
}

/// Board 9, "View Order Anytime": every line with its quantity, the estimated total and the budget bar (a pre-order: its pickup time instead).
class _OrderView extends StatelessWidget {
  const _OrderView({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final budget = app.preorder ? null : app.budget;
    final total = app._total;
    final share = budget == null || budget <= 0 ? 0.0 : (total / budget).toDouble();
    return Column(
      key: const ValueKey('order-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(
          onBack: () => app.go(_Phase.menu),
          title: '${app.preorder ? 'Your pre-order' : 'Your order'} (${app._count} ${app._count == 1 ? 'dish' : 'dishes'})',
          action: app._cart.isEmpty
              ? null
              : TextButton(
                  key: const ValueKey('order-clear'),
                  onPressed: () {
                    app._cart.clear();
                    app.go(_Phase.menu);
                  },
                  child: Text('Clear all', style: k.t(14, FontWeight.w700, color: _nonVeg)),
                ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            children: [
              for (final l in app._cart)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    children: [
                      SizedBox(width: 54, height: 54, child: _Art(item: l.item, radius: 12)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.item.name, style: k.t(15, FontWeight.w700)),
                            Text(guestMoney(l.item.price), style: k.t(13, FontWeight.w500, color: k.muted)),
                          ],
                        ),
                      ),
                      _Stepper(item: l.item, qty: l.qty, onAdd: () => app.add(l.item), onRemove: () => app.remove(l.item)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 64,
                        child: Text(guestMoney(l.item.price * l.qty), textAlign: TextAlign.right, style: k.t(15, FontWeight.w800)),
                      ),
                    ],
                  ),
                ),
              if (app._cart.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text('Nothing added yet.', style: k.t(15, FontWeight.w400, color: k.muted)),
                  ),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            color: k.card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Estimated total', style: k.t(15, FontWeight.w600, color: k.muted)),
                  ),
                  Text(guestMoney(total), key: const ValueKey('order-total'), style: k.t(22, FontWeight.w800)),
                ],
              ),
              if (budget != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('${guestMoney(total)} / ${guestMoney(budget)}', style: k.t(14, FontWeight.w700)),
                    const Spacer(),
                    Text('${(share * 100).round()}% used', style: k.t(13, FontWeight.w600, color: share > 1 ? _nonVeg : k.muted)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: share.clamp(0, 1), minHeight: 8, backgroundColor: k.line, color: share > 1 ? _nonVeg : k.accent),
                ),
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('budget-note'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: (share > 1 ? _nonVeg : k.accent).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                  child: Row(
                    children: [
                      Icon(share > 1 ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: share > 1 ? _nonVeg : k.accent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          share > 1
                              ? 'Over your budget by ${guestMoney(total - budget)}'
                              : "You're well within your budget! ${guestMoney(budget - total)} remaining",
                          style: k.t(13.5, FontWeight.w600, color: share > 1 ? _nonVeg : k.accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text('Taxes and charges are added on the bill.', style: k.t(12.5, FontWeight.w400, color: k.muted)),
              const SizedBox(height: 14),
              _Pill(
                'Continue to review',
                key: const ValueKey('order-continue'),
                trailing: Icons.arrow_forward_rounded,
                onTap: app._cart.isEmpty ? null : () => app.go(app.preorder ? _Phase.preReview : _Phase.review),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A text field of the review screens, in the page's colours.
InputDecoration _field(_Look k, String label, {String? hint}) => InputDecoration(
  labelText: label,
  labelStyle: k.t(14, FontWeight.w500, color: k.muted),
  hintText: hint,
  hintStyle: k.t(14, FontWeight.w400, color: k.muted.withValues(alpha: 0.7)),
  counterText: '',
  filled: true,
  fillColor: k.card,
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: k.line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: k.line),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: k.accent),
  ),
);

/// Boards 10-11, "Review & Add Notes" and the table: a name for the staff, a note for the kitchen, then send.
class _Review extends StatefulWidget {
  const _Review({required this.app});
  final _GuestAppState app;
  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  final _note = TextEditingController();
  final _name = TextEditingController();
  String _key = GuestGateway.newKey(); // one tap = one key; a retry after a failure sends the same key
  String? _sig;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final app = widget.app;
    // a changed order is a new tap with a new key; the same order retried keeps its key
    final sig = '${app._cart.map((l) => '${l.item.id}x${l.qty}').join(',')}|${_note.text.trim()}|${_name.text.trim()}|${app.couponCode ?? ''}';
    if (_sig != null && _sig != sig) _key = GuestGateway.newKey();
    _sig = sig;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (app.viaCustomer) {
        // contract A: the table is named by this visit's QR session, never by a label; the budget stays on this phone
        await app.placeWeb(
          WebOrderRequest(
            storeLink: app.slug,
            mode: 'dine_in',
            tableSession: app._visit?.session,
            lines: List.of(app._cart),
            guestName: _name.text,
            note: _note.text,
            couponCode: app.couponCode,
          ),
          _key,
        );
      } else {
        final r = await app.g.send(List.of(app._cart), guestName: _name.text, note: _note.text, key: _key);
        if (mounted) app._sent(r);
      }
    } catch (e) {
      if (!mounted) return;
      if (e is GuestApiException && e.sessionEnded) {
        app._fail(e);
        return;
      }
      setState(() {
        _busy = false;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final app = widget.app;
    return Column(
      key: const ValueKey('order-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(_Phase.order), title: 'Review your order'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
            children: [
              for (final l in app._cart)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      SizedBox(width: 44, height: 44, child: _Art(item: l.item, radius: 10)),
                      const SizedBox(width: 12),
                      Expanded(child: Text('${l.item.name}  × ${l.qty}', style: k.t(15, FontWeight.w600))),
                      Text(guestMoney(l.item.price * l.qty), style: k.t(15, FontWeight.w700)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    Icon(Icons.table_restaurant_rounded, color: k.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Dine in · ${app._menu!.tableWord} ${app._visit!.tableLabel}', style: k.t(15, FontWeight.w700))),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (app.g.waitsForStaff) ...[
                TextField(
                  key: const ValueKey('order-name'),
                  controller: _name,
                  maxLength: 40,
                  style: k.t(15, FontWeight.w500),
                  decoration: _field(k, 'Your first name (optional)'),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                key: const ValueKey('order-note'),
                controller: _note,
                maxLength: 300,
                maxLines: 3,
                minLines: 2,
                style: k.t(15, FontWeight.w500),
                decoration: _field(k, 'Special instructions (optional), e.g. less spicy'),
              ),
              if (app.offers.isNotEmpty) ...[const SizedBox(height: 14), _OffersList(app: app)],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Totals(app: app),
              Text('Pay at the table when you are done.', style: k.t(12.5, FontWeight.w400, color: k.muted)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    key: const ValueKey('order-error'),
                    style: k.t(14, FontWeight.w600, color: _nonVeg),
                  ),
                ),
              const SizedBox(height: 14),
              _Pill(
                app.g.waitsForStaff ? 'Send to the restaurant' : 'Send to the kitchen',
                key: const ValueKey('send-order'),
                busy: _busy,
                trailing: Icons.arrow_forward_rounded,
                onTap: app._cart.isEmpty ? null : _send,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Board 12-13, "Order Placed" and tracking: on the web page, each order of this visit and what the staff did with it (checked every few
/// seconds); with Hand to guest, the order number and "Back to staff".
class _SentView extends StatefulWidget {
  const _SentView({required this.app});
  final _GuestAppState app;
  @override
  State<_SentView> createState() => _SentViewState();
}

class _SentViewState extends State<_SentView> {
  _GuestAppState get app => widget.app;
  bool _ready = false; // the tap that sent the order must not also press "Order more", which sits in the same place
  Timer? _wake;

  @override
  void initState() {
    super.initState();
    app._refreshStatus(); // coming back to this page shows where the orders are now
    _wake = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _wake?.cancel();
    super.dispose();
  }

  (String, Color, IconData) _status(_Look k, Facts r) => switch (r.s('status')) {
    'waiting' => ('Waiting for the staff to confirm', k.waiting, Icons.hourglass_top_rounded),
    'accepted' => (
      '${r.m('order').s('display_no')} · ${switch (GuestTrack.of(r)?.stage) {
        'confirmed' => 'Confirmed',
        'in_kitchen' => 'Being prepared',
        'ready' => 'Ready to serve',
        'served' => 'Served',
        _ => r.m('order').s('status_label'),
      }}',
      k.accent,
      Icons.restaurant_rounded,
    ),
    'declined' => ('Not accepted${r.so('decline_reason') == null ? '' : ': ${r.s('decline_reason')}'}', _nonVeg, Icons.cancel_rounded),
    _ => (r.s('status'), k.muted, Icons.info_outline_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final last = app._last;
    final staff = !app.g.waitsForStaff;
    final displayNo = last?.m('order').so('display_no');
    final accepted = app._requests.where((r) => r.s('status') == 'accepted').toList();
    final served = accepted.isNotEmpty && !app._requests.any((r) => r.s('status') == 'waiting') && accepted.every((r) => GuestTrack.of(r)?.stage == 'served');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: k.accent,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: k.accent.withValues(alpha: 0.45), blurRadius: 34)],
              ),
              child: Icon(Icons.check_rounded, size: 52, color: k.onAccent),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            served ? 'Your order is served!' : (staff ? 'Sent to the kitchen' : 'Sent to the restaurant'),
            key: const ValueKey('sent-title'),
            textAlign: TextAlign.center,
            style: k.t(28, FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            served
                ? 'Hope you enjoy your meal.'
                : staff
                ? (displayNo == null ? 'The kitchen has your order.' : 'Order $displayNo is with the kitchen.')
                : accepted.isEmpty
                ? '${app._menu!.tableWord} ${app._visit!.tableLabel} · A member of staff will confirm it in a moment.'
                : '${app._menu!.tableWord} ${app._visit!.tableLabel} · We will keep this page up to date.',
            textAlign: TextAlign.center,
            style: k.t(15, FontWeight.w400, color: k.muted, height: 1.4),
          ),
          const SizedBox(height: 18),
          if (!staff)
            Expanded(
              child: ListView(
                children: [
                  for (final r in app._requests)
                    Container(
                      key: ValueKey('request-${r.s('id')}'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: k.card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: k.line),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_status(k, r).$3, color: _status(k, r).$2, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_status(k, r).$1, style: k.t(15, FontWeight.w700, color: _status(k, r).$2)),
                                const SizedBox(height: 4),
                                Text(
                                  r.l('lines').map((l) => '${l.n('qty').toInt()} × ${l.s('name')}').join(', '),
                                  style: k.t(13.5, FontWeight.w400, color: k.muted),
                                ),
                                if (GuestTrack.of(r) case final track?) _Timeline(track: track, showEta: app.showEta),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          else
            const Spacer(),
          if (!staff && accepted.isNotEmpty) ...[
            _Pill('View bill', key: const ValueKey('view-bill'), filled: !served ? false : true, onTap: _ready ? () => app.go(_Phase.bill) : null),
            const SizedBox(height: 10),
          ],
          _Pill('Order more', key: const ValueKey('order-more'), filled: !served, onTap: _ready ? () => app.go(_Phase.menu) : null),
          if (app.widget.onExit != null) ...[
            const SizedBox(height: 10),
            _Pill('Back to staff', key: const ValueKey('guest-exit'), filled: false, onTap: app.widget.onExit),
          ],
        ],
      ),
    );
  }
}

/// Board 13, live tracking: Order confirmed, In the kitchen, Ready, Served, with the time each happened and the minutes left while cooking
/// (unless the restaurant's tracking block hides the estimate).
class _Timeline extends StatelessWidget {
  const _Timeline({required this.track, this.showEta = true});
  final GuestTrack track;
  final bool showEta;
  static const _labels = {'confirmed': 'Order confirmed', 'in_kitchen': 'In the kitchen', 'ready': 'Ready', 'served': 'Served'};
  static const _icons = {
    'confirmed': Icons.check_rounded,
    'in_kitchen': Icons.soup_kitchen_rounded,
    'ready': Icons.room_service_rounded,
    'served': Icons.restaurant_rounded,
  };
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    if (track.stage == 'cancelled') {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('This order was cancelled.', style: k.t(13.5, FontWeight.w600, color: _nonVeg)),
      );
    }
    final current = track.steps.lastIndexWhere((x) => x.done);
    return Padding(
      key: const ValueKey('track'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showEta && track.minutesLeft != null)
            Container(
              key: const ValueKey('track-eta'),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timer_outlined, size: 18, color: k.accent),
                  const SizedBox(width: 6),
                  Text(
                    track.minutesLeft == 0 ? 'Almost ready' : 'Estimated serving time: about ${track.minutesLeft} min',
                    style: k.t(13.5, FontWeight.w700, color: k.accent),
                  ),
                ],
              ),
            ),
          for (final (n, step) in track.steps.indexed)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(color: step.done ? (n == current ? k.accent : k.accent.withValues(alpha: 0.25)) : k.card2, shape: BoxShape.circle),
                      child: Icon(_icons[step.key] ?? Icons.circle, size: 15, color: step.done ? (n == current ? k.onAccent : k.accent) : k.muted),
                    ),
                    if (n < track.steps.length - 1) Container(width: 2, height: 18, color: step.done ? k.accent.withValues(alpha: 0.4) : k.line),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _labels[step.key] ?? step.key,
                            style: k.t(14, n == current ? FontWeight.w800 : FontWeight.w500, color: step.done ? k.ink : k.muted),
                          ),
                        ),
                        if (step.done && step.at != null) Text(_clock(step.at!), style: k.t(12.5, FontWeight.w500, color: k.muted)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Board 16, "Final Bill (with Budget)" and feedback: the table's dishes and money, how it compares with the budget, the split per person
/// (when the restaurant's bill block offers it), "pay at the table", and how the visit was (one feedback per visit; choosing again changes
/// it; hidden when the bill block switches feedback off).
class _BillView extends StatefulWidget {
  const _BillView({required this.app});
  final _GuestAppState app;
  @override
  State<_BillView> createState() => _BillViewState();
}

class _BillViewState extends State<_BillView> {
  GuestBill? _bill;
  String? _error;
  int? _rating;
  final _comment = TextEditingController();
  bool _sending = false;
  bool _thanked = false;
  bool _askedForBill = false;
  static const _faces = [
    (5, Icons.sentiment_very_satisfied_rounded, 'Loved it'),
    (4, Icons.sentiment_satisfied_rounded, 'Good'),
    (3, Icons.sentiment_neutral_rounded, 'Okay'),
    (2, Icons.sentiment_dissatisfied_rounded, 'Could be better'),
  ];

  /// A web order's bill (contract A): it comes with the order's status, which keeps being asked for until it is paid.
  WebOrder? get _web => widget.app.viaCustomer ? widget.app.shownOrder : null;

  @override
  void initState() {
    super.initState();
    if (_web == null) _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final b = await widget.app.g.bill();
      if (mounted) {
        setState(() {
          _bill = b;
          _rating ??= b?.rating;
          _thanked = b?.rating != null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is GuestApiException ? e.message : 'Could not load the bill. Please try again.');
    }
  }

  Future<void> _send() async {
    final r = _rating;
    if (r == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.app.g.feedback(r, comment: _comment.text);
      if (mounted) {
        setState(() {
          _sending = false;
          _thanked = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e is GuestApiException ? e.message : 'Could not send. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final app = widget.app;
    final web = _web;
    final b = web != null ? web.bill : _bill;
    final budget = app.budget;
    final paid = web?.stage == 'paid' || (b != null && b.total > 0 && b.paid >= b.total);
    final where = web == null
        ? '${app._menu!.tableWord} ${app._visit!.tableLabel}'
        : [
            web.pickup || app._webPickup[app._shown] != null
                ? 'Pickup${(app._webPickup[app._shown] ?? web.pickupAt) == null ? '' : ' ${_pickupLabel((app._webPickup[app._shown] ?? web.pickupAt)!, app.slots?.timezone)}'}'
                : '${app._menu?.tableWord ?? 'Table'} ${web.tableLabel ?? app._visit?.tableLabel ?? ''}'.trim(),
            if (web.displayNo.isNotEmpty) 'Order #${web.displayNo}',
          ].join(' · ');
    Widget money(String label, num v, {bool big = false, Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: k.t(big ? 17 : 14.5, big ? FontWeight.w800 : FontWeight.w500, color: big ? k.ink : k.muted)),
          ),
          Text(v < 0 ? '−${guestMoney(-v)}' : guestMoney(v), key: key, style: k.t(big ? 22 : 14.5, FontWeight.w800)),
        ],
      ),
    );
    return Column(
      key: const ValueKey('bill-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(web != null ? _Phase.live : _Phase.sent), title: 'Your bill'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            children: [
              Text(where, key: const ValueKey('bill-where'), style: k.t(14, FontWeight.w600, color: k.muted)),
              const SizedBox(height: 10),
              if (b == null && _error == null && web == null)
                Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator(color: k.accent)),
                ),
              if (b == null && web != null)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text('The restaurant is making your bill. It shows here in a moment.', textAlign: TextAlign.center, style: k.t(15, FontWeight.w500, color: k.muted)),
                ),
              if (_error != null) ...[
                Text(
                  _error!,
                  key: const ValueKey('bill-error'),
                  style: k.t(14, FontWeight.w600, color: _nonVeg),
                ),
                if (b == null) ...[const SizedBox(height: 12), _Pill('Try again', key: const ValueKey('bill-retry'), filled: false, onTap: _load)],
              ],
              if (b != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(20)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (b.lines.isEmpty) Text('Nothing on the bill yet.', style: k.t(14.5, FontWeight.w500, color: k.muted)),
                      for (final l in b.lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(child: Text(l.name, style: k.t(15, FontWeight.w600))),
                              SizedBox(
                                width: 32,
                                child: Text(
                                  '${l.qty}',
                                  textAlign: TextAlign.center,
                                  style: k.t(14.5, FontWeight.w600, color: k.muted),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Text(guestMoney(l.total), textAlign: TextAlign.right, style: k.t(15, FontWeight.w700)),
                              ),
                            ],
                          ),
                        ),
                      Divider(color: k.line, height: 24),
                      money('Subtotal', b.subtotal),
                      if (b.discount > 0) money('Discount', -b.discount),
                if (b.gst > 0) money('GST', b.gst),
                if (b.serviceCharge > 0) money('Service charge', b.serviceCharge),
                if (b.roundOff != 0) money('Round off', b.roundOff),
                      const SizedBox(height: 4),
                      money('Total', b.total, big: true, key: const ValueKey('bill-total')),
                      if (b.paid > 0) money('Paid', b.paid),
                      if (b.paid > 0) money('Still to pay', b.due),
                    ],
                  ),
                ),
                if (budget != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('bill-budget'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: (b.total > budget ? _nonVeg : k.accent).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      children: [
                        Icon(b.total > budget ? Icons.warning_amber_rounded : Icons.check_circle_rounded, color: b.total > budget ? _nonVeg : k.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            b.total > budget
                                ? '${guestMoney(b.total)} of ${guestMoney(budget)}: ${guestMoney(b.total - budget)} over your budget.'
                                : 'Great! You stayed within your budget: ${guestMoney(b.total)} of ${guestMoney(budget)}.',
                            style: k.t(14, FontWeight.w600, color: b.total > budget ? _nonVeg : k.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (app.billSplit && b.total > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('bill-split'),
                    padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                    decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: k.line)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Split the bill', style: k.t(15, FontWeight.w700)),
                              Text(
                                '${guestMoney(((b.paid > 0 ? b.due : b.total) / app.people * 100).ceil() / 100)} each for ${app.people}',
                                key: const ValueKey('bill-split-each'),
                                style: k.t(13.5, FontWeight.w600, color: k.accent),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('bill-split-minus'),
                          tooltip: 'One person fewer',
                          onPressed: app.people > 1 ? () => setState(() => app.people--) : null,
                          icon: Icon(Icons.remove_rounded, color: k.ink),
                        ),
                        Text('${app.people}', style: k.t(18, FontWeight.w800)),
                        IconButton(
                          key: const ValueKey('bill-split-plus'),
                          tooltip: 'One more person',
                          onPressed: app.people < 30 ? () => setState(() => app.people++) : null,
                          icon: Icon(Icons.add_rounded, color: k.ink),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (paid)
                  Container(
                    key: const ValueKey('bill-paid'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      children: [
                        Icon(Icons.verified_rounded, color: k.accent),
                        const SizedBox(width: 10),
                        Expanded(child: Text('Paid. Thank you!', style: k.t(15, FontWeight.w800, color: k.accent))),
                      ],
                    ),
                  )
                else ...[
                  _Pill(
                    _askedForBill ? 'The staff will bring your bill' : (web?.pickup == true ? 'Pay when you collect' : 'Pay at the table'),
                    key: const ValueKey('bill-pay'),
                    filled: !_askedForBill,
                    onTap: _askedForBill ? null : () => setState(() => _askedForBill = true),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    web?.pickup == true
                        ? 'Paying from your phone is coming soon. For now you pay when you collect your order.'
                        : 'Paying from your phone is coming soon. For now a member of staff takes the payment at your table.',
                    textAlign: TextAlign.center,
                    style: k.t(12.5, FontWeight.w400, color: k.muted),
                  ),
                ],
                // feedback goes with the table's visit (its QR session); a pickup from the brand page has none
                if (app.billFeedback && !app.card) ...[
                  const SizedBox(height: 22),
                  Text('How was your experience?', style: k.t(18, FontWeight.w800)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final (v, face, label) in _faces)
                        Semantics(
                          button: true,
                          selected: _rating == v,
                          label: label,
                          child: InkWell(
                            key: ValueKey('rate-$v'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => setState(() {
                              _rating = v;
                              _thanked = false;
                            }),
                            child: Container(
                              width: 76,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _rating == v ? k.accent.withValues(alpha: 0.18) : k.card,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _rating == v ? k.accent : k.line),
                              ),
                              child: Column(
                                children: [
                                  Icon(face, size: 32, color: _rating == v ? k.accent : _amber),
                                  const SizedBox(height: 4),
                                  Text(
                                    label,
                                    textAlign: TextAlign.center,
                                    style: k.t(11.5, FontWeight.w600, color: _rating == v ? k.accent : k.muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_thanked)
                    Container(
                      key: const ValueKey('feedback-thanks'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: k.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                      child: Text('Thank you! The restaurant reads every message.', style: k.t(14, FontWeight.w700, color: k.accent)),
                    )
                  else if (_rating != null) ...[
                    TextField(
                      key: const ValueKey('feedback-comment'),
                      controller: _comment,
                      maxLength: 500,
                      maxLines: 3,
                      minLines: 1,
                      style: k.t(15, FontWeight.w500),
                      decoration: InputDecoration(
                        hintText: 'Anything to tell the restaurant? (optional)',
                        hintStyle: k.t(14, FontWeight.w400, color: k.muted),
                        counterText: '',
                        filled: true,
                        fillColor: k.card,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: k.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: k.line),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _Pill('Send feedback', key: const ValueKey('feedback-send'), busy: _sending, onTap: _send),
                  ],
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---- the pre-order (brand page, bakery boards 11-13)

/// Bakery board 11, "Pre-order": the days that still have a pickup time and that day's times, as the restaurant offers them (its hours, slot
/// length and notice, `gx_preorder_slots`). Asked again each time the screen opens, so a time that has passed is not offered; a time picked
/// before stays picked while it is still offered.
class _SlotPicker extends StatefulWidget {
  const _SlotPicker({required this.app});
  final _GuestAppState app;
  @override
  State<_SlotPicker> createState() => _SlotPickerState();
}

class _SlotPickerState extends State<_SlotPicker> {
  _GuestAppState get app => widget.app;
  String? _day;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await app.widget.preorders!.slots();
      if (!mounted) return;
      setState(() {
        app.slots = s;
        if (!s.days.any((d) => d.slots.contains(app.pickupAt))) app.pickupAt = null;
        _day = s.days.where((d) => d.slots.contains(app.pickupAt)).firstOrNull?.date ?? s.days.firstOrNull?.date;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is GuestApiException ? e.message : 'Could not load the pickup times. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final s = app.slots;
    final day = s?.days.where((d) => d.date == _day).firstOrNull;
    Widget chip({required Key key, required bool on, required VoidCallback onTap, required Widget child, double radius = 14}) => Material(
      color: on ? k.accent : k.card,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: Border.all(color: on ? k.accent : k.line)),
          child: child,
        ),
      ),
    );
    return Column(
      key: const ValueKey('pre-slots'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: app.previous == null ? null : app.back),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 2),
          child: Text('Pre-order', style: k.t(30, FontWeight.w800)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
          child: Text('Select date & time', style: k.t(15, FontWeight.w500, color: k.muted)),
        ),
        if (_loading)
          Expanded(child: Center(child: CircularProgressIndicator(color: k.accent)))
        else if (_error != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, key: const ValueKey('pre-slots-error'), textAlign: TextAlign.center, style: k.t(15, FontWeight.w600, color: _nonVeg)),
                    const SizedBox(height: 16),
                    _Pill('Try again', key: const ValueKey('pre-slots-retry'), filled: false, onTap: _load),
                  ],
                ),
              ),
            ),
          )
        else if (s == null || s.days.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  'No pickup times are open right now. Please check again later.',
                  key: const ValueKey('pre-no-slots'),
                  textAlign: TextAlign.center,
                  style: k.t(15, FontWeight.w500, color: k.muted, height: 1.4),
                ),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: s.days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, n) {
                final d = s.days[n];
                final date = DateTime.parse(d.date);
                final on = d.date == _day;
                return SizedBox(
                  width: 58,
                  child: Semantics(
                    button: true,
                    selected: on,
                    label: '${_weekdays[date.weekday - 1]} ${date.day} ${_months[date.month - 1]}',
                    child: chip(
                      key: ValueKey('pre-day-${d.date}'),
                      on: on,
                      radius: 16,
                      onTap: () => setState(() => _day = d.date),
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_weekdays[date.weekday - 1], style: k.t(12.5, FontWeight.w600, color: on ? k.onAccent : k.muted)),
                            const SizedBox(height: 2),
                            Text('${date.day}', style: k.t(20, FontWeight.w800, color: on ? k.onAccent : k.ink)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
            child: Text('Select a time slot', style: k.t(16, FontWeight.w700)),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.3,
              children: [
                for (final raw in day?.slots ?? const <String>[])
                  Semantics(
                    button: true,
                    selected: raw == app.pickupAt,
                    child: chip(
                      key: ValueKey('pre-slot-$raw'),
                      on: raw == app.pickupAt,
                      onTap: () => setState(() => app.pickupAt = raw),
                      child: Text(
                        _clock(guestWallTime(raw, s.timezone)),
                        style: k.t(14, FontWeight.w700, color: raw == app.pickupAt ? k.onAccent : k.ink),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (app.pickupAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
              child: Text(
                'Pickup ${_pickupLabel(app.pickupAt!, s.timezone)}',
                key: const ValueKey('pre-slot-picked'),
                textAlign: TextAlign.center,
                style: k.t(14, FontWeight.w600, color: k.muted),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
            child: _Pill(
              app.pickupAt == null ? 'Pick a time' : 'Continue',
              key: const ValueKey('pre-slot-continue'),
              trailing: Icons.arrow_forward_rounded,
              onTap: app.pickupAt == null ? null : app.next,
            ),
          ),
        ],
      ],
    );
  }
}

/// Bakery board 12, the pre-order's details: the pickup time (change it here), the dishes, a name and a 10-digit mobile number so the
/// restaurant can call, special instructions (with the restaurant's own hint), then send. The restaurant confirms it; nothing is paid here.
class _PreReview extends StatefulWidget {
  const _PreReview({required this.app});
  final _GuestAppState app;
  @override
  State<_PreReview> createState() => _PreReviewState();
}

class _PreReviewState extends State<_PreReview> {
  _GuestAppState get app => widget.app;
  late final _name = TextEditingController(text: app.preName);
  late final _phone = TextEditingController(text: app.prePhone);
  late final _note = TextEditingController(text: app.preNote);
  String _key = GuestGateway.newKey(); // one tap = one key; a retry after a failure sends the same key
  String? _sig;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    // kept for a second pre-order, or a trip to change the pickup time
    app
      ..preName = _name.text
      ..prePhone = _phone.text
      ..preNote = _note.text;
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Ten digits, without +91, spaces or dashes; null when it is not an Indian mobile number (the server checks it again).
  static String? _mobile(String v) {
    var d = v.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
    return RegExp(r'^[6-9][0-9]{9}$').hasMatch(d) ? d : null;
  }

  Future<void> _send() async {
    final phone = _mobile(_phone.text);
    final problem = _name.text.trim().isEmpty
        ? 'Enter your name so the restaurant knows whose order it is.'
        : phone == null
        ? 'Enter a 10-digit mobile number.'
        : app.pickupAt == null
        ? 'Pick a pickup time.'
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    // a changed pre-order is a new tap with a new key; the same one retried keeps its key
    final sig = '${app._cart.map((l) => '${l.item.id}x${l.qty}').join(',')}|${_name.text.trim()}|$phone|${app.pickupAt}|${_note.text.trim()}|${app.couponCode ?? ''}';
    if (_sig != null && _sig != sig) _key = GuestGateway.newKey();
    _sig = sig;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (app.viaCustomer) {
        await app.placeWeb(
          WebOrderRequest(
            storeLink: app.slug,
            mode: 'pickup',
            pickupAt: app.pickupAt,
            lines: List.of(app._cart),
            guestName: _name.text,
            phone: phone,
            note: _note.text,
            couponCode: app.couponCode,
          ),
          _key,
        );
      } else {
        final r = await app.widget.preorders!.place(List.of(app._cart), name: _name.text, phone: phone!, pickupAt: app.pickupAt!, note: _note.text, key: _key);
        if (mounted) app._preSent(r);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is GuestApiException ? e.message : 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    return Column(
      key: const ValueKey('pre-review'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(onBack: () => app.go(_Phase.order), title: 'Review your pre-order'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    Icon(Icons.schedule_rounded, color: k.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Pickup', style: k.t(13, FontWeight.w500, color: k.muted)),
                          Text(
                            app.pickupAt == null ? 'Pick a time' : _pickupLabel(app.pickupAt!, app.slots?.timezone),
                            key: const ValueKey('pre-review-pickup'),
                            style: k.t(15, FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('pre-change-slot'),
                      onPressed: () => app.go(_Phase.slot),
                      child: Text('Change', style: k.t(14, FontWeight.w700, color: k.accent)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              for (final l in app._cart)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      SizedBox(width: 44, height: 44, child: _Art(item: l.item, radius: 10)),
                      const SizedBox(width: 12),
                      Expanded(child: Text('${l.item.name}  × ${l.qty}', style: k.t(15, FontWeight.w600))),
                      Text(guestMoney(l.item.price * l.qty), style: k.t(15, FontWeight.w700)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('pre-name'),
                controller: _name,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                style: k.t(15, FontWeight.w500),
                decoration: _field(k, 'Your name'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('pre-phone'),
                controller: _phone,
                maxLength: 16, // room for "+91 98765 43210"
                keyboardType: TextInputType.phone,
                style: k.t(15, FontWeight.w500),
                decoration: _field(k, 'Mobile number (10 digits)'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('pre-note'),
                controller: _note,
                maxLength: 300,
                maxLines: 3,
                minLines: 2,
                style: k.t(15, FontWeight.w500),
                decoration: _field(k, 'Special instructions (optional)', hint: app.slots?.noteHint),
              ),
              if (app.offers.isNotEmpty) ...[const SizedBox(height: 14), _OffersList(app: app)],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Totals(app: app),
              Text('Pay when you pick it up.', style: k.t(12.5, FontWeight.w400, color: k.muted)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, key: const ValueKey('pre-error'), style: k.t(14, FontWeight.w600, color: _nonVeg)),
                ),
              const SizedBox(height: 14),
              _Pill(
                'Send pre-order',
                key: const ValueKey('pre-send'),
                busy: _busy,
                trailing: Icons.arrow_forward_rounded,
                onTap: app._cart.isEmpty ? null : _send,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Bakery board 13, "Pre-order sent" and its tracking (checked every few seconds): the pickup time, the dishes and the estimated total, and
/// what the restaurant did with it: waiting, accepted (its order, then the kitchen steps), or declined with the reason. The page address
/// carries the tracking link, so a reload or a shared link comes back here.
class _PreSent extends StatelessWidget {
  const _PreSent({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final r = app._pre!;
    final order = r.mo('order');
    final track = GuestTrack.of(r);
    final declined = r.s('status') == 'declined';
    final (title, line, color) = switch (r.s('status')) {
      'accepted' => ('Pre-order confirmed', [order?.so('display_no'), order?.so('status_label') ?? 'Confirmed'].nonNulls.join(' · '), k.accent),
      'declined' => ('Pre-order not accepted', r.so('decline_reason') ?? 'The restaurant could not take this pre-order.', _nonVeg),
      _ => ('Pre-order sent', 'Waiting for the restaurant to confirm', k.waiting),
    };
    final business = r.so('business') ?? app._menu?.brandName ?? '';
    return Padding(
      key: const ValueKey('pre-sent'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: declined ? _nonVeg : k.accent,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: (declined ? _nonVeg : k.accent).withValues(alpha: 0.4), blurRadius: 34)],
              ),
              child: Icon(declined ? Icons.close_rounded : Icons.check_rounded, size: 52, color: declined ? Colors.white : k.onAccent),
            ),
          ),
          const SizedBox(height: 16),
          Text(title, key: const ValueKey('pre-sent-title'), textAlign: TextAlign.center, style: k.t(28, FontWeight.w800)),
          if (business.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(business, textAlign: TextAlign.center, style: k.t(15, FontWeight.w500, color: k.muted)),
          ],
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(18), border: Border.all(color: k.line)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (r.so('pickup_at') != null)
                        Row(
                          children: [
                            Icon(Icons.schedule_rounded, size: 20, color: k.accent),
                            const SizedBox(width: 8),
                            Text('Pickup', style: k.t(14, FontWeight.w500, color: k.muted)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _pickupLabel(r.s('pickup_at'), app.slots?.timezone),
                                key: const ValueKey('pre-sent-pickup'),
                                textAlign: TextAlign.right,
                                style: k.t(15, FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      Divider(color: k.line, height: 22),
                      for (final l in r.l('lines'))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text('${l.n('qty').toInt()} × ${l.s('name')}', style: k.t(14.5, FontWeight.w500)),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: Text('Estimated total', style: k.t(14.5, FontWeight.w600, color: k.muted))),
                          Text(guestMoney(r.n('estimated_total')), key: const ValueKey('pre-sent-total'), style: k.t(18, FontWeight.w800)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line, key: const ValueKey('pre-status'), style: k.t(15, FontWeight.w700, color: color)),
                      if (track != null) _Timeline(track: track, showEta: app.showEta),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  r.so('message') ?? (app._track == null ? '' : 'Keep this page open or bookmark it: its link shows this pre-order any time.'),
                  textAlign: TextAlign.center,
                  style: k.t(13, FontWeight.w400, color: k.muted, height: 1.4),
                ),
              ],
            ),
          ),
          if (app._menu != null)
            _Pill(
              'Back to the menu',
              key: const ValueKey('pre-again'),
              filled: false,
              onTap: () => app.go(app.preorder ? _Phase.menu : app.steps.first),
            ),
        ],
      ),
    );
  }
}

// ---- Live mode (contract B): a toast per new order of another table, and a banner when a dish or category trends

const _fire = Color(0xFFFF6B2C);

/// The top of the page while Live mode is on: one small toast at a time ("1 Butter Chicken ordered on Table 10") and the trending banner
/// ("3 tables ordered Cold Coffee"). It never takes a tap: everything underneath keeps working.
class _LiveOverlay extends StatelessWidget {
  const _LiveOverlay({required this.toast, required this.streak});
  final String? toast;
  final String? streak;

  static Widget _drop(Widget child, Animation<double> a) => FadeTransition(
    opacity: a,
    child: SlideTransition(position: Tween(begin: const Offset(0, -0.6), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    Widget pill({required Key key, required String text, required Widget lead, required Color fill, required Color ink, Gradient? gradient}) => Semantics(
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Center(
          child: Container(
            key: key,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(8, 7, 14, 7),
            decoration: BoxDecoration(
              color: fill,
              gradient: gradient,
              borderRadius: BorderRadius.circular(999),
              border: gradient == null ? Border.all(color: k.line) : null,
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 6))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                lead,
                const SizedBox(width: 8),
                Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(13.5, FontWeight.w700, color: ink))),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: _drop,
          child: toast == null
              ? const SizedBox.shrink(key: ValueKey('no-toast'))
              : KeyedSubtree(
                  key: ValueKey('toast:$toast'),
                  child: pill(
                    key: const ValueKey('live-toast'),
                    text: toast!,
                    fill: k.card.withValues(alpha: 0.97),
                    ink: k.ink,
                    lead: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(color: k.accent, shape: BoxShape.circle),
                      child: Icon(Icons.restaurant_menu_rounded, size: 14, color: k.onAccent),
                    ),
                  ),
                ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: _drop,
          child: streak == null
              ? const SizedBox.shrink(key: ValueKey('no-streak'))
              : KeyedSubtree(
                  key: ValueKey('streak:$streak'),
                  child: pill(
                    key: const ValueKey('live-streak'),
                    text: streak!,
                    fill: _fire,
                    gradient: const LinearGradient(colors: [Color(0xFFFF8A2C), Color(0xFFFF4D4D)]),
                    ink: Colors.white,
                    lead: const Icon(Icons.local_fire_department_rounded, size: 22, color: Colors.white),
                  ),
                ),
        ),
      ],
    );
  }
}

/// "Live" in the menu header: on, the page shows what other tables are ordering; off, it stays quiet. Kept on this browser.
class _LiveSwitch extends StatelessWidget {
  const _LiveSwitch({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final on = app.live;
    return Tooltip(
      message: on ? 'Live mode is on: see what other tables are ordering' : 'Live mode is off',
      child: Semantics(
        button: true,
        toggled: on,
        label: 'Live mode',
        child: Material(
          color: on ? k.accent.withValues(alpha: 0.14) : k.card,
          shape: StadiumBorder(side: BorderSide(color: on ? k.accent : k.line)),
          child: InkWell(
            key: const ValueKey('live-mode'),
            customBorder: const StadiumBorder(),
            onTap: () => app.setLive(!on),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: on ? k.accent : k.muted, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text('Live', style: k.t(13, FontWeight.w700, color: on ? k.accent : k.muted)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- the restaurant's offers: shown on the menu and the review; "Apply" puts the code in the order, the bill makes the final figure

String _offerTitle(GuestOffer o) {
  if (o.title.isNotEmpty) return o.title;
  final v = o.value == o.value.roundToDouble() ? o.value.round().toString() : o.value.toString();
  return o.percent ? '$v% off' : '${guestMoney(o.value)} off';
}

String? _offerEnds(GuestOffer o) {
  final t = o.endsAt;
  if (t == null) return null;
  final now = DateTime.now();
  return t.year == now.year && t.month == now.month && t.day == now.day ? 'ends ${_clock(t)}' : 'till ${t.day} ${_months[t.month - 1]}';
}

/// One offer: its title, what it needs ("Add ₹80 more to use this offer"), its code, and Apply / Remove where the order can carry a code.
class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.app, required this.offer, this.compact = false});
  final _GuestAppState app;
  final GuestOffer offer;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final o = offer;
    final total = app._total;
    final applied = app.coupon?.id == o.id;
    final short = o.shortBy(total);
    final ends = _offerEnds(o);
    final (line, lineKey, lineColor) = short > 0 && app._count > 0
        ? (compact ? 'Add ${guestMoney(short)} more to use it' : 'Add ${guestMoney(short)} more to use this offer', ValueKey('offer-min-${o.id}'), k.waiting)
        : applied
        ? (compact ? 'Applied · about ${guestMoney(o.savingOn(total))} off' : 'Applied · about ${guestMoney(o.savingOn(total))} off, final on the bill', ValueKey('offer-on-${o.id}'), k.accent)
        : (
            [
              if (o.minOrder > 0) 'On orders of ${guestMoney(o.minOrder)} or more' else if (o.auto) 'Taken off on the bill' else 'Code ${o.code}',
              if (o.auto && o.minOrder > 0) 'on the bill',
              ?ends,
            ].join(' · '),
            ValueKey('offer-line-${o.id}'),
            k.muted,
          );
    final action = !app.canApplyOffers || o.auto
        ? null
        : applied
        ? TextButton(
            key: const ValueKey('offer-remove'),
            onPressed: () => app.applyOffer(null),
            child: Text('Remove', style: k.t(13.5, FontWeight.w700, color: k.muted)),
          )
        : Semantics(
            button: true,
            label: 'Apply offer ${o.code ?? _offerTitle(o)}',
            child: TextButton(
              key: ValueKey('offer-apply-${o.id}'),
              onPressed: short > 0 ? null : () => app.applyOffer(o),
              style: TextButton.styleFrom(
                backgroundColor: short > 0 ? k.card2 : k.accent,
                foregroundColor: short > 0 ? k.muted : k.onAccent,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 34),
                shape: const StadiumBorder(),
              ),
              child: ExcludeSemantics(child: Text('Apply', style: k.t(13.5, FontWeight.w800, color: short > 0 ? k.muted : k.onAccent))),
            ),
          );
    return Container(
      key: ValueKey('offer-${o.id}'),
      width: compact ? 300 : null,
      padding: EdgeInsets.fromLTRB(12, compact ? 6 : 12, 8, compact ? 6 : 12),
      decoration: BoxDecoration(
        color: applied ? k.accent.withValues(alpha: 0.12) : k.card,
        borderRadius: BorderRadius.circular(compact ? 16 : 18),
        border: Border.all(color: applied ? k.accent : k.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(applied ? Icons.check_circle_rounded : Icons.local_offer_rounded, size: 22, color: k.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(_offerTitle(o), maxLines: 1, overflow: TextOverflow.ellipsis, style: k.t(14.5, FontWeight.w800))),
                    if (!compact && o.code != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: k.muted.withValues(alpha: 0.6))),
                        child: Text(o.code!, style: k.t(11.5, FontWeight.w700, color: k.muted)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(line, key: lineKey, maxLines: compact ? 1 : 2, overflow: TextOverflow.ellipsis, style: k.t(12.5, FontWeight.w600, color: lineColor)),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 6), action],
        ],
      ),
    );
  }
}

/// The offers strip under the menu's header.
class _OffersStrip extends StatelessWidget {
  const _OffersStrip({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final list = app.offers;
    return SizedBox(
      key: const ValueKey('offers-strip'),
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, n) => _OfferCard(app: app, offer: list[n], compact: true),
      ),
    );
  }
}

/// The offers on the review screens, one under another, with the saving the applied one should give.
class _OffersList extends StatelessWidget {
  const _OffersList({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final c = app.coupon;
    final save = c?.savingOn(app._total) ?? 0;
    return Column(
      key: const ValueKey('review-offers'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Offers', style: k.t(16, FontWeight.w800)),
        const SizedBox(height: 8),
        for (final o in app.offers) Padding(padding: const EdgeInsets.only(bottom: 8), child: _OfferCard(app: app, offer: o)),
        if (c != null && save > 0)
          Text(
            'You save about ${guestMoney(save)} with ${c.code ?? _offerTitle(c)}. The final amount is on the bill.',
            key: const ValueKey('offer-saving'),
            style: k.t(13, FontWeight.w600, color: k.accent),
          ),
      ],
    );
  }
}

/// The review's total: with an applied offer, the subtotal, the offer's estimated saving and the estimated total.
class _Totals extends StatelessWidget {
  const _Totals({required this.app});
  final _GuestAppState app;
  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final total = app._total;
    final c = app.coupon;
    final save = c?.savingOn(total) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c != null && save > 0) ...[
          Row(
            children: [
              Expanded(child: Text('Subtotal', style: k.t(14.5, FontWeight.w500, color: k.muted))),
              Text(guestMoney(total), style: k.t(14.5, FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Text('Offer ${c.code ?? _offerTitle(c)} (estimate)', style: k.t(14.5, FontWeight.w500, color: k.accent))),
              Text('−${guestMoney(save)}', key: const ValueKey('review-offer'), style: k.t(14.5, FontWeight.w800, color: k.accent)),
            ],
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(child: Text(save > 0 ? 'Estimated total' : 'Total', style: k.t(16, FontWeight.w600, color: k.muted))),
            Text(guestMoney(total - save), key: const ValueKey('review-total'), style: k.t(22, FontWeight.w800)),
          ],
        ),
      ],
    );
  }
}

// ---- the web order's stages (contract A), after the founder's boards "Your Order #WD1234" and "Live Order Tracking"

/// Where a web order is, in plain words: sent (waiting for the restaurant), accepted (with the time it should take), preparing, on hold,
/// restaurant paused (why, and when it is back), ready, served, bill ready, paid, or declined with the reason. Asked again every few seconds
/// until it is paid, declined or cancelled; "Get the bill" asks the restaurant for it once it may.
class _StageView extends StatefulWidget {
  const _StageView({required this.app});
  final _GuestAppState app;
  @override
  State<_StageView> createState() => _StageViewState();
}

class _StageViewState extends State<_StageView> {
  _GuestAppState get app => widget.app;
  bool _asking = false;
  String? _billNote;
  bool _ready = false; // the tap that sent the order must not also press the button that sits in the same place
  Timer? _wake;

  static const _steps = ['waiting_partner', 'accepted', 'preparing', 'ready', 'served', 'bill_ready', 'paid'];

  @override
  void initState() {
    super.initState();
    _wake = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _wake?.cancel();
    super.dispose();
  }

  Future<void> _askBill() async {
    setState(() {
      _asking = true;
      _billNote = null;
    });
    final note = await app.askBill();
    if (mounted) {
      setState(() {
        _asking = false;
        _billNote = note;
      });
    }
  }

  ({String title, String line, IconData icon, Color color}) _words(_Look k, WebOrder o, bool pickup) => switch (o.shown) {
    'waiting_partner' => (title: 'Order sent', line: 'Waiting for the restaurant', icon: Icons.hourglass_top_rounded, color: k.waiting),
    'accepted' => (title: 'Accepted', line: 'The restaurant has accepted your order.', icon: Icons.check_circle_rounded, color: k.accent),
    'preparing' => (title: 'Preparing', line: 'The kitchen is preparing your order.', icon: Icons.soup_kitchen_rounded, color: k.accent),
    'on_hold' => (title: 'On hold', line: 'The kitchen has put your order on hold', icon: Icons.pause_circle_filled_rounded, color: k.waiting),
    'paused' => (
      title: 'Restaurant paused',
      // the answer's reason is a code (person, business, auto_missed, ...): only a written sentence is shown as it is
      line: (o.paused?.reason ?? '').contains(' ') ? o.paused!.reason! : 'The restaurant has paused orders for a little while. Your order waits for them.',
      icon: Icons.storefront_rounded,
      color: k.waiting,
    ),
    'ready' => (
      title: pickup ? 'Ready for pickup' : 'Ready',
      line: pickup ? 'Your order is ready to collect.' : 'Your order is ready and on its way to your table.',
      icon: Icons.room_service_rounded,
      color: k.accent,
    ),
    'served' => (title: pickup ? 'Picked up' : 'Served', line: 'Hope you enjoy your meal.', icon: Icons.restaurant_rounded, color: k.accent),
    'bill_ready' => (
      title: 'Bill ready',
      line: pickup ? 'Your bill is ready: pay when you collect.' : 'Your bill is ready. A member of staff will take the payment at your table.',
      icon: Icons.receipt_long_rounded,
      color: k.accent,
    ),
    'paid' => (title: 'Paid', line: 'Thank you! See you again soon.', icon: Icons.verified_rounded, color: k.accent),
    'declined' => (title: 'Declined', line: o.declineReason ?? 'The restaurant could not take this order.', icon: Icons.cancel_rounded, color: _nonVeg),
    'cancelled' => (title: 'Cancelled', line: o.declineReason ?? 'This order was cancelled.', icon: Icons.block_rounded, color: _nonVeg),
    _ => (title: o.stageLabel ?? 'Order sent', line: 'We will keep this page up to date.', icon: Icons.info_outline_rounded, color: k.muted),
  };

  @override
  Widget build(BuildContext context) {
    final k = _lookOf(context);
    final id = app._shown!;
    final o = app.shownOrder!;
    final pickupAt = app._webPickup[id] ?? o.pickupAt;
    final pickup = o.pickup || pickupAt != null;
    final lines = o.lines.isNotEmpty ? [for (final l in o.lines) (name: l.name, qty: l.qty, status: l.status)] : [for (final l in app._webLines[id] ?? const <({String name, int qty})>[]) (name: l.name, qty: l.qty, status: '')];
    final count = lines.fold(0, (a, l) => a + l.qty);
    final w = _words(k, o, pickup);
    final stopped = const {'declined', 'cancelled'}.contains(o.stage);
    final where = pickup
        ? 'Pickup${pickupAt == null ? '' : ' ${_pickupLabel(pickupAt, app.slots?.timezone)}'}'
        : '${app._menu?.tableWord ?? 'Table'} ${o.tableLabel ?? app._visit?.tableLabel ?? ''}'.trim();
    // the step the order has reached; held or paused, it stops where it was
    final reached = math.max(0, _steps.indexOf(const {'on_hold': 'preparing'}[o.stage] ?? o.stage));
    final halted = const {'on_hold', 'paused'}.contains(o.shown);
    final eta = app.showEta && o.etaMinutes != null && const {'accepted', 'preparing'}.contains(o.shown);
    final stepNames = {
      'waiting_partner': ('Sent', 'Waiting for the restaurant'),
      'accepted': ('Accepted', 'The restaurant has your order'),
      'preparing': ('Preparing', 'The kitchen is on it'),
      'ready': ('Ready', pickup ? 'Ready to collect' : 'On its way to your table'),
      'served': (pickup ? 'Picked up' : 'Served', 'Enjoy your meal'),
      'bill_ready': ('Bill ready', pickup ? 'Pay when you collect' : 'Pay at your table'),
      'paid': ('Paid', 'Thank you'),
    };
    const lineWords = {
      'waiting': 'Waiting',
      'pending': 'Waiting',
      'queued': 'In the queue',
      'preparing': 'Preparing',
      'ready': 'Ready',
      'served': 'Served',
      'cancelled': 'Cancelled',
    };
    final orders = app._web.entries.toList();
    return Column(
      key: const ValueKey('stage-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackBar(
          // opened from its link while the menu itself is not available: there is nothing to go back to
          onBack: app._menu == null ? null : () => app.go(pickup ? (app.preorder ? _Phase.menu : app.steps.first) : _Phase.menu),
          title: o.displayNo.isEmpty ? 'Your order' : 'Your order #${o.displayNo}',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            children: [
              Text(
                [where, if (count > 0) count == 1 ? '1 item' : '$count items'].where((s) => s.isNotEmpty).join(' · '),
                key: const ValueKey('stage-where'),
                style: k.t(14, FontWeight.w600, color: k.muted),
              ),
              if (orders.length > 1) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: orders.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, n) {
                      final e = orders[orders.length - 1 - n]; // the newest first
                      final on = e.key == id;
                      return Semantics(
                        button: true,
                        selected: on,
                        child: ChoiceChip(
                          key: ValueKey('web-order-${e.key}'),
                          selected: on,
                          showCheckmark: false,
                          onSelected: (_) => app.setState(() => app._shown = e.key),
                          selectedColor: k.accent,
                          backgroundColor: k.card,
                          side: BorderSide(color: on ? k.accent : k.line),
                          label: Text(e.value.displayNo.isEmpty ? 'Order ${orders.length - n}' : '#${e.value.displayNo}', style: k.t(13, FontWeight.w700, color: on ? k.onAccent : k.ink)),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 14),
              // the stage itself, said out loud by a screen reader when it changes
              Semantics(
                liveRegion: true,
                label: '${w.title}. ${w.line}',
                child: ExcludeSemantics(
                  child: AnimatedContainer(
                    key: ValueKey('stage-${o.shown}'),
                    duration: const Duration(milliseconds: 250),
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: w.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: w.color.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(color: w.color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: w.color.withValues(alpha: 0.35), blurRadius: 18)]),
                          child: Icon(w.icon, size: 30, color: w.color == k.accent ? k.onAccent : Colors.white),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(w.title, key: const ValueKey('stage-title'), style: k.t(24, FontWeight.w800)),
                              const SizedBox(height: 3),
                              Text(w.line, key: const ValueKey('stage-line'), style: k.t(14.5, FontWeight.w500, color: k.muted, height: 1.35)),
                              if (o.shown == 'paused' && o.paused?.backAt != null) ...[
                                const SizedBox(height: 4),
                                Text('Back at ${_clock(o.paused!.backAt!)}', key: const ValueKey('stage-back-at'), style: k.t(14, FontWeight.w700, color: w.color)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (eta) ...[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('stage-eta'),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(18), border: Border.all(color: k.line)),
                  child: Row(
                    children: [
                      Icon(Icons.timer_outlined, color: k.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text(pickup ? 'Estimated ready time' : 'Estimated serving time', style: k.t(14, FontWeight.w500, color: k.muted))),
                      Text('About ${o.etaMinutes} min', style: k.t(16, FontWeight.w800)),
                    ],
                  ),
                ),
              ],
              if (!stopped) ...[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('stage-timeline'),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(20)),
                  child: Column(
                    children: [
                      for (final (n, s) in _steps.indexed)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    color: n < reached
                                        ? k.accent.withValues(alpha: 0.25)
                                        : n == reached
                                        ? (halted ? k.waiting : k.accent)
                                        : k.card2,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    n < reached ? Icons.check_rounded : (n == reached && halted ? Icons.pause_rounded : Icons.circle),
                                    size: n <= reached ? 17 : 8,
                                    color: n < reached ? k.accent : (n == reached ? (halted ? Colors.white : k.onAccent) : k.muted),
                                  ),
                                ),
                                if (n < _steps.length - 1) Container(width: 2, height: 22, color: n < reached ? k.accent.withValues(alpha: 0.45) : k.line),
                              ],
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            stepNames[s]!.$1,
                                            style: k.t(14.5, n == reached ? FontWeight.w800 : FontWeight.w600, color: n <= reached ? k.ink : k.muted),
                                          ),
                                          if (n == reached)
                                            Text(
                                              !halted
                                                  ? stepNames[s]!.$2
                                                  : o.shown == 'on_hold'
                                                  ? 'On hold in the kitchen'
                                                  : 'Restaurant paused${o.paused?.backAt == null ? '' : ' · back at ${_clock(o.paused!.backAt!)}'}',
                                              style: k.t(12.5, halted ? FontWeight.w700 : FontWeight.w500, color: halted ? k.waiting : k.muted),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (n == 0 && o.placedAt != null) Text(_clock(o.placedAt!), style: k.t(12.5, FontWeight.w500, color: k.muted)),
                                    if (n == 1 && o.acceptedAt != null) Text(_clock(o.acceptedAt!), style: k.t(12.5, FontWeight.w500, color: k.muted)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
              if (lines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: BoxDecoration(color: k.card, borderRadius: BorderRadius.circular(18), border: Border.all(color: k.line)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final l in lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(child: Text('${l.qty} × ${l.name}', style: k.t(14.5, FontWeight.w600))),
                              if (!stopped && !o.done && lineWords[l.status] != null) Text(lineWords[l.status]!, style: k.t(12.5, FontWeight.w600, color: k.muted)),
                            ],
                          ),
                        ),
                      if (o.total != null && o.total! > 0) ...[
                        Divider(color: k.line, height: 18),
                        Row(
                          children: [
                            Expanded(child: Text('Estimated total', style: k.t(14, FontWeight.w600, color: k.muted))),
                            Text(guestMoney(o.total!), key: const ValueKey('stage-total'), style: k.t(16, FontWeight.w800)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (app._webOffline)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    key: const ValueKey('stage-offline'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.wifi_off_rounded, size: 16, color: k.muted),
                      const SizedBox(width: 6),
                      Text('Reconnecting… this page keeps trying.', style: k.t(13, FontWeight.w500, color: k.muted)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // the answer to "Get the bill" sits by the button that asked
              if (_billNote != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_billNote!, key: const ValueKey('bill-note'), textAlign: TextAlign.center, style: k.t(13.5, FontWeight.w600, color: k.waiting)),
                ),
              if (o.bill != null) ...[
                _Pill('View bill', key: const ValueKey('view-bill'), trailing: Icons.receipt_long_rounded, onTap: _ready ? () => app.go(_Phase.bill) : null),
                const SizedBox(height: 10),
              ] else if (o.canRequestBill) ...[
                _Pill('Get the bill', key: const ValueKey('get-bill'), busy: _asking, trailing: Icons.receipt_long_rounded, onTap: _ready ? _askBill : null),
                const SizedBox(height: 10),
              ],
              if (app._menu != null)
                _Pill(
                  pickup ? 'Back to the menu' : 'Order more',
                  key: const ValueKey('order-more'),
                  filled: o.bill == null && !o.canRequestBill,
                  onTap: _ready ? () => app.go(pickup ? (app.preorder ? _Phase.menu : app.steps.first) : _Phase.menu) : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
