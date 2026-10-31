import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/item_name.dart';
import '../ui/theme.dart';
import 'setup_api.dart';
import 'setup_flow.dart';
import 'setup_widgets.dart';

/// Figma 21 "POS Setup": name this device as the POS terminal; tick the peripherals in use (they are paired later on the device).
class PosScreen extends StatefulWidget {
  const PosScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> with TourHost {
  final _periKey = GlobalKey();
  late final List<Map<String, dynamic>> _devices = SetupState.maps(widget.state.pos['devices']);
  late final _name = TextEditingController(text: _devices.where((d) => d['type'] == 'pos_terminal').firstOrNull?['name'] as String? ?? '');
  late final Set<String> _peri = {for (final d in _devices) if (d['type'] != 'pos_terminal') d['type'] as String};
  late String? _connection = _devices.where((d) => d['type'] != 'pos_terminal').firstOrNull?['connection'] as String?;
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _status(String type) => _peri.contains(type)
      ? (_devices.any((d) => d['type'] == type && d['connected'] == true) ? 'Connected' : 'Selected · pair it on this device later')
      : 'Not connected';

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return showToast(context, 'Give this POS device a name.');
    if (_peri.isNotEmpty && _connection == null) return showToast(context, 'Choose Bluetooth, USB or network for your peripherals.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.registerPos({
          'device_name': _name.text,
          'peripherals': _peri.toList(),
          if (_peri.isNotEmpty) 'connection': _connection,
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final registered = widget.state.pos['registered'] == true;
    final kotAllowed = widget.state.pos['kot_allowed'] == true;
    void toggle(String type, bool on) => setState(() => on ? _peri.add(type) : _peri.remove(type));
    return SetupDialog(
      title: 'POS Setup',
      subtitle: 'Register your billing device. Add peripherals only if you use them.',
      tour: tourFor(5, 'Get your POS ready', 'Set up your POS device and connect supported printers and scanners.', _periKey),
      children: [
        SetupStatusPill(registered ? 'Device registered' : 'Device not registered', done: registered),
        const SizedBox(height: 14),
        SetupField(label: 'POS device name', controller: _name, hint: 'e.g. Front counter', maxLength: 60),
        const SizedBox(height: 16),
        const SetupHeading('Optional peripherals'),
        const SizedBox(height: 8),
        TourTarget(
          tourKey: _periKey,
          child: SetupBox(children: [
            SetupCheck(value: _peri.contains('receipt_printer'), title: 'Receipt printer', sub: _status('receipt_printer'), onChanged: (v) => toggle('receipt_printer', v)),
            SetupCheck(value: _peri.contains('scanner'), title: 'Barcode scanner', sub: _status('scanner'), onChanged: (v) => toggle('scanner', v)),
            SetupCheck(
              value: _peri.contains('kot_printer'),
              title: 'KOT printer',
              sub: kotAllowed ? _status('kot_printer') : 'Restaurant kitchens only · not applicable to retail',
              onChanged: kotAllowed ? (v) => toggle('kot_printer', v) : null,
            ),
          ]),
        ),
        const SizedBox(height: 14),
        SetupSelect<String>(
          label: 'Connection · if adding a peripheral',
          value: _connection,
          options: const ['bluetooth', 'usb', 'lan'],
          hint: 'Choose Bluetooth, USB or network',
          display: (v) => switch (v) { 'bluetooth' => 'Bluetooth', 'usb' => 'USB', _ => 'Network (LAN)' },
          onChanged: (v) => setState(() => _connection = v),
        ),
        const SizedBox(height: 12),
        const SetupNote('Leave peripherals unchecked to skip them. You can connect them later.'),
      ],
      actions: [
        PillPrimary(label: _busy ? 'Saving…' : 'Set Up Device', onPressed: _busy ? null : _save),
        const SizedBox(height: 8),
        PillSecondary(label: 'Skip for Now', onPressed: _busy ? null : () => popWith(context, widget.state)),
      ],
    );
  }
}

const _permissions = [
  ('billing.collect', 'Create bills & collect payments'),
  ('catalogue.view', 'View catalogue & stock'),
  ('refunds.manage', 'Manage refunds'),
  ('settings.manage', 'Change business settings'),
];

Set<String> _defaultPermissions(String role) => switch (role) {
      'manager' => {'billing.collect', 'catalogue.view', 'refunds.manage'},
      'kitchen' => {'catalogue.view'},
      _ => {'billing.collect', 'catalogue.view'},
    };

String _roleName(String r) => switch (r) { 'cashier' || 'biller' => 'Cashier', 'manager' || 'location_manager' => 'Manager', 'kitchen' => 'Kitchen', _ => r };

/// Figma 22 "Staff Setup" (optional): invite a team member with a role and the permissions they get.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> with TourHost {
  final _roleKey = GlobalKey();
  late SetupState _s = widget.state;
  final _name = TextEditingController();
  final _email = TextEditingController();
  String _role = 'cashier';
  Set<String> _perms = _defaultPermissions('cashier');
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_name.text.trim().length < 2) return showToast(context, "Enter the staff member's name.");
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) return showToast(context, 'Enter a valid email for the invite.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.inviteStaff({'name': _name.text, 'email': _email.text.trim(), 'role': _role, 'permissions': _perms.toList()}));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (s != null) {
        _s = s;
        _name.clear();
        _email.clear();
      }
    });
    if (s != null) showToast(context, 'Invite saved.');
  }

  @override
  Widget build(BuildContext context) {
    final roles = SetupState.strings(_s.staff['roles']);
    final invites = SetupState.maps(_s.staff['invites']);
    return SetupDialog(
      kicker: 'Business setup · Optional',
      title: 'Staff Setup',
      subtitle: 'Invite your team and choose what each staff member can access.',
      tour: tourFor(6, 'Bring your team onboard', 'Add staff and assign roles so everyone has the right access.', _roleKey),
      children: [
        SetupField(label: 'Staff name', controller: _name, hint: 'Full name', maxLength: 120),
        const SizedBox(height: 12),
        SetupField(label: 'Email for the invite', controller: _email, hint: 'name@example.com', keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 12),
        TourTarget(
          tourKey: _roleKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SetupSelect<String>(
              label: 'Role',
              value: _role,
              options: roles.isEmpty ? const ['cashier', 'manager'] : roles,
              hint: 'Choose a role',
              display: _roleName,
              onChanged: (v) => setState(() {
                _role = v;
                _perms = _defaultPermissions(v);
              }),
            ),
            const SizedBox(height: 14),
            SetupHeading('${_roleName(_role)} permissions'),
            const SizedBox(height: 8),
            SetupBox(children: [
              for (final (key, label) in _permissions)
                SetupCheck(value: _perms.contains(key), title: label, onChanged: (v) => setState(() => v ? _perms.add(key) : _perms.remove(key))),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        const SetupNote('Add Staff saves an invite for this email with only the selected permissions.'),
        if (invites.isNotEmpty) ...[
          const SizedBox(height: 16),
          const SetupHeading('Invited'),
          const SizedBox(height: 4),
          for (final i in invites)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text('${i['name'] ?? i['email']} · ${_roleName(i['role'] as String? ?? '')}', style: inter(12.5, 600))),
                Text(i['status'] == 'accepted' ? 'Joined' : 'Invited', style: inter(10.5, 700, color: i['status'] == 'accepted' ? kDone : kMuted)),
              ]),
            ),
        ],
      ],
      actions: [
        PillSecondary(label: _busy ? 'Saving…' : 'Add Staff', onPressed: _busy ? null : _add),
        const SizedBox(height: 8),
        PillPrimary(label: 'Continue', onPressed: _busy ? null : () => popWith(context, _s)),
      ],
    );
  }
}

