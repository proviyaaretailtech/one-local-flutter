import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../states/state_kit.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'storefront_api.dart';

// Shared pieces of the storefront screens (section M, Figma assets/figma_ref_m). Colours come from the exported frames: lime #76EC00 for the
// selected state and the Publish button, black for the main button, soft grey fields. Nothing here decides anything; the database does.
const kSfLime = Color(0xFF76EC00);
const kSfLimeSoft = Color(0xFFE6FAC9);
const kSfLimeLine = Color(0xFF8BE03A);
const kSfField = Color(0xFFF3F4F1);

/// A person-readable sentence for any failure (the server's own sentence when it sent one).
String sfMessage(Object e) => e is StorefrontException ? e.message : (e is Exception && e.toString().contains('SocketException') ? 'No connection. Check your internet and try again.' : 'Something went wrong. Please try again.');

/// Page frame: round white back button, title (+ optional subtitle), scrolling body, optional pinned bottom area.
class SfPage extends StatelessWidget {
  const SfPage({super.key, required this.title, this.subtitle, required this.children, this.bottom, this.trailing, this.onBack, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24)});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? bottom, trailing;
  final VoidCallback? onBack;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: Column(children: [
            // the banner (☰ always), with the one back arrow, the page's line and its action under it
            AppHeader(
              title: title,
              safeTop: false,
              back: true,
              onBack: onBack,
              under: subtitle == null && trailing == null
                  ? null
                  : Row(children: [
                      Expanded(child: Text(subtitle ?? '', style: inter(13, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ?trailing,
                    ]),
            ),
            Expanded(child: ListView(padding: padding, children: children)),
            if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 14), child: bottom),
          ]),
        ),
      );
}

class SfLabel extends StatelessWidget {
  const SfLabel(this.text, {super.key, this.top = 18});
  final String text;
  final double top;
  @override
  Widget build(BuildContext context) => Padding(padding: EdgeInsets.only(top: top, bottom: 8), child: Text(text, style: inter(16, 700)));
}

/// White rounded card (a row, a group of settings).
class SfCard extends StatelessWidget {
  const SfCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(14), this.selected = false});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final bool selected;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: const Color(0xFFFAFBF8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: selected ? kSfLimeLine : kLine, width: selected ? 1.5 : 1)),
          child: InkWell(customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), onTap: onTap, child: Padding(padding: padding, child: child)),
        ),
      );
}

/// Text box with the grey field look, an optional "n/max" counter under it.
class SfField extends StatefulWidget {
  const SfField({super.key, required this.controller, this.hint, this.maxLength, this.number = false, this.prefix, this.lines = 1, this.onChanged, this.label, this.enabled = true});
  final TextEditingController controller;
  final String? hint, prefix, label;
  final int? maxLength;
  final bool number, enabled;
  final int lines;
  final ValueChanged<String>? onChanged;
  @override
  State<SfField> createState() => _SfFieldState();
}

class _SfFieldState extends State<SfField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  void _tick() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      maxLines: widget.lines,
      minLines: widget.lines,
      onChanged: widget.onChanged,
      keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true) : (widget.lines > 1 ? TextInputType.multiline : TextInputType.text),
      inputFormatters: [if (widget.number) FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')), if (widget.maxLength != null) LengthLimitingTextInputFormatter(widget.maxLength)],
      style: inter(16, 400),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: inter(16, 400, color: kMuted),
        prefixText: widget.prefix,
        prefixStyle: inter(16, 500),
        semanticCounterText: widget.label,
        filled: true,
        fillColor: const Color(0xFFFAFBF8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      field,
      if (widget.maxLength != null)
        Padding(padding: const EdgeInsets.only(top: 6, right: 4), child: Text('${widget.controller.text.length}/${widget.maxLength}', textAlign: TextAlign.right, style: inter(12, 400, color: kMuted))),
    ]);
  }
}

/// "Show Ratings  [switch]" row; [sub] is the muted line under the title.
class SfToggle extends StatelessWidget {
  const SfToggle({super.key, required this.title, this.sub, required this.value, required this.onChanged});
  final String title;
  final String? sub;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(16, 400)),
              if (sub != null) Text(sub!, style: inter(13, 400, color: kMuted)),
            ]),
          ),
          Semantics(
            label: title,
            toggled: value,
            child: Switch(value: value, onChanged: onChanged, activeThumbColor: Colors.white, activeTrackColor: kSfLime, inactiveTrackColor: const Color(0xFFD1D5DB), inactiveThumbColor: Colors.white, trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent)),
          ),
        ]),
      );
}

/// Row of equal tiles, one selected (Layout style: Grid / Horizontal Scroll / List; Columns: 2 / 3 / 4; Rounded / Square).
class SfChoice<T> extends StatelessWidget {
  const SfChoice({super.key, required this.options, required this.value, required this.onChanged, this.tall = false});
  final List<(T, String, IconData?)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool tall;
  @override
  Widget build(BuildContext context) => Row(children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              button: true,
              selected: options[i].$1 == value,
              label: options[i].$2,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onChanged(options[i].$1),
                child: Container(
                  height: tall ? 76 : 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: options[i].$1 == value ? kSfLimeSoft : kSfField,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: options[i].$1 == value ? kSfLimeLine : Colors.transparent, width: 1.5),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (options[i].$3 != null) ...[Icon(options[i].$3, size: 22, color: options[i].$1 == value ? kInk : kMuted), const SizedBox(height: 6)],
                    Text(options[i].$2, textAlign: TextAlign.center, style: inter(options[i].$3 != null ? 12.5 : 15, options[i].$1 == value ? 700 : 500, color: options[i].$1 == value ? kInk : kMuted)),
                  ]),
                ),
              ),
            ),
          ),
        ],
      ]);
}

