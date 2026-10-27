import 'package:flutter/material.dart';

import '../home/home_widgets.dart' show kLime;
import '../ui/app_header.dart';
import '../ui/theme.dart';
import '../ui/i18n.dart';

/// Small building blocks shared by the Customer, One Local Wallet and Manage account screens, in the app's look
/// (white top band with a round back button, white cards with a hairline, dark full-width action with a lime label).

class CwaTopBar extends StatelessWidget {
  const CwaTopBar({super.key, required this.title, this.onBack, this.trailing});
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  // The shared banner (back, store name over the page's name, bell, ☰).
  @override
  Widget build(BuildContext context) => AppHeader(title: title, onBack: onBack, back: true, trailing: trailing);
}

class CwaCard extends StatelessWidget {
  const CwaCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine)),
        child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class CwaButton extends StatelessWidget {
  const CwaButton({super.key, required this.label, required this.onPressed, this.busy = false, this.light = false, this.danger = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy, light, danger;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final bg = danger ? const Color(0xFFFEF2F2) : light ? Colors.white : kPrimary;
    final fg = danger ? kError : light ? kInk : kLime;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: light || danger ? const BorderSide(color: kLine) : BorderSide.none),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onPressed,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          child: busy
              ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: onPressed == null ? kMuted : fg), const SizedBox(width: 8)],
                  Text(label, style: inter(15, 600, color: onPressed == null ? kMuted : fg)),
                ]),
        ),
      ),
    );
  }
}

class CwaField extends StatelessWidget {
  const CwaField({super.key, required this.label, required this.controller, this.hint, this.keyboardType, this.maxLines = 1, this.enabled = true, this.fieldKey});
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final int maxLines;
  final bool enabled;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: inter(12.5, 600, color: kMuted)),
          const SizedBox(height: 6),
          TextField(
            key: fieldKey,
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            maxLines: maxLines,
            style: inter(15, 500),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: inter(14, 400, color: kMuted),
              filled: true,
              fillColor: kField,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kFieldBorder)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kFieldBorder)),
            ),
          ),
        ]),
      );
}

/// A failed load says so and offers a retry; nothing is invented.
class CwaLoadError extends StatelessWidget {
  const CwaLoadError({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: Text(tr('Try again'), style: inter(14, 600, color: kLink))),
        ]),
      );
}

class CwaRow extends StatelessWidget {
  const CwaRow(this.label, this.value, {super.key, this.strong = false});
  final String label, value;
  final bool strong;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: inter(13, 400, color: kMuted))),
          const SizedBox(width: 12),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: inter(13.5, strong ? 700 : 500))),
        ]),
      );
}

class CwaSection extends StatelessWidget {
  const CwaSection(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(title, style: inter(14, 700)),
      );
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// 20 Oct 2026
String cwaDate(DateTime? d) => d == null ? '—' : '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]} ${d.year}';

/// 20 Oct 2026, 14:05
String cwaDateTime(DateTime? d) => d == null ? '—' : '${cwaDate(d)}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
