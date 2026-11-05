import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../storefront/section_editors.dart' show SfImagePicker;
import '../storefront/sf_widgets.dart';
import '../ui/theme.dart';
import 'experience_api.dart';
import 'experience_screen.dart' show ExperienceController;

// The editor sheet of each block and the colour sheet. A sheet pops with the changed block (the screen saves it as the draft) or null.
// The limits are the database's (gx__clean); checking them here only spares the restaurant a refused save.

/// Opens the editor of [b]; answers the changed block, or null when nothing was saved.
Future<GxBlock?> editBlock(BuildContext context, GxBlock b, ExperienceController c) => showModalBottomSheet<GxBlock>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => switch (b.type) {
        'welcome' => _WelcomeEditor(b: b, c: c),
        'order_mode' => _OrderModeEditor(b: b),
        'budget' => _BudgetEditor(b: b),
        'swipe' => _SwipeEditor(b: b),
        'highlights' => _HighlightsEditor(b: b, dishes: c.dishes),
        'preorder' => _PreorderEditor(b: b),
        'tracking' => _TrackingEditor(b: b),
        'bill' => _BillEditor(b: b),
        _ => GxSheet(title: b.label, children: [Text('Your menu categories show as a grid of tiles. There is nothing else to set here.', style: inter(14, 400, color: kMuted))]),
      },
    );

/// Sheet frame: grabber, title, a line under it, scrolling fields, an optional error line and the Save button.
class GxSheet extends StatelessWidget {
  const GxSheet({super.key, required this.title, this.sub, required this.children, this.onSave, this.error, this.saveLabel = 'Save'});
  final String title;
  final String? sub, error;
  final List<Widget> children;
  final VoidCallback? onSave;
  final String saveLabel;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 10),
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(19, 800)),
                if (sub != null) Text(sub!, style: inter(13, 500, color: kMuted)),
              ]),
            ),
            Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), children: children)),
            if (error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(error!, key: const ValueKey('gx-sheet-error'), style: inter(13.5, 600, color: kError))),
            if (onSave != null || error != null)
              Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 14), child: SfSave(saveLabel, key: const ValueKey('gx-sheet-save'), onPressed: onSave)),
          ]),
        ),
      );
}

/// A note that says when a change waits for OneLocal (so the restaurant is not surprised).
class GxReviewNote extends StatelessWidget {
  const GxReviewNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.shieldCheck, size: 17, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: inter(13, 500, height: 1.35))),
        ]),
      );
}

String? _textError(Map<String, String> fields) {
  for (final e in fields.entries) {
    if (!gxTextOk(e.value)) return '${e.key} cannot contain < or >.';
  }
  return null;
}

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay _time(String? hhmm, TimeOfDay fallback) {
  final p = (hhmm ?? '').split(':');
  final h = p.isNotEmpty ? int.tryParse(p[0]) : null, m = p.length > 1 ? int.tryParse(p[1]) : null;
  return h == null || m == null ? fallback : TimeOfDay(hour: h, minute: m);
}

/// "Opens 09:00 [change]": a row that opens the time picker.
class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.label, required this.value, required this.onChanged, this.onClear});
  final String label;
  final String? value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: inter(16, 400))),
          if (value != null && onClear != null) IconButton(tooltip: 'Clear $label', onPressed: onClear, icon: const Icon(LucideIcons.x, size: 18)),
          OutlinedButton(
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: _time(value, const TimeOfDay(hour: 12, minute: 0)));
              if (t != null) onChanged(_hhmm(t));
            },
            child: Text(value == null ? 'Set time' : clock12(value!), style: inter(14, 700)),
          ),
        ]),
      );
}

// ------------------------------------------------------------------------------------------------ welcome

class _WelcomeEditor extends StatefulWidget {
  const _WelcomeEditor({required this.b, required this.c});
  final GxBlock b;
  final ExperienceController c;
  @override
  State<_WelcomeEditor> createState() => _WelcomeEditorState();
}

class _WelcomeEditorState extends State<_WelcomeEditor> {
  late final p = widget.b.props;
  late final headline = TextEditingController(text: '${p['headline'] ?? ''}');
  late final subtext = TextEditingController(text: '${p['subtext'] ?? ''}');
  late final cta = TextEditingController(text: '${p['cta_label'] ?? ''}');
  late String? image = p['image_id'] as String?;

