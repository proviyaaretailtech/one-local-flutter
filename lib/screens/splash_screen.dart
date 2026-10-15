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
      body: ClipRect(
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
                const Positioned(left: 0, right: 0, top: 127, child: Align(alignment: Alignment.topCenter, child: PartnerWordmark())),
                _primary(label: 'Sign In', color: kMuted, top: 469, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SigninChooserScreen()))),
                _primary(label: 'Become a seller', color: const Color(0xFFA1FE2F), top: 539, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPersonalScreen()))),
                // Google pill
                Positioned(
                  left: 34,
                  top: 608,
                  width: 161,
                  height: 33,
                  child: _Pill(
                    color: Colors.white,
                    onTap: () => auth.signInWithGoogle(),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(left: 8, top: 4, width: 24.4, height: 25, child: Image.asset('assets/figma/google_g.png', fit: BoxFit.cover)),
                        Positioned(left: 45, top: 10, child: Text('SignUp with Google ', style: inter(10, 600, color: Colors.black, shadows: _textShadow))),
                      ],
                    ),
                  ),
                ),
                // Apple pill
                Positioned(
                  left: 208,
                  top: 608,
                  width: 161,
                  height: 33,
                  child: _Pill(
                    color: Colors.black,
                    onTap: () => auth.signInWithApple(),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: -2,
                          top: -6,
                          width: 43,
                          height: 44,
                          child: ClipRect(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(left: 43 * 0.0107, top: 44 * -0.0926, width: 43, height: 44 * 1.1751, child: Image.asset('assets/figma/apple_logo.png', fit: BoxFit.fill)),
                              ],
                            ),
                          ),
                        ),
                        Positioned(left: 45, top: 10, child: Text('SignUp  with Apple', style: inter(11, 600, color: Colors.white, shadows: const [Shadow(color: Color(0x40FFFFFF), offset: Offset(0, 4), blurRadius: 4)]))),
                      ],
                    ),
                  ),
                ),
              ],
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
            child: Center(child: Text(label, style: inter(16, 600, color: Colors.white, shadows: _textShadow))),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.child, required this.onTap});
  final Color color;
  final Widget child;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(11),
        boxShadow: const [BoxShadow(color: Color(0x40000000), offset: Offset(0, 4), blurRadius: 4)],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: BorderRadius.circular(11), onTap: onTap, child: ClipRRect(borderRadius: BorderRadius.circular(11), child: child)),
      ),
    );
  }
}
