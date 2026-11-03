import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../assistant/ol_bot.dart' show OlBot, OlFace, OlSpeech;
import '../assistant/ol_tour.dart';
import '../ui/theme.dart';
import 'free_slots_screen.dart';
import 'history_screen.dart';
import 'manage_screen.dart';
import 'service_api.dart';
import 'service_media.dart';
import 'service_menu.dart';
import 'service_money.dart';

// Ol in the Service POS (founder, 3 Nov 2026): the store's character takes the last slot of the service bar and works as a guide. It says
// hello once and one tip the first time each tab opens; tapped, it asks "Where do you want to go?": places to jump to, "Show me how"
// walkthroughs on the real screens, and answers with steps. All on the phone: no AI, no network. The same for every kind of service.

// ============================================================================================================ THE GUIDE (edit here)

/// Each tab's tip, said the first time that tab is ever opened on this device.
const _tips = {
  'Home': "Today's visits, money and free slots are here. Tap me whenever you want to go somewhere.",
  'Catalogue': 'Your services are here. Inventory, next to Services, has your team, places, tools and materials.',
  'Bill': "Red bills are due, green are today's, blue are paid. Tap a bill to collect it or send it on WhatsApp.",
  'Bookings': 'Pick a day to see its bookings. Pull the handle up to see the day hour by hour.',
};

/// Quick questions per tab, shown under the places.
const _quick = {
  'Home': ['Who is free now?', 'Close the day', 'Change opening hours'],
  'Catalogue': ['Add a service', 'Pause a service', 'Lend out a tool'],
  'Bill': ['Collect a payment', 'Send a bill on WhatsApp', 'Give a discount'],
  'Bookings': ['Book a visit', 'Start a job at a home', 'Reschedule a booking'],
};

/// A place Ol can take you: a tab, a page opened in a tab, or a walk to it on the real screens.
class ServiceOlPlace {
  const ServiceOlPlace(this.icon, this.title, this.where, this.words, {required this.tab, this.page, this.tour});
  final IconData icon;
  final String title, where, words, tab;
  final Widget Function()? page;
  final OlTour? tour;

  bool matches(String q) {
    final hay = '$title $where $words'.toLowerCase();
    return q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).every(hay.contains);
  }
}

ServiceApi _api() => ServiceApi();

/// Every place in the Service POS, in the order "Take me to" shows them.
final List<ServiceOlPlace> serviceOlPlaces = [
  ServiceOlPlace(LucideIcons.calendarDays, 'Bookings', 'Calendar, list, board, map', 'booking appointment calendar schedule visit today week month', tab: 'Bookings'),
  ServiceOlPlace(LucideIcons.receiptText, 'Bills', 'Due, today and paid', 'bill payment collect due paid invoice receipt whatsapp', tab: 'Bill'),
  ServiceOlPlace(LucideIcons.layoutList, 'Services', 'Your catalogue', 'service catalogue price add pause photo menu list', tab: 'Catalogue'),
  ServiceOlPlace(LucideIcons.boxes, 'Inventory', 'Team, places, tools, materials, items in care', 'inventory stock tool material place room chair court care lend gear', tab: 'Catalogue',
      tour: OlTour('Open Inventory', [
        OlStep('Inventory sits next to Services. Tap it.', target: OlTarget.key('tab-inventory')),
        OlStep('Pick Team, Places, Tools, Materials or In care at the top. Anything that needs you shows a dot.', next: true),
      ])),
  ServiceOlPlace(LucideIcons.slidersHorizontal, 'Service management', 'Opening hours, slots, who works when', 'manage management hours open close slot timing break staff hours week',
      tab: 'Home', page: () => ManageScreen(api: _api())),
  ServiceOlPlace(LucideIcons.clock, 'Free slots', 'Who is free and when', 'free slot available who empty gap', tab: 'Home', page: () => FreeSlotsScreen(api: _api())),
  ServiceOlPlace(LucideIcons.wallet, 'Money', 'Wallet, cash drawer, dues', 'money cash drawer wallet earning close day due owe income', tab: 'Home', page: () => const ServiceMoneyScreen()),
  ServiceOlPlace(LucideIcons.users, 'Team & providers', 'Who does which service', 'team staff provider worker people skill', tab: 'Home', page: () => serviceScreen('staff', _api())),
  ServiceOlPlace(LucideIcons.images, 'Media', 'Service photos', 'media photo picture image standard', tab: 'Home', page: () => const ServiceMediaScreen()),
  ServiceOlPlace(LucideIcons.package, 'Packages', 'Bundles of services', 'package bundle combo', tab: 'Home', page: () => serviceScreen('packages', _api())),
  ServiceOlPlace(LucideIcons.star, 'Memberships', 'Monthly and yearly plans', 'membership plan member subscription monthly', tab: 'Home', page: () => serviceScreen('memberships', _api())),
  ServiceOlPlace(LucideIcons.history, 'Visit history', 'Past visits and money', 'history past visit report sales record', tab: 'Home', page: () => ServiceHistoryScreen(api: _api())),
  ServiceOlPlace(LucideIcons.calendarOff, 'Holidays & time off', 'Days closed, people away', 'holiday closed leave time off availability exception', tab: 'Home', page: () => serviceScreen('availability', _api())),
];

