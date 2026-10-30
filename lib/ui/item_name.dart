import 'package:flutter/services.dart';

// A product's name (founder, 31 Oct 2026): typed in CAPITALS only, at most 25 characters; it is saved in Title Case, so the catalogue,
// the Bill, receipts and every list show "Amul Ghee", never "AMUL GHEE".

const kItemNameMax = 25;

/// Small letters turn into capitals as they are typed, and the name stops at [kItemNameMax].
class ItemNameFormatter extends TextInputFormatter {
  const ItemNameFormatter();

  static String clean(String v) {
    final s = v.toUpperCase();
    return s.length > kItemNameMax ? s.substring(0, kItemNameMax) : s;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = clean(newValue.text);
    if (text == newValue.text) return newValue;
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: clean(newValue.text.substring(0, end)).length.clamp(0, text.length)));
  }
}

const itemNameFormatters = <TextInputFormatter>[ItemNameFormatter()];

/// "AMUL GHEE" → "Amul Ghee", "PARLE-G 5KG" → "Parle-G 5kg": a capital after a space or sign, small letters elsewhere (a letter
/// after a number stays small, so sizes read 5kg and 500g).
String titleCase(String v) {
  final out = StringBuffer();
  var start = true;
  for (final ch in v.trim().replaceAll(RegExp(r'\s+'), ' ').split('')) {
    final letter = ch.toLowerCase() != ch.toUpperCase();
    out.write(start && letter ? ch.toUpperCase() : ch.toLowerCase());
    start = !(letter || RegExp(r'[0-9]').hasMatch(ch));
  }
  return out.toString();
}
