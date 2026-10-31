import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/app_actions.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'ol_bot.dart' show OlFace;
import 'ol_tour.dart';

// "Ask Ol" (founder, 31 Oct 2026): a short chat that answers from a guide to this restaurant app kept on the phone — no AI, no network.
// The guide's content (tips, quick chips, topics and walkthroughs) is the one list below; edit it there.

// ============================================================================================================ THE GUIDE (edit here)

/// Each tab's tip, said the first time that tab is ever opened on this device.
const _tips = {
  'Home': "Today's sales, bills and kitchen are here. Tap me any time to find something or to be shown how.",
  'Menu': 'Quick add a dish here. Tap ⋮ on a dish for the AI enhancer, description and timings, or to mark it out of stock.',
  'Bill': 'Choose a table, then tap dishes to add them. Takeaway and Delivery need no table.',
  'Orders': 'Every order is here, newest first. Tap one to see its dishes and where it is.',
};

/// 3–4 quick questions per tab, shown above the box in Ask Ol.
const _quick = {
  'Home': ['Take an order', "Today's sales", 'Add a dish', 'Settings'],
  'Menu': ['Add a dish', 'Mark out of stock', 'Dish photo', 'Recipe costs'],
  'Bill': ['Split a bill', 'Takeaway on a table', 'Ready to serve', 'Add a table'],
  'Orders': ['Order history', 'Take an order', "Today's sales"],
};

/// What Ol knows: the words a question may use, and the answer (a sentence, the steps, the tab that has it).
const _topics = <_Topic>[
  _Topic(['take', 'order', 'new', 'dine', 'kot', 'kitchen', 'send', 'cart', 'table', 'start'], OlAnswer(
    'To take a dine-in order:',
    steps: ['Open Bill', 'Keep Dine in and tap the table box to choose the table', 'Tap dishes to add them (tap again for one more)', 'Tap Send to kitchen, or Hold'],
    tab: 'Bill',
  )),
  _Topic(['takeaway', 'parcel', 'pack', 'away', 'same', 'table'], OlAnswer(
    'Takeaway for guests already at a table goes on their bill:',
    steps: ['Open Bill and choose their table', 'Tap the Takeaway pill', 'Tap the dishes to pack; they show "Takeaway" on the bill and the kitchen ticket'],
    tab: 'Bill',
  )),
  _Topic(['delivery', 'deliver', 'address', 'phone', 'own'], OlAnswer(
    'For a delivery order:',
    steps: ['Open Bill and tap the Delivery pill', 'Tap the dishes', 'Send to kitchen, then enter the name, phone and address'],
    tab: 'Bill',
  )),
  _Topic(['split', 'cash', 'card', 'upi', 'pay', 'payment', 'settle', 'generate', 'bill', 'checkout'], OlAnswer(
    'To split one bill across Cash, Card and UPI:',
    steps: ['Open Bill and tap the table', 'Tap Generate Bill (Take Payment once it is generated)', 'On Checkout tap Split Pay', 'Type each method\'s amount, then take each payment'],
    tab: 'Bill',
  )),
  _Topic(['ready', 'serve', 'served', 'kds', 'display', 'waiter'], OlAnswer(
    'Dishes the kitchen has made wait in Ready to serve:',
    steps: ['Open Bill', 'Tap Ready to serve', 'Mark dishes served as they go to the table'],
    tab: 'Bill',
  )),
  _Topic(['table', 'add', 'rename', 'seat', 'qr', 'manage', 'clean', 'area', 'floor'], OlAnswer(
    'Tables are managed from Bill:',
    steps: ['Open Bill', 'Tap ⋮ at the top', 'Manage tables adds, renames or changes seats; Table QR codes let guests order from their table'],
    tab: 'Bill',
  )),
  _Topic(['dish', 'item', 'menu', 'add', 'new', 'price', 'category', 'quick', 'create'], OlAnswer(
    'To add a dish:',
    steps: ['Open Menu', 'Tap Quick add beside the search', 'Type the name, price and category, then save'],
    tab: 'Menu',
  )),
  _Topic(['photo', 'picture', 'image', 'ai', 'background', 'enhance'], OlAnswer(
    'For a dish photo:',
    steps: ['Open Menu', 'Tap ⋮ on the dish, then AI enhancer', 'Choose the background (Keep, Studio or Remove) and the size (4:5 or square)', 'Tap Make picture, then Use this picture'],
    tab: 'Menu',
  )),
  _Topic(['description', 'describe', 'timing', 'time', 'hour', 'available', 'breakfast', 'lunch', 'dinner'], OlAnswer(
    'To change a dish\'s description or serving times:',
    steps: ['Open Menu', 'Tap ⋮ on the dish', 'Tap Edit description & timings'],
    tab: 'Menu',
  )),
  _Topic(['stock', 'out', 'finished', 'unavailable', 'off', 'over'], OlAnswer(
    'To mark a dish out of stock:',
    steps: ['Open Menu', 'Tap ⋮ on the dish', 'Tap Mark out of stock (and Mark in stock when it is back)'],
    tab: 'Menu',
  )),
  _Topic(['recipe', 'cost', 'margin', 'food', 'profit', 'ingredient', 'made', 'make'], OlAnswer(
    'Recipes and food cost are in Menu:',
    steps: ['Open Menu', 'Tap Recipe to see each dish\'s cost and margin (green is healthy)', 'Ingredients is in the ☰ side menu, under Inventory'],
    tab: 'Menu',
  )),
  _Topic(['history', 'past', 'old', 'track', 'status', 'online', 'where', 'all'], OlAnswer(
    'Every order, newest first, is in Orders. Tap one for its dishes and where it is; All Orders in the ☰ side menu has the full history.',
    tab: 'Orders',
  )),
  _Topic(['sales', 'today', 'revenue', 'report', 'dashboard', 'earning', 'money', 'collection'], OlAnswer(
    'Today\'s sales are on Home. For any day or month:',
    steps: ['Tap ☰ at the top left', 'Tap Reports', 'Open Sales summary, Item-wise or Category-wise sales'],
    tab: 'Home',
  )),
  _Topic(['setting', 'outlet', 'profile', 'gst', 'printer', 'language'], OlAnswer(
    'Settings are in the side menu:',
    steps: ['Open Home', 'Tap ☰ at the top left', 'Tap Settings (outlet info, timings, phone numbers, printers)'],
    tab: 'Home',
  )),
];