/// The jobs Ol can show on the real screens. Keys and words are the screens' own.
const serviceOlTours = <OlTour>[
  OlTour('Book a visit', [
    OlStep('Tap Bookings at the bottom.', target: OlTarget.key('tab-Bookings')),
    OlStep('Tap New booking.', target: OlTarget.key('new-booking')),
    OlStep('Pick the service, the time and who does it, add the customer, and save. It shows on the calendar at once.', next: true),
  ]),
  OlTour('Start a job', [
    OlStep('Tap Bookings at the bottom.', target: OlTarget.key('tab-Bookings')),
    OlStep('Tap New job: work at the customer\'s place, one visit or repeating.', target: OlTarget.key('new-job')),
    OlStep('Add the customer, the services, the team and the time, then save.', next: true),
  ]),
  OlTour('Collect a bill', [
    OlStep('Tap Bill at the bottom.', target: OlTarget.key('tab-Bill')),
    OlStep('Red bills are due. Tap the bill to collect it, take cash, card or UPI, and send the receipt on WhatsApp.', next: true),
  ]),
  OlTour('Add a service', [
    OlStep('Tap Catalogue at the bottom.', target: OlTarget.key('tab-Catalogue')),
    OlStep('Tap Add service.', target: OlTarget.key('add-service')),
    OlStep('Pick what you are adding: an appointment, an event, a home visit and so on. Each opens its own form.', next: true),
  ]),
  OlTour('Lend out a tool', [
    OlStep('Tap Catalogue at the bottom.', target: OlTarget.key('tab-Catalogue')),
    OlStep('Tap Inventory.', target: OlTarget.key('tab-inventory')),
    OlStep('Tap Tools.', target: OlTarget.key('inv-tile-tools')),
    OlStep('Tap the tool, then Lend out. Say how many and who has them; tap Got back when they return.', next: true),
  ]),
  OlTour('Change opening hours', [
    OlStep('Tap Home at the bottom.', target: OlTarget.key('tab-Home')),
    OlStep('Open the menu.', target: OlTarget.key('home-menu')),
    OlStep('Tap Service management.', target: OlTarget.text('Service management')),
    OlStep('Tap Edit hours. Set the days you open, the times and the break, then save.', target: OlTarget.key('edit-hours'), next: true),
  ]),
];

/// What Ol answers: the words a question may use, the answer, its steps, and the place that has it.
class ServiceOlAnswer {
  const ServiceOlAnswer(this.text, {this.steps = const [], this.place});
  final String text;
  final List<String> steps;
  final String? place; // a [ServiceOlPlace.title]
}

