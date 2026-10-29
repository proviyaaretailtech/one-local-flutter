import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/net_guard.dart';
import '../home/home_widgets.dart' show kLime, rupees;
import '../ui/theme.dart';
import 'customer_widgets.dart';
import 'customers_api.dart';
import '../ui/i18n.dart';

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

class _Avatar extends StatelessWidget {
  const _Avatar(this.name, {this.size = 40});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: kLime, shape: BoxShape.circle),
        child: Text(_initials(name), style: inter(size * 0.36, 700, color: kPrimary)),
      );
}

/// One customer in a list: name, phone (as the database sent it, masked or not), visits and spend.
class CustomerTile extends StatelessWidget {
  const CustomerTile({super.key, required this.customer, required this.onTap});
  final Customer customer;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: CwaCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            _Avatar(customer.name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(customer.name, style: inter(14.5, 600), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(customer.phone, style: inter(12.5, 400, color: kMuted)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(rupees(customer.spent), style: inter(13.5, 600)),
              Text('${customer.visits} visit${customer.visits == 1 ? '' : 's'}', style: inter(11.5, 400, color: kMuted)),
            ]),
          ]),
        ),
      );
}

/// Side nav "Customer": the business's customers, search by name or phone, add, open one.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key, this.api});
  final CustomersApi? api;
  static Route<void> route({CustomersApi? api}) => MaterialPageRoute(builder: (_) => CustomersScreen(api: api));
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  late final CustomersApi _api = widget.api ?? CustomersApi();
  final _q = TextEditingController();
  final _items = <Customer>[];
  CustomerPage? _page;
  String? _error;
  bool _loading = true;
  Timer? _debounce;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final mine = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _api.list(q: _q.text, offset: more ? (_page?.nextOffset ?? 0) : 0);
      if (!mounted || mine != _seq) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(p.items);
        _page = p;
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

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _open(Customer c) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerDetailScreen(api: _api, id: c.id)));
    if (mounted) _load();
  }

  Future<void> _add() async {
    final saved = await Navigator.of(context).push<Customer>(MaterialPageRoute(builder: (_) => CustomerFormScreen(api: _api)));
    if (saved != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        CwaTopBar(title: tr('Customers')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: TextField(
            key: const ValueKey('customer-search'),
            controller: _q,
            onChanged: _search,
            style: inter(15, 500),
            decoration: InputDecoration(
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: kMuted),
              hintText: tr('Search by name or mobile number'),
              hintStyle: inter(14, 400, color: kMuted),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: const BorderSide(color: kLine)),
            ),
          ),
        ),
        if (p != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
            child: Row(children: [
              Text('${p.total} customer${p.total == 1 ? '' : 's'}', style: inter(12.5, 500, color: kMuted)),
              const Spacer(),
              if (!p.fullContact) Text('Contact details hidden for your role', style: inter(11.5, 400, color: kMuted)),
            ]),
          ),
        Expanded(
          child: _error != null && _items.isEmpty
              ? Center(child: CwaLoadError(message: _error!, onRetry: _load))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
                    if (_loading && _items.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
                    if (!_loading && _items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(_q.text.trim().isEmpty ? 'No customers yet. Add one here or from a bill.' : 'No customer matches "${_q.text.trim()}".',
                            textAlign: TextAlign.center, style: inter(14, 500, color: kMuted)),
                      ),
                    for (final c in _items) CustomerTile(customer: c, onTap: () => _open(c)),
                    if (p?.nextOffset != null)
                      TextButton(onPressed: _loading ? null : () => _load(more: true), child: Text(tr('Show more'), style: inter(14, 600, color: kLink))),
                  ]),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: CwaButton(label: tr('Add customer'), icon: LucideIcons.userPlus, onPressed: _add),
          ),
        ),
      ]),
    );
  }
}

