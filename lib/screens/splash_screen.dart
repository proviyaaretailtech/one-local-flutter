import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../ui/splash_backdrop.dart';
import '../ui/theme.dart';
import 'register_personal_screen.dart';
import 'signin_chooser_screen.dart';

/// Figma "splash" (402 x 874), both frames in one screen. Drawn on a fixed canvas and scaled to the screen, so every position, size,
/// blur and shadow is the design's own.
///
/// With [intro] it opens on the first frame (logo in the middle, lime wash, "Easy Selling starts here") and after [hold] moves smoothly
/// to the second: the logo glides up, the wash fades, the four buttons fade in and the two taglines settle under them (founder, 22 Oct
/// 2026: the taglines stay on the sign-up page, and no jump between the two frames). A tap during the first frame moves on at once.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.intro = false, this.hold = const Duration(milliseconds: 2200)});
  final bool intro;
  final Duration hold;

  static const _w = SplashBackdrop.w;
  static const _h = SplashBackdrop.h;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900), value: widget.intro ? 0 : 1);
  late final Animation<double> _move = CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic);
  late final Animation<double> _show = CurvedAnimation(parent: _c, curve: const Interval(0.45, 1, curve: Curves.easeOut));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    if (widget.intro) _t = Timer(widget.hold, _go);
  }

  void _go() {
    _t?.cancel();
    if (mounted && _c.value == 0) _c.forward();
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository();
    return Scaffold(
      backgroundColor: Colors.white,
      // SizedBox.expand: the Scaffold body is loosely constrained, so without it the FittedBox shrinks to the design's
      // aspect ratio and sits top-left (white band on the right on any screen wider than 402:874) instead of covering.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _c.value == 0 ? _go : null,
        child: SizedBox.expand(
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: SplashScreen._w,
                height: SplashScreen._h,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    final m = _move.value, s = _show.value;
                    // the buttons only take taps once they are there
                    final ready = _c.value == 1;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const SplashBackdrop(),
                        // Lime wash at the foot of the picture (first frame only).
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 150,
                          child: Opacity(
                            opacity: 1 - m,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [const Color(0x00A1FE2F), const Color(0xFFA1FE2F).withValues(alpha: 0.95)],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Logo: the middle of the first frame (334) up to the second's (127).
                        Positioned(left: 0, right: 0, top: _lerp(334, 127, m), child: const Align(alignment: Alignment.topCenter, child: PartnerWordmark())),
                        // Taglines: the foot of the first frame (780) up to just under the four buttons (668).
                        Positioned(
                          left: 0,
                          right: 0,
                          top: _lerp(780, 668, m),
                          child: Column(children: [
                            Text('Easy Selling starts here', style: inter(_lerp(26, 22, m), 700, color: kPrimary, shadows: const [Shadow(color: Color(0xCCFFFFFF), blurRadius: 10)])),
                            const SizedBox(height: 6),
                            Text('Your Business, Simplified', style: inter(_lerp(16, 15, m), 400, color: kPrimary, shadows: const [Shadow(color: Color(0xCCFFFFFF), blurRadius: 8)])),
                          ]),
                        ),
                        // The four buttons fade in and rise a little.
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: !ready,
                            child: Opacity(
                              opacity: s,
                              child: Transform.translate(
                                offset: Offset(0, 16 * (1 - s)),
                                child: Stack(clipBehavior: Clip.none, children: [
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
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
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
                style: inter(16, 600, color: Colors.white, shadows: kSplashTextShadow),
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