const _topics = <(List<String>, ServiceOlAnswer)>[
  (['book', 'booking', 'appointment', 'visit', 'new', 'slot', 'customer'], ServiceOlAnswer('To book a visit:',
      steps: ['Open Bookings', 'Tap New booking', 'Pick the service, the time and who does it', 'Add the customer and save'], place: 'Bookings')),
  (['reschedule', 'move', 'change', 'cancel', 'no', 'show', 'late'], ServiceOlAnswer('To change a booking:',
      steps: ['Open Bookings and pick the day', 'Tap the booking', 'Reschedule, cancel or mark a no-show from there'], place: 'Bookings')),
  (['job', 'home', 'site', 'location', 'repeat', 'team', 'start'], ServiceOlAnswer('For work at the customer\'s place:',
      steps: ['Open Bookings', 'Tap New job', 'Add the customer, services, team and time (one visit or repeating)', 'Save'], place: 'Bookings')),
  (['bill', 'pay', 'payment', 'collect', 'due', 'cash', 'upi', 'card', 'paid'], ServiceOlAnswer('To collect a payment:',
      steps: ['Open Bill', 'Red bills are due: tap one', 'Take cash, card or UPI'], place: 'Bills')),
  (['whatsapp', 'send', 'share', 'receipt', 'link'], ServiceOlAnswer('To send a bill:',
      steps: ['Open Bill and tap the bill', 'Tap WhatsApp: the customer gets a short note and a link to the bill'], place: 'Bills')),
  (['discount', 'off', 'less', 'percent'], ServiceOlAnswer('A discount goes on the bill:',
      steps: ['Open Bill and tap the bill (or make a new bill)', 'Enter the discount in ₹ or %'], place: 'Bills')),
  (['service', 'add', 'price', 'catalogue', 'create', 'new'], ServiceOlAnswer('To add a service:',
      steps: ['Open Catalogue', 'Tap Add service', 'Pick what you are adding and fill its form'], place: 'Services')),
  (['pause', 'stop', 'hide', 'off'], ServiceOlAnswer('To stop taking bookings for a service:',
      steps: ['Open Catalogue', 'Tap ⋮ on the service', 'Tap Pause bookings (Take bookings again turns it back on)'], place: 'Services')),
  (['inventory', 'tool', 'lend', 'material', 'stock', 'place', 'room', 'chair', 'court', 'care', 'gear'], ServiceOlAnswer('Tools, materials, places and items in care are in Inventory:',
      steps: ['Open Catalogue', 'Tap Inventory', 'Pick the section and tap an item for Lend out, Add stock, Block and more'], place: 'Inventory')),
  (['team', 'staff', 'provider', 'worker', 'people', 'skill'], ServiceOlAnswer('Your team and what each person does are in Team & providers. Inventory shows who is free right now.',
      place: 'Team & providers')),
  (['hour', 'open', 'opening', 'closing', 'time', 'timing', 'break', 'slot', 'length', 'week'], ServiceOlAnswer('Opening hours and slots are in Service management:',
      steps: ['Open the menu (☰) on Home', 'Tap Service management', 'Tap Edit hours'], place: 'Service management')),
  (['free', 'available', 'who', 'empty', 'gap'], ServiceOlAnswer('Free slots shows who is free and when, today.', place: 'Free slots')),
  (['money', 'drawer', 'wallet', 'earning', 'day', 'owe', 'income', 'close'], ServiceOlAnswer('Money has your wallet, money from services, the cash drawer (close the day there) and what customers owe.',
      place: 'Money')),
  (['photo', 'media', 'picture', 'image'], ServiceOlAnswer('A service\'s photo is set on the service (Camera, Gallery or Standard). Media has all your photos.', place: 'Media')),
  (['package', 'bundle', 'combo'], ServiceOlAnswer('Packages are bundles of services at one price.', place: 'Packages')),
  (['membership', 'plan', 'member', 'subscription'], ServiceOlAnswer('Memberships are monthly or yearly plans customers buy.', place: 'Memberships')),
  (['history', 'past', 'report', 'sales', 'record'], ServiceOlAnswer('Visit history has every past visit and its money.', place: 'Visit history')),
  (['holiday', 'leave', 'closed', 'away', 'exception'], ServiceOlAnswer('Days closed and people away are in Holidays & time off.', place: 'Holidays & time off')),
];

const serviceOlNotSure = "I'm not sure about that one yet. Try bookings, bills, services, inventory, team, hours or money.";

