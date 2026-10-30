import 'package:flutter/services.dart';

// The supplier's invoice number (founder, 31 Oct 2026): typed by hand, never made up by the app. Capital letters, numbers, - and /
// only, up to 16 (INV001, ABC/2026/01, 001-2026, INV/26-27/001). Small letters turn into capitals; spaces and other signs are dropped.

const kInvoiceNoMax = 16;

/// Turns small letters into capitals, drops anything but A–Z, 0–9, - and /, and stops at [kInvoiceNoMax].
class InvoiceNoFormatter extends TextInputFormatter {
  const InvoiceNoFormatter();

  static String clean(String v) {
    final s = v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9/-]'), '');
    return s.length > kInvoiceNoMax ? s.substring(0, kInvoiceNoMax) : s;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = clean(newValue.text);
    if (text == newValue.text) return newValue;
    // keep the cursor where it was, counting only the characters that stay
    final before = clean(newValue.text.substring(0, newValue.selection.end.clamp(0, newValue.text.length)));
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: before.length.clamp(0, text.length)));
  }
}

const invoiceNoFormatters = <TextInputFormatter>[InvoiceNoFormatter()];