/// One customer: contact, visits and spend, wallet and loyalty balance, recent bills. Edit only for roles the database allows.
class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({super.key, this.api, required this.id});
  final CustomersApi? api;
  final String id;
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late final CustomersApi _api = widget.api ?? CustomersApi();
  CustomerDetail? _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = await _api.view(widget.id);
      if (mounted) setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _error = errorSentence(e));
    }
  }

  Future<void> _edit() async {
    final c = _c;
    if (c == null) return;
    final saved = await Navigator.of(context).push<Customer>(MaterialPageRoute(builder: (_) => CustomerFormScreen(api: _api, existing: c)));
    if (saved != null && mounted) _load();
  }

  Widget _stat(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: inter(16, 700)),
            const SizedBox(height: 2),
            Text(label, style: inter(11.5, 400, color: kMuted)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        CwaTopBar(
          title: tr('Customer details'),
          trailing: c != null && c.canManage
              ? TextButton(key: const ValueKey('customer-edit'), onPressed: _edit, child: Text(tr('Edit'), style: inter(14, 600, color: kLink)))
              : null,
        ),
        Expanded(
          child: c == null
              ? Center(child: _error != null ? CwaLoadError(message: _error!, onRetry: _load) : const CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
                  CwaCard(
                    child: Row(children: [
                      _Avatar(c.name, size: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c.name, style: inter(17, 700)),
                          const SizedBox(height: 3),
                          Text(c.phone, style: inter(13.5, 500, color: kMuted)),
                          if (c.email != null) Text(c.email!, style: inter(13, 400, color: kMuted)),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    _stat('Visits', '${c.visits}'),
                    const SizedBox(width: 8),
                    _stat('Spent', rupees(c.spent)),
                    const SizedBox(width: 8),
                    _stat('Last visit', c.lastVisit == null ? '—' : cwaDate(c.lastVisit)),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _stat('Store wallet', rupees(c.walletBalance)),
                    const SizedBox(width: 8),
                    _stat('Loyalty points', '${c.loyaltyPoints}'),
                  ]),
                  const CwaSection('About'),
                  CwaCard(
                    child: Column(children: [
                      if (c.fullContact) ...[
                        CwaRow('GSTIN', c.gstNumber ?? '—'),
                        CwaRow('Birthday', c.dateOfBirth ?? '—'),
                        CwaRow('Anniversary', c.anniversary ?? '—'),
                        CwaRow('Address', c.address.isEmpty ? '—' : c.address),
                      ],
                      CwaRow('Prefers', switch (c.preferredDining) { 'takeaway' => 'Takeaway', 'delivery' => 'Delivery', _ => 'Dine-in' }),
                      CwaRow('Added at', c.locationName.isEmpty ? '—' : c.locationName),
                      if (c.notes.isNotEmpty) CwaRow('Notes', c.notes),
                      if (!c.fullContact) Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Contact details, dates and address are shown to managers only.', style: inter(11.5, 400, color: kMuted)),
                      ),
                    ]),
                  ),
                  const CwaSection('Recent bills'),
                  if (c.orders.isEmpty) Text(tr('No bills linked to this customer yet.'), style: inter(13, 400, color: kMuted)),
                  for (final o in c.orders)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: CwaCard(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(o.number, style: inter(14, 600)),
                              Text('${cwaDateTime(o.at)} · ${o.paid ? 'Paid' : o.status.replaceAll('_', ' ')}', style: inter(12, 400, color: kMuted)),
                            ]),
                          ),
                          Text(rupees(o.total), style: inter(14, 600)),
                        ]),
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}

/// Add a customer (any counter role) or change one (roles the database allows). A phone already on file brings back that customer.
class CustomerFormScreen extends StatefulWidget {
  const CustomerFormScreen({super.key, this.api, this.existing, this.initialPhone = ''});
  final CustomersApi? api;
  final CustomerDetail? existing;
  final String initialPhone;
  @override
  State<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends State<CustomerFormScreen> {
  late final CustomersApi _api = widget.api ?? CustomersApi();
  late final _first = TextEditingController(text: widget.existing?.firstName ?? '');
  late final _last = TextEditingController(text: widget.existing?.lastName ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? widget.initialPhone);
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late final _gst = TextEditingController(text: widget.existing?.gstNumber ?? '');
  late final _dob = TextEditingController(text: widget.existing?.dateOfBirth ?? '');
  late final _ann = TextEditingController(text: widget.existing?.anniversary ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_first, _last, _phone, _email, _gst, _dob, _ann, _address, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_first.text.trim().isEmpty || _phone.text.replaceAll(RegExp(r'\D'), '').length < 10) {
      showToast(context, 'Enter the name and a 10-digit mobile number.');
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await _api.save({
        if (widget.existing != null) 'id': widget.existing!.id,
        'first_name': _first.text.trim(),
        'last_name': _last.text.trim(),
        'phone': _phone.text.trim(),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
        if (_gst.text.trim().isNotEmpty) 'gst_number': _gst.text.trim(),
        if (_dob.text.trim().isNotEmpty) 'date_of_birth': _dob.text.trim(),
        if (_ann.text.trim().isNotEmpty) 'anniversary': _ann.text.trim(),
        'address': _address.text.trim(),
        'notes': _notes.text.trim(),
      });
      if (!mounted) return;
      if (s.duplicate) showToast(context, '${s.customer.name} already has this number. Using that customer.');
      Navigator.of(context).pop(s.customer);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    // When editing, a masked phone means the role cannot see it in full: the database refuses such edits anyway.
    final full = widget.existing?.fullContact ?? true;
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        CwaTopBar(title: editing ? 'Edit customer' : 'New customer'),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), children: [
            CwaField(label: tr('First name *'), controller: _first, fieldKey: const ValueKey('cust-first')),
            CwaField(label: tr('Last name'), controller: _last, fieldKey: const ValueKey('cust-last')),
            CwaField(label: tr('Mobile number *'), controller: _phone, mobile: true, hint: tr('10-digit mobile'), enabled: full, fieldKey: const ValueKey('cust-phone')),
            CwaField(label: tr('Email'), controller: _email, keyboardType: TextInputType.emailAddress, enabled: full),
            CwaField(label: tr('GSTIN (for business bills)'), controller: _gst, hint: '22AAAAA0000A1Z5', enabled: full),
            Row(children: [
              Expanded(child: CwaField(label: tr('Birthday'), controller: _dob, hint: 'YYYY-MM-DD', enabled: full)),
              const SizedBox(width: 10),
              Expanded(child: CwaField(label: tr('Anniversary'), controller: _ann, hint: 'YYYY-MM-DD', enabled: full)),
            ]),
            CwaField(label: tr('Address'), controller: _address, maxLines: 2, enabled: full),
            CwaField(label: tr('Notes'), controller: _notes, maxLines: 2),
            Text('Marketing messages are off until the customer agrees.', style: inter(11.5, 400, color: kMuted)),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: CwaButton(key: const ValueKey('cust-save'), label: editing ? 'Save changes' : 'Save customer', busy: _busy, onPressed: _save),
          ),
        ),
      ]),
    );
  }
}
