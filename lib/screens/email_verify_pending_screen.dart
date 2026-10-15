import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/mask.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'otp_verify_screen.dart';

/// Figma "Account Pending Verification".
class EmailVerifyPendingScreen extends StatefulWidget {
  const EmailVerifyPendingScreen({super.key, required this.email, this.auth});
  final String email;
  final AuthRepository? auth;
  @override
  State<EmailVerifyPendingScreen> createState() => _EmailVerifyPendingScreenState();
}

class _EmailVerifyPendingScreenState extends State<EmailVerifyPendingScreen> {
  bool _showBanner = true;

  late final _auth = widget.auth ?? AuthRepository();

  Future<void> _resend() async {
    try {
      await _auth.sendEmailCode(widget.email);
      if (mounted) showToast(context, 'New code sent to ${maskEmail(widget.email)}');
    } catch (e) {
      if (mounted) showToast(context, friendlyAuthError(e, fallback: 'Could not resend the code. Try again.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      children: [
        const BrandNav(),
        FormContent(children: [
          const Kicker('Account · Verification'),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(color: kNote, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const Ico(lucideMailCheck, size: 28),
              ),
              const SizedBox(height: 28),
              const PageIntro(
                title: 'You’re almost verified.',
                subtitle: 'Your contact verification is still pending. Confirm your email to continue to OneLocal.',
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showBanner) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF5FF),
                    border: Border.all(color: const Color(0xFF3B82F6)),
                    borderRadius: BorderRadius.circular(kRadius),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Ico(lucideInfo, size: 20, color: Color(0xFF3B82F6)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Contact verification pending', style: inter(14, 600)),
                            const SizedBox(height: 4),
                            Text('Enter the code sent to your email.', style: inter(12, 400, color: kMuted)),
                          ],
                        ),
                      ),
                      InkWell(onTap: () => setState(() => _showBanner = false), child: const Ico(lucideX, size: 18, color: kInk)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(kRadius)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Verification email', style: inter(13, 400, color: kMuted)),
                    const SizedBox(height: 4),
                    Text(maskEmail(widget.email), style: inter(16, 500)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('Check your inbox and spam folder. If you request another code, use only the newest one.', style: inter(15, 400, color: kMuted, height: 1.5)),
              const SizedBox(height: 24),
              LinkText('Change verification email', align: TextAlign.left, onTap: () => Navigator.of(context).popUntil((r) => r.isFirst)),
            ],
          ),
        ]),
      ],
      actions: [
        PrimaryAction(
          label: 'Verify contact',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OtpVerifyScreen(email: widget.email, auth: _auth))),
        ),
        const SizedBox(height: 12),
        SecondaryAction(label: 'Resend verification code', onPressed: _resend),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
          child: SizedBox(
            width: double.infinity,
            child: Text('Sign in with a different account', textAlign: TextAlign.center, style: inter(14, 400, color: kMuted)),
          ),
        ),
      ],
    );
  }
}
