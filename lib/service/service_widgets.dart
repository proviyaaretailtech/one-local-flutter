import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../outlets/outlet_header.dart';
import '../ui/app_header.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';

/// Top of every Service POS screen (Figma section I): menu button, OneLocal wordmark, initials avatar, then "Service" and "Business · City".
class ServiceTopBar extends StatelessWidget {
  const ServiceTopBar({super.key, this.business = '', this.onMenu, this.onBack, this.initials});
  final String business;
  final VoidCallback? onMenu, onBack;
  final String? initials;
  // First-level screens: the dashboard's banner (outlet, status); inner screens: the shared banner with back.
  @override
  Widget build(BuildContext context) => onBack == null
      ? OutletHeader(title: 'Service POS', onMenu: onMenu, initials: initials)
      : AppHeader(title: 'Service', kicker: business.isEmpty ? null : business, onBack: onBack, onMenu: onMenu);
}

/// Status pill of an appointment: green Confirmed / Completed, amber Deposit pending, red Cancelled / No-show, grey otherwise.
class ApptStatusChip extends StatelessWidget {
  const ApptStatusChip({super.key, required this.label, required this.tone});
  final String label, tone;
  @override
  Widget build(BuildContext context) {
    final (bg, fg, dot) = switch (tone) {
      'good' => (kChipGreen, kGreenText, kLink),
      'warn' => (const Color(0xFFFFF9E3), const Color(0xFFA23F00), const Color(0xFFF59E0B)),
      'bad' => (kBadBg, kBadText, kBadText),
      _ => (kInfoGreyBg, kInk, kMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: inter(12, 600, color: fg)),
      ]),
    );
  }
}

/// Rounded filter chip (Day / Week / All providers).
class ModeChip extends StatelessWidget {
  const ModeChip(this.label, {super.key, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? kChipGreen : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: selected ? kLink : kLine),
            ),
            // sized to the label, also inside a Wrap (an aligned Container would stretch to the full width)
            child: Center(widthFactor: 1, child: ExcludeSemantics(child: Text(label, style: inter(13, selected ? 600 : 400, color: selected ? kInk : kMuted)))),
          ),
        ),
      );
}

/// Body of every section I screen: the top bar, a scrolling page with the frame's title and subtitle, and the bottom bar (Bill active).
/// [body] is null while the first answer is loading; [error] replaces it with the server's sentence and a retry.
class ServicePage extends StatelessWidget {
  const ServicePage({super.key, required this.title, this.subtitle = '', this.business = '', this.body, this.error, this.onRetry, this.onRefresh, this.onNavigate, this.onMenu, this.scrollKey});
  final String title, subtitle, business;
  final List<Widget>? body;
  final String? error;
  final VoidCallback? onRetry, onMenu;
  final Future<void> Function()? onRefresh;
  final ValueChanged<String>? onNavigate;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) {
    final list = ListView(key: scrollKey, padding: const EdgeInsets.fromLTRB(16, 12, 16, 20), children: [
      Text(title, style: inter(22, 700, height: 1.15)),
      if (subtitle.isNotEmpty) ...[const SizedBox(height: 4), Text(subtitle, style: inter(13, 400, color: kMuted))],
      const SizedBox(height: 12),
      if (error != null)
        OrderCardBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(error!, style: inter(13.5, 500)),
          if (onRetry != null) ...[const SizedBox(height: 8), SmallPill('Try again', onTap: onRetry)],
        ]))
      else if (body == null)
        const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText)))
      else
        // the store's motion (founder's reference video, 29 Oct 2026): sections build in one after another, once
        for (var i = 0; i < body!.length; i++) Entrance(index: i, child: body![i]),
    ]);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        ServiceTopBar(business: business, onMenu: onMenu, onBack: onMenu == null && Navigator.canPop(context) ? () => Navigator.maybePop(context) : null),
        Expanded(child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list)),
        PosBottomNav(active: 'bill', onTap: (id) => id == 'bill' ? Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == ServiceRoutes.calendar) : (onNavigate ?? (_) => showToast(context, 'That part of the app is not built yet.'))(id)),
      ]),
    );
  }
}

/// Route names the section I screens use, so the Bill tab can return to the calendar.
class ServiceRoutes {
  ServiceRoutes._();
  static const calendar = 'service/calendar';
}

