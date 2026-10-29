import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/i18n.dart';
import '../ui/name_input.dart';
import '../ui/theme.dart';

// Who the cart is for (founder, 29 Oct 2026): the mobile number is asked before a cart starts and cannot be skipped, because the number is
// the customer's unique id. The name is optional (letters only).

/// The 10 digits of an Indian mobile, or null when [raw] is not one. A leading +91, 91 or 0 is dropped.
String? cleanMobile(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  return RegExp(r'^[6-9]\d{9}$').hasMatch(d) ? d : null;
}

/// "9876543210" -> "98765 43210".
String showMobile(String digits) => digits.length == 10 ? '${digits.substring(0, 5)} ${digits.substring(5)}' : digits;

/// Asks for the customer's mobile (required) and name (optional). Answers (name, 10-digit mobile), or null when closed.
/// With [canSkip] a small "Skip for now" lets a vendor in a hurry go on without it (founder, 29 Oct 2026): that answers ('', '').
Future<(String, String)?> askCartCustomer(BuildContext context, {String name = '', String phone = '', String? title, bool canSkip = false}) =>
    showOrderSheet<(String, String)>(context, title: title ?? tr('Customer'), body: (_) => _CustomerForm(name: name == 'Guest' ? '' : name, phone: phone, canSkip: canSkip));

class _CustomerForm extends StatefulWidget {
  const _CustomerForm({required this.name, required this.phone, this.canSkip = false});
  final String name, phone;
  final bool canSkip;
  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  late final _name = TextEditingController(text: widget.name);
  late final _phone = TextEditingController(text: widget.phone);
  String? _phoneError, _nameError;

  void _save() {
    final phone = cleanMobile(_phone.text);
    final name = cleanName(_name.text);
    setState(() {
      _phoneError = phone == null ? tr(_phone.text.trim().isEmpty ? 'Enter the customer\'s mobile number.' : 'Enter a 10-digit mobile number.') : null;
      _nameError = name.isEmpty ? null : nameProblem(name);
    });
    if (phone == null || _nameError != null) return;
    Navigator.pop(context, (name, phone));
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('The mobile number is needed: it is how the customer is known.'), style: inter(13, 500, color: kMuted)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('cart-customer-phone'),
          controller: _phone,
          autofocus: true,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d +]')), LengthLimitingTextInputFormatter(16)],
          decoration: InputDecoration(labelText: tr('Mobile number *'), prefixText: '+91 ', errorText: _phoneError),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('cart-customer-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          inputFormatters: nameFormatters,
          decoration: InputDecoration(labelText: tr('Name (optional)'), errorText: _nameError),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        // Skip sits right beside Save, so a vendor in a hurry sees it at once (founder, 29 Oct 2026)
        Row(children: [
          Expanded(flex: 3, child: DarkCta(key: const ValueKey('cart-customer-save'), label: tr('Save'), onPressed: _save)),
          if (widget.canSkip) ...[
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  key: const ValueKey('cart-customer-skip'),
                  onPressed: () => Navigator.pop(context, ('', '')),
                  icon: const Icon(LucideIcons.skipForward, size: 18, color: kInk),
                  label: Text(tr('Skip for now'), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, 700)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kInk,
                    backgroundColor: const Color(0xFFF3F4F1),
                    side: const BorderSide(color: Color(0xFFDDDFD8)),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ]);
}
