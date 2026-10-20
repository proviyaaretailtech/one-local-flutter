import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Design tokens, read from Figma FINAL-PARTNER-APP section A (values as drawn).
const kBg = Color(0xFFF5F5F0);
const kInk = Color(0xFF111827);
const kMuted = Color(0xFF6B7280);
const kLink = Color(0xFF3DB800);
const kField = Color(0xFFF7F8F6);
const kFieldBorder = Color(0xFFE3E8E3);
const kLine = Color(0xFFE5E7EB);
const kPrimary = Color(0xFF0C1F15);
const kNote = Color(0xFFEBFAE0);
const kCheck = Color(0xFF76EC00);
const kError = Color(0xFFD92D20);

const double kPadX = 24;
const double kFieldH = 54;
const double kRadius = 12;
const double kBorderW = 1;

/// The app's type scale. Every [inter] size snaps to the nearest step (a tie goes to the smaller one), so text that was
/// drawn at 12.5 or 13.5 lines up with 13, and nothing is smaller than 11.
const kTypeScale = <double>[11, 12, 13, 14, 16, 18, 20, 24, 28, 32];

double typeSize(double size) {
  var best = kTypeScale.first;
  for (final s in kTypeScale) {
    if ((s - size).abs() < (best - size).abs()) best = s;
  }
  return best;
}

/// Inter at a named weight, on the type scale ([typeSize]). Inter.ttf is a variable font, so the weight axis is set too.
TextStyle inter(double size, int weight, {Color color = kInk, double? height, List<Shadow>? shadows}) {
  return TextStyle(
    fontFamily: 'Inter',
    fontSize: typeSize(size),
    fontWeight: FontWeight.values[(weight ~/ 100) - 1],
    fontVariations: [FontVariation('wght', weight.toDouble())],
    color: color,
    height: height,
    shadows: shadows,
  );
}

ThemeData posTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: kBg,
    fontFamily: 'Inter',
    colorScheme: ColorScheme.fromSeed(seedColor: kPrimary, primary: kPrimary),
  );
}

/// Figma 112.46deg gradient, #f5f5f0 at 25% to #eaf7e8 at 75% (registration screen).
const kRegistrationGradient = LinearGradient(
  begin: Alignment(-0.9238, -0.3827),
  end: Alignment(0.9238, 0.3827),
  colors: [Color(0xFFF5F5F0), Color(0xFFEAF7E8)],
  stops: [0.25, 0.75],
);

/// Page shell: scrolling content, then a pinned action area.
class ScreenShell extends StatelessWidget {
  const ScreenShell({super.key, required this.children, required this.actions, this.gradient});
  final List<Widget> children;
  final List<Widget> actions;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(color: kBg, gradient: gradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(kPadX, 16, kPadX, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// SVG drawn slightly outside its box, as Figma exports it (inset percentages).
class _InsetSvg extends StatelessWidget {
  const _InsetSvg({required this.asset, required this.w, required this.h, required this.left, required this.right, required this.bottom});
  final String asset;
  final double w, h, left, right, bottom; // fractions, negative = outside the box
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: left * w,
            right: right * w,
            top: 0,
            bottom: bottom * h,
            child: SvgPicture.asset(asset, fit: BoxFit.fill),
          ),
        ],
      ),
    );
  }
}

/// OneLocal wordmark (two Figma SVG groups), 120 x 20.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key});
  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 120,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0.65,
            child: _InsetSvg(asset: 'assets/figma/logo_one.svg', w: 52, h: 19.2, left: -0.0157, right: -0.0262, bottom: -0.1135),
          ),
          Positioned(
            left: 54.4,
            top: 0,
            child: _InsetSvg(asset: 'assets/figma/logo_local.svg', w: 65.6, h: 19.9, left: -0.0125, right: -0.0208, bottom: -0.1099),
          ),
        ],
      ),
    );
  }
}

/// Logo left, "Help" right. 24 / 16 padding. With [back] (the sign-in screens, whose Figma frames have no way back)
/// and a screen to go back to, a back circle (the [StepNav] style, 36) sits before the logo. Off by default: screens
/// with a [StepNav] already have their own back.
class BrandNav extends StatelessWidget {
  const BrandNav({super.key, this.back = false});
  final bool back;
  @override
  Widget build(BuildContext context) {
    final canPop = back && (ModalRoute.of(context)?.canPop ?? false);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kPadX, vertical: 16),
      child: Row(
        children: [
          if (canPop) ...[
            Semantics(
              button: true,
              label: 'Back',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.maybePop(context),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: kBg, shape: BoxShape.circle, border: Border.all(color: kLine, width: kBorderW)),
                  child: SvgPicture.asset('assets/figma/arrow_left.svg', width: 14, height: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          const BrandLogo(),
          const Spacer(),
          Text('Help', style: inter(14, 600, color: kLink)),
        ],
      ),
    );
  }
}

/// Back circle (44) and a right-aligned step caption. Registration screens.
class StepNav extends StatelessWidget {
  const StepNav({super.key, required this.caption, required this.onBack});
  final String caption;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPadX, 0, kPadX, 12),
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            InkWell(
              customBorder: const CircleBorder(),
              onTap: onBack,
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: kLine, width: kBorderW),
                ),
                child: SvgPicture.asset('assets/figma/arrow_left.svg', width: 16, height: 16),
              ),
            ),
            Text(caption, style: inter(13, 400, color: kMuted)),
          ],
        ),
      ),
    );
  }
}

/// Form content column: 24 side padding, 12 top, 24 bottom, 28 between kicker, intro and body.
class FormContent extends StatelessWidget {
  const FormContent({super.key, required this.children, this.gap = 28});
  final List<Widget> children;
  final double gap;
  @override
  Widget build(BuildContext context) {
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) spaced.add(SizedBox(height: gap));
      spaced.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPadX, 12, kPadX, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced),
    );
  }
}

