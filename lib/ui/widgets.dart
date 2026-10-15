import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'theme.dart';

/// White secondary button with a 1px #e5e7eb border (Figma "Resend verification code", "Switch account").
class SecondaryAction extends StatelessWidget {
  const SecondaryAction({super.key, required this.label, required this.onPressed, this.height = kFieldH});
  final String label;
  final VoidCallback? onPressed;
  final double height;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: const BorderSide(color: kLine, width: kBorderW),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius),
        onTap: onPressed,
        child: Container(
          height: height,
          alignment: Alignment.center,
          child: Text(label, style: inter(16, 600)),
        ),
      ),
    );
  }
}

/// Six boxed digits (Figma "6-digit verification code"): 50 x 53, radius 12, active box has a 2px green border.
class OtpBoxes extends StatefulWidget {
  const OtpBoxes({super.key, required this.controller, this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  @override
  State<OtpBoxes> createState() => _OtpBoxesState();
}

class _OtpBoxesState extends State<OtpBoxes> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    _focus.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final active = text.length.clamp(0, 5);
    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: Stack(
        children: [
          Row(
            children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 53,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kField,
                      borderRadius: BorderRadius.circular(kRadius),
                      border: Border.all(
                        color: (_focus.hasFocus && i == active) ? kLink : kFieldBorder,
                        width: (_focus.hasFocus && i == active) ? 2 : kBorderW,
                      ),
                    ),
                    child: Text(i < text.length ? text[i] : '', style: inter(24, 500)),
                  ),
                ),
              ],
            ],
          ),
          // The real input sits invisibly over the boxes.
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                onChanged: widget.onChanged,
                decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lucide icon at a design size/colour.
class Ico extends StatelessWidget {
  const Ico(this.icon, {super.key, this.size = 20, this.color = kLink});
  final IconData icon;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(icon, size: size, color: color);
}

const lucideMailCheck = LucideIcons.mailCheck;
const lucideCircleCheck = LucideIcons.circleCheck;
const lucideInfo = LucideIcons.info;
const lucideX = LucideIcons.x;
const lucideBuilding = LucideIcons.building2;
const lucideHandshake = LucideIcons.handshake;
const lucideStore = LucideIcons.store;
const lucideEye = LucideIcons.eye;

/// Bottom sheet for a legal document. The real text/URL is not supplied yet, so it says so.
void showLegalSheet(BuildContext context, String title) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: inter(20, 600)),
          const SizedBox(height: 12),
          Text('The full $title is being finalised. OneLocal will share the current copy with you during onboarding.', style: inter(14, 400, color: kMuted, height: 1.5)),
          const SizedBox(height: 24),
          PrimaryAction(label: 'Close', onPressed: () => Navigator.pop(ctx)),
        ],
      ),
    ),
  );
}

/// Country codes offered for mobile sign-in. India first.
const kCountryCodes = <(String, String)>[
  ('India', '+91'),
  ('United Arab Emirates', '+971'),
  ('United States', '+1'),
  ('United Kingdom', '+44'),
  ('Singapore', '+65'),
];

/// Bottom sheet that returns the chosen country code, or null if dismissed.
Future<String?> pickCountryCode(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kPadX, 24, kPadX, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Country code', style: inter(20, 600)),
            const SizedBox(height: 12),
            for (final (name, code) in kCountryCodes)
              InkWell(
                onTap: () => Navigator.pop(ctx, code),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      Expanded(child: Text(name, style: inter(15, code == current ? 600 : 400))),
                      Text(code, style: inter(15, 500, color: kMuted)),
                      if (code == current) ...[const SizedBox(width: 8), const Ico(lucideCircleCheck, size: 18)],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
