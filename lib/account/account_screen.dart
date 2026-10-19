import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_widgets.dart';
import '../home/home_widgets.dart' show kLime;
import '../ui/theme.dart';
import 'account_api.dart';

/// Side nav "Manage account": the signed-in person's name, email and mobile, how they can sign in, where they are signed in, and
/// "Sign out of all devices". Email and mobile change through Supabase's own confirmation; the name is saved on their memberships.
class ManageAccountScreen extends StatefulWidget {
  const ManageAccountScreen({super.key, this.api, this.auth, this.onSignedOut});
  final AccountApi? api;
  final AccountAuth? auth;
  /// Where the app goes once every session is revoked (the sign-in screen). Defaults to the first route.
  final void Function(BuildContext context)? onSignedOut;
  static Route<void> route({AccountApi? api, AccountAuth? auth}) => MaterialPageRoute(builder: (_) => ManageAccountScreen(api: api, auth: auth));
  @override
  State<ManageAccountScreen> createState() => _ManageAccountScreenState();
}

class _ManageAccountScreenState extends State<ManageAccountScreen> {
  late final AccountApi _api = widget.api ?? AccountApi();
  late final AccountAuth _auth = widget.auth ?? SupabaseAccountAuth();
  AccountInfo? _a;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      // a newly confirmed login email reaches the person's memberships (no change when nothing is new)
      try {
        await _api.syncContact();
      } catch (_) {/* the profile still loads */}
      final a = await _api.get();
      if (mounted) setState(() => _a = a);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<String?> _ask(String title, String label, {String initial = '', TextInputType? type, String? hint, String action = 'Save'}) {
    final c = TextEditingController(text: initial);
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(ctx).bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: inter(18, 700)),
          const SizedBox(height: 14),
          CwaField(label: label, controller: c, keyboardType: type, hint: hint, fieldKey: const ValueKey('acct-ask')),
          CwaButton(key: const ValueKey('acct-ask-ok'), label: action, onPressed: () => Navigator.pop(ctx, c.text.trim())),
        ]),
      ),
    );
  }

  Future<void> _run(Future<void> Function() work, String done) async {
    setState(() => _busy = true);
    try {
      await work();
      if (mounted) showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editName() async {
    final name = await _ask('Your name', 'Full name', initial: _a?.name ?? '');
    if (name == null || name.isEmpty || !mounted) return;
    await _run(() async {
      await _api.saveName(name);
      await _auth.setDisplayName(name);
    }, 'Name saved.');
  }

  Future<void> _editEmail() async {
    final email = await _ask('Change email', 'New email', initial: _a?.email ?? '', type: TextInputType.emailAddress, action: 'Send confirmation');
    if (email == null || email.isEmpty || !mounted) return;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      showToast(context, 'That email looks wrong.');
      return;
    }
    await _run(() => _auth.changeEmail(email), 'Open the link we sent to $email to confirm.');
  }

  Future<void> _editPhone() async {
    final raw = await _ask('Change mobile number', 'New mobile number', type: TextInputType.phone, hint: '10-digit mobile', action: 'Send code');
    if (raw == null || !mounted) return;
    final digits = raw.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^(91|0)(?=[6-9]\d{9}$)'), '');
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) {
      showToast(context, 'Enter a 10-digit mobile number.');
      return;
    }
    final e164 = '+91$digits';
    try {
      await _auth.changePhone(e164);
    } catch (e) {
      if (mounted) showToast(context, e.toString());
      return;
    }
    if (!mounted) return;
    final code = await _ask('Enter the code', 'Code sent to ••••••${digits.substring(6)}', type: TextInputType.number, action: 'Confirm');
    if (code == null || code.isEmpty || !mounted) return;
    await _run(() => _auth.confirmPhone(e164, code), 'Mobile number changed.');
  }

  Future<void> _signOutEverywhere() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sign out of all devices?', style: inter(17, 700)),
        content: Text('Every phone and browser signed in with this account, including this one, will need to sign in again.', style: inter(14, 400)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: inter(14, 600, color: kMuted))),
          TextButton(key: const ValueKey('acct-signout-all-yes'), onPressed: () => Navigator.pop(ctx, true), child: Text('Sign out everywhere', style: inter(14, 700, color: kError))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.recordSignOutEverywhere();
      await _auth.signOutEverywhere();
      if (!mounted) return;
      final go = widget.onSignedOut;
      setState(() => _busy = false);
      if (go != null) {
        go(context);
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, e.toString());
        setState(() => _busy = false);
      }
    }
  }

  Widget _line(IconData icon, String label, String value, {String? action, VoidCallback? onTap, Key? key, String? foot}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 18, color: kMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: inter(11.5, 500, color: kMuted)),
              Text(value, style: inter(14.5, 600)),
              if (foot != null) Text(foot, style: inter(11.5, 400, color: const Color(0xFFB54708))),
            ]),
          ),
          if (action != null) TextButton(key: key, onPressed: _busy ? null : onTap, child: Text(action, style: inter(13.5, 600, color: kLink))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        const CwaTopBar(title: 'Manage account'),
        Expanded(
          child: a == null
              ? Center(child: _error != null ? CwaLoadError(message: _error!, onRetry: _load) : const CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
                  CwaCard(
                    child: Column(children: [
                      _line(LucideIcons.user, 'Name', a.name.isEmpty ? 'Not set' : a.name, action: 'Edit', onTap: _editName, key: const ValueKey('acct-edit-name')),
                      const Divider(color: kLine, height: 1),
                      _line(LucideIcons.mail, 'Email', a.email.isEmpty ? 'Not set' : a.email,
                          action: 'Change', onTap: _editEmail, key: const ValueKey('acct-edit-email'),
                          foot: a.pendingEmail != null ? 'Waiting for you to confirm ${a.pendingEmail}' : (!a.emailConfirmed && a.email.isNotEmpty ? 'Not confirmed yet' : null)),
                      const Divider(color: kLine, height: 1),
                      _line(LucideIcons.smartphone, 'Mobile', a.phone == null ? 'Not set' : '+${a.phone}',
                          action: a.phone == null ? 'Add' : 'Change', onTap: _editPhone, key: const ValueKey('acct-edit-phone')),
                    ]),
                  ),
                  const CwaSection('How you sign in'),
                  CwaCard(
                    child: Column(children: [
                      for (final m in a.methods)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Icon(m.enabled ? LucideIcons.circleCheck : LucideIcons.circle, size: 18, color: m.enabled ? kLink : kMuted),
                            const SizedBox(width: 12),
                            Expanded(child: Text(m.label, style: inter(14, m.enabled ? 600 : 400, color: m.enabled ? kInk : kMuted))),
                            Text(
                              m.method == 'partner_code' && m.code != null
                                  ? (m.enabled ? '${m.code} · until ${cwaDate(m.validUntil)}' : 'expired')
                                  : (m.enabled ? 'On' : 'Off'),
                              style: inter(12, 500, color: kMuted),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                  const CwaSection('Where you are signed in'),
                  CwaCard(
                    child: Column(children: [
                      if (a.devices.isEmpty) Text('No active sessions.', style: inter(13, 400, color: kMuted)),
                      for (final d in a.devices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            const Icon(LucideIcons.monitorSmartphone, size: 18, color: kMuted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(d.device, style: inter(13.5, 600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                Text('Last active ${cwaDateTime(d.lastActive)}', style: inter(11.5, 400, color: kMuted)),
                              ]),
                            ),
                            if (d.thisDevice)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: kLime, borderRadius: BorderRadius.circular(10)),
                                child: Text('This device', style: inter(10.5, 700, color: kPrimary)),
                              ),
                          ]),
                        ),
                    ]),
                  ),
                  if (a.memberships.isNotEmpty) ...[
                    const CwaSection('Your businesses'),
                    CwaCard(
                      child: Column(children: [
                        for (final m in a.memberships)
                          CwaRow('${m['organization'] ?? ''}${m['location'] == null ? '' : ' · ${m['location']}'}', '${m['role_name'] ?? m['role'] ?? ''}', strong: m['current'] == true),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 22),
                  CwaButton(
                      key: const ValueKey('acct-signout-all'),
                      label: 'Sign out of all devices',
                      icon: LucideIcons.logOut,
                      danger: true,
                      busy: _busy,
                      onPressed: _signOutEverywhere),
                ]),
        ),
      ]),
    );
  }
}