/// White card with an optional bold heading (every block of the section I frames).
class SvcCard extends StatelessWidget {
  const SvcCard({super.key, this.title, this.trailing, required this.children, this.onTap});
  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final card = OrderCardBox(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Text(title!, style: inter(16, 700, height: 1.25))), ?trailing]),
          const SizedBox(height: 6),
        ],
        ...children,
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: onTap == null ? card : InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap, child: card),
    );
  }
}

/// "Label    value" row of the frames: grey label in a fixed column, bold value.
class SvcKV extends StatelessWidget {
  const SvcKV(this.k, this.v, {super.key, this.valueColor = kInk, this.labelWidth = 120});
  final String k, v;
  final Color valueColor;
  final double labelWidth;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: labelWidth, child: Text(k, style: inter(13, 400, color: kMuted))),
          Expanded(child: Text(v, style: inter(13.5, 600, color: valueColor))),
        ]),
      );
}

/// "• Hair spa · +20 min     1×     ₹200" line.
class SvcLine extends StatelessWidget {
  const SvcLine(this.name, {super.key, this.qty, required this.amount, this.muted = false});
  final String name, amount;
  final String? qty;
  final bool muted;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Container(width: 7, height: 7, decoration: const BoxDecoration(color: kLink, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text(name, style: inter(13.5, 500, color: muted ? kMuted : kInk))),
          if (qty != null) ...[TagChip(qty!), const SizedBox(width: 18)],
          SizedBox(width: 72, child: Text(amount, textAlign: TextAlign.right, style: inter(13.5, 700))),
        ]),
      );
}

/// Rounded search field of the list frames.
class SvcSearch extends StatelessWidget {
  const SvcSearch({super.key, required this.hint, required this.onChanged, this.fieldKey});
  final String hint;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFD9DBD3))),
        child: Row(children: [
          const Icon(LucideIcons.search, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: fieldKey,
              onChanged: onChanged,
              style: inter(14, 400),
              decoration: InputDecoration(isDense: true, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, hintText: hint, hintStyle: inter(14, 400, color: kHint)),
            ),
          ),
        ]),
      );
}

/// A wrapping row of [ModeChip]s; [selected] is the value of the chosen one.
class SvcChips extends StatelessWidget {
  const SvcChips({super.key, required this.options, required this.selected, required this.onSelect});
  final List<(String value, String label)> options;
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (v, l) in options) ModeChip(l, selected: v == selected, onTap: () => onSelect(v)),
        ]),
      );
}

/// "18 total" / "2 exceptions" count pill next to a section heading.
class SvcSectionHead extends StatelessWidget {
  const SvcSectionHead(this.title, {super.key, this.count});
  final String title;
  final String? count;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(children: [
          Expanded(child: Text(title, style: inter(17, 700))),
          if (count != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: kLine)),
              child: Text(count!, style: inter(12, 500, color: kMuted)),
            ),
        ]),
      );
}

/// Blue "i" banner with a title, a line and a dismiss cross (frames 84, 89, 92, 103, 104).
class SvcInfo extends StatefulWidget {
  const SvcInfo({super.key, required this.title, required this.text});
  final String title, text;
  @override
  State<SvcInfo> createState() => _SvcInfoState();
}

class _SvcInfoState extends State<SvcInfo> {
  bool _shown = true;
  @override
  Widget build(BuildContext context) => !_shown
      ? const SizedBox.shrink()
      : Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFF0F6FF), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF3B82F6))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(LucideIcons.info, size: 20, color: Color(0xFF3B82F6)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: inter(15, 600)),
                const SizedBox(height: 4),
                Text(widget.text, style: inter(13, 400, color: kMuted, height: 1.4)),
              ]),
            ),
            Semantics(button: true, label: 'Dismiss', child: InkWell(onTap: () => setState(() => _shown = false), child: const Icon(LucideIcons.x, size: 18, color: kMuted))),
          ]),
        );
}

/// The status chip tones of the section I frames for a server tone word.
ApptStatusChip svcStatus(String label, String tone) => ApptStatusChip(label: label, tone: tone);

/// Asks how the customer pays [amount]: cash (with the amount received), card or UPI. Returns (method, tendered) or null.
Future<(String, num?)?> pickPayment(BuildContext context, {required String title, required num amount}) async {
  final method = await showOrderSheet<String>(context, title: title, body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (id, label) in const [('cash', 'Cash'), ('card', 'Card'), ('upi', 'UPI / QR')]) ...[
          LightCta(key: ValueKey('pay-$id'), label: label, onPressed: () => Navigator.pop(ctx, id)),
          const SizedBox(height: 8),
        ],
      ]));
  if (method == null || !context.mounted) return null;
  if (method != 'cash') return (method, null);
  final c = TextEditingController(text: amount.toStringAsFixed(0));
  final got = await showOrderSheet<num>(context, title: 'Cash received', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const ValueKey('cash-received'), controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(prefixText: '₹ ')),
        const SizedBox(height: 14),
        DarkCta(label: 'Done', onPressed: () => Navigator.pop(ctx, num.tryParse(c.text.trim()))),
      ]));
  return got == null ? null : ('cash', got);
}

