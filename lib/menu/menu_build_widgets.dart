import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';

const kMbLime = Color(0xFFA1FE2F);
const kMbGreenBg = Color(0xFFE9F9DC);
const kMbGreen = Color(0xFF15803D);
const kMbAmberBg = Color(0xFFFEF3C7);
const kMbAmber = Color(0xFFB45309);
const kMbRedBg = Color(0xFFFEE2E2);
const kMbRed = Color(0xFFB91C1C);

/// Colour of a food cost %: up to 35 healthy, up to 45 watch, above that too high (a common restaurant rule of thumb).
(Color, Color) foodCostTone(double? pct) => switch (pct) {
      null => (kField, kMuted),
      final p when p <= 35 => (kMbGreenBg, kMbGreen),
      final p when p <= 45 => (kMbAmberBg, kMbAmber),
      _ => (kMbRedBg, kMbRed),
    };

String pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}%';

/// The three sub-masters at the top of the Menu tab (founder sketch): Menu · Recipe · Ingredients.
class SubMasterTabs extends StatelessWidget {
  const SubMasterTabs({super.key, required this.labels, required this.selected, required this.onSelect});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                child: InkWell(
                  key: ValueKey('sub-master-${labels[i].toLowerCase()}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelect(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == selected ? kInk : kField,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: i == selected ? kInk : kFieldBorder),
                    ),
                    child: Text(labels[i], style: inter(14, 600, color: i == selected ? kMbLime : kInk)),
                  ),
                ),
              ),
            ),
          ],
        ]),
      );
}

/// A small figure tile of a summary row.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.tone});
  final String label, value;
  final (Color, Color)? tone;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: tone?.$1 ?? Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: inter(18, 700, color: tone?.$2 ?? kInk)),
            const SizedBox(height: 2),
            Text(label, maxLines: 2, style: inter(12, 500, color: kMuted)),
          ]),
        ),
      );
}

/// A row of filter chips. A few wrap (every chip on screen); many (more than six) scroll sideways on one line instead of stacking
/// into rows that push the list off the screen (founder, 29 Oct 2026).
class FilterChips extends StatelessWidget {
  const FilterChips({super.key, required this.items, required this.selected, required this.onSelect, this.keyPrefix = 'mb-chip'});
  final List<(String?, String)> items; // (value, label); null value = "All"
  final String? selected;
  final ValueChanged<String?> onSelect;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) {
    final chips = _chips();
    if (items.length <= 6) return Wrap(spacing: 8, runSpacing: 8, children: chips);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [for (final (i, c) in chips.indexed) ...[if (i > 0) const SizedBox(width: 8), c]]),
    );
  }

  List<Widget> _chips() => [
        for (final (v, label) in items)
          InkWell(
            key: ValueKey('$keyPrefix-${v ?? 'all'}'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => onSelect(v),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: v == selected ? kInk : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: v == selected ? kInk : kLine),
              ),
              child: Text(label, style: inter(13, v == selected ? 600 : 500, color: v == selected ? Colors.white : kInk)),
            ),
          ),
      ];
}

/// A rounded white card with an optional title.
class MbCard extends StatelessWidget {
  const MbCard({super.key, this.title, required this.child, this.trailing, this.padding = const EdgeInsets.all(14)});
  final String? title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;
  // A Material surface (not a decorated box), so list tiles and ink splashes inside draw on it.
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine)),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: padding,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(children: [Expanded(child: Text(title!, style: inter(15, 700))), ?trailing]),
                ),
              child,
            ]),
          ),
        ),
      );
}

/// A rounded white row surface for list tiles and tappable rows.
class MbRowSurface extends StatelessWidget {
  const MbRowSurface({super.key, required this.child, this.radius = 14, this.margin = const EdgeInsets.only(bottom: 8)});
  final Widget child;
  final double radius;
  final EdgeInsets margin;
  @override
  Widget build(BuildContext context) => Padding(
        padding: margin,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: const BorderSide(color: kLine)),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      );
}

/// A labelled text field in the app's field style.
class MbField extends StatelessWidget {
  const MbField({super.key, required this.label, required this.controller, this.hint, this.number = false, this.decimals = true, this.prefix, this.suffix, this.fieldKey, this.onChanged, this.maxLength});
  final String label;
  final TextEditingController controller;
  final String? hint, prefix, suffix;
  final bool number, decimals;
  final Key? fieldKey;
  final ValueChanged<String>? onChanged;
  final int? maxLength;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          TextField(
            key: fieldKey,
            controller: controller,
            onChanged: onChanged,
            maxLength: maxLength,
            keyboardType: number ? TextInputType.numberWithOptions(decimal: decimals) : TextInputType.text,
            inputFormatters: number ? [FilteringTextInputFormatter.allow(RegExp(decimals ? r'[0-9.]' : r'[0-9]'))] : null,
            style: inter(15, 500),
            decoration: InputDecoration(
              hintText: hint,
              counterText: '',
              prefixText: prefix,
              suffixText: suffix,
              isDense: true,
              filled: true,
              fillColor: kField,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kFieldBorder)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kFieldBorder)),
            ),
          ),
        ]),
      );
}

/// Choose one of a few options (veg / non-veg / egg, eat / drink, unit…).
class MbSegments extends StatelessWidget {
  const MbSegments({super.key, required this.label, required this.options, required this.value, required this.onChanged, this.keyPrefix = 'seg'});
  final String label;
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (v, l) in options)
              ChoiceChip(
                key: ValueKey('$keyPrefix-$v'),
                label: Text(l, style: inter(13, 600, color: v == value ? Colors.white : kInk)),
                selected: v == value,
                showCheckmark: false,
                selectedColor: kInk,
                backgroundColor: Colors.white,
                side: BorderSide(color: v == value ? kInk : kLine),
                onSelected: (_) => onChanged(v),
              ),
          ]),
        ]),
      );
}

/// The dark full-width action at the bottom of an editor.
class MbPrimaryButton extends StatelessWidget {
  const MbPrimaryButton(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 50,
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kInk, disabledBackgroundColor: kMuted, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: busy ? null : onPressed,
          child: Text(busy ? 'Saving…' : label, style: inter(15, 700, color: kMbLime)),
        ),
      );
}

/// A centred "nothing here yet" with an action.
class MbEmpty extends StatelessWidget {
  const MbEmpty({super.key, required this.icon, required this.title, required this.body, this.action, this.onAction});
  final IconData icon;
  final String title, body;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        child: Column(children: [
          Container(width: 64, height: 64, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: Icon(icon, color: kLink, size: 28)),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: inter(16, 700)),
          const SizedBox(height: 4),
          Text(body, textAlign: TextAlign.center, style: inter(13, 400, color: kMuted, height: 1.4)),
          if (action != null) ...[const SizedBox(height: 14), OutlinedButton(onPressed: onAction, child: Text(action!, style: inter(14, 600)))],
        ]),
      );
}

/// Parses "12.5" (or "") into a number; null when empty or not a number.
double? numOf(String s) => double.tryParse(s.trim());
