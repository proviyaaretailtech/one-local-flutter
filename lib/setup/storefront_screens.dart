import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../onboarding/document_picker.dart';
import '../ui/theme.dart';
import 'setup_api.dart';
import 'setup_flow.dart';
import 'setup_widgets.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _daysText(Set<int> d) {
  if (d.isEmpty) return '';
  if (d.length == 7) return 'Every day';
  final s = d.toList()..sort();
  return s.map((i) => _days[i - 1]).join(', ');
}

String _time(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay? _parse(String? s) {
  final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s ?? '');
  return m == null ? null : TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!));
}

/// A field that opens the clock and shows HH:MM.
class TimeField extends StatelessWidget {
  const TimeField({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final TimeOfDay? value;
  final ValueChanged<TimeOfDay> onChanged;
  @override
  Widget build(BuildContext context) => SetupSelect<TimeOfDay>(
        label: label,
        value: value,
        options: const [],
        hint: 'Select time',
        display: _time,
        onChanged: onChanged,
      ).withTap(() async {
        final t = await showTimePicker(context: context, initialTime: value ?? const TimeOfDay(hour: 9, minute: 0));
        if (t != null) onChanged(t);
      });
}

extension on SetupSelect<TimeOfDay> {
  /// The same look as a list field, but the tap opens the clock instead of a list.
  Widget withTap(VoidCallback onTap) => Builder(
        builder: (context) => Stack(children: [
          this,
          Positioned.fill(child: Material(type: MaterialType.transparency, child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap))),
        ]),
      );
}

/// Dashed upload tile (logo or cover). Shows the uploaded image once there is one.
class UploadTile extends StatelessWidget {
  const UploadTile({super.key, required this.title, required this.sub, required this.url, required this.busy, required this.onTap});
  final String title, sub;
  final String? url;
  final bool busy;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: busy ? null : onTap,
          child: CustomPaint(
            painter: _DashedBorder(),
            child: SizedBox(
              height: 82,
              child: url != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(url!, fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, _, _) => _label('Uploaded', 'Tap to replace')))
                  : busy
                      ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kDone)))
                      : _label(title, sub),
            ),
          ),
        ),
      );

  Widget _label(String t, String s) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(LucideIcons.upload, size: 18, color: kInk),
        const SizedBox(height: 6),
        Text(t, style: inter(12.5, 700)),
        const SizedBox(height: 4),
        Text(s, style: inter(10.5, 400, color: kMuted)),
      ]);
}

