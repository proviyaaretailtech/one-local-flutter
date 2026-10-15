/// "+91 ••••• 43210" from "+919876543210".
String maskPhone(String e164) {
  final d = e164.replaceAll(RegExp(r'\D'), '');
  if (d.length < 10) return e164;
  final tail = d.substring(d.length - 5);
  final cc = d.substring(0, d.length - 10);
  return '+${cc.isEmpty ? '91' : cc} ••••• $tail';
}

/// "r•••@sharmastore.in" from "ravi@sharmastore.in".
String maskEmail(String email) {
  final at = email.indexOf('@');
  if (at < 1) return email;
  return '${email[0]}•••${email.substring(at)}';
}