  @override
  void dispose() {
    headline.dispose();
    subtext.dispose();
    cta.dispose();
    super.dispose();
  }

  String? get _error {
    if (headline.text.trim().isEmpty) return 'Write a headline.';
    if (cta.text.trim().isEmpty) return 'Write the button text.';
    return _textError({'The headline': headline.text, 'The welcome line': subtext.text, 'The button': cta.text});
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return GxSheet(
      title: 'Welcome screen',
      sub: 'The first thing a guest sees after scanning',
      error: err,
      onSave: err != null
          ? null
          : () => Navigator.of(context).pop(widget.b.withProps({
                ...p,
                'headline': headline.text.trim(),
                'subtext': subtext.text.trim().isEmpty ? null : subtext.text.trim(),
                'cta_label': cta.text.trim(),
                'image_id': image,
              })),
      children: [
        const SfLabel('Headline', top: 8),
        SfField(key: const ValueKey('gx-headline'), controller: headline, maxLength: 60, hint: 'Food looks better when you explore it.', onChanged: (_) => setState(() {})),
        const SfLabel('Welcome line', top: 8),
        SfField(key: const ValueKey('gx-subtext'), controller: subtext, maxLength: 140, lines: 3, hint: 'One or two lines about your place', onChanged: (_) => setState(() {})),
        const SfLabel('Button', top: 8),
        SfField(key: const ValueKey('gx-cta'), controller: cta, maxLength: 24, hint: 'Start exploring', onChanged: (_) => setState(() {})),
        const SfLabel('Picture'),
        SfImagePicker(c: widget.c.images, kind: 'banner', selectedId: image, onChanged: (v) => setState(() => image = v)),
        if (image != null) ...[const SizedBox(height: 10), SfSoft('No picture', icon: LucideIcons.imageOff, onPressed: () => setState(() => image = null))],
        const GxReviewNote('New wording is read by OneLocal\'s AI in a few seconds. Prices, offers, phone numbers or links in the text go to a OneLocal person first.'),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ order mode

class _OrderModeEditor extends StatefulWidget {
  const _OrderModeEditor({required this.b});
  final GxBlock b;
  @override
  State<_OrderModeEditor> createState() => _OrderModeEditorState();
}

class _OrderModeEditorState extends State<_OrderModeEditor> {
  late final p = widget.b.props;
  late bool dine = p['dine_in'] != false, pre = p['pre_order'] == true;
  late final dineLabel = TextEditingController(text: '${p['dine_in_label'] ?? 'Dine-in'}');
  late final preLabel = TextEditingController(text: '${p['pre_order_label'] ?? 'Pre-order'}');

  @override
  void dispose() {
    dineLabel.dispose();
    preLabel.dispose();
    super.dispose();
  }

  String? get _error {
    if (!dine && !pre) return 'Offer dine-in, pre-order or both.';
    if (dineLabel.text.trim().isEmpty || preLabel.text.trim().isEmpty) return 'Write both labels.';
    return _textError({'The dine-in label': dineLabel.text, 'The pre-order label': preLabel.text});
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return GxSheet(
      title: 'Dine-in or pre-order',
      sub: 'How guests can order from your page',
      error: err,
      onSave: err != null
          ? null
          : () => Navigator.of(context).pop(widget.b.withProps({...p, 'dine_in': dine, 'pre_order': pre, 'dine_in_label': dineLabel.text.trim(), 'pre_order_label': preLabel.text.trim()})),
      children: [
        // the last mode that is on cannot be switched off: a page needs one way to order
        SfToggle(title: 'Dine-in', sub: 'Order at the table from the QR code', value: dine, onChanged: dine && !pre ? null : (v) => setState(() => dine = v)),
        SfToggle(title: 'Pre-order', sub: 'Pick a day and time, collect at the counter', value: pre, onChanged: pre && !dine ? null : (v) => setState(() => pre = v)),
        const SfLabel('Dine-in label', top: 8),
        SfField(controller: dineLabel, maxLength: 24, hint: 'Dine-in', onChanged: (_) => setState(() {})),
        const SfLabel('Pre-order label', top: 8),
        SfField(controller: preLabel, maxLength: 24, hint: 'Pre-order', onChanged: (_) => setState(() {})),
        const GxReviewNote('Switching dine-in or pre-order on or off goes to OneLocal review before guests see it.'),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ budget

class _BudgetEditor extends StatefulWidget {
  const _BudgetEditor({required this.b});
  final GxBlock b;
  @override
  State<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<_BudgetEditor> {
  late final p = widget.b.props;
  late final min = TextEditingController(text: '${p['min'] ?? 500}');
  late final max = TextEditingController(text: '${p['max'] ?? 20000}');
  late final def = TextEditingController(text: '${p['default'] ?? 2000}');
  late bool split = p['split'] != false;

  @override
  void dispose() {
    min.dispose();
    max.dispose();
    def.dispose();
    super.dispose();
  }

  int? _n(TextEditingController c) => int.tryParse(c.text.trim());

  String? get _error {
    final lo = _n(min), hi = _n(max), d = _n(def);
    if (lo == null || hi == null || d == null) return 'Use whole rupees.';
    if ([lo, hi, d].any((v) => v < 100 || v > 100000)) return 'Budgets go from ₹100 to ₹1,00,000.';
    if (lo >= hi) return 'The lowest budget must be below the highest.';
    if (d < lo || d > hi) return 'The starting budget must sit between the lowest and the highest.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return GxSheet(
      title: 'Table budget',
      sub: 'Guests set a budget and watch it fill as they add dishes',
      error: err,
      onSave: err != null ? null : () => Navigator.of(context).pop(widget.b.withProps({...p, 'min': _n(min), 'max': _n(max), 'default': _n(def), 'split': split})),
      children: [
        const SfLabel('Lowest budget', top: 8),
        SfField(key: const ValueKey('gx-budget-min'), controller: min, number: true, prefix: '₹ ', onChanged: (_) => setState(() {})),
        const SfLabel('Highest budget'),
        SfField(key: const ValueKey('gx-budget-max'), controller: max, number: true, prefix: '₹ ', onChanged: (_) => setState(() {})),
        const SfLabel('Starting budget'),
        SfField(key: const ValueKey('gx-budget-default'), controller: def, number: true, prefix: '₹ ', onChanged: (_) => setState(() {})),
        const SizedBox(height: 8),
        SfToggle(title: 'Split between people', sub: 'Shows the amount per person', value: split, onChanged: (v) => setState(() => split = v)),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ swipe

class _SwipeEditor extends StatefulWidget {
  const _SwipeEditor({required this.b});
  final GxBlock b;
  @override
  State<_SwipeEditor> createState() => _SwipeEditorState();
}

class _SwipeEditorState extends State<_SwipeEditor> {
  late final p = widget.b.props;
  late String style = '${p['card_style'] ?? 'stack'}';
  late bool ring = p['budget_ring'] != false;

  @override
  Widget build(BuildContext context) => GxSheet(
        title: 'Swipe deck',
        sub: 'Dishes as cards: swipe right to add',
        onSave: () => Navigator.of(context).pop(widget.b.withProps({...p, 'card_style': style, 'budget_ring': ring})),
        children: [
          const SfLabel('Cards', top: 8),
          SfChoice<String>(options: const [('stack', 'Stacked', LucideIcons.layers), ('full', 'Full screen', LucideIcons.maximize)], value: style, tall: true, onChanged: (v) => setState(() => style = v)),
          const SizedBox(height: 8),
          SfToggle(title: 'Budget ring', sub: 'How much of the budget is used, at the top', value: ring, onChanged: (v) => setState(() => ring = v)),
        ],
      );
}

// ------------------------------------------------------------------------------------------------ highlights

class _HighlightsEditor extends StatefulWidget {
  const _HighlightsEditor({required this.b, required this.dishes});
  final GxBlock b;
  final List<Facts> dishes;
  @override
  State<_HighlightsEditor> createState() => _HighlightsEditorState();
}

class _HighlightsEditorState extends State<_HighlightsEditor> {
  late final p = widget.b.props;
  late final picksTitle = TextEditingController(text: '${p['picks_title'] ?? "Chef's picks"}');
  late final limitedTitle = TextEditingController(text: '${p['limited_title'] ?? 'Limited today'}');
  late List<String> picks = [for (final i in (p['pick_ids'] as List?) ?? const []) '$i'];
  late List<String> limited = [for (final i in (p['limited_ids'] as List?) ?? const []) '$i'];
  late String? until = p['limited_until'] as String?;

  @override
  void dispose() {
    picksTitle.dispose();
    limitedTitle.dispose();
    super.dispose();
  }

  String? get _error {
    if (picksTitle.text.trim().isEmpty || limitedTitle.text.trim().isEmpty) return 'Write both titles.';
    return _textError({'The picks title': picksTitle.text, 'The limited title': limitedTitle.text});
  }

  Widget _chosen(String key, List<String> ids, String title, ValueChanged<List<String>> onChanged) {
    final names = {for (final d in widget.dishes) d.s('id'): d.s('name')};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (ids.isEmpty) Text('No dishes chosen yet.', style: inter(13.5, 400, color: kMuted)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final id in ids) Chip(label: Text(names[id] ?? 'A dish no longer on the menu', style: inter(13, 600)), onDeleted: () => onChanged([...ids]..remove(id))),
      ]),
      const SizedBox(height: 8),
      SfSoft('Choose dishes (${ids.length}/8)', key: ValueKey(key), icon: LucideIcons.listChecks, onPressed: () async {
        final out = await chooseDishes(context, dishes: widget.dishes, chosen: ids, title: title);
        if (out != null) onChanged(out);
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return GxSheet(
      title: "Chef's picks & limited today",
      sub: 'Up to 8 dishes in each row. Prices come from your menu.',
      error: err,
      onSave: err != null
          ? null
          : () => Navigator.of(context).pop(widget.b.withProps({
                ...p,
                'picks_title': picksTitle.text.trim(),
                'pick_ids': picks,
                'limited_title': limitedTitle.text.trim(),
                'limited_ids': limited,
                'limited_until': until,
              })),
      children: [
        const SfLabel('First row title', top: 8),
        SfField(controller: picksTitle, maxLength: 30, hint: "Chef's picks", onChanged: (_) => setState(() {})),
        _chosen('gx-choose-picks', picks, picksTitle.text.trim().isEmpty ? "Chef's picks" : picksTitle.text.trim(), (v) => setState(() => picks = v)),
        const SfLabel('Second row title'),
        SfField(controller: limitedTitle, maxLength: 30, hint: 'Limited today', onChanged: (_) => setState(() {})),
        _chosen('gx-choose-limited', limited, limitedTitle.text.trim().isEmpty ? 'Limited today' : limitedTitle.text.trim(), (v) => setState(() => limited = v)),
        const SizedBox(height: 8),
        _TimeRow(label: 'Ends today at', value: until, onChanged: (v) => setState(() => until = v), onClear: () => setState(() => until = null)),
      ],
    );
  }
}

/// The dishes of the menu with a tick each; at most [limit] can be ticked. Answers the ticked ids in menu order, or null.
Future<List<String>?> chooseDishes(BuildContext context, {required List<Facts> dishes, required List<String> chosen, required String title, int limit = 8}) =>
    showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _DishChooser(dishes: dishes, chosen: chosen, title: title, limit: limit),
    );

class _DishChooser extends StatefulWidget {
  const _DishChooser({required this.dishes, required this.chosen, required this.title, required this.limit});
  final List<Facts> dishes;
  final List<String> chosen;
  final String title;
  final int limit;
  @override
  State<_DishChooser> createState() => _DishChooserState();
}

class _DishChooserState extends State<_DishChooser> {
  late final Set<String> on = {...widget.chosen};

  @override
  Widget build(BuildContext context) {
    final full = on.length >= widget.limit;
    return GxSheet(
      title: widget.title,
      sub: '${on.length} of ${widget.limit} chosen',
      saveLabel: 'Done',
      onSave: () => Navigator.of(context).pop([
        for (final d in widget.dishes)
          if (on.contains(d.s('id'))) d.s('id'),
      ]),
      children: [
        if (widget.dishes.isEmpty) Text('No dishes on your menu are available right now.', style: inter(14, 400, color: kMuted)),
        for (final d in widget.dishes)
          CheckboxListTile(
            key: ValueKey('gx-dish-${d.s('id')}'),
            contentPadding: EdgeInsets.zero,
            value: on.contains(d.s('id')),
            onChanged: !on.contains(d.s('id')) && full ? null : (v) => setState(() => v == true ? on.add(d.s('id')) : on.remove(d.s('id'))),
            secondary: SfThumb(d.so('image_url'), size: 44, radius: 10),
            title: Text(d.s('name'), style: inter(15, 600)),
            subtitle: Text(gxPrice(d.no('price')), style: inter(13, 400, color: kMuted)),
          ),
      ],
    );
  }
}

/// A menu price (rupees, as menu_items.price) as "₹260" or "₹260.50".
String gxPrice(num? v) => v == null ? '' : '₹${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(2)}';

// ------------------------------------------------------------------------------------------------ pre-order

class _PreorderEditor extends StatefulWidget {
  const _PreorderEditor({required this.b});
  final GxBlock b;
  @override
  State<_PreorderEditor> createState() => _PreorderEditorState();
}

class _PreorderEditorState extends State<_PreorderEditor> {
  late final p = widget.b.props;
  late int days = (p['days_ahead'] as num?)?.toInt() ?? 5;
  late int slot = (p['slot_minutes'] as num?)?.toInt() ?? 30;
  late String opens = '${p['opens'] ?? '09:00'}', closes = '${p['closes'] ?? '21:00'}';
  late final lead = TextEditingController(text: '${p['lead_minutes'] ?? 30}');
  late final hint = TextEditingController(text: '${p['note_hint'] ?? ''}');

  @override
  void dispose() {
    lead.dispose();
    hint.dispose();
    super.dispose();
  }

  String? get _error {
    if (opens.compareTo(closes) >= 0) return 'Pre-orders must open before they close.';
    final l = int.tryParse(lead.text.trim());
    if (l == null || l < 0 || l > 240) return 'Time to prepare is 0 to 240 minutes.';
    return _textError({'The note hint': hint.text});
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return GxSheet(
      title: 'Pre-order slots',
      sub: 'When guests can pick up what they order ahead',
      error: err,
      onSave: err != null
          ? null
          : () => Navigator.of(context).pop(widget.b.withProps({
                ...p,
                'days_ahead': days,
                'slot_minutes': slot,
                'opens': opens,
                'closes': closes,
                'lead_minutes': int.parse(lead.text.trim()),
                'note_hint': hint.text.trim().isEmpty ? null : hint.text.trim(),
              })),
      children: [
        Row(children: [
          Expanded(child: Text('Days ahead', style: inter(16, 400))),
          IconButton(tooltip: 'Fewer days', onPressed: days > 1 ? () => setState(() => days--) : null, icon: const Icon(LucideIcons.minus, size: 18)),
          Text('$days', key: const ValueKey('gx-days'), style: inter(16, 800)),
          IconButton(tooltip: 'More days', onPressed: days < 14 ? () => setState(() => days++) : null, icon: const Icon(LucideIcons.plus, size: 18)),
        ]),
        const SfLabel('Time slots', top: 8),
        SfChoice<int>(options: const [(15, '15 min', null), (30, '30 min', null), (60, '1 hour', null)], value: slot, onChanged: (v) => setState(() => slot = v)),
        const SizedBox(height: 8),
        _TimeRow(label: 'First pickup', value: opens, onChanged: (v) => setState(() => opens = v)),
        _TimeRow(label: 'Last pickup', value: closes, onChanged: (v) => setState(() => closes = v)),
        const SfLabel('Time to prepare (minutes)'),
        SfField(controller: lead, number: true, onChanged: (_) => setState(() {})),
        const SfLabel('Note hint', top: 8),
        SfField(controller: hint, maxLength: 60, hint: 'e.g. pack separately, birthday message', onChanged: (_) => setState(() {})),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ tracking, bill

class _TrackingEditor extends StatefulWidget {
  const _TrackingEditor({required this.b});
  final GxBlock b;
  @override
  State<_TrackingEditor> createState() => _TrackingEditorState();
}

class _TrackingEditorState extends State<_TrackingEditor> {
  late bool eta = widget.b.props['show_eta'] != false;
  @override
  Widget build(BuildContext context) => GxSheet(
        title: 'Order tracking',
        sub: 'What guests see after they order',
        onSave: () => Navigator.of(context).pop(widget.b.withProps({...widget.b.props, 'show_eta': eta})),
        children: [
          SfToggle(title: 'Show the expected time', sub: 'e.g. 15 – 20 minutes', value: eta, onChanged: (v) => setState(() => eta = v)),
          const GxReviewNote('Turning the expected time off goes to OneLocal review.'),
        ],
      );
}

class _BillEditor extends StatefulWidget {
  const _BillEditor({required this.b});
  final GxBlock b;
  @override
  State<_BillEditor> createState() => _BillEditorState();
}

class _BillEditorState extends State<_BillEditor> {
  late bool split = widget.b.props['split'] != false, feedback = widget.b.props['feedback'] != false;
  @override
  Widget build(BuildContext context) => GxSheet(
        title: 'Bill & feedback',
        sub: 'The end of the visit',
        onSave: () => Navigator.of(context).pop(widget.b.withProps({...widget.b.props, 'split': split, 'feedback': feedback})),
        children: [
          SfToggle(title: 'Split bill', value: split, onChanged: (v) => setState(() => split = v)),
          SfToggle(title: 'Ask for feedback', value: feedback, onChanged: (v) => setState(() => feedback = v)),
          const GxReviewNote('Turning split bill or feedback off goes to OneLocal review.'),
        ],
      );
}

// ------------------------------------------------------------------------------------------------ colours

/// The six colours and the font. Answers the new theme, or null.
Future<Map<String, String>?> editColours(BuildContext context, Map<String, String> theme) => showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _ColourSheet(theme: theme),
    );

class _ColourSheet extends StatefulWidget {
  const _ColourSheet({required this.theme});
  final Map<String, String> theme;
  @override
  State<_ColourSheet> createState() => _ColourSheetState();
}

class _ColourSheetState extends State<_ColourSheet> {
  static final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');
  late final ctl = {for (final (k, _) in gxColourKeys) k: TextEditingController(text: widget.theme[k] ?? '')};
  late String font = widget.theme['font'] == 'serif' ? 'serif' : 'sans';

  @override
  void dispose() {
    for (final c in ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid => ctl.values.every((c) => _hex.hasMatch(c.text.trim()));

  Widget _row(String key, String label) {
    final c = ctl[key]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(child: Text(label, style: inter(16, 400))),
        SizedBox(
          width: 170,
          child: TextField(
            key: ValueKey('gx-colour-$key'),
            controller: c,
            onChanged: (_) => setState(() {}),
            style: inter(15, 400, color: kMuted),
            decoration: InputDecoration(
              filled: true,
              fillColor: kSfField,
              isDense: true,
              prefixIcon: Padding(padding: const EdgeInsets.all(10), child: Container(width: 22, height: 22, decoration: BoxDecoration(color: hexColor(c.text.trim()), shape: BoxShape.circle, border: Border.all(color: kLine)))),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              errorText: _hex.hasMatch(c.text.trim()) ? null : 'Use #RRGGBB',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => GxSheet(
        title: 'Colours & font',
        sub: 'Colour changes go live as soon as you publish',
        error: _valid ? null : 'Every colour is # and six letters or numbers, like #F5B83D.',
        onSave: _valid ? () => Navigator.of(context).pop({for (final e in ctl.entries) e.key: e.value.text.trim().toUpperCase(), 'font': font}) : null,
        children: [
          const SizedBox(height: 8),
          for (final (k, label) in gxColourKeys) _row(k, label),
          const SfLabel('Font', top: 4),
          SfChoice<String>(options: const [('sans', 'Clean (sans)', null), ('serif', 'Classic (serif)', null)], value: font, onChanged: (v) => setState(() => font = v)),
        ],
      );
}