class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.drawRRect(rr, Paint()..color = kBg);
    final paint = Paint()
      ..color = kBoxBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in (Path()..addRRect(rr)).computeMetrics()) {
      for (double d = 0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => false;
}

/// Figma 24 "OneLocal Listing Setup": public name, description, logo and cover, address, opening hours.
class ListingScreen extends StatefulWidget {
  const ListingScreen({super.key, required this.api, required this.state, this.picker = const ImagePicker()});
  final SetupApi api;
  final SetupState state;
  final DocumentPicker picker;
  @override
  State<ListingScreen> createState() => _ListingScreenState();
}

class _ListingScreenState extends State<ListingScreen> with TourHost {
  final _imagesKey = GlobalKey();
  late SetupState _s = widget.state;
  late final Map<String, dynamic> _l = widget.state.listing;
  late final _name = TextEditingController(text: _l['public_name'] as String? ?? '');
  late final _desc = TextEditingController(text: _l['description'] as String? ?? '');
  late final _address = TextEditingController(text: _l['address_line'] as String? ?? '');
  late Set<int> _openDays = {for (final d in (_l['open_days'] as List?) ?? const []) (d as num).toInt()};
  late TimeOfDay? _opens = _parse(_l['opens_at'] as String?);
  late TimeOfDay? _closes = _parse(_l['closes_at'] as String?);
  String? _uploading;
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _upload(String kind) async {
    final f = await widget.picker.pick();
    if (f == null || !mounted) return;
    if (f.contentType != 'image/jpeg' && f.contentType != 'image/png') return showToast(context, 'Upload a JPG or PNG.');
    if (f.bytes.length > 5 * 1024 * 1024) return showToast(context, 'Each image can be up to 5 MB.');
    setState(() => _uploading = kind);
    final s = await setupGuarded(context, () => widget.api.uploadImage(kind: kind, bytes: f.bytes, contentType: f.contentType));
    if (!mounted) return;
    setState(() {
      _uploading = null;
      if (s != null) _s = s;
    });
  }

  Future<void> _pickDays() async {
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _DaysSheet(initial: _openDays),
    );
    if (picked != null) setState(() => _openDays = picked);
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return showToast(context, 'Enter your public business name.');
    if (_desc.text.trim().length < 10) return showToast(context, 'Tell customers what you sell in 10 to 500 characters.');
    if (_address.text.trim().length < 5) return showToast(context, 'Enter the address customers should see.');
    if (_openDays.isEmpty) return showToast(context, 'Select the days you are open.');
    if (_opens == null || _closes == null) return showToast(context, 'Choose your opening and closing time.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.saveListing({
          'public_name': _name.text,
          'description': _desc.text.trim(),
          'address_line': _address.text,
          'open_days': (_openDays.toList()..sort()),
          'opens_at': _time(_opens!),
          'closes_at': _time(_closes!),
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final l = _s.listing;
    return SetupDialog(
      title: 'OneLocal Listing Setup',
      subtitle: 'Help nearby customers find and recognise your business.',
      tour: tourFor(8, 'Create your storefront', 'Add your business details and images to help customers discover your store on OneLocal.', _imagesKey),
      children: [
        SetupField(label: 'Public business name', controller: _name, hint: 'Enter your public business name', maxLength: 80),
        const SizedBox(height: 12),
        SetupField(label: 'Description', controller: _desc, hint: 'Tell customers what you sell', maxLines: 3, maxLength: 500),
        const SizedBox(height: 12),
        TourTarget(
          tourKey: _imagesKey,
          child: Row(children: [
            Expanded(child: UploadTile(title: 'Upload logo', sub: 'Square · JPG or PNG', url: l['logo_url'] as String?, busy: _uploading == 'logo', onTap: () => _upload('logo'))),
            const SizedBox(width: 8),
            Expanded(child: UploadTile(title: 'Upload cover', sub: 'Landscape · JPG or PNG', url: l['cover_url'] as String?, busy: _uploading == 'cover', onTap: () => _upload('cover'))),
          ]),
        ),
        const SizedBox(height: 12),
        SetupField(label: 'Address', controller: _address, hint: 'Shop address customers will see', maxLines: 2, maxLength: 250),
        const SizedBox(height: 16),
        const SetupHeading('Opening hours'),
        const SizedBox(height: 10),
        Stack(children: [
          SetupSelect<String>(label: 'Open days', value: _openDays.isEmpty ? null : _daysText(_openDays), options: const [], hint: 'Select days of the week', display: (v) => v, onChanged: (_) {}),
          Positioned.fill(child: Material(type: MaterialType.transparency, child: InkWell(onTap: _pickDays))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TimeField(label: 'Opens at', value: _opens, onChanged: (t) => setState(() => _opens = t))),
          const SizedBox(width: 8),
          Expanded(child: TimeField(label: 'Closes at', value: _closes, onChanged: (t) => setState(() => _closes = t))),
        ]),
      ],
      actions: [PillPrimary(label: _busy ? 'Saving…' : 'Save Listing', onPressed: _busy ? null : _save)],
    );
  }
}

class _DaysSheet extends StatefulWidget {
  const _DaysSheet({required this.initial});
  final Set<int> initial;
  @override
  State<_DaysSheet> createState() => _DaysSheetState();
}

class _DaysSheetState extends State<_DaysSheet> {
  late final Set<int> _d = {...widget.initial};
  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Open days', style: inter(16, 700)),
            const SizedBox(height: 8),
            for (var i = 1; i <= 7; i++)
              SetupCheck(value: _d.contains(i), title: const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][i - 1],
                  onChanged: (v) => setState(() => v ? _d.add(i) : _d.remove(i))),
            const SizedBox(height: 12),
            PillPrimary(label: 'Done', onPressed: () => Navigator.pop(context, _d)),
          ]),
        ),
      );
}

/// Figma 25 "Delivery / Fulfilment Setup" (optional): pickup, self-delivery with its radius, minimum, fee and hours, OneLocal delivery.
class FulfilmentScreen extends StatefulWidget {
  const FulfilmentScreen({super.key, required this.api, required this.state});
  final SetupApi api;
  final SetupState state;
  @override
  State<FulfilmentScreen> createState() => _FulfilmentScreenState();
}