/// One-line text input sheet. Returns the trimmed text, or null when dismissed.
Future<String?> askText(BuildContext context, String title, {String initial = '', String hint = '', String action = 'Save', TextInputType keyboard = TextInputType.text, int lines = 1}) {
  final c = TextEditingController(text: initial);
  return showOrderSheet<String>(context, title: title, body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(key: const ValueKey('ask-text'), controller: c, keyboardType: keyboard, minLines: lines, maxLines: lines == 1 ? 1 : lines + 2, decoration: InputDecoration(hintText: hint)),
        const SizedBox(height: 14),
        DarkCta(label: action, onPressed: () => Navigator.pop(ctx, c.text.trim())),
      ]));
}

/// Rupees without paise when whole ("₹1,350", "₹63,936").
String svcRupees(num v) {
  final neg = v < 0;
  final whole = v.abs().round() == v.abs();
  final s = whole ? v.abs().round().toString() : v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  var n = parts[0];
  if (n.length > 3) {
    final last3 = n.substring(n.length - 3);
    var rest = n.substring(0, n.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    n = '${groups.join(',')},$last3';
  }
  return '${neg ? '−' : ''}₹$n${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// "+91 98765 43210" for a 10-digit Indian mobile number; anything else as it is.
String svcPhone(String digits) => digits.length == 10 ? '+91 ${digits.substring(0, 5)} ${digits.substring(5)}' : digits;

/// The "+ New …" button at the top of a service tab (founder, 2 Nov 2026: create actions are seen without scrolling). Slim; dark with lime
/// text for the main action, white with a line for a second one beside it.
class SvcTopButton extends StatelessWidget {
  const SvcTopButton(this.label, {super.key, required this.onTap, this.dark = true});
  final String label;
  final VoidCallback onTap;
  final bool dark;
  @override
  Widget build(BuildContext context) => Material(
        color: dark ? kPrimary : Colors.white,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: dark ? null : Border.all(color: kPrimary)),
            child: Text(label, style: inter(15, 700, color: dark ? kLime : kPrimary)),
          ),
        ),
      );
}

/// Where a booking or job came from (founder, 2 Nov 2026): "Booked online" (the customer app, blue) or "Booked offline" (logged in the POS,
/// grey). [short] says just Online / Offline, for the small blocks of the day view and the board.
class SourceTag extends StatelessWidget {
  const SourceTag({super.key, required this.online, this.short = false});
  final bool online;
  final bool short;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = online ? (const Color(0xFFE6EEFF), const Color(0xFF1D4ED8)) : (kInfoGreyBg, kMuted);
    final label = short ? (online ? 'Online' : 'Offline') : (online ? 'Booked online' : 'Booked offline');
    return Container(
      padding: EdgeInsets.symmetric(horizontal: short ? 6 : 10, vertical: short ? 1 : 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(online ? LucideIcons.smartphone : LucideIcons.store, size: short ? 11 : 13, color: fg),
        const SizedBox(width: 4),
        Text(label, style: inter(short ? 10.5 : 12, 600, color: fg)),
      ]),
    );
  }
}

/// A figure that counts up softly (founder, 2 Nov 2026: the store's count-up felt "too abrupt and fast"): longer, easing out gently so
/// the last numbers settle slowly, whole numbers while it runs, and the figure fades in as it starts. The exact value shows at the end.
class SoftCountUp extends StatelessWidget {
  const SoftCountUp(this.value, {super.key, required this.style, this.format, this.duration = const Duration(milliseconds: 1600)});
  final num value;
  final TextStyle style;
  final String Function(num v)? format;
  final Duration duration;
  @override
  Widget build(BuildContext context) {
    String write(num v) => format == null ? '${v.round()}' : format!(v);
    if (reduceMotion(context) || value == 0) return Text(write(value), style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutQuart,
      builder: (_, t, _) => Opacity(
        opacity: (0.35 + t * 1.3).clamp(0.0, 1.0),
        child: Text(t >= 1 ? write(value) : write((value * t).roundToDouble()), style: style),
      ),
    );
  }
}