/// A line that shows whether part of the catalogue is ready: a green tick when it is, a grey dot until then. Nothing to tap.
class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.title});
  final bool done;
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: done ? const Color(0xFF15803D) : const Color(0xFFB8BCC4)),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: inter(13.5, 500, color: done ? kInk : kMuted))),
          Text(done ? 'Done' : 'Not yet', style: inter(12, 600, color: done ? const Color(0xFF15803D) : kMuted)),
        ]),
      );
}

/// Figma 23 "Catalogue Setup": first items for billing. Items are added one at a time here.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> with TourHost {
  final _addKey = GlobalKey();
  late SetupState _s = widget.state;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  Future<void> _addItem() async {
    final s = await showModalBottomSheet<SetupState>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => AddItemSheet(api: widget.api, state: _s),
    );
    if (s != null && mounted) {
      setState(() => _s = s);
      showToast(context, 'Item added.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _s.catalogue;
    final items = (c['items'] ?? 0) as int;
    final food = _s.isRestaurant;
    final add = TourTarget(tourKey: _addKey, child: items == 0 ? PillPrimary(label: 'Add Items', onPressed: _addItem) : PillSecondary(label: 'Add Items', onPressed: _addItem));
    return SetupDialog(
      title: 'Catalogue Setup',
      subtitle: food ? 'Add the dishes on your menu so you can start billing.' : 'Add the retail products you sell so you can start billing.',
      tour: tourFor(7, 'Add what you sell', 'Set up your products, restaurant menu, or services based on your business type.', _addKey),
      children: [
        SetupBox(padding: const EdgeInsets.fromLTRB(12, 12, 12, 12), children: [
          Row(children: [
            const Icon(LucideIcons.package, size: 24, color: kInk),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(food ? 'Menu items' : 'Retail products', style: inter(13, 700)),
                const SizedBox(height: 2),
                Text(items == 0 ? 'No items added yet' : '$items ${items == 1 ? 'item' : 'items'} added', style: inter(12, 400, color: kMuted)),
              ]),
            ),
          ]),
        ]),
        const SizedBox(height: 16),
        const SetupHeading('Before your first sale'),
        const SizedBox(height: 8),
        // progress, not something to tap (founder, 28 Oct 2026: they looked like checkboxes): each line turns green by itself
        SetupBox(key: const ValueKey('catalogue-progress'), children: [
          _Progress(done: c['names_done'] == true, title: food ? 'Dish names & categories' : 'Product names & categories'),
          _Progress(done: c['prices_done'] == true, title: 'Selling price & tax on every item'),
        ]),
        const SizedBox(height: 12),
        const SetupNote('Add items one at a time now, or add them later from Items. You can edit them any time.'),
      ],
      actions: items == 0
          // Add later (founder, 28 Oct 2026): setup goes on; the catalogue stays on the checklist
          ? [add, const SizedBox(height: 8), PillSecondary(key: const ValueKey('catalogue-later'), label: 'Add later', onPressed: () => popWith(context, _s))]
          : [add, const SizedBox(height: 8), PillPrimary(label: 'Continue', onPressed: () => popWith(context, _s))],
    );
  }
}