/// The jobs Ol can show on the real screens ("Show me how"). Keys and words are the screens' own.
const olTours = <OlTour>[
  OlTour('Take a dine-in order', [
    OlStep('Tap Bill at the bottom. Orders are taken here.', target: OlTarget.key('tab-Bill')),
    OlStep('Keep Dine in chosen.', target: OlTarget.key('mode-dine_in'), next: true),
    OlStep('Tap the table box to choose the guests\' table.', target: OlTarget.key('open-tables')),
    OlStep('Pick their table.', target: OlTarget.keyPrefix('table-')),
    OlStep('Tap a dish to add it. Tap it again for one more.', target: OlTarget.keyPrefix('dish-square-')),
    OlStep('When the order is ready, tap Send to kitchen. The kitchen gets the ticket at once.', target: OlTarget.key('bill-send'), next: true),
  ]),
  OlTour('Split a bill', [
    OlStep('Tap Bill at the bottom.', target: OlTarget.key('tab-Bill')),
    OlStep('Tap the table that wants to pay.', target: OlTarget.keyPrefix('deck-front-'), next: true),
    OlStep('Tap Generate Bill. (Once it is generated this button says Take Payment.)', target: OlTarget.text('Generate Bill')),
    OlStep('On Checkout, tap Split Pay.', target: OlTarget.text('Split Pay')),
    OlStep('Type what each method pays — Cash, Card or UPI — then take each payment. Done!', target: OlTarget.key('take-payment'), next: true),
  ]),
  OlTour('Add a dish', [
    OlStep('Tap Menu at the bottom.', target: OlTarget.key('tab-Menu')),
    OlStep('Tap Quick add.', target: OlTarget.key('menu-quick-add')),
    OlStep('Type the dish name, price and category, then save. It shows on the Bill at once.', next: true),
  ]),
  OlTour('Mark a dish out of stock', [
    OlStep('Tap Menu at the bottom.', target: OlTarget.key('tab-Menu')),
    OlStep('Tap ⋮ on the dish.', target: OlTarget.keyPrefix('more-')),
    OlStep('Tap Mark out of stock. Guests cannot order it until you mark it in stock again.', target: OlTarget.keyPrefix('stock-')),
  ]),
  OlTour('Add a table', [
    OlStep('Tap Bill at the bottom.', target: OlTarget.key('tab-Bill')),
    OlStep('Tap ⋮ at the top.', target: OlTarget.key('floor-more')),
    OlStep('Tap Manage tables.', target: OlTarget.key('open-manage-tables')),
    OlStep('Add a table with its name and seats, or change the ones you have. Save, and it shows on the floor.', next: true),
  ]),
  OlTour("See today's sales", [
    OlStep('Tap Home at the bottom.', target: OlTarget.key('tab-Home')),
    OlStep("Today's sales are here.", target: OlTarget.key('rst-net-sales'), next: true),
    OlStep('For more, open the side menu.', target: OlTarget.key('home-menu')),
    OlStep('Tap Reports.', target: OlTarget.text('Reports')),
    OlStep('Tap Sales summary: net sales, bills, tax, discounts and refunds for any day.', target: OlTarget.key('reports-open-sales')),
  ]),
];

