import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/home_widgets.dart' show FloatingTabBar, BarTab;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';

// Section Z (error, offline and sync states). Pieces shared by every state screen, read from the exported frames in assets/figma_ref_q.
// None of these screens decides anything: the caller says what happened and what each button does.

enum StateTone { danger, warn, ok }

const _toneBg = {StateTone.danger: Color(0xFFFEE2E2), StateTone.warn: Color(0xFFFEF3C7), StateTone.ok: kChipGreen};
const _toneFg = {StateTone.danger: Color(0xFFDC2626), StateTone.warn: Color(0xFFB45309), StateTone.ok: kGreenText};

/// Round 72px icon badge with a tinted ground (offline, server, sync, clock).
class StateIcon extends StatelessWidget {
  const StateIcon(this.icon, {super.key, this.tone = StateTone.danger, this.busy = false});
  final IconData icon;
  final StateTone tone;

  /// Shows a ring spinner around the icon (sync in progress).
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: _toneBg[tone], shape: BoxShape.circle),
        child: Stack(alignment: Alignment.center, children: [
          if (busy) SizedBox(width: 60, height: 60, child: CircularProgressIndicator(strokeWidth: 3, color: _toneFg[tone])),
          Icon(icon, size: 30, color: busy ? kInk : _toneFg[tone]),
        ]),
      );
}

/// Grey inset block: optional bold heading and lines of muted text ("What to do", "Retained queue").
class InfoBox extends StatelessWidget {
  const InfoBox({super.key, this.title, required this.lines});
  final String? title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title != null) ...[Text(title!, style: inter(14, 700)), const SizedBox(height: 6)],
          for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(l, style: inter(14.5, 400, color: kMuted, height: 1.4))),
        ]),
      );
}

/// The centred white card of the status states: badge, optional chip, title, body, optional info block, then the buttons.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.icon,
    this.tone = StateTone.danger,
    this.busy = false,
    required this.title,
    required this.body,
    this.chip,
    this.info,
    this.extra,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });
  final IconData icon;
  final StateTone tone;
  final bool busy;
  final String title, body;
  final String? chip;
  final InfoBox? info;
  final Widget? extra;
  final String? primaryLabel, secondaryLabel;
  final VoidCallback? onPrimary, onSecondary;

  @override
  Widget build(BuildContext context) => OrderCardBox(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(children: [
          StateIcon(icon, tone: tone, busy: busy),
          const SizedBox(height: 16),
          if (chip != null) ...[DotChip(chip!, bg: _toneBg[tone]!, fg: _toneFg[tone]!), const SizedBox(height: 10)],
          Text(title, textAlign: TextAlign.center, style: inter(22, 700)),
          const SizedBox(height: 10),
          Text(body, textAlign: TextAlign.center, style: inter(15, 400, color: kMuted, height: 1.45)),
          if (info != null) ...[const SizedBox(height: 18), info!],
          if (extra != null) ...[const SizedBox(height: 14), extra!],
          if (primaryLabel != null) ...[const SizedBox(height: 18), DarkCta(label: primaryLabel!, onPressed: onPrimary)],
          if (secondaryLabel != null) ...[const SizedBox(height: 10), LightCta(label: secondaryLabel!, onPressed: onSecondary)],
        ]),
      );
}

/// Red banner at the top of a device error ("Terminal disconnected during payment").
class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key, required this.title, required this.body, this.onClose});
  final String title, body;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
        decoration: BoxDecoration(color: const Color(0xFFFEE9E7), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFF2A39D))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.circleX, size: 20, color: Color(0xFFDC2626))),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: inter(14.5, 700)),
              const SizedBox(height: 3),
              Text(body, style: inter(13, 400, color: kMuted, height: 1.4)),
            ]),
          ),
          if (onClose != null) InkWell(onTap: onClose, child: const Padding(padding: EdgeInsets.all(2), child: Icon(LucideIcons.x, size: 18, color: kMuted))),
        ]),
      );
}

/// Page frame of the status states: top bar, scrolling body, optional floating tab bar.
class StateFrame extends StatelessWidget {
  const StateFrame({super.key, required this.title, required this.children, this.tabs, this.onTab, this.onBack, this.bottom, this.centered = false});
  final String title;
  final List<Widget> children;
  final List<BarTab>? tabs;
  final ValueChanged<String>? onTab;
  final VoidCallback? onBack;

  /// Pinned under the body, above the tab bar (hint line and buttons).
  final Widget? bottom;

  /// Vertically centres the body (a single status card on an empty page).
  final bool centered;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OrdersTopBar(title: title, onBack: onBack),
          Expanded(
            child: centered
                ? Center(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 16), child: Column(mainAxisSize: MainAxisSize.min, children: children)))
                : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
          ),
          if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 14), child: bottom),
          if (tabs != null) SafeArea(top: false, child: FloatingTabBar(tabs: tabs!, onTap: onTab ?? (_) {})),
        ]),
      );
}

/// The plain "wireframe" pages (order missed, item not available, we'll be right back, coming soon): heading, lead line, cards, two buttons at the foot.
class WirePage extends StatelessWidget {
  const WirePage({super.key, required this.title, required this.lead, required this.cards, required this.primaryLabel, this.onPrimary, this.secondaryLabel, this.onSecondary, this.onBack});
  final String title, lead, primaryLabel;
  final String? secondaryLabel;
  final List<Widget> cards;
  final VoidCallback? onPrimary, onSecondary, onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Semantics(
                  button: true,
                  label: 'Back',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onBack,
                    child: Container(width: 40, height: 40, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: const Icon(LucideIcons.arrowLeft, size: 20, color: kInk)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: inter(22, 700))),
              ]),
              const SizedBox(height: 12),
              Text(lead, style: inter(14.5, 400, color: kMuted, height: 1.4)),
              const SizedBox(height: 14),
              Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: c)]))),
              DarkCta(label: primaryLabel, onPressed: onPrimary),
              if (secondaryLabel != null) ...[const SizedBox(height: 10), LightCta(label: secondaryLabel!, onPressed: onSecondary)],
            ]),
          ),
        ),
      );
}

/// A white card of a [WirePage]: bold heading with an optional chip, then body lines.
class WireCard extends StatelessWidget {
  const WireCard({super.key, required this.title, this.chip, this.chipBg = const Color(0xFFFEF3C7), this.chipFg = const Color(0xFF92400E), this.lines = const []});
  final String title;
  final String? chip;
  final Color chipBg, chipFg;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(title, style: inter(17, 700))),
            if (chip != null) ...[const SizedBox(width: 10), TagChip(chip!, bg: chipBg, fg: chipFg)],
          ]),
          for (final l in lines) Padding(padding: const EdgeInsets.only(top: 4), child: Text(l, style: inter(14, 400, color: kMuted, height: 1.4))),
        ]),
      );
}
