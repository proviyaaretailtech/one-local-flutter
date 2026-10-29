/// A WhatsApp chat with [text] typed in, to an Indian mobile (the last 10 digits of [phone]), or to any chat when there is no number.
///
/// Straight to api.whatsapp.com, never wa.me: wa.me redirects there and turns emojis into "�" on the way (founder, 28 Oct 2026).
/// Spaces go as %20, not "+".
Uri whatsAppLink(String phone, String text) {
  final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  final to = d.length >= 10 ? 'phone=91${d.substring(d.length - 10)}&' : '';
  return Uri.parse('https://api.whatsapp.com/send?${to}text=${Uri.encodeComponent(text)}');
}
