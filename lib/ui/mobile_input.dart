import 'package:flutter/services.dart';

/// Every mobile number box starts with India's code (founder, 28 Oct 2026): "+91 " shown in front, and only the 10 digits typed.
const kMobilePrefix = '+91 ';

/// Keeps the 10-digit mobile number: digits only, and a pasted "+91 98765 43210", "919876543210" or "09876543210" becomes "9876543210".
class MobileDigitsFormatter extends TextInputFormatter {
  const MobileDigitsFormatter();
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = localMobile(newValue.text);
    if (digits == newValue.text) return newValue;
    return TextEditingValue(text: digits, selection: TextSelection.collapsed(offset: digits.length));
  }
}

/// The formatters for a mobile number box.
const mobileFormatters = <TextInputFormatter>[MobileDigitsFormatter()];

/// A saved or typed number as the 10 digits the box shows: "+91 98765 43210" → "9876543210". Anything else keeps its digits (at most 10).
String localMobile(String? raw) {
  var d = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.length > 10 && d.startsWith('91')) d = d.substring(2);
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  return d.length > 10 ? d.substring(0, 10) : d;
}
