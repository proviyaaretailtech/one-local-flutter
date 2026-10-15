import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import 'theme.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
bool isEmail(String s) => _emailRe.hasMatch(s.trim());

/// "Forgot password?": asks for the account email and sends a reset link.
Future<void> showForgotPasswordSheet(BuildContext context, {String initialEmail = '', AuthRepository? auth}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => _ForgotSheet(initialEmail: initialEmail, auth: auth ?? AuthRepository()),
  );
}

class _ForgotSheet extends StatefulWidget {
  const _ForgotSheet({required this.initialEmail, required this.auth});
  final String initialEmail;
  final AuthRepository auth;
  @override
  State<_ForgotSheet> createState() => _ForgotSheetState();
}

class _ForgotSheetState extends State<_ForgotSheet> {
  late final _email = TextEditingController(text: widget.initialEmail);
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim().toLowerCase();
    if (!isEmail(email)) {
      showToast(context, 'Please enter a valid email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.auth.sendPasswordReset(email);
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'If that email has an account, a reset link is on its way.');
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not send the reset link. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(kPadX, 24, kPadX, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reset your password', style: inter(20, 600)),
          const SizedBox(height: 8),
          Text('Enter your account email. We’ll send a link to choose a new password.', style: inter(14, 400, color: kMuted, height: 1.5)),
          const SizedBox(height: 20),
          LabeledField(
            label: 'Account email',
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _send(),
            autofillHints: const [AutofillHints.email],
          ),
          const SizedBox(height: 20),
          PrimaryAction(label: _busy ? 'Sending…' : 'Send reset link', onPressed: _busy ? null : _send),
        ],
      ),
    );
  }
}