/// Name, category, selling price (and veg / non-veg for restaurants). Saves through the server and closes with the new state.
class AddItemSheet extends StatefulWidget {
  const AddItemSheet({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<AddItemSheet> {
  final _name = TextEditingController();
  late final _category = TextEditingController(text: SetupState.strings(widget.state.catalogue['categories']).firstOrNull ?? '');
  final _price = TextEditingController();
  String _food = 'veg';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final price = double.tryParse(_price.text.trim());
    if (_name.text.trim().length < 2) return showToast(context, 'Enter the item name.');
    if (_category.text.trim().length < 2) return showToast(context, 'Enter a category.');
    if (price == null || price <= 0) return showToast(context, 'Enter a selling price above zero.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.addItem({
          // a store's product name: typed in capitals, saved in Title Case
          'name': widget.state.isRestaurant ? _name.text : titleCase(_name.text),
          'category': _category.text,
          'price': _price.text.trim(),
          if (widget.state.isRestaurant) 'food_type': _food,
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) Navigator.of(context).pop(s);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add an item', style: inter(18, 700)),
          const SizedBox(height: 14),
          widget.state.isRestaurant
              ? SetupField(label: 'Item name', controller: _name, hint: 'e.g. Masala Dosa', maxLength: 120)
              : SetupField(label: 'Item name (capitals)', controller: _name, hint: 'e.g. TATA SALT', maxLength: kItemNameMax, inputFormatters: itemNameFormatters),
          const SizedBox(height: 12),
          SetupField(label: 'Category', controller: _category, hint: widget.state.isRestaurant ? 'e.g. South Indian' : 'e.g. Staples', maxLength: 60),
          const SizedBox(height: 12),
          SetupField(
            label: 'Selling price (₹)',
            controller: _price,
            hint: '0.00',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
          ),
          if (widget.state.isRestaurant) ...[
            const SizedBox(height: 12),
            SetupSelect<String>(
              label: 'Food type',
              value: _food,
              options: const ['veg', 'non_veg', 'egg'],
              hint: 'Choose',
              display: (v) => switch (v) { 'veg' => 'Veg', 'non_veg' => 'Non-veg', _ => 'Egg' },
              onChanged: (v) => setState(() => _food = v),
            ),
          ],
          const SizedBox(height: 18),
          PillPrimary(label: _busy ? 'Saving…' : 'Add item', onPressed: _busy ? null : _save),
        ]),
      );
}
