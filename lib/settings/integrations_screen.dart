import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../orders/order_widgets.dart' show OrdersTopBar, kBadText, kChipGreen, kGreenText, kLimeSoft, kWarnBg, kWarnText;
import '../states/state_kit.dart' show StateTone, StatusCard;
import '../ui/theme.dart';
import 'integrations_api.dart';
import 'settings_api.dart';
import 'settings_sheets.dart' show FormCtx, FormSheet;
import 'settings_widgets.dart';

/// Settings -> Integrations: connect the POS or billing software a business already uses (Petpooja, GoFrugal). Everything shown is what
/// `pos_integrations_get` says. Connecting sends the keys once to the server, which checks them with the provider and keeps them encrypted;
/// they are never shown again. Who may change it is the database's decision (`can_edit`); everyone else sees the page read-only.
class IntegrationsScreen extends StatefulWidget {
  IntegrationsScreen({super.key, SettingsEnv? env}) : env = env ?? SettingsEnv();
  final SettingsEnv env;

  @override
  State<IntegrationsScreen> createState() => _IntegrationsScreenState();
}

class _IntegrationsScreenState extends State<IntegrationsScreen> {
  IntegrationsState? _s;
  String? _error;
  bool _offline = false;

  /// The provider an action is running for: its buttons and switches wait.
  String? _busy;

