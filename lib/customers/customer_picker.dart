import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../ui/theme.dart';
import 'customer_widgets.dart';
import 'customers_api.dart';
import 'customers_screen.dart';

/// The answer of the S5.5 sheet: walk-in ([customer] null) or a customer of the business.
class CustomerChoice {
  const CustomerChoice.walkIn() : customer = null;
  const CustomerChoice(Customer this.customer);
  final Customer? customer;
  bool get walkIn => customer == null;
  String get label => customer?.name ?? 'Walk-in';
}

/// Step S5.5 "Customer: existing, walk-in or new customer" (Figma FINAL F, Customer Selection). Returns null when dismissed.
Future<CustomerChoice?> showCustomerPicker(BuildContext context, {CustomersApi? api}) => showModalBottomSheet<CustomerChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(height: MediaQuery.sizeOf(context).height * 0.8, child: CustomerPicker(api: api ?? CustomersApi())),
      ),
    );

class CustomerPicker extends StatefulWidget {
  const CustomerPicker({super.key, required this.api});
  final CustomersApi api;
  @override
  State<CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<CustomerPicker> {
  final _q = TextEditingController();
  List<Customer> _items = const [];
  String? _error;
  bool _loading = false;
  Timer? _debounce;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final mine = ++_seq;
    setState(() => _loading = true);
    try {
      final digits = _q.text.replaceAll(RegExp(r'\D'), '');
      // A full mobile number is looked up across the whole business, so a customer of another outlet is found, not added twice.
      final List<Customer> items;
      if (digits.length >= 10 && digits.length == _q.text.replaceAll(RegExp(r'[\s+\-]'), '').length) {
        final hit = await widget.api.lookup(digits);
        items = hit == null ? const [] : [hit];
      } else {
        items = (await widget.api.list(q: _q.text)).items;
      }
      if (!mounted || mine != _seq) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() {
        _error = errorSentence(e);
        _loading = false;
      });
    }
  }

  Future<void> _addNew() async {
    final digits = _q.text.replaceAll(RegExp(r'\D'), '');
    final c = await Navigator.of(context).push<Customer>(
        MaterialPageRoute(builder: (_) => CustomerFormScreen(api: widget.api, initialPhone: digits.length >= 10 ? digits : '')));
    if (c != null && mounted) Navigator.of(context).pop(CustomerChoice(c));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: kLine, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Text('Customer for this bill', style: inter(18, 700)),
          const SizedBox(height: 4),
          Text('Existing, walk-in or new customer.', style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 14),
          CwaCard(
            key: const ValueKey('pick-walk-in'),
            onTap: () => Navigator.of(context).pop(const CustomerChoice.walkIn()),
            child: Row(children: [
              const Icon(LucideIcons.footprints, size: 20, color: kInk),
              const SizedBox(width: 12),
              Expanded(child: Text('Walk-in customer', style: inter(15, 600))),
              Text('No details', style: inter(12, 400, color: kMuted)),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pick-search'),
            controller: _q,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), _search);
            },
            style: inter(15, 500),
            decoration: InputDecoration(
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              hintText: 'Mobile number or name',
              hintStyle: inter(14, 400, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kLine)),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _error != null
                ? CwaLoadError(message: _error!, onRetry: _search)
                : _loading && _items.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _items.isEmpty
                        ? Center(child: Text('No customer found. Add them as new.', style: inter(13.5, 500, color: kMuted)))
                        : ListView(children: [
                            for (final c in _items) CustomerTile(customer: c, onTap: () => Navigator.of(context).pop(CustomerChoice(c))),
                          ]),
          ),
          CwaButton(key: const ValueKey('pick-add-new'), label: 'Add new customer', icon: LucideIcons.userPlus, light: true, onPressed: _addNew),
        ]),
      );
}
