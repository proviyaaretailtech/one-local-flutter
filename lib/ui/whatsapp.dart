/// A WhatsApp chat with [text] typed in, to an Indian mobile (the last 10 digits of [phone]), or to any chat when there is no number.
///
/// Straight to api.whatsapp.com, never wa.me: wa.me redirects there and turns emojis into "�" on the way (founder, 28 Oct 2026).
/// Spaces go as %20, not "+".
Uri whatsAppLink(String phone, String text) {
  final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  final to = d.length >= 10 ? 'phone=91${d.substring(d.length - 10)}&' : '';
  return Uri.parse('https://api.whatsapp.com/send?${to}text=${Uri.encodeComponent(text)}');
}

// Tables in a WhatsApp message (founder, 1 Nov 2026): lines inside ``` show in WhatsApp's fixed-width text, so columns line up. 30 characters
// fit one line on a phone.

/// The width of a WhatsApp table, in characters.
const waTableWidth = 30;

/// [left] and [right] on one table line, the right one against the edge.
String waPair(String left, String right) => '$left${' ' * (waTableWidth - left.length - right.length).clamp(1, waTableWidth)}$right';

/// A rule across the table.
final waRule = '-' * waTableWidth;

/// A quantity as people write it: 17, 2.5, 0.125 (never 17.0).
String waQty(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