  IntegrationsApi get _api => widget.env.integrations;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _offline = false;
    });
    try {
      final s = await _api.get();
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _offline = e is! PartnerApiException;
        _error = e is PartnerApiException ? e.message : 'Could not reach the server. Check your connection and try again.';
      });
    }
  }

  /// Runs one server action for [provider]; on success the page becomes its answer and [done] (if any) is shown.
  Future<IntegrationsState?> _run(String provider, Future<IntegrationsState> Function() call, {String? done}) async {
    setState(() => _busy = provider);
    final next = await guarded(context, call);
    if (!mounted) return null;
    setState(() {
      _busy = null;
      if (next != null) _s = next;
    });
    if (next != null && done != null) showToast(context, done);
    return next;
  }

  Future<void> _connect(IntegrationInfo i) async {
    final next = await openConnectSheet(context, _api, i);
    if (!mounted || next == null) return;
    setState(() => _s = next);
    showToast(context, '${providerInfo(i.provider).name} connected.');
  }

  Future<void> _test(IntegrationInfo i) async {
    final next = await _run(i.provider, () => _api.test(i.provider));
    final c = next?.check;
    if (c != null && mounted) showToast(context, c.message.isEmpty ? (c.ok ? 'Connection works.' : 'The connection check failed.') : c.message);
  }

  Future<void> _disconnect(IntegrationInfo i) async {
    final name = providerInfo(i.provider).name;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect $name?', style: inter(17, 700)),
        content: Text('The saved $name keys are deleted from One Local and nothing more is synced. Nothing changes in your $name account.', style: inter(14, 400)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: inter(14, 600, color: kMuted))),
          TextButton(key: ValueKey('integration-disconnect-yes-${i.provider}'), onPressed: () => Navigator.pop(ctx, true), child: Text('Disconnect', style: inter(14, 700, color: kError))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _run(i.provider, () => _api.disconnect(i.provider), done: '$name disconnected.');
  }

  void _back() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        OrdersTopBar(title: 'Integrations', onBack: _back),
        Expanded(
          child: s == null
              ? _Loading(error: _error, offline: _offline, onRetry: _load)
              : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: _body(s))),
        ),
      ]),
    );
  }

  List<Widget> _body(IntegrationsState s) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
          child: Text('Connect the POS or billing software you already use. Your keys are checked with the provider before they are saved.', style: inter(13, 500, color: kMuted, height: 1.35)),
        ),
        if (!s.canEdit) const Padding(padding: EdgeInsets.only(top: 10), child: _ReadOnlyNote()),
        for (final i in s.integrations) ...[const SizedBox(height: 14), _card(i, s.canEdit)],
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.lock, size: 14, color: kMuted)),
          const SizedBox(width: 6),
          Expanded(child: Text('Keys are stored encrypted and are never shown again. Disconnecting deletes them from One Local.', style: inter(12, 400, color: kMuted, height: 1.35))),
        ]),
      ];

  Widget _card(IntegrationInfo i, bool edit) {
    final p = providerInfo(i.provider);
    final busy = _busy == i.provider;
    final idle = _busy == null;
    Widget sw(IconData icon, (String, String) label, bool value, Future<IntegrationsState> Function(bool) save) => SettingRow(
          icon: icon,
          title: label.$1,
          subtitle: label.$2,
          actions: [LimeSwitch(label: '${p.name} ${label.$1}', value: value, onChanged: edit && idle ? (v) => _run(i.provider, () => save(v)) : null)],
        );
    return Container(
      key: ValueKey('integration-${i.provider}'),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFECEDE8))),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _Mark(p.name),
              const SizedBox(width: 12),
              Expanded(child: Text(p.name, style: inter(15.5, 700))),
              const SizedBox(width: 8),
              _StatePill(i),
            ]),
            // under the name row, not beside the pill, so it keeps the card's width on a phone
            if (p.blurb.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(p.blurb, style: inter(12.5, 400, color: kMuted, height: 1.4))),
          ]),
        ),
        if (i.isConnected && edit) _details(i),
        if (i.isConnected) ...[
          const Divider(height: 1, thickness: 1, color: Color(0xFFF1F2EE)),
          Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 0), child: Text('WHAT TO SYNC', style: inter(11, 700, color: kMuted).copyWith(letterSpacing: 0.4))),
          sw(LucideIcons.bookOpen, p.menu, i.syncMenu, (v) => _api.setSync(i.provider, menu: v)),
          sw(LucideIcons.receipt, p.orders, i.syncOrders, (v) => _api.setSync(i.provider, orders: v)),
          sw(LucideIcons.package, p.stock, i.syncStock, (v) => _api.setSync(i.provider, stock: v)),
        ],
        if (edit) ...[
          const Divider(height: 1, thickness: 1, color: Color(0xFFF1F2EE)),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: busy
                ? const SizedBox(height: 40, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))))
                : i.isConnected
                    ? Wrap(alignment: WrapAlignment.spaceBetween, children: [
                        RowAction('Test connection', onTap: idle ? () => _test(i) : null),
                        RowAction('Update keys', onTap: idle ? () => _connect(i) : null),
                        _DangerAction('Disconnect', onTap: idle ? () => _disconnect(i) : null),
                      ])
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                        child: PanelButton('Connect ${p.name}', onPressed: idle ? () => _connect(i) : null),
                      ),
          ),
        ],
      ]),
    );
  }

  Widget _details(IntegrationInfo i) {
    final at = i.lastCheckAt;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(12), border: Border.all(color: kFieldBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (i.restaurantId != null) _Fact('Restaurant ID', i.restaurantId!),
        if (i.storeUrl != null) _Fact('Store URL', i.storeUrl!),
        if (i.outletId != null) _Fact('Outlet', i.outletId!),
        if (i.keyHint != null) _Fact('Key', '•••• ${i.keyHint}'),
        if (at != null) _Fact('Last checked', _when(at)),
        if (i.lastCheckMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(i.lastCheckOk == false ? LucideIcons.circleAlert : LucideIcons.circleCheck, size: 15, color: i.lastCheckOk == false ? kWarnText : kGreenText),
              const SizedBox(width: 6),
              Expanded(child: Text(i.lastCheckMessage!, style: inter(12, 500, color: i.lastCheckOk == false ? kWarnText : kGreenText, height: 1.35))),
            ]),
          ),
      ]),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "23 Oct, 4:05 PM".
