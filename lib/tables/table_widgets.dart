import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../outlets/outlet_header.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'table_qr_api.dart';
import 'tables_api.dart';

/// What the tables screens need from the rest of the app. Screens owned by other sections plug in through these hooks.
class TablesEnv {
  TablesEnv({TablesApi? api, this.onNavigate, this.onStartOrder, this.initials = '', this.onMenu, TableQrApi? qrApi})
      : api = api ?? TablesApi(),
        qrApi = qrApi ?? TableQrApi();
  final TablesApi api;

  /// Table QR codes and guest orders (0560, 0561).
  final TableQrApi qrApi;

  /// Bottom-bar tabs this section does not own: 'home', 'menu', 'orders', 'stock'.
  final ValueChanged<String>? onNavigate;

  /// "Start New Order" on a table (the counter-bill flow of section F). Null until the host plugs it in.
  final void Function(BuildContext context, Facts table)? onStartOrder;

  /// Two letters in the round badge top right (the signed-in person's initials); empty hides the badge.
  final String initials;
  final VoidCallback? onMenu;
}

// Colours sampled from the exported frames (assets/figma_ref_h, screen-1-tables-grid, screen-merge-tables, screen-order-detail).
const kLimeBtn = Color(0xFF76EC00);
const kAvailBorder = Color(0xFF7AE517);
const kAvailBg = Color(0xFFF0FDF0);
const kAvailText = Color(0xFF16A34A);
const kOccBorder = Color(0xFF7C3AED);
const kOccBg = Color(0xFFF3E8FF);
const kOccText = Color(0xFF7C3AED);
const kResBorder = Color(0xFF2563EB);
const kResBg = Color(0xFFEFF6FF);
const kResText = Color(0xFF2563EB);
const kCleanBorder = Color(0xFF9CA3AF);
const kCleanBg = Color(0xFFF3F4F6);
const kCleanText = Color(0xFF6B7280);
const kBusyBorder = Color(0xFFD97706);
const kBusyBg = Color(0xFFFEF0D8);
const kTableDot = Color(0xFF10B981);

/// Status words and colours of a table card: (label, border, background, text).
(String, Color, Color, Color) tableLook(String status) => switch (status) {
      'available' => ('AVAILABLE', kAvailBorder, kAvailBg, kAvailText),
      'occupied' => ('OCCUPIED', kOccBorder, kOccBg, kOccText),
      'reserved' => ('RESERVED', kResBorder, kResBg, kResText),
      'cleaning' => ('CLEANING', kCleanBorder, kCleanBg, kCleanText),
      _ => (status.toUpperCase(), kCleanBorder, kCleanBg, kCleanText),
    };

/// "1h 15m" / "45m" / "2h". Display only; the minutes come from the server.
String elapsed(num minutes) {
  final m = minutes.toInt();
  if (m < 60) return '${m}m';
  final h = m ~/ 60, r = m % 60;
  return r == 0 ? '${h}h' : '${h}h ${r}m';
}

/// "7:30 PM".
String clock12(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// "19:30" (the store's wall clock, as the server sends it) to "7:30 PM".
String clockFromHm(String hm) {
  final p = hm.split(':');
  if (p.length < 2) return hm;
  return clock12(DateTime(2000, 1, 1, int.tryParse(p[0]) ?? 0, int.tryParse(p[1]) ?? 0));
}

/// "07:30 PM" (the reserve form's time box).
String clock12Padded(DateTime d) => clock12(d).padLeft(8, '0');

/// "₹1,302".
String rupees(num? v) => '₹${qty(v ?? 0)}';

String pax(num seats) => '${seats.toInt()} Pax';

/// Page shell of the tables screens: header (menu or back, title, subtitle, round initials badge), body, floating bottom bar.
class TablesPage extends StatelessWidget {
  const TablesPage({super.key, required this.env, required this.title, this.subtitle, required this.children, this.back = false, this.onRefresh, this.nav = true, this.footer});
  final TablesEnv env;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool back;
  final Future<void> Function()? onRefresh;
  final bool nav;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    Widget list = ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 24), children: children);
    if (onRefresh != null) list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // the floor (first-level) shows the outlet header (specs/outlets-multi); inner screens the banner (☰ always) with the one back
          // arrow and their line under it
          if (!back)
            OutletHeader(title: title, onMenu: env.onMenu, safeTop: false, initials: env.initials)
          else
            AppHeader(
              title: title,
              safeTop: false,
              back: true,
              backKey: const ValueKey('tbl-back'),
              onMenu: env.onMenu,
              under: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13.5, 400, color: kMuted)),
            ),
          Expanded(child: list),
          ?footer,
        ]),
      ),
      bottomNavigationBar: nav ? TablesNav(onTap: (id) => env.onNavigate?.call(id)) : null,
    );
  }
}

