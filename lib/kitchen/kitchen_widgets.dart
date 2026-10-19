import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_widgets.dart' show kNavyH, kLimeH, kGreyBg, kAmberText, kAmberBgH, kBlueIconBg, kGreenIconBg, kPostedText;
import '../ui/theme.dart';
import 'kitchen_api.dart';

/// What the kitchen screens share: the API and the ways out of the section (the other bottom-bar tabs).
class KitchenEnv {
  KitchenEnv({KitchenApi? api, this.onNavigate, this.initials = '', this.refreshEvery = const Duration(seconds: 20)}) : api = api ?? KitchenApi();
  final KitchenApi api;

  /// Bottom-bar tabs this section does not own: 'money', 'menu', 'orders', 'stock'. 'pos' is the section itself.
  final ValueChanged<String>? onNavigate;

  /// The signed-in person's initials for the round button on the right of the top bar (empty: a person icon).
  final String initials;

  /// How often the display asks again by itself; null turns that off.
  final Duration? refreshEvery;

  void tab(BuildContext context, String id) {
    if (id == 'pos') {
      Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == setupRoute);
    } else if (onNavigate != null) {
      onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  void later(BuildContext context, String what) => showToast(context, '$what opens in a later release.');
  Future<T?> push<T>(BuildContext context, Widget screen) => Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

  static const setupRoute = '/kitchen';
}

/// Page frame of the kitchen frames: white bar with menu, screen title and the person's initials; scrolling body; floating dark bottom bar (POS active).
class KitchenPage extends StatelessWidget {
  const KitchenPage({super.key, required this.env, required this.title, required this.child, this.onRefresh});
  final KitchenEnv env;
  final String title;
  final Widget child;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          Container(
            padding: EdgeInsets.fromLTRB(14, MediaQuery.paddingOf(context).top + 10, 14, 10),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: kLine))),
            child: Row(children: [
              Semantics(
                button: true,
                label: 'Menu',
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(LucideIcons.menu, size: 18, color: kInk),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: Semantics(header: true, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(19, 700)))),
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0xFFF3F4F1), shape: BoxShape.circle),
                child: env.initials.isEmpty ? const Icon(LucideIcons.user, size: 16, color: kInk) : Text(env.initials, style: inter(13, 700)),
              ),
            ]),
          ),
          Expanded(
            child: onRefresh == null ? child : RefreshIndicator(onRefresh: onRefresh!, child: child),
          ),
        ]),
        bottomNavigationBar: KitchenBottomNav(onTap: (id) => env.tab(context, id)),
      );
}

/// Floating dark bar: Money, Menu, POS (raised lime tile), Orders, Stock.
class KitchenBottomNav extends StatelessWidget {
  const KitchenBottomNav({super.key, required this.onTap});
  final ValueChanged<String> onTap;
  static const tabs = [
    ('money', 'Money', LucideIcons.indianRupee),
    ('menu', 'Menu', LucideIcons.bookOpen),
    ('pos', 'POS', LucideIcons.receiptText),
    ('orders', 'Orders', LucideIcons.shoppingBag),
    ('stock', 'Stock', LucideIcons.boxes),
  ];
  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Container(
          height: 84,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(color: kNavyH, borderRadius: BorderRadius.circular(34)),
          child: Row(children: [
            for (final (id, label, icon) in tabs)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: id == 'pos',
                  label: label,
                  child: InkWell(
                    key: ValueKey('kit-tab-$id'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onTap(id),
                    child: Container(
                      decoration: id == 'pos' ? BoxDecoration(color: kLimeH, borderRadius: BorderRadius.circular(14)) : null,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 22, color: id == 'pos' ? kNavyH : Colors.white),
                        const SizedBox(height: 5),
                        ExcludeSemantics(child: Text(label, maxLines: 1, style: inter(11, id == 'pos' ? 700 : 500, color: id == 'pos' ? kNavyH : Colors.white))),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// Heading, optional subtitle and an optional "‹ Kitchen setup" crumb.
class KitchenHeading extends StatelessWidget {
  const KitchenHeading(this.title, {super.key, this.subtitle, this.crumb});
  final String title;
  final String? subtitle, crumb;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (crumb != null)
            Semantics(
              button: true,
              label: 'Back to $crumb',
              child: InkWell(onTap: () => Navigator.of(context).maybePop(), child: Padding(padding: const EdgeInsets.only(bottom: 10), child: ExcludeSemantics(child: Text('‹ $crumb', style: inter(14, 400, color: kMuted))))),
            ),
          Semantics(header: true, child: Text(title, style: inter(23, 700))),
          if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle!, style: inter(14, 400, color: kMuted))),
        ]),
      );
}

/// Small dark pill button with a plus ("+ Add station").
class KitchenAddButton extends StatelessWidget {
  const KitchenAddButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: kNavyH,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(LucideIcons.plus, size: 15, color: Colors.white),
                const SizedBox(width: 6),
                ExcludeSemantics(child: Text(label, style: inter(14, 600, color: Colors.white))),
              ]),
            ),
          ),
        ),
      );
}

/// Pill used for status and station tags: soft background, coloured text.
class KitchenTag extends StatelessWidget {
  const KitchenTag(this.text, {super.key, required this.bg, required this.fg, this.size = 12.5, this.weight = 600});
  final String text;
  final Color bg, fg;
  final double size;
  final int weight;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: inter(size, weight, color: fg)),
      );
}

/// Status of a kitchen ticket: NEW (blue), IN PROGRESS (amber), READY (green), SERVED (grey).
(String, Color, Color) ticketLook(String chip) => switch (chip) {
      'new' => ('NEW', kBlueIconBg, const Color(0xFF1D4ED8)),
      'in_progress' => ('IN PROGRESS', kAmberBgH, kAmberText),
      'ready' => ('READY', kGreenIconBg, kPostedText),
      _ => ('SERVED', kGreyBg, kMuted),
    };

String channelLabel(String c) => switch (c) {
      'dine_in' => 'Dine-in',
      'pickup' => 'Takeaway',
      'delivery' => 'Delivery',
      'online' => 'Online',
      'swiggy' => 'Swiggy',
      'zomato' => 'Zomato',
      _ => 'Order',
    };