Set<String> _words(String q) => q
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.length > 1)
    .map((w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.substring(0, w.length - 1) : w)
    .toSet();

/// The topic sharing the most words with the question; none at all is the "not sure" answer.
ServiceOlAnswer serviceOlAnswer(String question) {
  final q = _words(question);
  ServiceOlAnswer? best;
  var top = 0;
  for (final (words, a) in _topics) {
    final score = words.where(q.contains).length;
    if (score > top) {
      best = a;
      top = score;
    }
  }
  return best ?? const ServiceOlAnswer(serviceOlNotSure);
}

// ============================================================================================================ Ol in the bar

/// Opens a tab, and a page in it when there is one (the app shell does this).
typedef ServiceOlOpen = void Function(String tab, Widget Function()? page);

/// Ol in the last slot of the service bar.
class ServiceOl extends StatefulWidget {
  const ServiceOl({super.key, required this.current, required this.open});

  /// The tab on screen ('Home', 'Catalogue', 'Bill', 'Bookings'): the tip and the quick questions follow it.
  final String current;
  final ServiceOlOpen open;

  static bool _helloSeen = false, _loaded = false;
  static final _tipped = <String>{};
  static const _helloKey = 'svc_ol_hello_seen', _tipsKey = 'svc_ol_tips_said';

  /// Tests start each time from a phone that has heard nothing.
  static void reset() {
    _helloSeen = _loaded = false;
    _tipped.clear();
  }

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _helloSeen = _helloSeen || (p.getBool(_helloKey) ?? false);
      _tipped.addAll(p.getStringList(_tipsKey) ?? const []);
    } catch (_) {/* no storage: once per session */}
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_helloKey, _helloSeen);
      await p.setStringList(_tipsKey, _tipped.toList());
    } catch (_) {}
  }

  @override
  State<ServiceOl> createState() => _ServiceOlState();
}

class _ServiceOlState extends State<ServiceOl> with SingleTickerProviderStateMixin {
  final _link = LayerLink();
  final _bubble = OverlayPortalController();
  late final AnimationController _hop = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  Timer? _say, _hide;
  String? _text;

  @override
  void initState() {
    super.initState();
    _speak();
  }

  @override
  void didUpdateWidget(ServiceOl old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hide?.cancel();
        if (_bubble.isShowing) _bubble.hide();
        _speak();
      });
    }
  }

  @override
  void dispose() {
    _say?.cancel();
    _hide?.cancel();
    _hop.dispose();
    super.dispose();
  }

  /// Hello the first time ever; otherwise this tab's tip the first time it is opened. A moment after the page draws.
  Future<void> _speak() async {
    _say?.cancel();
    final tab = widget.current;
    await ServiceOl._load();
    if (!mounted || widget.current != tab) return;
    final hello = !ServiceOl._helloSeen;
    final tip = hello ? null : _tips[tab];
    if (!hello && (tip == null || ServiceOl._tipped.contains(tab))) return;
    void say() {
      // no tips over a walkthrough: the tab's tip waits for the next time it opens
      if (!mounted || widget.current != tab || OlWalk.current != null) return;
      hello ? ServiceOl._helloSeen = true : ServiceOl._tipped.add(tab);
      if (OlBot.animate) ServiceOl._save();
      setState(() => _text = hello ? "Hi, I'm Ol! I know my way around. Tap me and tell me where you want to go." : tip);
      _bubble.show();
      if (OlBot.animate) {
        _hop.forward(from: 0);
        _hide?.cancel();
        _hide = Timer(Duration(seconds: hello ? 9 : 7), () => mounted ? _bubble.hide() : null);
      }
    }

    if (OlBot.animate) {
      _say = Timer(const Duration(milliseconds: 900), say);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => say());
    }
  }

  Future<void> _open() async {
    _hide?.cancel();
    if (_bubble.isShowing) _bubble.hide();
    if (OlBot.animate) _hop.forward(from: 0);
    final overlay = Overlay.of(context, rootOverlay: true);
    final pick = await showServiceOlSheet(context, current: widget.current);
    if (pick == null || !mounted) return;
    final place = pick.place;
    if (place != null) {
      widget.open(place.tab, place.page);
      if (place.tour != null) OlWalk.start(overlay, place.tour!);
    }
    if (pick.tour != null) OlWalk.start(overlay, pick.tour!);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: (_) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(-2, -8),
          child: Align(
            alignment: Alignment.bottomRight,
            child: OlSpeech(text: _text ?? '', onTap: _open, onClose: () {
              _hide?.cancel();
              _bubble.hide();
            }),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: Semantics(
            button: true,
            label: 'Ol, your guide. Where do you want to go?',
            excludeSemantics: true,
            child: GestureDetector(
              key: const ValueKey('service-ol'),
              behavior: HitTestBehavior.opaque,
              onTap: _open,
              child: LayoutBuilder(builder: (context, box) {
                final h = (box.maxWidth * 1.12 / OlFace.aspect).clamp(44.0, 52.0);
                return OverflowBox(
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: AnimatedBuilder(
                    animation: _hop,
                    builder: (_, child) {
                      final v = _hop.value, up = sin(v * pi);
                      return Transform.translate(
                        offset: Offset(0, -10 * up),
                        child: Transform.scale(alignment: Alignment.bottomCenter, scaleX: 1 + 0.06 * up * (1 - v), scaleY: 1 - 0.06 * up * (1 - v), child: child),
                      );
                    },
                    child: OlFace(height: h),
                  ),
                );
              }),
            ),
          ),
        ),
      );
}