/// Green uppercase kicker (12 / 600).
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key, this.size = 12});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: inter(size, 600, color: kLink));
}

/// Title and subtitle, 12 apart. Sizes differ on the registration screens (30 / 14).
class PageIntro extends StatelessWidget {
  const PageIntro({super.key, required this.title, required this.subtitle, this.titleSize = 32, this.subtitleSize = 15});
  final String title;
  final String subtitle;
  final double titleSize, subtitleSize;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: inter(titleSize, 600, height: 1.12)),
        const SizedBox(height: 12),
        Text(subtitle, style: inter(subtitleSize, 400, color: kMuted, height: 1.5)),
      ],
    );
  }
}

/// Dark primary button, 54 tall, radius 12, soft shadow.
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kPrimary,
          borderRadius: BorderRadius.circular(kRadius),
          boxShadow: const [BoxShadow(color: Color(0x1A000000), offset: Offset(0, 2), blurRadius: 4)],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadius),
            onTap: onPressed,
            child: Container(
              height: kFieldH,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(label, style: inter(16, 600, color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Green text link, centred (14 / 600).
class LinkText extends StatelessWidget {
  const LinkText(this.label, {super.key, this.onTap, this.align = TextAlign.center});
  final String label;
  final VoidCallback? onTap;
  final TextAlign align;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: double.infinity,
        child: Text(label, textAlign: align, style: inter(14, 600, color: kLink, height: 1.5)),
      ),
    );
  }
}

class FooterNote extends StatelessWidget {
  const FooterNote(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Text(label, textAlign: TextAlign.center, style: inter(12, 400, color: kMuted, height: 1.5)),
    );
  }
}

/// 54 field box: bg #f7f8f6, 1 border #e3e8e3, radius 12.
class FieldBox extends StatelessWidget {
  const FieldBox({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: kFieldH,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kField,
        border: Border.all(color: kFieldBorder, width: kBorderW),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(children: [Expanded(child: child)]),
    );
  }
}

InputDecoration get plainInput => const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero);

/// Label above a field. [labelSize]/[labelWeight] differ between screens (13/500 vs 14/600).
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.keyboardType,
    this.obscure = false,
    this.hint,
    this.trailingSvg,
    this.trailingIcon,
    this.onTrailingTap,
    this.prefix,
    this.onChanged,
    this.labelSize = 14,
    this.labelWeight = 600,
    this.labelGap = 8,
    this.maxLength,
    this.textInputAction,
    this.onSubmitted,
    this.inputFormatters,
    this.autofillHints,
    this.focusNode,
  });
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final String? hint;
  final String? trailingSvg;
  final IconData? trailingIcon;
  final VoidCallback? onTrailingTap;
  final Widget? prefix;
  final ValueChanged<String>? onChanged;
  final double labelSize;
  final int labelWeight;
  final double labelGap;
  final int? maxLength;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: inter(labelSize, labelWeight)),
        SizedBox(height: labelGap),
        Container(
          height: kFieldH,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: kField,
            border: Border.all(color: kFieldBorder, width: kBorderW),
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: Row(
            children: [
              if (prefix != null) ...[prefix!, const SizedBox(width: 10)],
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  obscureText: obscure,
                  maxLength: maxLength,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  textInputAction: textInputAction,
                  inputFormatters: inputFormatters,
                  autofillHints: autofillHints,
                  focusNode: focusNode,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: inter(15, 400),
                  decoration: plainInput.copyWith(hintText: hint, counterText: '', hintStyle: inter(15, 400, color: kMuted)),
                ),
              ),
              if (trailingSvg != null || trailingIcon != null) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: onTrailingTap,
                  child: trailingSvg != null
                      ? SvgPicture.asset(trailingSvg!, width: 18, height: 18)
                      : Icon(trailingIcon, size: 18, color: kMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Light-green helper note (icon, bold line, muted line).
class HelpfulNote extends StatelessWidget {
  const HelpfulNote({super.key, required this.iconAsset, required this.title, required this.body});
  final String iconAsset, title, body;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SvgPicture.asset(iconAsset, width: 20, height: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: inter(14, 600)),
                const SizedBox(height: 4),
                Text(body, style: inter(12, 400, color: kMuted, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Selectable option card (white, 1 border, green when selected).
class OptionCard extends StatelessWidget {
  const OptionCard({super.key, required this.iconAsset, required this.title, required this.subtitle, required this.selected, required this.onTap});
  final String iconAsset, title, subtitle;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: selected ? kLink : kLine, width: kBorderW),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SvgPicture.asset(iconAsset, width: 20, height: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: inter(14, 600)),
                  const SizedBox(height: 6),
                  Text(subtitle, style: inter(13, 400, color: kMuted)),
                ],
              ),
            ),
            SvgPicture.asset(selected ? 'assets/figma/circle_dot.svg' : 'assets/figma/circle.svg', width: 20, height: 20),
          ],
        ),
      ),
    );
  }
}

/// Used by the splash: CSS `drop-shadow` pair from the Figma buttons.
const kButtonShadows = [
  BoxShadow(color: Color(0x40000000), offset: Offset(0, 4), blurRadius: 2),
  BoxShadow(color: Color(0x1A000000), offset: Offset(0, 2), blurRadius: 4),
];

double degToRad(double d) => d * math.pi / 180;

/// Short message at the bottom of the screen (validation, errors). Replaces any toast already showing.
void showToast(BuildContext context, String message) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Text(message, style: inter(14, 500, color: Colors.white)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: kPrimary,
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      duration: const Duration(seconds: 3),
    ),
  );
}
