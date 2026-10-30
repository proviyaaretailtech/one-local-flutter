import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/mobile_input.dart';
import '../ui/theme.dart';
import 'bill_api.dart';
import 'table_widgets.dart';

/// The customer on a restaurant bill (founder, 30 Oct 2026), on Checkout (before the bill is paid) and Send receipt (after): a customer icon
/// with the name and mobile number, or "Add customer". A tap asks the name and number and puts that customer on the bill ([BillApi.setCustomer]);
/// the number then fills in WhatsApp and SMS.
class BillCustomerButton extends StatelessWidget {
  const BillCustomerButton({super.key, required this.api, required this.order, required this.onSaved});
  final BillApi api;

  /// The bill (`rst_bill_order_json`): id, customer_name, customer_phone.
  final Facts order;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    final name = order.so('customer_name') ?? '';
    final phone = localMobile(order.so('customer_phone'));
    final has = name.isNotEmpty || phone.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kLine)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('bill-customer'),
          onTap: () async {
            if (await askBillCustomer(context, api: api, orderId: order.s('id'), name: name, phone: phone)) onSaved();
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: has ? kAvailBg : const Color(0xFFF3F4F6), shape: BoxShape.circle),
                child: Icon(has ? LucideIcons.userCheck : LucideIcons.userPlus, size: 21, color: has ? kAvailText : kInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(has ? (name.isEmpty ? 'Customer' : name) : 'Add customer', key: const ValueKey('bill-customer-name'), style: inter(16, 700)),
                  Text(has ? (phone.isEmpty ? 'No mobile number' : '$kMobilePrefix$phone') : 'Name and mobile number',
                      key: const ValueKey('bill-customer-phone'), style: inter(13.5, 400, color: kMuted)),
                ]),
              ),
              Icon(has ? LucideIcons.pencil : LucideIcons.plus, size: 18, color: kMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The name and mobile number sheet; true once the customer is on the bill.
Future<bool> askBillCustomer(BuildContext context, {required BillApi api, required String orderId, String name = '', String phone = ''}) async {
  final n = TextEditingController(text: name), m = TextEditingController(text: phone);
  String? error;
  var busy = false;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (c) => StatefulBuilder(
      builder: (c, set) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 18 + MediaQuery.of(c).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Customer for this bill', style: inter(20, 800)),
          Text('A number already saved brings up that customer.', style: inter(13, 500, color: kMuted)),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('bill-customer-name-field'),
            controller: n,
            autofocus: name.isEmpty,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(LucideIcons.userRound, size: 18)),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('bill-customer-phone-field'),
            controller: m,
            keyboardType: TextInputType.phone,
            inputFormatters: mobileFormatters,
            decoration: const InputDecoration(labelText: 'Mobile number', prefixText: kMobilePrefix, prefixIcon: Icon(LucideIcons.phone, size: 18)),
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, key: const ValueKey('bill-customer-error'), style: inter(14, 500, color: kError))),
          const SizedBox(height: 16),
          LimeButton('Save customer', key: const ValueKey('bill-customer-save'), busy: busy, onPressed: () async {
            final digits = m.text.replaceAll(RegExp(r'\D'), '');
            if (n.text.trim().isEmpty) return set(() => error = 'Enter the customer\'s name.');
            if (digits.length != 10) return set(() => error = 'Enter a 10-digit mobile number.');
            set(() {
              busy = true;
              error = null;
            });
            try {
              await api.setCustomer(orderId, name: n.text, phone: digits);
              if (c.mounted) Navigator.pop(c, true);
            } catch (e) {
              set(() {
                busy = false;
                error = sayError(e);
              });
            }
          }),
        ]),
      ),
    ),
  );
  return saved == true;
}
