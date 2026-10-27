import 'package:flutter/material.dart';

import '../account/account_api.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Become a seller, right after the code (founder, 28 Oct 2026): set a password, so the next sign-in is the mobile number (or email)
/// and this password, with no code to wait for. Then [next] (the application).
class CreatePasswordScreen extends StatefulWidget {
  const CreatePasswordScreen({super.key, required this.next, this.auth});
  final Widget next;
  final AccountAuth? auth;
  @override
  State<CreatePasswordScreen> createState() => _CreatePasswordScreenState();
}

class _CreatePasswordScreenState extends State<CreatePasswordScreen> {
  late final AccountAuth _auth = widget.auth ?? SupabaseAccountAuth();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true, _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _long => _password.text.length >= 8;
  bool get _mixed => RegExp('[A-Za-z]').hasMatch(_password.text) && RegExp('[0-9]').hasMatch(_password.text);

  void _goOn() => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => widget.next));

  Future<void> _save() async {
    if (_busy) return;
    if (!_long || !_mixed) return showToast(context, 'Use at least 8 characters, with letters and numbers.');
    if (_confirm.text != _password.text) return showToast(context, 'The two passwords do not match.');
    setState(() => _busy = true);
    try {
      await _auth.setPassword(_password.text);
      if (!mounted) return;
      showToast(context, 'Password set.');
      _goOn();
    } on PasswordNeedsCode {
      // should not happen right after the code; the person carries on and can set it in Manage account
      if (!mounted) return;
      showToast(context, 'The password could not be set now. You can set it later in Manage account.');
      _goOn();
    } on AccountApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'The password could not be saved. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _rule(bool ok, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.circle_outlined, size: 16, color: ok ? const Color(0xFF15803D) : kMuted),
          const SizedBox(width: 8),
          Text(text, style: inter(13, 500, color: ok ? kInk : kMuted)),
        ]),
      );

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false, // the account is made: no going back to the code
        child: ScreenShell(
          gradient: kRegistrationGradient,
          children: [
            const BrandNav(),
            FormContent(children: [
              const Kicker('Registration · Security'),
              const PageIntro(
                title: 'Set a password.',
                subtitle: 'Next time, sign in with your mobile number and this password. No code to wait for.',
                titleSize: 30,
                subtitleSize: 14,
              ),
              AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LabeledField(
                    key: const ValueKey('new-password'),
                    label: 'Password',
                    controller: _password,
                    obscure: _hide,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    trailingSvg: _hide ? 'assets/figma/eye_off.svg' : null,
                    trailingIcon: _hide ? null : lucideEye,
                    onTrailingTap: () => setState(() => _hide = !_hide),
                  ),
                  _rule(_long, 'At least 8 characters'),
                  _rule(_mixed, 'Letters and numbers'),
                  const SizedBox(height: 20),
                  LabeledField(
                    key: const ValueKey('confirm-password'),
                    label: 'Confirm password',
                    controller: _confirm,
                    obscure: _hide,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    onChanged: (_) => setState(() {}),
                  ),
                ]),
              ),
            ]),
          ],
          actions: [
            PrimaryAction(key: const ValueKey('save-password'), label: _busy ? 'Saving…' : 'Save password & continue', onPressed: _busy ? null : _save),
          ],
        ),
      );
}