String _when(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${t.day} ${_months[t.month - 1]}, $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// The sheet that sends a provider's keys. On success it closes with the new page; on refusal it shows the server's sentence (the
/// provider's own reason when it gave one) and keeps what was typed.
Future<IntegrationsState?> openConnectSheet(BuildContext context, IntegrationsApi api, IntegrationInfo current) {
  final p = providerInfo(current.provider);
  final petpooja = current.provider == 'petpooja';
  // the only check here is "is it empty"; the server and the provider check the rest
  String? missing(FormCtx f, Map<String, String> fields) {
    for (final e in fields.entries) {
      if (f.text(e.key).isEmpty) return 'Enter the ${e.value}.';
    }
    return null;
  }

  return showSettingsSheet<IntegrationsState>(
    context,
    title: current.isConnected ? 'Update ${p.name} keys' : 'Connect ${p.name}',
    subtitle: 'We check these with ${p.name} before saving them.',
    body: (_) => FormSheet<IntegrationsState>(
      button: current.isConnected ? 'Check & save' : 'Check & connect',
      initial: petpooja
          ? {'rid': current.restaurantId ?? '', 'key': '', 'secret': '', 'token': ''}
          : {'url': current.storeUrl ?? '', 'key': '', 'outlet': current.outletId ?? ''},
      validate: (f) => petpooja
          ? missing(f, {'rid': 'restaurant ID', 'key': 'app key', 'secret': 'app secret', 'token': 'access token'})
          : missing(f, {'url': 'store URL', 'key': 'API key'}),
      submit: (f) => petpooja
          ? api.connectPetpooja(restaurantId: f.text('rid'), appKey: f.text('key'), appSecret: f.text('secret'), accessToken: f.text('token'))
          : api.connectGofrugal(storeUrl: f.text('url'), apiKey: f.text('key'), outletId: f.text('outlet')),
      children: (f) => [
        if (p.help.isNotEmpty) _HelpNote(p.help),
        if (petpooja) ...[
          SheetField(label: 'Restaurant ID', controller: f.ctl('rid'), hint: 'restID from Petpooja'),
          SheetField(label: 'App key', controller: f.ctl('key'), hint: 'Paste the app key', obscure: true),
          SheetField(label: 'App secret', controller: f.ctl('secret'), hint: 'Paste the app secret', obscure: true),
          SheetField(label: 'Access token', controller: f.ctl('token'), hint: 'Paste the access token', obscure: true),
        ] else ...[
          SheetField(label: 'Store URL', controller: f.ctl('url'), hint: 'http://yourstore.example.com/WebReporter', keyboardType: TextInputType.url, helper: 'Ends in /WebReporter, or /RayMedi_HQ for GoFrugal HQ. It must be reachable from the internet.'),
          SheetField(label: 'API key', controller: f.ctl('key'), hint: 'Paste the X-Auth-Token', obscure: true),
          SheetField(label: 'Outlet ID (optional)', controller: f.ctl('outlet'), hint: 'Only if your GoFrugal has several outlets'),
        ],
        if (current.isConnected) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Saved keys are never shown. Enter them again to replace them.', style: inter(12, 400, color: kMuted))),
      ],
    ),
  );
}

class _HelpNote extends StatelessWidget {
  const _HelpNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(LucideIcons.info, size: 16, color: kGreenText),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: inter(12, 500, color: kGreenText, height: 1.4))),
        ]),
      );
}

/// A rounded square with the provider's first letter (no third-party logo is drawn).
class _Mark extends StatelessWidget {
  const _Mark(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(12)),
        child: Center(child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: inter(17, 800, color: kGreenText))),
      );
}

/// "• Connected" (green), "• Needs attention" (amber), "• Not connected" (grey).
class _StatePill extends StatelessWidget {
  const _StatePill(this.i);
  final IntegrationInfo i;
  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = i.needsAttention
        ? ('Needs attention', kWarnText, kWarnBg)
        : i.isConnected
            ? ('Connected', kGreenText, kLimeSoft)
            : ('Not connected', kMuted, const Color(0xFFF1F2EE));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: inter(12, 600, color: fg)),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 104, child: Text(label, style: inter(12, 500, color: kMuted))),
          Expanded(child: Text(value, style: inter(12.5, 600, height: 1.3))),
        ]),
      );
}

/// The red text button of a card ("Disconnect").
class _DangerAction extends StatelessWidget {
  const _DangerAction(this.label, {this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10), child: Text(label, style: inter(13.5, 600, color: kBadText)))),
      );
}

class _ReadOnlyNote extends StatelessWidget {
  const _ReadOnlyNote();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
        child: Row(children: [
          const Icon(LucideIcons.lock, size: 16, color: kMuted),
          const SizedBox(width: 8),
          Expanded(child: Text('Only the owner or a manager can connect or change integrations.', style: inter(12.5, 400, color: kMuted))),
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
        child: StatusCard(icon: offline ? LucideIcons.wifiOff : LucideIcons.circleAlert, tone: StateTone.warn, title: offline ? 'You’re offline' : 'Could not open Integrations', body: error!, primaryLabel: 'Try again', onPrimary: onRetry),
      ),
    );
  }
}