// ============================================================================================================ matching

/// One answer: what Ol says, the steps, and the tab that has it (null when Ol is not sure).
class OlAnswer {
  const OlAnswer(this.text, {this.steps = const [], this.tab});
  final String text;
  final List<String> steps;
  final String? tab;
}

class _Topic {
  const _Topic(this.words, this.answer);
  final List<String> words;
  final OlAnswer answer;
}

/// What Ol knows about the restaurant app, from the list above. A question is matched to the topic whose words it shares most.
class OlGuide {
  const OlGuide();

  static const notSure = "I'm not sure about that one yet. Try asking about orders, tables, takeaway, splitting a bill, dishes, recipes or sales.";

  String greeting(String tab, DateTime now) {
    final h = now.hour;
    final hello = h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
    return "${tr(hello)}! ${tr("I'm Ol 👋 I can take you anywhere in the app.")} ${tr("You're on")} ${tr(tab)}. ${tr('What do you need?')}";
  }

  String? tipFor(String tab) => _tips[tab];
  List<String> quickFor(String tab) => _quick[tab] ?? const ['Take an order', 'Add a dish', 'Split a bill'];
  List<OlTour> get tours => olTours;

  /// The question's words: lowercase, no apostrophes or punctuation, no one-letter words, a trailing "s" (not "ss") dropped.
  static Set<String> words(String q) => q
      .toLowerCase()
      .replaceAll("'", '')
      .replaceAll('’', '')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1)
      .map(_stem)
      .toSet();
  static String _stem(String w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.substring(0, w.length - 1) : w;

  /// The topic sharing the most words wins; none at all is the "not sure" answer.
  OlAnswer answer(String question) {
    final q = words(question);
    _Topic? best;
    var bestScore = 0;
    for (final t in _topics) {
      final score = t.words.where((w) => q.contains(_stem(w))).length;
      if (score > bestScore) {
        best = t;
        bestScore = score;
      }
    }
    return best?.answer ?? const OlAnswer(notSure);
  }

  /// Walkthroughs whose name shares a word with the question ("split" finds "Split a bill"); small words do not count.
  List<OlTour> toursFor(String question) {
    final q = words(question)..removeAll(const {'a', 'an', 'the', 'to', 'do', 'how', 'my', 'of', 'on', 'in', 'see', 'show', 'me', 'add'});
    if (q.isEmpty) return const [];
    return olTours.where((t) => words(t.name).any(q.contains)).toList();
  }
}

// ============================================================================================================ the sheet

/// What the person chose in Ask Ol: a tab to switch to, a walkthrough to start, or a place in the app to open.
class OlPick {
  const OlPick({this.tab, this.tour, this.action});
  final String? tab;
  final OlTour? tour;
  final VoidCallback? action;
}

/// "Ask Ol": greets by the time of day, answers with steps and "Take me there", finds places like the side menu's search, and starts
/// "Show me how". [context] is the page Ol sits on; places found are opened from it.
Future<OlPick?> showOlSheet(BuildContext context, {required String current, OlGuide guide = const OlGuide()}) {
  List<AppAction> places;
  try {
    places = appActions(context);
  } catch (_) {
    places = const [];
  }
  return showModalBottomSheet<OlPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (_) => _OlSheet(current: current, guide: guide, places: places),
  );
}

class _Msg {
  const _Msg(this.text, {this.mine = false, this.answer});
  final String text;
  final bool mine;
  final OlAnswer? answer;
}

class _OlSheet extends StatefulWidget {
  const _OlSheet({required this.current, required this.guide, required this.places});
  final String current;
  final OlGuide guide;
  final List<AppAction> places;
  @override
  State<_OlSheet> createState() => _OlSheetState();
}

class _OlSheetState extends State<_OlSheet> {
  final _ask = TextEditingController();
  final _scroll = ScrollController();
  late final _msgs = <_Msg>[_Msg(widget.guide.greeting(widget.current, DateTime.now()))];

