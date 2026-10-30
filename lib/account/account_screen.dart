import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_widgets.dart';
import '../home/control_centre_screen.dart' show initials;
import '../home/home_widgets.dart' show kLime;
import '../settings/settings_widgets.dart' show GroupCard, GroupTitle, RowAction, SettingRow, StatusPill;
import '../ui/theme.dart';
import '../auth/partner_api.dart' show PartnerApiException;
import 'account_api.dart';
import 'delete_account_screen.dart';
import '../ui/motion.dart';

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

  Future<String?> _ask(String title, String label, {String initial = '', TextInputType? type, String? hint, String action = 'Save', bool mobile = false}) {
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
          CwaField(label: label, controller: c, keyboardType: type, hint: hint, mobile: mobile, fieldKey: const ValueKey('acct-ask')),
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
    final raw = await _ask('Change mobile number', 'New mobile number', mobile: true, hint: '10-digit mobile', action: 'Send code');
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

  /// Set a password, or change it (founder, 27 Oct 2026). It is for signing in with the email and this password, so an email is
  /// needed first. When the login server asks for proof, a one-time code goes to the email and is asked for here.
  Future<void> _password(bool has) async {
    final a = _a;
    if (a == null) return;
    // the password goes with the email or the mobile number: one of them is needed
    final login = [if (a.email.isNotEmpty) a.email, if (a.phone != null) '+${a.phone}'].join(' or ');
    if (login.isEmpty) {
      showToast(context, 'Add an email or a mobile number first: you sign in with it and this password.');
      return;
    }
    final p = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _PasswordSheet(has: has, email: login),
    );
    if (p == null || !mounted) return;
    final done = has ? 'Password changed.' : 'Password set. You can now sign in with $login and this password.';
    try {
      setState(() => _busy = true);
      try {
        await _auth.setPassword(p);
      } on PasswordNeedsCode {
        await _auth.reauthenticate();
        if (!mounted) return;
        setState(() => _busy = false);
        final code = await _ask('Enter the code', 'Code sent to ${a.email.isNotEmpty ? a.email : '+${a.phone}'}', type: TextInputType.number, action: 'Confirm');
        if (code == null || code.isEmpty || !mounted) return;
        setState(() => _busy = true);
        await _auth.setPassword(p, nonce: code);
      }
      if (!mounted) return;
      showToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOutEverywhere() async {
    final yes = await showOlDialog<bool>(
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

  /// Delete account: its own screen with the warnings and the typed DELETE; once asked, every device is signed out.
  Future<void> _deleteAccount() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => DeleteAccountScreen(api: _api, auth: _auth)));
    if (done != true || !mounted) return;
    showToast(context, 'Your account will be deleted in 30 days. Sign in again before then to keep it.');
    final go = widget.onSignedOut;
    if (go != null) {
      go(context);
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  // Laid out like the Settings page (Figma section P, there is no Manage account frame): a profile card, then grouped white
  // cards of rows (round green icon, title, status line, green action on the right).
  Widget _profile(AccountInfo a) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFECEDE8))),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
            child: Text(initials(a.name.isEmpty ? a.email : a.name), style: inter(16, 700, color: kPrimary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name.isEmpty ? 'Your account' : a.name, style: inter(16, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text([if (a.email.isNotEmpty) a.email, if (a.phone != null) '+${a.phone}'].join(' · '),
                  style: inter(12, 400, color: kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );

  Widget _act(String label, VoidCallback onTap, Key key) => RowAction(label, key: key, onTap: _busy ? null : onTap);

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
              : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
                  _profile(a),
                  const GroupTitle('Profile'),
                  GroupCard(children: [
                    SettingRow(icon: LucideIcons.user, title: 'Name', subtitle: a.name.isEmpty ? 'Not set' : a.name, actions: [_act('Edit', _editName, const ValueKey('acct-edit-name'))]),
                    SettingRow(
                      icon: LucideIcons.mail,
                      title: 'Email',
                      subtitle: [
                        a.email.isEmpty ? 'Not set' : a.email,
                        if (a.pendingEmail != null) 'Waiting for you to confirm ${a.pendingEmail}' else if (!a.emailConfirmed && a.email.isNotEmpty) 'Not confirmed yet',
                      ].join(' · '),
                      actions: [_act('Change', _editEmail, const ValueKey('acct-edit-email'))],
                    ),
                    SettingRow(
                      icon: LucideIcons.smartphone,
                      title: 'Mobile number',
                      subtitle: a.phone == null ? 'Not set' : '+${a.phone}',
                      actions: [_act(a.phone == null ? 'Add' : 'Change', _editPhone, const ValueKey('acct-edit-phone'))],
                    ),
                  ]),
                  const GroupTitle('How you sign in'),
                  GroupCard(children: [
                    for (final m in a.methods)
                      SettingRow(
                        icon: m.method == 'partner_code' ? LucideIcons.keyRound : m.method == 'google' ? LucideIcons.globe : m.method.contains('phone') || m.method.contains('sms') ? LucideIcons.smartphone : LucideIcons.mail,
                        title: m.label,
                        subtitle: m.method == 'partner_code' && m.code != null
                            ? (m.enabled ? '${m.code} · until ${cwaDate(m.validUntil)}' : 'Expired')
                            : (m.enabled ? 'You can sign in this way' : 'Not set up'),
                        actions: [
                          StatusPill(m.enabled ? 'On' : 'Off', good: m.enabled),
                          // the password is the one method set here: Set when there is none, Change when there is
                          if (m.method == 'password') _act(m.enabled ? 'Change' : 'Set', () => _password(m.enabled), const ValueKey('acct-password')),
                        ],
                      ),
                  ]),
                  const GroupTitle('Where you are signed in'),
                  GroupCard(children: [
                    if (a.devices.isEmpty) const SettingRow(icon: LucideIcons.monitorSmartphone, title: 'No active sessions', subtitle: 'Sign in on a phone or browser to see it here'),
                    for (final d in a.devices)
                      SettingRow(
                        icon: LucideIcons.monitorSmartphone,
                        title: d.device,
                        subtitle: 'Last active ${cwaDateTime(d.lastActive)}',
                        actions: [if (d.thisDevice) const StatusPill('This device', good: true)],
                      ),
                  ]),
                  if (a.memberships.isNotEmpty) ...[
                    const GroupTitle('Your businesses'),
                    GroupCard(children: [
                      for (final m in a.memberships)
                        SettingRow(
                          icon: LucideIcons.store,
                          title: '${m['organization'] ?? ''}${m['location'] == null ? '' : ' · ${m['location']}'}',
                          subtitle: '${m['role_name'] ?? m['role'] ?? ''}',
                          actions: [if (m['current'] == true) const StatusPill('Current', good: true)],
                        ),
                    ]),
                  ],
                  const SizedBox(height: 22),
                  CwaButton(
                      key: const ValueKey('acct-signout-all'),
                      label: 'Sign out of all devices',
                      icon: LucideIcons.logOut,
                      danger: true,
                      busy: _busy,
                      onPressed: _signOutEverywhere),
                  // apart from everything else, at the very end
                  const SizedBox(height: 48),
                  const Divider(color: Color(0xFFE3E5DF)),
                  const SizedBox(height: 20),
                  DeleteAccountCard(onPressed: _busy ? null : _deleteAccount),
                ]),
        ),
      ]),
    );
  }
}

