import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../home/home_nav.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kChipGreen, kGreenText, kLime, kLimeSoft, kWarnBg, kWarnText;
import '../states/state_kit.dart' show StateTone, StatusCard;
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'returns_screens.dart';
import 'settings_api.dart';
import 'settings_sheets.dart';
import 'settings_widgets.dart';
import 'support_screens.dart';

/// Settings and store profile (Figma section P "Settings"). Everything shown is what `pos_settings_get` says; every Edit opens one sheet
/// that saves one field group. Who may save is the database's decision (`can_edit`); a person who may not sees the page read-only.
class SettingsScreen extends StatefulWidget {
  SettingsScreen({super.key, SettingsEnv? env}) : env = env ?? SettingsEnv();
  final SettingsEnv env;

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

  Future<void> _setLanguage(String code) async {
    if (code == _s?.language) return;
    setState(() => _busy = true);
    final next = await guarded(context, () => widget.env.api.saveLanguage(code));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (next != null) _s = next;
    });
    if (next != null) {
      setAppLanguage(code); // every screen switches at once
      showToast(context, 'Language: ${kLanguages[code] ?? code}.');
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

  /// The open section (one of [_parts]), or null for the section cards.
  String? _part;

  /// Back closes an open section first, then Settings.
  void _back() => _part != null ? setState(() => _part = null) : Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final part = s == null ? null : _parts(s).where((p) => p.id == _part).firstOrNull;
    return PopScope(
      canPop: _part == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _part = null);
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: Column(
          children: [
            OrdersTopBar(title: tr(part?.title ?? 'Settings'), onBack: _back),
            Expanded(
              child: s == null
                  ? _Loading(error: _error, offline: _offline, onRetry: _load)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        children: part == null ? _hub(s) : [const SizedBox(height: 10), GroupCard(children: part.rows)],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// The section cards (founder, 26 Oct 2026): Store · Orders & delivery · Team & access · Money & documents · Me & app, each with a
  /// one-line summary; one tap opens its rows.
  List<Widget> _hub(SettingsState s) => [
    ..._notes(s),
    const SizedBox(height: 6),
    for (final p in _parts(s))
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: kLine),
          ),
          child: InkWell(
            key: ValueKey('settings-part-${p.id}'),
            borderRadius: BorderRadius.circular(18),
            onTap: p.open ?? () => setState(() => _part = p.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kLimeSoft, borderRadius: BorderRadius.circular(12)),
                    child: Icon(p.icon, size: 20, color: kInk),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr(p.title), style: inter(15.5, 700)),
                        const SizedBox(height: 2),
                        Text(
                          p.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: inter(12.5, 400, color: kMuted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
                ],
              ),
            ),
          ),
        ),
      ),
  ];

  /// The store's name, and the warnings (settings not loaded, read-only) above the cards.
  List<Widget> _notes(SettingsState s) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(s.businessName.isEmpty ? 'Store preferences' : s.businessName, style: inter(13, 500, color: kMuted)),
          ),
        ],
      ),
    ),
    if (_unloaded != null)
      Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(color: kWarnBg, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            const Icon(LucideIcons.circleAlert, size: 18, color: kWarnText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your saved settings could not be loaded, so everything shows as not set. Saving may not work yet. ($_unloaded)',
                style: inter(12, 500, color: kWarnText, height: 1.35),
              ),
            ),
            TextButton(
              onPressed: _load,
              child: Text(tr('Try again'), style: inter(12, 700, color: kWarnText)),
            ),
          ],
        ),
      ),
    if (!s.canEdit) Padding(padding: const EdgeInsets.only(top: 10), child: _ReadOnlyNote()),
  ];

  /// Each section's rows, with the one-line summary its card shows. The bank details show only to whoever may see them (the
  /// server's `bank_visible`: the owner); everyone else sees just the documents in Money & documents.
  List<_Part> _parts(SettingsState s) {
    final edit = s.canEdit;
    Widget editBtn(Future<SettingsState?> Function(BuildContext, SettingsEnv, SettingsState) open) =>
        edit ? RowAction(tr('Edit'), onTap: () => _sheet(open)) : const SizedBox(width: 8);
    const go = [Icon(LucideIcons.chevronRight, size: 18, color: kMuted)];
    final bank = s.bankStatus;
    String onOff(bool v) => v ? 'on' : 'off';
    return [
      _Part(
        'store',
        'Store',
        LucideIcons.store,
        '${clock12(s.opensAt)} – ${clock12(s.closesAt)} · ${s.address == null ? 'location not added' : 'location set'}',
        [
          SettingRow(icon: LucideIcons.mapPin, title: tr('Location'), subtitle: s.address ?? 'Not added', actions: [editBtn(openLocationSheet)]),
          SettingRow(
            icon: LucideIcons.clock,
            title: tr('Opening & closing timings'),
            subtitle: 'Opening: ${clock12(s.opensAt)} · Closing: ${clock12(s.closesAt)}',
            actions: [editBtn(openHoursSheet)],
          ),
          SettingRow(
            icon: LucideIcons.qrCode,
            title: tr('Payment QR'),
            subtitle: s.qrUploaded ? 'QR uploaded' : 'Upload or manage your store QR code',
            actions: [RowAction(tr('Edit'), onTap: () => _sheet(openQrSheet))],
          ),
        ],
      ),
      _Part(
        'orders',
        'Orders & delivery',
        LucideIcons.truck,
        '${s.prepMinutes == null ? 'Ready time not set' : 'Ready in ${s.prepMinutes} min'} · pickup ${onOff(s.pickup)} · QR checkout ${onOff(s.qrCheckout)}',
        [
          if (HomeNav.deliverySettings != null)
            SettingRow(
              key: const ValueKey('settings-delivery-area'),
              icon: LucideIcons.mapPinned,
              title: tr('Delivery area & charges'),
              subtitle: tr('Delivery distance, fee, minimum order, free delivery above'),
              onTap: () => HomeNav.deliverySettings!(context),
              actions: go,
            ),
          SettingRow(
            icon: LucideIcons.timer,
            title: tr('Delivery time / readiness'),
            subtitle: s.prepMinutes == null ? 'Not set' : '${s.prepMinutes} min',
            actions: [editBtn(openReadinessSheet)],
          ),
          SettingRow(
            icon: LucideIcons.shoppingBag,
            title: tr('Online self-pickup orders'),
            subtitle: '${s.pickup ? 'On' : 'Off'} · Accept orders for store pickup',
            onTap: edit ? () => _sheet(openPickupSheet) : null,
            actions: [
              LimeSwitch(label: tr('Online self-pickup orders'), value: s.pickup, onChanged: edit && !_busy ? (v) => _toggle(widget.env.api.setPickup, v) : null),
            ],
          ),
          SettingRow(
            icon: LucideIcons.scanQrCode,
            title: tr('QR self-checkout'),
            subtitle: '${s.qrCheckout ? 'On' : 'Off'} · Let customers scan and pay',
            onTap: edit ? () => _sheet(openQrCheckoutSheet) : null,
            actions: [
              LimeSwitch(label: tr('QR self-checkout'), value: s.qrCheckout, onChanged: edit && !_busy ? (v) => _toggle(widget.env.api.setQrCheckout, v) : null),
            ],
          ),
          // no "Store Delivery" row: tracking orders is the Online order tab, not a setting (founder, 26 Oct 2026)
        ],
      ),
      _Part(
        'team',
        'Team & access',
        LucideIcons.users,
        '${s.activeUsers == 1 ? '1 user' : '${s.activeUsers} users'}${s.ownerName == null ? '' : ' · owner ${s.ownerName}'}',
        [
          // Users, roles and invites belong to the Team section (L). This row only points there.
          SettingRow(
            icon: LucideIcons.userPlus,
            title: tr('Manage store access'),
            subtitle: s.activeUsers == 1 ? '1 user' : '${s.activeUsers} users',
            actions: [LimePill(tr('Add users'), onTap: () => HomeNav.go(context, HomeNav.team, 'Team'))],
          ),
          SettingRow(
            icon: LucideIcons.user,
            title: tr('Owner'),
            subtitle: s.ownerName == null ? 'Not added' : '${s.ownerName} · +91 ${s.ownerPhone}',
            actions: [editBtn(openOwnerSheet)],
          ),
          SettingRow(
            icon: LucideIcons.phone,
            title: tr('Staff number'),
            subtitle: s.staffPhone == null ? 'Not added' : '+91 ${s.staffPhone}',
            actions: [editBtn(openStaffPhoneSheet)],
          ),
          SettingRow(
            icon: LucideIcons.headset,
            title: tr('Help / replacements'),
            subtitle: s.helpName == null ? 'Not added' : '${s.helpName} · +91 ${s.helpPhone}',
            actions: [editBtn(openHelpSheet)],
          ),
        ],
      ),
      _Part(
        'money',
        'Money & documents',
        LucideIcons.landmark,
        [
          if (bank != null) s.bankLast4 == null ? 'Bank not added' : 'Bank ••${s.bankLast4} ${bank == 'verified' ? 'verified' : 'not verified'}',
          '${s.documentCount} ${s.documentCount == 1 ? 'document' : 'documents'}',
        ].join(' · '),
        [
          if (bank != null) ...[
            SettingRow(
              icon: LucideIcons.landmark,
              title: tr('Bank details'),
              subtitle: '${s.bankLast4 == null ? 'Not added' : 'Account ending ${s.bankLast4}'} · ${bank == 'verified' ? 'Verified' : 'Unverified'}',
              actions: [
                if (edit) RowAction(tr('Edit'), onTap: () => _sheet(openBankSheet)),
                if (edit && bank != 'verified') RowAction(tr('Verify'), onTap: () => _sheet(openBankSheet)),
              ],
            ),
            WarnStrip(tr('Bank details must match the Shop Act.')),
          ],
          SettingRow(
            icon: LucideIcons.files,
            title: tr('Documents'),
            subtitle: s.documentCount == 0 ? 'Manage store documents' : '${s.documentCount} ${s.documentCount == 1 ? 'document' : 'documents'}',
            actions: [
              RowAction(
                'Edit',
                onTap: () => _sheet((c, e, st) async {
                  await openDocumentsSheet(c, e, st);
                  return null;
                }),
              ),
            ],
          ),
        ],
      ),
      // Returns, refunds & replacements (founder's spec, 29 Oct 2026): one tap opens its own page
      _Part('returns', 'Returns & refunds', LucideIcons.packageCheck, 'Policy for each category · always-covered claims', const [],
          open: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReturnsHomeScreen(api: widget.env.returns)))),
      _Part('me', 'Me & app', LucideIcons.settings2, '${kLanguages[s.language] ?? s.language} · help · feedback', [
        // one step (founder, 26 Oct 2026): the three languages right on the row; a tap saves it, no sheet
        _LanguageRow(current: s.language, onPick: edit && !_busy ? _setLanguage : null),
        SettingRow(
          icon: LucideIcons.circleQuestionMark,
          title: tr('Support & Help'),
          subtitle: s.openRequests > 0 ? '${s.openRequests} open ${s.openRequests == 1 ? 'request' : 'requests'}' : 'We’re here to help you run your store.',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupportScreen(env: widget.env))),
          actions: go,
        ),
        SettingRow(
          icon: LucideIcons.messageSquare,
          title: tr('Feedback'),
          subtitle: tr('Report an issue or idea'),
          onTap: () => openFeedbackSheet(context, widget.env),
          actions: go,
        ),
      ]),
    ];
  }
}

