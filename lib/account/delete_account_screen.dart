import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../customers/customer_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'account_api.dart';

// Delete account (founder, 31 Oct 2026): at the very end of Manage account, apart from everything else. Three warnings before anything
// happens — what is lost (and which businesses nobody else can run), "are you sure?", then type DELETE — and a 30-day grace period:
// the person is signed out everywhere at once, signing in within 30 days cancels it, after that the login and personal details are gone.

const _red = Color(0xFFC62828);
const _redWash = Color(0xFFFDECEC);

/// The danger card at the end of Manage account: red border, one line, one red button.
class DeleteAccountCard extends StatelessWidget {
  const DeleteAccountCard({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('acct-danger'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _red.withValues(alpha: 0.5), width: 1.2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(LucideIcons.triangleAlert, size: 18, color: _red),
            const SizedBox(width: 8),
            Text('Danger zone', style: inter(15, 800, color: _red)),
          ]),
          const SizedBox(height: 6),
          Text('Delete your OneLocal account and your personal details. This cannot be undone after 30 days.', style: inter(13, 500, color: kMuted, height: 1.4)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('acct-delete'),
            onPressed: onPressed,
            icon: const Icon(LucideIcons.trash2, size: 18, color: _red),
            label: Text('Delete account', style: inter(15, 700, color: _red)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              side: const BorderSide(color: _red, width: 1.4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ]),
      );
}

/// The delete flow. Pops true once the request is saved and every device is signed out.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key, required this.api, required this.auth});
  final AccountApi api;
  final AccountAuth auth;
  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  Map<String, dynamic>? _preview;
  String? _error;
  int _step = 0; // 0: what you lose · 1: type DELETE
  bool _understood = false, _busy = false;
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final p = await widget.api.deletePreview();
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = e is AccountApiException ? e.message : 'Could not load your account. Check your connection and try again.');
    }
  }

  List<String> get _soleOwner => ((_preview?['sole_owner_of'] as List?) ?? const []).map((e) => '$e').toList();
  int get _memberships => ((_preview?['memberships'] as num?) ?? 0).toInt();

  /// Warning two: "Are you really sure?"
  Future<void> _continue() async {
    final yes = await showOlDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('del-sure'),
        icon: const Icon(LucideIcons.triangleAlert, color: _red, size: 30),
        title: Text('Are you really sure?', style: inter(18, 800)),
        content: Text(
          [
            'You will be signed out of every phone and computer right now.',
            if (_soleOwner.isNotEmpty) 'Nobody else will be able to run ${_soleOwner.join(', ')}.',
            'After 30 days your account is deleted for good and cannot be brought back.',
          ].join('\n\n'),
          style: inter(14, 500, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(key: const ValueKey('del-sure-no'), onPressed: () => Navigator.pop(ctx, false), child: Text('Keep my account', style: inter(14, 700, color: kInk))),
          TextButton(key: const ValueKey('del-sure-yes'), onPressed: () => Navigator.pop(ctx, true), child: Text('Yes, continue', style: inter(14, 700, color: _red))),
        ],
      ),
    );
    if (yes == true && mounted) setState(() => _step = 1);
  }

  /// Warning three is the typed DELETE; then the request, then every device signs out.
  Future<void> _delete() async {
    if (_typed.text.trim() != 'DELETE' || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.requestDelete();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, e is AccountApiException ? e.message : 'Your account was not deleted. Check your connection and try again.');
      }
      return;
    }
    try {
      await widget.api.recordSignOutEverywhere();
    } catch (_) {}
    try {
      await widget.auth.signOutEverywhere();
    } catch (_) {} // the request is saved; this device signs out with the next step
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _point(IconData icon, String text, {bool red = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 19, color: red ? _red : kInk),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: inter(14, red ? 700 : 500, color: red ? _red : kInk, height: 1.4))),
        ]),
      );

  Widget _what() => ListView(key: const ValueKey('del-what'), padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _redWash, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            const Icon(LucideIcons.triangleAlert, color: _red, size: 26),
            const SizedBox(width: 12),
            Expanded(child: Text('Deleting your account cannot be undone after 30 days.', style: inter(15, 800, color: _red, height: 1.3))),
          ]),
        ),
        const SizedBox(height: 18),
        Text('What happens', style: inter(16, 800)),
        const SizedBox(height: 12),
        _point(LucideIcons.logOut, 'You are signed out of every phone and computer right away.'),
        _point(LucideIcons.store, _memberships == 0 ? 'You are not part of any business.' : 'You are removed from ${_memberships == 1 ? 'your business' : 'all $_memberships businesses'} after 30 days.'),
        if (_soleOwner.isNotEmpty)
          _point(LucideIcons.shieldAlert, 'You are the only owner of ${_soleOwner.join(', ')}. Nobody will be able to manage ${_soleOwner.length == 1 ? 'it' : 'them'}. Add another owner in Team first if the business should go on.',
              red: true),
        _point(LucideIcons.userX, 'After 30 days your login, name, email, mobile number and devices are deleted for good.'),
        _point(LucideIcons.receiptText, 'Bills, sales and tax records stay with the business, because the law requires it. They will no longer show your name.'),
        _point(LucideIcons.rotateCcw, 'Changed your mind? Sign in again within 30 days and your account stays.'),
        const SizedBox(height: 6),
        InkWell(
          key: const ValueKey('del-understand'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _understood = !_understood),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(_understood ? LucideIcons.squareCheck : LucideIcons.square, color: _understood ? _red : kMuted, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text('I understand that my account will be deleted and this cannot be undone after 30 days.', style: inter(13.5, 600, height: 1.35))),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          key: const ValueKey('del-continue'),
          onPressed: _understood ? _continue : null,
          style: FilledButton.styleFrom(backgroundColor: _red, disabledBackgroundColor: _red.withValues(alpha: 0.3), minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Text('Continue', style: inter(15.5, 700, color: Colors.white)),
        ),
        const SizedBox(height: 8),
        TextButton(key: const ValueKey('del-keep'), onPressed: () => Navigator.of(context).pop(false), child: Text('Keep my account', style: inter(15, 700, color: kInk))),
      ]);

  Widget _type() {
    final ok = _typed.text.trim() == 'DELETE';
    return ListView(key: const ValueKey('del-type'), padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
      Text('Last step', style: inter(13, 700, color: _red)),
      const SizedBox(height: 4),
      Text('Type DELETE to delete your account', style: inter(20, 800, height: 1.25)),
      const SizedBox(height: 8),
      Text('Type the word in capital letters. Your account will be deleted in 30 days unless you sign in again before then.', style: inter(13.5, 500, color: kMuted, height: 1.4)),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('del-confirm'),
        controller: _typed,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        onChanged: (_) => setState(() {}),
        style: inter(18, 800, color: ok ? _red : kInk),
        decoration: InputDecoration(
          hintText: 'DELETE',
          hintStyle: inter(18, 700, color: const Color(0xFFCFD2CA)),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: ok ? _red : const Color(0xFFD9DBD5), width: 1.4)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _red, width: 1.8)),
        ),
      ),
      const SizedBox(height: 18),
      FilledButton.icon(
        key: const ValueKey('del-final'),
        onPressed: ok && !_busy ? _delete : null,
        icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(LucideIcons.trash2, size: 18),
        label: Text('Delete my account', style: inter(15.5, 700, color: Colors.white)),
        style: FilledButton.styleFrom(
          backgroundColor: _red,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _red.withValues(alpha: 0.3),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      const SizedBox(height: 8),
      TextButton(key: const ValueKey('del-keep-2'), onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text('Keep my account', style: inter(15, 700, color: kInk))),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: Column(children: [
          const CwaTopBar(title: 'Delete account'),
          Expanded(
            child: _preview == null
                ? Center(child: _error != null ? CwaLoadError(message: _error!, onRetry: _load) : const CircularProgressIndicator())
                : _step == 0
                    ? _what()
                    : _type(),
          ),
        ]),
      );
}

/// After a sign-in: a deletion asked for in the last 30 days is cancelled, and the person is told so.
Future<void> cancelAccountDeletionOnSignIn(BuildContext context, AccountApi api) async {
  try {
    final r = await api.cancelDelete();
    if (r && context.mounted) showToast(context, 'Welcome back. You signed in, so your account will not be deleted.');
  } catch (_) {} // not signed in yet, or offline: it is checked again next time
}
