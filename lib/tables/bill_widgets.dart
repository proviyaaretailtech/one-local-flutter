import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_widgets.dart' show kLimeH, kNavyH;
import '../ui/theme.dart';
import 'table_widgets.dart';

/// The name of the first bill screen's route (pushed from "Table T12 Order"); "Back to tables" and "New Order" return below it.
const billRouteName = 'rst-bill';

/// Back to the tables floor: closes every bill screen and the table's order screen (the floor reloads and shows the table Cleaning).
void backToTables(BuildContext context) {
  final nav = Navigator.of(context);
  var found = false;
  nav.popUntil((r) {
    if (r.settings.name == billRouteName) found = true;
    return found || r.isFirst;
  });
  if (found) nav.pop('tables');
}

/// White rounded card of the Checkout frame with its grey capital heading ("CURRENT ITEMS (TABLE 22)", "BILL SUMMARY").
class BillCard extends StatelessWidget {
  const BillCard({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title != null) ...[Text(title!, style: inter(14, 700, color: kMuted)), const SizedBox(height: 8)],
          ...children,
        ]),
      );
}

/// "2 × Paneer Butter Masala ₹640" / "Subtotal ₹1,240".
class BillLine extends StatelessWidget {
  const BillLine(this.label, this.value, {super.key, this.bold = false, this.muted = false, this.valueColor, this.valueKey});
  final String label, value;
  final bool bold, muted;
  final Color? valueColor;
  final Key? valueKey;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(child: Text(label, style: inter(bold ? 17 : 16, bold ? 700 : 400, color: muted ? kMuted : kInk))),
          Text(value, key: valueKey, style: inter(bold ? 22 : 16, bold ? 800 : 500, color: valueColor ?? kInk)),
        ]),
      );
}

/// Grey filled input of the Checkout frame ("Add a note for the kitchen", "dineQR30", "₹1,302").
class BillField extends StatelessWidget {
  const BillField({super.key, required this.controller, required this.hint, this.keyboard, this.maxLength, this.enabled = true, this.onChanged, this.fieldKey});
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboard;
  final int? maxLength;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final Key? fieldKey;
  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        keyboardType: keyboard,
        maxLength: maxLength,
        onChanged: onChanged,
        style: inter(17, 600),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: inter(17, 500, color: kMuted),
          counterText: '',
          filled: true,
          fillColor: const Color(0xFFF3F4F2),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE3E5E0))),
          disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE3E5E0))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
        ),
      );
}

/// One payment-method tile: Cash, Card, UPI / QR, Split Pay. The chosen one is lime.
class MethodTile extends StatelessWidget {
  const MethodTile({super.key, required this.label, required this.icon, required this.selected, required this.onTap, this.enabled = true});
  final String label;
  final IconData icon;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        child: Material(
          color: selected ? kLimeBtn : const Color(0xFFF3F4F2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? kLimeBtn : const Color(0xFFE3E5E0))),
          child: InkWell(
            key: ValueKey('method-$label'),
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(
              height: 56,
              child: Row(children: [
                const SizedBox(width: 16),
                Icon(icon, size: 20, color: selected ? kInk : (enabled ? kMuted : kCleanBorder)),
                const SizedBox(width: 10),
                Flexible(child: Text(label, style: inter(16, selected ? 700 : 600, color: selected ? kInk : (enabled ? kMuted : kCleanBorder)))),
              ]),
            ),
          ),
        ),
      );
}

const methodIcons = {'cash': LucideIcons.banknote, 'card': LucideIcons.creditCard, 'upi': LucideIcons.qrCode, 'split': LucideIcons.columns2};

/// A choice chip row (Cash / Card / UPI per guest; Guest 1 / Guest 2 per item).
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({super.key, required this.options, required this.selected, required this.onSelect, this.keyPrefix = 'choice'});
  final List<(String, String)> options; // (value, label)
  final String selected;
  final ValueChanged<String> onSelect;
  final String keyPrefix;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (v, label) in options)
          InkWell(
            key: ValueKey('$keyPrefix-$v'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(v),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: v == selected ? kNavyH : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: v == selected ? kNavyH : const Color(0xFFD9DBD5)),
              ),
              child: Text(label, style: inter(13.5, 600, color: v == selected ? Colors.white : kInk)),
            ),
          ),
      ]);
}

/// Small helper: the amount a person typed ("₹1,302", "1302.50") as a number, or null.
num? typedAmount(String text) {
  final t = text.replaceAll(RegExp(r'[₹,\s]'), '');
  if (t.isEmpty) return null;
  final v = num.tryParse(t);
  return v == null || v < 0 ? null : v;
}

/// Dark full-width button of the Journey 5 frames ("Take payment · Guest 1", "Back to tables"): lime text on navy.
class DarkLimeButton extends StatelessWidget {
  const DarkLimeButton(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onPressed != null && !busy,
        child: Material(
          color: onPressed == null ? const Color(0xFF6B7280) : kNavyH,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : onPressed,
            child: Container(
              height: 58,
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kLimeH))
                  : Text(label, textAlign: TextAlign.center, style: inter(16.5, 700, color: kLimeH)),
            ),
          ),
        ),
      );
}
