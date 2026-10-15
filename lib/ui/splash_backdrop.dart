import 'package:flutter/material.dart';

/// The Figma splash picture on its 402 x 874 canvas: "image 8" is 755 x 1002 at (-123, -102).
/// Shared by the intro splash and the sign-in splash.
class SplashBackdrop extends StatelessWidget {
  const SplashBackdrop({super.key});
  static const w = 402.0;
  static const h = 874.0;
  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: w / 2 + 53.5 - 755 / 2,
      top: -102,
      width: 755,
      height: 1002,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 755 * 0.0483,
            top: 1002 * 0.0209,
            width: 755 * 0.7152,
            height: 1002 * 0.9582,
            child: Image.asset('assets/figma/splash_bg.png', fit: BoxFit.fill),
          ),
        ],
      ),
    );
  }
}

const kSplashTextShadow = [Shadow(color: Color(0x40000000), offset: Offset(0, 4), blurRadius: 4)];

/// "OneLocal" over "PARTNER" in Poppins, right-aligned, as on the Figma splashes.
class PartnerWordmark extends StatelessWidget {
  const PartnerWordmark({super.key});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text.rich(
          TextSpan(
            children: const [
              TextSpan(text: 'One', style: TextStyle(color: Color(0xFF0C1F15))),
              TextSpan(text: 'Local', style: TextStyle(color: Color(0xFF6EE315))),
            ],
            style: const TextStyle(fontFamily: 'Poppins', fontSize: 64, fontWeight: FontWeight.w800, shadows: kSplashTextShadow, height: 1.5),
          ),
        ),
        const Text(
          'PARTNER',
          style: TextStyle(fontFamily: 'Poppins', fontSize: 34, fontWeight: FontWeight.w800, color: Colors.black, shadows: kSplashTextShadow, height: 1.5),
        ),
      ],
    );
  }
}
