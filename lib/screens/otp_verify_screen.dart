import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../onboarding/checklist_screen.dart' show OnboardingEntry;

/// Figma "OTP Verification". Exactly one of [phone] (+91XXXXXXXXXX) or [email] is set.
/// [registering] sends the person on to the account-type screen instead of the signed-in home.
class OtpVerifyScreen extends StatefulWidget {
  const OtpVerifyScreen({super.key, this.phone, this.email, this.registering = false, this.auth, this.resendSeconds = 30, this.name});
  final String? phone;
  final String? email;
  final bool registering;
  final AuthRepository? auth;
  final int resendSeconds;

  /// The name typed on Create account, for the shop owner on the application.
  final String? name;

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _code = TextEditingController();
  late final _auth = widget.auth ?? AuthRepository();
  Timer? _timer;
  late int _left = widget.resendSeconds;
  bool _busy = false;

  bool get _isPhone => widget.phone != null;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _left = widget.resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _left = (_left - 1).clamp(0, 999));
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    try {
      if (_isPhone) {
        await _auth.sendPhoneCode(widget.phone!);
      } else {
        await _auth.sendEmailCode(widget.email!);
      }
      if (!mounted) return;
      _code.clear();
      _startTimer();
      showToast(context, 'New code sent to ${_isPhone ? maskPhone(widget.phone!) : maskEmail(widget.email!)}');
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not resend the code. Try again.'));
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      showToast(context, 'Please enter all 6 digits of the code.');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_isPhone) {
        await _auth.verifyPhoneCode(widget.phone!, code);
      } else {
        await _auth.verifyEmailCode(widget.email!, code);
      }
      if (!mounted) return;
      if (widget.registering) {
        // straight into the application (founder, 27 Oct 2026): the store type is asked once there, and nothing in between
        Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => OnboardingEntry(auth: _auth, phone: widget.phone, name: widget.name)), (r) => r.isFirst);
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      if (mounted) {
        _code.clear();
        showToast(context, friendlyAuthError(e, fallback: 'That code is not right, or it has expired.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _countdown => '00:${_left.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final target = _isPhone ? maskPhone(widget.phone!) : maskEmail(widget.email!);
    return ScreenShell(
      children: [
        const BrandNav(back: true),
        FormContent(children: [
          const Kicker('Sign in · Verify'),
          PageIntro(
            title: _isPhone ? 'Check your messages.' : 'Check your inbox.',
            subtitle: 'Enter the code sent to $target. It’s how we know it’s you.',
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinkText(_isPhone ? 'Edit mobile number' : 'Edit email address', align: TextAlign.left, onTap: () => Navigator.pop(context)),
              const SizedBox(height: 24),
              Text('6-digit verification code', style: inter(14, 600)),
              const SizedBox(height: 12),
              OtpBoxes(
                controller: _code,
                onChanged: (v) {
                  if (v.length == 6) _verify();
                },
              ),
              const SizedBox(height: 16),
              if (_left > 0)
                Text('Resend code in $_countdown', style: inter(14, 400, color: kMuted))
              else
                LinkText('Resend code', align: TextAlign.left, onTap: _resend),
              const SizedBox(height: 20),
              const HelpfulNote(
                iconAsset: 'assets/figma/message_circle.svg',
                title: 'Use the latest code',
                body: 'Enter all 6 digits from the message you just received.',
              ),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(label: _busy ? 'Verifying…' : 'Verify code', onPressed: _busy ? null : _verify),
        const SizedBox(height: 16),
        LinkText('Back to sign in', onTap: () => Navigator.of(context).popUntil((r) => r.isFirst)),
        const SizedBox(height: 16),
        const FooterNote('Never share your verification code with anyone.'),
      ],
    );
  }
}