class _FulfilmentScreenState extends State<FulfilmentScreen> with TourHost {
  final _optionsKey = GlobalKey();
  late final Map<String, dynamic> _f = widget.state.fulfilment;
  late bool _pickup = _f['pickup'] == true;
  late bool _self = _f['self_delivery'] == true;
  late bool _onelocal = _f['onelocal_delivery'] == true;
  late final _radius = TextEditingController(text: _num(_f['radius_km']));
  late final _areas = TextEditingController(text: SetupState.strings(_f['service_areas']).join(', '));
  late final _min = TextEditingController(text: _num(_f['min_order']));
  late final _fee = TextEditingController(text: _num(_f['delivery_fee']));
  late String _hours = _f['delivery_hours'] as String? ?? 'same_as_opening';
  late TimeOfDay? _from = _parse(_f['delivery_from'] as String?);
  late TimeOfDay? _to = _parse(_f['delivery_to'] as String?);
  bool _busy = false;

  static String _num(Object? v) {
    if (v == null) return '';
    final n = (v as num).toDouble();
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  void dispose() {
    for (final c in [_radius, _areas, _min, _fee]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_pickup || _self || _onelocal)) return showToast(context, 'Choose at least one way customers get their orders.');
    if (_self && (double.tryParse(_radius.text) ?? 0) < 0.5) return showToast(context, 'Delivery radius must be 0.5 to 30 km.');
    if (_self && _hours == 'custom' && (_from == null || _to == null)) return showToast(context, 'Choose your delivery start and end time.');
    setState(() => _busy = true);
    final s = await setupGuarded(context, () => widget.api.saveFulfilment({
          'pickup': _pickup,
          'self_delivery': _self,
          'onelocal_delivery': _onelocal,
          if (_self) ...{
            'radius_km': _radius.text.trim(),
            'service_areas': _areas.text.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList(),
            'min_order': _min.text.trim(),
            'delivery_fee': _fee.text.trim(),
            'delivery_hours': _hours,
            if (_hours == 'custom') 'delivery_from': _time(_from!),
            if (_hours == 'custom') 'delivery_to': _time(_to!),
          },
        }));
    if (!mounted) return;
    setState(() => _busy = false);
    if (s != null) popWith(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final money = [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))];
    return SetupDialog(
      kicker: 'Business setup · Optional',
      title: 'Delivery / Fulfilment Setup',
      subtitle: 'Choose delivery or customer pickup. Delivery is optional.',
      tour: tourFor(9, 'Choose how orders are fulfilled', 'Configure delivery, pickup, service areas, and the options available to your customers.', _optionsKey),
      children: [
        TourTarget(
          tourKey: _optionsKey,
          child: SetupBox(children: [
            SetupCheck(value: _pickup, title: 'Customer pickup', sub: 'Customers collect from your shop', onChanged: (v) => setState(() => _pickup = v)),
            SetupCheck(value: _self, title: 'Self-delivery', sub: 'Your team delivers orders', onChanged: (v) => setState(() => _self = v)),
            SetupCheck(value: _onelocal, title: 'OneLocal delivery', sub: 'Subject to availability in your area', onChanged: (v) => setState(() => _onelocal = v)),
          ]),
        ),
        if (_self) ...[
          const SizedBox(height: 16),
          const SetupHeading('Self-delivery settings'),
          const SizedBox(height: 10),
          SetupField(label: 'Delivery radius (km)', controller: _radius, hint: 'e.g. 3', keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}\.?\d?'))]),
          const SizedBox(height: 12),
          SetupField(label: 'Delivery areas · optional', controller: _areas, hint: 'Areas, separated by commas'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: SetupField(label: 'Minimum order', controller: _min, hint: 'Enter ₹ amount', keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: money)),
            const SizedBox(width: 8),
            Expanded(child: SetupField(label: 'Delivery fee', controller: _fee, hint: 'Enter ₹ amount', keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: money)),
          ]),
          const SizedBox(height: 12),
          SetupSelect<String>(
            label: 'Delivery hours',
            value: _hours,
            options: const ['same_as_opening', 'custom'],
            hint: 'Choose',
            display: (v) => v == 'custom' ? 'Custom hours' : 'Same as opening hours',
            onChanged: (v) => setState(() => _hours = v),
          ),
          if (_hours == 'custom') ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TimeField(label: 'From', value: _from, onChanged: (t) => setState(() => _from = t))),
              const SizedBox(width: 8),
              Expanded(child: TimeField(label: 'To', value: _to, onChanged: (t) => setState(() => _to = t))),
            ]),
          ],
          const SizedBox(height: 12),
          const SetupNote('Accept delivery orders only within your radius and selected areas during delivery hours.'),
        ],
      ],
      actions: [PillPrimary(label: _busy ? 'Saving…' : 'Save & Continue', onPressed: _busy ? null : _save)],
    );
  }
}