// ============================================================================================================ the sheet

/// What was chosen: a place to go, or a walkthrough to start.
class ServiceOlPick {
  const ServiceOlPick({this.place, this.tour});
  final ServiceOlPlace? place;
  final OlTour? tour;
}

Future<ServiceOlPick?> showServiceOlSheet(BuildContext context, {required String current}) => showModalBottomSheet<ServiceOlPick>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _OlSheet(current: current),
    );

class _OlSheet extends StatefulWidget {
  const _OlSheet({required this.current});
  final String current;
  @override
  State<_OlSheet> createState() => _OlSheetState();
}

class _OlSheetState extends State<_OlSheet> {
  final _ask = TextEditingController();
  ServiceOlAnswer? _answer;
  String _asked = '';

  @override
  void initState() {
    super.initState();
    _ask.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ask.dispose();
    super.dispose();
  }

  void _send(String q) {
    final text = q.trim();
    if (text.isEmpty) return;
    setState(() {
      _asked = text;
      _answer = serviceOlAnswer(text);
      _ask.clear();
    });
  }

  void _go(ServiceOlPlace p) => Navigator.of(context).pop(ServiceOlPick(place: p));
  void _show(OlTour t) => Navigator.of(context).pop(ServiceOlPick(tour: t));

  ServiceOlPlace? _place(String? title) => title == null ? null : serviceOlPlaces.where((p) => p.title == title).firstOrNull;

  Widget _head(String text) => Padding(padding: const EdgeInsets.fromLTRB(0, 14, 0, 8), child: Text(text, style: inter(13, 700, color: kMuted)));