/// Picture box: the signed link when there is one, a neutral placeholder otherwise (a link may be missing or expired).
class SfThumb extends StatelessWidget {
  const SfThumb(this.url, {super.key, this.size = 56, this.radius = 12, this.width, this.icon = LucideIcons.image});
  final String? url;
  final double size, radius;
  final double? width;
  final IconData icon;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: width ?? size,
          height: size,
          child: url == null || url!.isEmpty
              ? Container(color: const Color(0xFFFFF4B8), child: Icon(icon, size: size * 0.4, color: kMuted))
              : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: const Color(0xFFFFF4B8), child: Icon(icon, size: size * 0.4, color: kMuted))),
        ),
      );
}

/// Main black button of the forms (Figma "Save"), busy-aware.
class SfSave extends StatelessWidget {
  const SfSave(this.label, {super.key, required this.onPressed, this.busy = false, this.lime = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy, lime;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null && !busy ? 0.5 : 1,
        child: Material(
          color: lime ? kSfLime : const Color(0xFF0A0A0A),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : onPressed,
            child: SizedBox(
              height: 54,
              width: double.infinity,
              child: Center(
                child: busy
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: lime ? kInk : Colors.white))
                    : Text(label, style: inter(16, 700, color: lime ? kInk : Colors.white)),
              ),
            ),
          ),
        ),
      );
}

/// Light grey button ("Change Image", "Edit", "Back to Builder").
class SfSoft extends StatelessWidget {
  const SfSoft(this.label, {super.key, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Material(
        color: kSfField,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: SizedBox(
            height: 50,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: 18, color: kInk), const SizedBox(width: 8)],
              Text(label, style: inter(15, 700)),
            ]),
          ),
        ),
      );
}

/// Green confirmation strip ("Your storefront will show: Open daily, 9 AM – 9 PM.").
class SfNote extends StatelessWidget {
  const SfNote(this.text, {super.key, this.icon = LucideIcons.circleCheck});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kSfLimeSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: kInk),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: inter(14, 400, height: 1.35))),
        ]),
      );
}

/// Loads once, shows a spinner, the server's sentence with "Try again", or the content. [reload] refetches.
class SfLoader<T> extends StatefulWidget {
  const SfLoader({super.key, required this.load, required this.builder});
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  @override
  State<SfLoader<T>> createState() => _SfLoaderState<T>();
}

class _SfLoaderState<T> extends State<SfLoader<T>> {
  T? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final d = await widget.load();
      if (mounted) setState(() { _data = d; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = sfMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data != null) return widget.builder(context, _data as T, _run);
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: StatusCard(icon: LucideIcons.cloudOff, title: 'Could not load this', body: _error!, primaryLabel: 'Try again', onPrimary: () { setState(() => _error = null); _run(); }),
      );
    }
    return const Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator(color: kInk)));
  }
}

String rs(num? minor) => minor == null ? '—' : '₹${(minor / 100) == (minor / 100).roundToDouble() ? (minor / 100).round() : (minor / 100).toStringAsFixed(2)}';

/// "9:00 AM" from "09:00".
String clock12(String hhmm) {
  final p = hhmm.split(':');
  if (p.length < 2) return hhmm;
  final h = int.tryParse(p[0]) ?? 0;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${p[1]} ${h < 12 ? 'AM' : 'PM'}';
}

/// Shows a failure as a toast, except a version conflict, which gets a clear sentence the caller can act on.
void sfToast(BuildContext context, Object e) => showToast(context, sfMessage(e));

const kWeekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Money text field value ("30" rupees) -> paise, or null for empty.
int? paise(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final d = double.tryParse(t);
  return d == null ? null : (d * 100).round();
}

String rupeeText(num? minor) => minor == null ? '' : ((minor / 100) == (minor / 100).roundToDouble() ? '${(minor / 100).round()}' : (minor / 100).toStringAsFixed(2));

/// Hex colour text ("#76EC00") to a colour; the grey for anything else.
Color hexColor(String? h) {
  final m = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(h ?? '');
  return m == null ? kLine : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

/// "Open daily · 9 AM – 9 PM" or "Mon–Sat 9 AM – 9 PM · Sun closed" from the server's seven day rows (day 1 = Monday).
String hoursSummary(List<Map<String, dynamic>> days) {
  if (days.isEmpty) return '';
  String span(Map<String, dynamic> d) => '${clock12('${d['opens']}')} – ${clock12('${d['closes']}')}';
  final open = days.where((d) => d['open'] == true).toList();
  if (open.isEmpty) return 'Closed';
  if (open.length == 7 && open.every((d) => span(d) == span(open.first))) return 'Open daily · ${span(open.first)}';
  const short = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final parts = <String>[];
  var i = 0;
  while (i < days.length) {
    final d = days[i];
    var j = i;
    while (j + 1 < days.length && days[j + 1]['open'] == d['open'] && (d['open'] != true || span(days[j + 1]) == span(d))) { j++; }
    final range = i == j ? short[i] : '${short[i]}–${short[j]}';
    parts.add(d['open'] == true ? '$range ${span(d)}' : '$range closed');
    i = j + 1;
  }
  return parts.join(' · ');
}

/// Whole-day text for a date from the server ("2026-10-10" or an ISO time) as "10 Oct 2026".
String dayText(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