/// One Settings section: its card (icon, title, summary) and the rows it opens.
class _Part {
  const _Part(this.id, this.title, this.icon, this.summary, this.rows, {this.open});
  final String id, title, summary;
  final IconData icon;
  final List<Widget> rows;
  /// Set when the card opens a page of its own instead of rows.
  final VoidCallback? open;
}

/// Language as a three-way toggle on the row itself: English · हिन्दी · Hinglish. [onPick] null: read-only.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.current, required this.onPick});
  final String current;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(width: 36, height: 36, decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(12)), child: const Icon(LucideIcons.languages, size: 18, color: kGreenText)),
            const SizedBox(width: 12),
            Text(tr('Language'), style: inter(14.5, 600)),
          ]),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: const Color(0xFFF1F3EE), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              for (final (code, label) in const [('en', 'English'), ('hi', 'हिन्दी'), ('hi-en', 'Hinglish')])
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: current == code,
                    label: kLanguages[code] ?? label,
                    excludeSemantics: true,
                    child: Material(
                      color: current == code ? kLime : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        key: ValueKey('language-$code'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: onPick == null || current == code ? null : () => onPick!(code),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Text(label, textAlign: TextAlign.center, style: inter(13.5, current == code ? 800 : 500, color: current == code ? kInk : kMuted)),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      );
}

class _ReadOnlyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: kLine),
    ),
    child: Row(
      children: [
        const Icon(LucideIcons.lock, size: 16, color: kMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tr('Only the owner or a manager can change these settings.'), style: inter(12.5, 400, color: kMuted)),
        ),
      ],
    ),
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
        child: StatusCard(
          icon: offline ? LucideIcons.wifiOff : LucideIcons.circleAlert,
          tone: StateTone.warn,
          title: offline ? 'You’re offline' : 'Could not open Settings',
          body: error!,
          primaryLabel: tr('Try again'),
          onPrimary: onRetry,
        ),
      ),
    );
  }
}