  @override
  Widget build(BuildContext context) {
    final typed = _ask.text.trim();
    final places = typed.isEmpty ? serviceOlPlaces.take(8).toList() : serviceOlPlaces.where((p) => p.matches(typed)).take(5).toList();
    final tw = _words(typed)..removeAll(const {'a', 'an', 'the', 'to', 'do', 'how', 'my', 'of', 'on', 'in', 'see', 'show', 'me'});
    final tours = typed.isEmpty ? serviceOlTours : serviceOlTours.where((t) => _words(t.name).any(tw.contains)).toList();
    final a = _answer;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
          child: Column(key: const ValueKey('service-ol-sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
              child: Row(children: [
                const OlFace(height: 44, still: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Where do you want to go?', style: inter(19, 800)),
                    Text("I'm Ol, your guide. Pick a place, or ask me.", style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                key: const ValueKey('service-ol-ask'),
                controller: _ask,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: inter(15, 500),
                decoration: InputDecoration(
                  hintText: 'e.g. lend a tool, opening hours, collect a bill',
                  hintStyle: inter(14, 400, color: kHint),
                  filled: true,
                  fillColor: const Color(0xFFF4F5F1),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
                  suffixIcon: IconButton(key: const ValueKey('service-ol-send'), onPressed: () => _send(_ask.text), icon: const Icon(LucideIcons.sendHorizontal, color: OlFace.ink)),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (a != null && typed.isEmpty) _answerCard(a),
                  if (places.isNotEmpty) ...[
                    _head(typed.isEmpty ? 'Take me to' : 'Places'),
                    if (typed.isEmpty)
                      GridView.count(
                        crossAxisCount: 4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 0.9,
                        children: [for (final p in places) _placeTile(p)],
                      )
                    else
                      for (final p in places) _placeRow(p),
                  ],
                  if (tours.isNotEmpty) ...[
                    _head('Show me how'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final t in tours)
                        ActionChip(
                          key: ValueKey('service-ol-tour-${t.name}'),
                          avatar: const Icon(LucideIcons.mousePointerClick, size: 15, color: OlFace.deep),
                          label: Text(t.name, style: inter(13, 600)),
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFFCDEFA8)),
                          shape: const StadiumBorder(),
                          onPressed: () => _show(t),
                        ),
                    ]),
                  ],
                  if (typed.isEmpty) ...[
                    _head('Ask me'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final q in _quick[widget.current] ?? _quick['Home']!)
                        ActionChip(
                          key: ValueKey('service-ol-quick-$q'),
                          label: Text(q, style: inter(13, 600)),
                          backgroundColor: const Color(0xFFF1FBE6),
                          side: const BorderSide(color: Color(0xFFCDEFA8)),
                          shape: const StadiumBorder(),
                          onPressed: () => _send(q),
                        ),
                    ]),
                  ],
                  if (typed.isNotEmpty && places.isEmpty && tours.isEmpty)
                    Padding(padding: const EdgeInsets.only(top: 14), child: Text('Press send and I will answer.', style: inter(13, 500, color: kMuted))),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Ol's answer to what was asked: the words, the steps, and Take me there.
  Widget _answerCard(ServiceOlAnswer a) {
    final p = _place(a.place);
    return Container(
      key: const ValueKey('service-ol-answer'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFF4F5F1), borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('“$_asked”', style: inter(12.5, 500, color: kMuted)),
        const SizedBox(height: 6),
        Text(a.text, style: inter(14.5, 600, color: OlFace.ink, height: 1.35)),
        for (var i = 0; i < a.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: OlFace.lime, shape: BoxShape.circle),
                child: Text('${i + 1}', style: inter(11, 800, color: OlFace.ink)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(a.steps[i], style: inter(13.5, 500, color: OlFace.ink))),
            ]),
          ),
        if (p != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('service-ol-take'),
            style: FilledButton.styleFrom(backgroundColor: OlFace.ink, foregroundColor: Colors.white, shape: const StadiumBorder()),
            onPressed: () => _go(p),
            icon: const Icon(LucideIcons.arrowRight, size: 16),
            label: Text('Take me there', style: inter(14, 700, color: Colors.white)),
          ),
        ],
      ]),
    );
  }

  Widget _placeTile(ServiceOlPlace p) => Material(
        color: const Color(0xFFF4F5F1),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey('service-ol-place-${p.title}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => _go(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Icon(p.icon, size: 18, color: kInk),
              ),
              const SizedBox(height: 6),
              Text(p.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: inter(11.5, 600, height: 1.15)),
            ]),
          ),
        ),
      );

  Widget _placeRow(ServiceOlPlace p) => ListTile(
        key: ValueKey('service-ol-place-${p.title}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(backgroundColor: const Color(0xFFF1FBE6), child: Icon(p.icon, size: 18, color: kInk)),
        title: Text(p.title, style: inter(14, 700)),
        subtitle: Text(p.where, style: inter(12, 400, color: kMuted)),
        trailing: const Icon(LucideIcons.chevronRight, size: 16, color: kMuted),
        onTap: () => _go(p),
      );
}
