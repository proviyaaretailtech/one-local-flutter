import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/splash_backdrop.dart';
import '../ui/theme.dart';

/// Figma "splash" with "Easy Selling starts here". Shows for a moment, then the sign-in splash.
class IntroSplashScreen extends StatefulWidget {
  const IntroSplashScreen({super.key, required this.onDone, this.hold = const Duration(milliseconds: 2200)});
  final VoidCallback onDone;
  final Duration hold;
  @override
  State<IntroSplashScreen> createState() => _IntroSplashScreenState();
}

class _IntroSplashScreenState extends State<IntroSplashScreen> {
  Timer? _t;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.hold, _next);
  }

  void _next() {
    if (!mounted || _done) return;
    _done = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: GestureDetector(
        onTap: _next,
        // SizedBox.expand: the Scaffold body is loosely constrained; without it the FittedBox below shrinks to the
        // design's aspect ratio and sits top-left instead of covering the screen.
        child: SizedBox.expand(
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: SplashBackdrop.w,
                height: SplashBackdrop.h,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const SplashBackdrop(),
                    // Lime wash at the foot of the picture.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 150,
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
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 334,
                      child: Align(alignment: Alignment.topCenter, child: PartnerWordmark()),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 780,
                      child: Column(
                        children: [
                          Text('Easy Selling starts here', style: inter(26, 700, color: kPrimary)),
                          const SizedBox(height: 6),
                          Text('Your Business, Simplified', style: inter(16, 400, color: kPrimary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
