import 'package:flutter/services.dart';

/// A person's name (founder, 29 Oct 2026): letters only, in any script (Hindi too), with spaces and the marks names use (. ' -).
/// Digits and other symbols cannot be typed.
final _nameChars = RegExp(r"[\p{L}\p{M} .'\-]", unicode: true);
final _hasLetter = RegExp(r'\p{L}', unicode: true);

/// For a name field: only letters, spaces and . ' - get through, up to 80 characters.
final List<TextInputFormatter> nameFormatters = [FilteringTextInputFormatter.allow(_nameChars), LengthLimitingTextInputFormatter(80)];

/// The name tidied: single spaces, no spaces at the ends.
String cleanName(String raw) => raw.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Why [raw] is not a name, or null when it is.
String? nameProblem(String raw, {String empty = 'Please enter your full name.'}) {
  final n = cleanName(raw);
  if (n.isEmpty) return empty;
  if (!n.split('').every(_nameChars.hasMatch)) return 'A name can have letters only, no numbers.';
  if (_hasLetter.allMatches(n).length < 2) return 'Please enter your full name.';
  return null;
}
