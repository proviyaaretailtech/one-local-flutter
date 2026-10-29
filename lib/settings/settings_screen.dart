import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../home/home_nav.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kWarnBg, kWarnText;
import '../states/state_kit.dart' show StateTone, StatusCard;
import '../ui/theme.dart';
import 'activity_log_screen.dart';
import 'settings_api.dart';
import 'settings_sheets.dart';
import 'settings_widgets.dart';
import 'support_screens.dart';

/// One part of Settings opened on its own from a More tile: only that part's rows, under the tile's name.
enum SettingsPart {
  timings('Outlet timings'),
  phones('Phone numbers'),
  outletInfo('Outlet info');

  const SettingsPart(this.title);
  final String title;
}

/// Settings and store profile (Figma section P "Settings"). Everything shown is what `pos_settings_get` says; every Edit opens one sheet
/// that saves one field group. Who may save is the database's decision (`can_edit`); a person who may not sees the page read-only.
/// With [part], only that part's rows show (the More page's Outlet timings, Phone numbers and Outlet info tiles).
class SettingsScreen extends StatefulWidget {
  SettingsScreen({super.key, SettingsEnv? env, this.part}) : env = env ?? SettingsEnv();
  final SettingsEnv env;
  final SettingsPart? part;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsState? _s;
  String? _error;
  bool _offline = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Set when the server answered but could not give the saved settings: the page still shows (every row empty) under a warning.
  String? _unloaded;

  Future<void> _load() async {
    setState(() {
      _error = null;
      _offline = false;
    });
    try {
      final s = await widget.env.api.get();
      if (mounted) {
        setState(() {
          _s = s;
          _unloaded = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is PartnerApiException && e.status < 500) {
          // A refusal (not allowed, signed out): its own sentence, no page.
          _error = e.message;
        } else if (e is PartnerApiException) {
          // The server failed (for example a database without this release's functions): show Settings anyway, empty, and
          // say so (saving may fail too).
          _unloaded = e.message;
          _s ??= SettingsState({
            'can_edit': true,
            'bank_visible': true,
            'bank': {'status': 'not_added'},
            'organization': {'name': HomeNav.storeName ?? ''},
          });
        } else {
          _error = 'Could not reach the server. Check your connection and try again.';
          _offline = true;
        }
      });
    }
  }

  Future<void> _sheet(Future<SettingsState?> Function(BuildContext, SettingsEnv, SettingsState) open) async {
    final s = _s;
    if (s == null) return;
    final next = await open(context, widget.env, s);
    if (!mounted) return;
    if (next != null) {
      setState(() => _s = next);
      showToast(context, 'Saved.');
    } else {
      _load(); // documents and QR save themselves inside their sheet
    }
  }