/// New password, typed twice; it can be shown. At least 8 characters with a letter and a number (the login server checks again).
class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.has, required this.email});
  final bool has;
  final String email;
  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _one = TextEditingController(), _two = TextEditingController();
  bool _show = false;
  String? _problem;

  @override
  void dispose() {
    _one.dispose();
    _two.dispose();
    super.dispose();
  }

  void _save() {
    final p = _one.text;
    final why = p.length < 8
        ? 'Use at least 8 characters.'
        : !RegExp(r'[A-Za-z]').hasMatch(p) || !RegExp(r'\d').hasMatch(p)
            ? 'Use letters and numbers.'
            : p != _two.text
                ? 'The two passwords are not the same.'
                : null;
    if (why != null) return setState(() => _problem = why);
    Navigator.pop(context, p);
  }

  Widget _field(TextEditingController c, String label, Key key) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: key,
          controller: c,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _problem = null),
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon: IconButton(
              tooltip: _show ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _show = !_show),
              icon: Icon(_show ? LucideIcons.eyeOff : LucideIcons.eye, size: 18),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.has ? 'Change password' : 'Set a password', style: inter(18, 700)),
            const SizedBox(height: 4),
            Text('You sign in with ${widget.email} and this password. At least 8 characters, with letters and numbers.', style: inter(13, 400, color: kMuted, height: 1.35)),
            const SizedBox(height: 14),
            _field(_one, widget.has ? 'New password' : 'Password', const ValueKey('acct-password-new')),
            _field(_two, 'Type it again', const ValueKey('acct-password-again')),
            if (_problem != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_problem!, key: const ValueKey('acct-password-problem'), style: inter(13, 600, color: kError))),
            CwaButton(key: const ValueKey('acct-password-save'), label: widget.has ? 'Change password' : 'Set password', onPressed: _save),
          ]),
        ),
      );
}