/// Floating dark bottom bar of the POS frames: Home, Menu, Bill (active), Orders, Stock.
class TablesNav extends StatelessWidget {
  const TablesNav({super.key, required this.onTap});
  final ValueChanged<String> onTap;
  static const tabs = [
    ('home', 'Home', LucideIcons.house),
    ('menu', 'Menu', LucideIcons.bookOpen),
    ('pos', 'Bill', LucideIcons.receiptText),
    ('orders', 'Orders', LucideIcons.shoppingBag),
    ('stock', 'Stock', LucideIcons.boxes),
  ];
  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 12, 14, 14), // 12 above: the last button of a page never touches the bar
        child: Container(
          height: 78,
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
                    key: ValueKey('tbl-tab-$id'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onTap(id),
                    child: Container(
                      decoration: id == 'pos' ? BoxDecoration(color: kLimeH, borderRadius: BorderRadius.circular(12)) : null,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 20, color: id == 'pos' ? kNavyH : Colors.white),
                        const SizedBox(height: 5),
                        ExcludeSemantics(child: Text(label, maxLines: 1, style: inter(10.5, id == 'pos' ? 700 : 500, color: id == 'pos' ? kNavyH : Colors.white))),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// One card of the grid: "T1  4 Pax", status chip, elapsed or booking time.
class TableCard extends StatelessWidget {
  const TableCard({super.key, required this.table, required this.onTap, this.selected = false, this.busyLook = false, this.compact = false});
  final Facts table;
  final VoidCallback? onTap;
  final bool selected;

  /// Merge screen: an occupied table is drawn orange.
  final bool busyLook;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final status = table.s('status');
    var (label, border, bg, text) = tableLook(status);
    if (busyLook && status == 'occupied') (label, border, bg, text) = ('OCCUPIED', kBusyBorder, kBusyBg, kBusyBorder);
    if (selected) (label, border, bg, text) = ('SELECTED', kAvailBorder, kAvailBg, kAvailText);
    final sub = switch (status) {
      'occupied' when table.no('elapsed_minutes') != null => elapsed(table.n('elapsed_minutes')),
      'reserved' when table.so('reserved_local') != null => clockFromHm(table.s('reserved_local')),
      'reserved' when table.t('reserved_at') != null => clock12(table.t('reserved_at')!),
      _ => null,
    };
    final name = Text(table.s('label'), style: inter(compact ? 22 : 26, 700));
    final seats = Text(pax(table.n('seats')), style: inter(compact ? 14 : 16, 500, color: kMuted));
    return Semantics(
      button: onTap != null,
      label: '${table.s('label')}, ${pax(table.n('seats'))}, ${label.toLowerCase()}',
      child: InkWell(
        key: ValueKey('table-${table.s('label')}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: compact ? 108 : 112,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: border, width: 2)),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              compact
                  ? Column(mainAxisSize: MainAxisSize.min, children: [name, seats])
                  : Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [name, const SizedBox(width: 8), seats]),
              const SizedBox(height: 4),
              Container(
                padding: compact ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: compact ? null : BoxDecoration(color: Colors.white.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
                child: Text(label, style: inter(compact ? 13 : 14.5, 700, color: text)),
              ),
              if (sub != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(sub, style: inter(14, 400, color: kMuted))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Lime full-width button of the tables frames ("Start New Order", "Confirm Reservation", "Join Tables").
class LimeButton extends StatelessWidget {
  const LimeButton(this.label, {super.key, required this.onPressed, this.icon, this.busy = false, this.height = 52});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final double height;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onPressed != null && !busy,
        child: Material(
          color: onPressed == null ? const Color(0xFFD7F0B0) : kLimeBtn,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: busy ? null : onPressed,
            child: Container(
              height: height,
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (icon != null) ...[Icon(icon, size: 20, color: kInk), const SizedBox(width: 10)],
                      Flexible(child: Text(label, textAlign: TextAlign.center, style: inter(16, 700, color: onPressed == null ? kMuted : kInk))),
                    ]),
            ),
          ),
        ),
      );
}

/// White outlined button ("Reserve Table", "Send KOT").
class OutlineButtonT extends StatelessWidget {
  const OutlineButtonT(this.label, {super.key, required this.onPressed, this.icon, this.height = 52, this.dark = false, this.enabledLook = true});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  /// Dark outline (the sheet's "Reserve Table").
  final bool dark;

  /// A button that stays tappable (to say why it is off) but is drawn grey.
  final bool enabledLook;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onPressed != null,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: dark ? kNavyH : const Color(0xFFD9DBD5), width: dark ? 1.6 : 1.2)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Container(
              height: height,
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 20, color: kInk), const SizedBox(width: 10)],
                Flexible(child: Text(label, textAlign: TextAlign.center, style: inter(15.5, 600, color: enabledLook ? kInk : kMuted))),
              ]),
            ),
          ),
        ),
      );
}

/// Error card with a retry.
class TablesError extends StatelessWidget {
  const TablesError(this.message, {super.key, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kCardLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Could not load this', style: inter(15, 600)),
          const SizedBox(height: 6),
          Text(message, style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 10),
          InvSecondary('Try again', onPressed: onRetry),
        ]),
      );
}

Widget tablesLoading() => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)));

/// The sentence to show for a failed call.
String sayError(Object e) => e is PartnerApiException ? e.message : 'Something went wrong. Please try again.';
