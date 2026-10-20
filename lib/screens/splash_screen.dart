import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/splash_backdrop.dart';
import '../ui/theme.dart';
import 'register_personal_screen.dart';
import 'signin_chooser_screen.dart';

/// Figma "splash" (402 x 874). Drawn on a fixed canvas and scaled to the screen, so every
/// position, size, blur and shadow is the design's own.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  static const _w = SplashBackdrop.w;
  static const _h = SplashBackdrop.h;
  static const _textShadow = kSplashTextShadow;

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository();
    return Scaffold(
      backgroundColor: Colors.white,
      // SizedBox.expand: the Scaffold body is loosely constrained, so without it the FittedBox shrinks to the design's
      // aspect ratio and sits top-left (white band on the right on any screen wider than 402:874) instead of covering.
      body: SizedBox.expand(
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: _w,
              height: _h,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const SplashBackdrop(),
                  // Logo block: content starts 127 down (top -73 + 200).
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 127,
                    child: Align(alignment: Alignment.topCenter, child: PartnerWordmark()),
                  ),
                  _primary(
                    label: 'Sign In',
                    color: kMuted,
                    top: 469,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SigninChooserScreen())),
                  ),
                  _primary(
                    label: 'Become a seller',
                    color: const Color(0xFFA1FE2F),
                    top: 539,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPersonalScreen())),
                  ),
                  // Google and Apple pills: the Figma columns (34 and 208, 161 wide), but one height, one text style and the
                  // icon + label centred together, so the pair reads as a matched set.
                  Positioned(
                    left: 34,
                    top: 606,
                    width: 161,
                    height: 40,
                    child: _Pill(
                      color: Colors.white,
                      onTap: () => auth.signInWithGoogle(),
                      icon: Image.asset('assets/figma/google_g.png', width: 18, height: 18, fit: BoxFit.contain),
                      label: Text('Sign up with Google', style: inter(12, 600, color: Colors.black)),
                    ),
                  ),
                  Positioned(
                    left: 208,
                    top: 606,
                    width: 161,
                    height: 40,
                    child: _Pill(
                      color: Colors.black,
                      onTap: () => auth.signInWithApple(),
                      // The Apple artwork has wide transparent margins; scale the drawing (not its 18 pt slot) to match the Google mark.
                      icon: Transform.scale(
                        scale: 1.8,
                        child: Image.asset('assets/figma/apple_logo.png', width: 18, height: 18, fit: BoxFit.contain),
                      ),
                      label: Text('Sign up with Apple', style: inter(12, 600, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _primary({required String label, required Color color, required double top, required VoidCallback onTap}) {
    return Positioned(
      left: 30,
      top: top,
      width: 342,
      height: 54,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(color: Color(0x40000000), offset: Offset(0, 4), blurRadius: 2),
            BoxShadow(color: Color(0x1A000000), offset: Offset(0, 2), blurRadius: 4),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Center(
              child: Text(
                label,
                style: inter(16, 600, color: Colors.white, shadows: _textShadow),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.icon, required this.label, required this.onTap});
  final Color color;
  final Widget icon;
  final Widget label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Color(0x26000000), offset: Offset(0, 2), blurRadius: 4),
          BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 2),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 8),
              Flexible(child: label),
            ],
          ),
        ),
      ),
    );
  }
}