  @override
  void initState() {
    super.initState();
    _ask.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ask.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String q) {
    final text = q.trim();
    if (text.isEmpty) return;
    final a = widget.guide.answer(text);
    setState(() {
      _msgs.add(_Msg(text, mine: true));
      _msgs.add(_Msg(a.text, answer: a));
      _ask.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final typed = _ask.text.trim();
    final quick = widget.guide.quickFor(widget.current);
    final tours = typed.isEmpty ? widget.guide.tours : widget.guide.toursFor(typed);
    // the app's own search, as in the side menu: every word in the title, the place or its words
    final places = typed.isEmpty ? const <AppAction>[] : (widget.places.where((a) => a.matches(typed)).toList()..sort((a, b) => a.rank(typed).compareTo(b.rank(typed)))).take(4).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(children: [
                const OlFace(height: 40, still: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Ask Ol'), style: inter(19, 800)),
                    Text(tr('Your helper · finds anything in the app'), style: inter(12.5, 400, color: kMuted)),
                  ]),
                ),
              ]),
            ),
            Flexible(
              child: ListView(
                key: const ValueKey('ol-chat'),
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [for (final m in _msgs) _bubbleFor(m)],
              ),
            ),
            // places in the app that match what is being typed
            for (final p in places)
              ListTile(
                key: ValueKey('ol-place-${p.title}'),
                dense: true,
                leading: Icon(p.icon, size: 20, color: kInk),
                title: Text(tr(p.title), style: inter(14, 700)),
                subtitle: Text(tr(p.where), style: inter(12, 400, color: kMuted)),
                trailing: const Icon(LucideIcons.chevronRight, size: 16, color: kMuted),
                onTap: () => Navigator.of(context).pop(OlPick(action: p.open)),
              ),
            // "Show me how": every walkthrough before anything is typed; the ones that match after
            if (typed.isNotEmpty)
              for (final t in tours)
                ListTile(
                  key: ValueKey('ol-show-${t.name}'),
                  dense: true,
                  leading: const Icon(LucideIcons.mousePointerClick, size: 20, color: OlFace.deep),
                  title: Text('${tr('Show me how')}: ${tr(t.name)}', style: inter(14, 700)),
                  subtitle: Text('${t.steps.length} ${tr('steps, on your screen')}', style: inter(12, 400, color: kMuted)),
                  onTap: () => Navigator.of(context).pop(OlPick(tour: t)),
                ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                if (typed.isEmpty)
                  for (final t in tours)
                    ActionChip(
                      key: ValueKey('ol-tour-${t.name}'),
                      avatar: const Icon(LucideIcons.mousePointerClick, size: 15, color: OlFace.deep),
                      label: Text(tr(t.name), style: inter(13, 600)),
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFCDEFA8)),
                      shape: const StadiumBorder(),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(OlPick(tour: t)),
                    ),
                for (final q in quick)
                  ActionChip(
                    key: ValueKey('ol-quick-${q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}'),
                    label: Text(tr(q), style: inter(13, 600)),
                    backgroundColor: const Color(0xFFF1FBE6),
                    side: const BorderSide(color: Color(0xFFCDEFA8)),
                    shape: const StadiumBorder(),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _send(q),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                key: const ValueKey('ol-ask'),
                controller: _ask,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                style: inter(15, 500),
                decoration: InputDecoration(
                  hintText: tr('Ask Ol… e.g. where do I split a bill?'),
                  hintStyle: inter(14, 400, color: kMuted),
                  filled: true,
                  fillColor: const Color(0xFFF4F5F1),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  suffixIcon: IconButton(key: const ValueKey('ol-send'), onPressed: () => _send(_ask.text), icon: const Icon(LucideIcons.sendHorizontal, color: OlFace.ink)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _bubbleFor(_Msg m) {
    final a = m.answer;
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: m.mine ? OlFace.ink : const Color(0xFFF4F5F1),
          // the corner nearest the one speaking is squared off
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(m.mine ? 18 : 4),
            bottomRight: Radius.circular(m.mine ? 4 : 18),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.mine ? m.text : tr(m.text), style: inter(14, m.mine ? 600 : 500, color: m.mine ? Colors.white : OlFace.ink, height: 1.4)),
          if (a != null && a.steps.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < a.steps.length; i++)
              Padding(padding: const EdgeInsets.only(top: 3), child: Text('${i + 1}. ${tr(a.steps[i])}', style: inter(13.5, 400, color: OlFace.ink, height: 1.35))),
          ],
          if (a?.tab != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              key: ValueKey('ol-go-${a!.tab}'),
              style: FilledButton.styleFrom(backgroundColor: OlFace.ink, shape: const StadiumBorder(), visualDensity: VisualDensity.compact),
              onPressed: () => Navigator.of(context).pop(OlPick(tab: a.tab)),
              icon: const Icon(LucideIcons.arrowRight, size: 16, color: OlFace.lime),
              label: Text('${tr('Take me there')} · ${tr(a.tab!)}', style: inter(13.5, 700, color: Colors.white)),
            ),
          ],
        ]),
      ),
    );
  }
}