  Future<void> _toggle(Future<SettingsState> Function(bool) save, bool on) async {
    setState(() => _busy = true);
    final next = await guarded(context, () => save(on));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (next != null) _s = next;
    });
  }

  void _back() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: widget.part?.title ?? 'Settings', onBack: _back),
        Expanded(
          child: s == null
              ? _Loading(error: _error, offline: _offline, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: _body(s))),
        ),
      ]),
    );
  }

  List<Widget> _body(SettingsState s) {
    final edit = s.canEdit;
    Widget editBtn(Future<SettingsState?> Function(BuildContext, SettingsEnv, SettingsState) open) => edit ? RowAction('Edit', onTap: () => _sheet(open)) : const SizedBox(width: 8);
    final bank = s.bankStatus;
    final part = widget.part;
    final all = part == null;
    return [
      Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 0), child: Row(children: [Expanded(child: Text(s.businessName.isEmpty ? 'Store preferences' : s.businessName, style: inter(13, 500, color: kMuted)))])),
      if (_unloaded != null)
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: BoxDecoration(color: kWarnBg, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(LucideIcons.circleAlert, size: 18, color: kWarnText),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Your saved settings could not be loaded, so everything shows as not set. Saving may not work yet. ($_unloaded)',
                  style: inter(12, 500, color: kWarnText, height: 1.35)),
            ),
            TextButton(onPressed: _load, child: Text('Try again', style: inter(12, 700, color: kWarnText))),
          ]),
        ),
      if (!edit) Padding(padding: const EdgeInsets.only(top: 10), child: _ReadOnlyNote()),
      if (all || part == SettingsPart.timings) ...[
        const GroupTitle('Timings & readiness'),
        GroupCard(children: [
          SettingRow(icon: LucideIcons.clock, title: 'Opening & closing timings', subtitle: 'Opening: ${clock12(s.opensAt)} · Closing: ${clock12(s.closesAt)}', actions: [editBtn(openHoursSheet)]),
          SettingRow(icon: LucideIcons.truck, title: 'Delivery time / readiness', subtitle: s.prepMinutes == null ? 'Not set' : '${s.prepMinutes} min', actions: [editBtn(openReadinessSheet)]),
        ]),
      ],
      if (all || part == SettingsPart.phones) ...[
        GroupTitle(all ? 'Contact details & users' : 'Contact numbers'),
        GroupCard(children: [
          SettingRow(icon: LucideIcons.headset, title: 'Help / replacements', subtitle: s.helpName == null ? 'Not added' : '${s.helpName} · +91 ${s.helpPhone}', actions: [editBtn(openHelpSheet)]),
          SettingRow(icon: LucideIcons.user, title: 'Owner', subtitle: s.ownerName == null ? 'Not added' : '${s.ownerName} · +91 ${s.ownerPhone}', actions: [editBtn(openOwnerSheet)]),
          SettingRow(icon: LucideIcons.phone, title: 'Staff number', subtitle: s.staffPhone == null ? 'Not added' : '+91 ${s.staffPhone}', actions: [editBtn(openStaffPhoneSheet)]),
          // Users, roles and invites belong to the Team section (L). This row only points there (the More page has its own Manage staff tile).
          if (all)
            SettingRow(
              icon: LucideIcons.userPlus,
              title: 'Manage store access',
              subtitle: s.activeUsers == 1 ? '1 user' : '${s.activeUsers} users',
              actions: [LimePill('Add users', onTap: () => HomeNav.go(context, HomeNav.team, 'Team'))],
            ),
        ]),
      ],
      if (all) const GroupTitle('Order preferences'),
      if (all) GroupCard(children: [
        SettingRow(
          icon: LucideIcons.shoppingBag,
          title: 'Online self-pickup orders',
          subtitle: '${s.pickup ? 'On' : 'Off'} · Accept orders for store pickup',
          onTap: edit ? () => _sheet(openPickupSheet) : null,
          actions: [LimeSwitch(label: 'Online self-pickup orders', value: s.pickup, onChanged: edit && !_busy ? (v) => _toggle(widget.env.api.setPickup, v) : null)],
        ),
        SettingRow(
          icon: LucideIcons.qrCode,
          title: 'QR self-checkout',
          subtitle: '${s.qrCheckout ? 'On' : 'Off'} · Let customers scan and pay',
          onTap: edit ? () => _sheet(openQrCheckoutSheet) : null,
          actions: [LimeSwitch(label: 'QR self-checkout', value: s.qrCheckout, onChanged: edit && !_busy ? (v) => _toggle(widget.env.api.setQrCheckout, v) : null)],
        ),
      ]),
      if (all || part == SettingsPart.outletInfo) const GroupTitle('Business details'),
      if (all || part == SettingsPart.outletInfo) GroupCard(children: [
        SettingRow(
          icon: LucideIcons.files,
          title: 'Documents',
          subtitle: s.documentCount == 0 ? 'Manage store documents' : '${s.documentCount} ${s.documentCount == 1 ? 'document' : 'documents'}',
          actions: [RowAction('Edit', onTap: () => _sheet((c, e, st) async {
                await openDocumentsSheet(c, e, st);
                return null;
              }))],
        ),
        if (bank != null) ...[
          SettingRow(
            icon: LucideIcons.landmark,
            title: 'Bank details',
            subtitle: '${s.bankLast4 == null ? 'Not added' : 'Account ending ${s.bankLast4}'} · ${bank == 'verified' ? 'Verified' : 'Unverified'}',
            actions: [if (edit) RowAction('Edit', onTap: () => _sheet(openBankSheet)), if (edit && bank != 'verified') RowAction('Verify', onTap: () => _sheet(openBankSheet))],
          ),
          const WarnStrip('Bank details must match the Shop Act.'),
        ],
        SettingRow(icon: LucideIcons.qrCode, title: 'Upload your QR', subtitle: s.qrUploaded ? 'QR uploaded' : 'Upload or manage your store QR code', actions: [RowAction('Edit', onTap: () => _sheet(openQrSheet))]),
        SettingRow(icon: LucideIcons.languages, title: 'Language', subtitle: kLanguages[s.language] ?? s.language, onTap: edit ? () => _sheet(openLanguageSheet) : null, actions: [if (edit) RowAction('Edit', onTap: () => _sheet(openLanguageSheet))]),
        SettingRow(icon: LucideIcons.mapPin, title: 'Location', subtitle: s.address ?? 'Not added', actions: [editBtn(openLocationSheet)]),
      ]),
      if (all) ..._more(s),
    ];
  }

  /// Support, store delivery and feedback: only on the full Settings page.
  List<Widget> _more(SettingsState s) {
    // one group, like the sections above it (founder, 29 Oct 2026: four lone cards looked scattered); a restaurant has its own Orders
    // tab, so the store's "Store Delivery" row is the store's only
    const chevron = [Icon(LucideIcons.chevronRight, size: 18, color: kMuted)];
    return [
      const GroupTitle('More'),
      GroupCard(children: [
        SettingRow(
          key: const ValueKey('settings-activity-log'),
          icon: LucideIcons.history,
          title: 'Activity log',
          subtitle: 'Every order’s timeline: placed, KOTs, ready, billed, paid',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ActivityLogScreen(env: widget.env))),
          actions: chevron,
        ),
        // a restaurant's three pages that left the side bar (founder, 29 Oct 2026: "put them in Settings")
        if (HomeNav.shell?.kind == 'restaurant') ...[
          SettingRow(
            key: const ValueKey('settings-purchase-orders'),
            icon: LucideIcons.truck,
            title: 'Purchase orders',
            subtitle: 'Order from suppliers, send on WhatsApp or SMS, receive stock',
            onTap: () => HomeNav.go(context, HomeNav.purchases, 'Purchase orders'),
            actions: chevron,
          ),
          SettingRow(
            key: const ValueKey('settings-menu-link'),
            icon: LucideIcons.globe,
            title: 'Menu link',
            subtitle: 'Your public menu page: share it, no sign-in needed',
            onTap: () => HomeNav.go(context, HomeNav.menuLink, 'Menu link'),
            actions: chevron,
          ),
          SettingRow(
            key: const ValueKey('settings-delivery'),
            icon: LucideIcons.bike,
            title: 'Delivery settings',
            subtitle: 'Delivery or pickup, radius, fee, minimum order',
            onTap: () => HomeNav.go(context, HomeNav.deliverySettings, 'Delivery settings'),
            actions: chevron,
          ),
        ],
        SettingRow(
          icon: LucideIcons.circleQuestionMark,
          title: 'Support & Help',
          subtitle: s.openRequests > 0 ? '${s.openRequests} open ${s.openRequests == 1 ? 'request' : 'requests'}' : 'We’re here to help you run your store.',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupportScreen(env: widget.env))),
          actions: chevron,
        ),
        if (HomeNav.shell?.kind != 'restaurant')
          SettingRow(
            icon: LucideIcons.truck,
            title: 'Store Delivery',
            subtitle: 'Track requests, stock readiness and orders from picking to delivery',
            onTap: () => HomeNav.go(context, HomeNav.orders, 'Orders'),
            actions: chevron,
          ),
        SettingRow(
          icon: LucideIcons.messageSquareText,
          title: 'Feedback',
          subtitle: 'Report an issue or idea',
          onTap: () => openFeedbackSheet(context, widget.env),
          actions: chevron,
        ),
      ]),
    ];
  }
}

class _ReadOnlyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
        child: Row(children: [
          const Icon(LucideIcons.lock, size: 16, color: kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text('Only the owner or a manager can change these settings.', style: inter(12.5, 400, color: kMuted))),
        ]),
      );
}

class _Loading extends StatelessWidget {
  const _Loading({required this.error, required this.offline, required this.onRetry});
  final String? error;
  final bool offline;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    if (error == null) return const Center(child: CircularProgressIndicator(color: kInk));
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: StatusCard(icon: offline ? LucideIcons.wifiOff : LucideIcons.circleAlert, tone: StateTone.warn, title: offline ? 'You’re offline' : 'Could not open Settings', body: error!, primaryLabel: 'Try again', onPrimary: onRetry),
      ),
    );
  }
}
