import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../onboarding/document_picker.dart';
import '../setup/setup_api.dart' show ImagePicker;
import '../ui/theme.dart';
import 'sf_widgets.dart';
import 'storefront_api.dart';

/// Figma "Business Profile": cover and logo, name, about, category, address, phone, store link. The server checks every field and that the
/// store link is free (a taken link is a clear sentence, not a crash).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.api, this.picker = const ImagePicker()});
  final StorefrontApi api;
  final DocumentPicker picker;
  @override
  Widget build(BuildContext context) => SfLoader<Facts>(
        load: api.settings,
        builder: (ctx, s, reload) => _ProfileForm(api: api, picker: picker, profile: s.m('profile'), reload: reload),
      );
}

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({required this.api, required this.picker, required this.profile, required this.reload});
  final StorefrontApi api;
  final DocumentPicker picker;
  final Facts profile;
  final Future<void> Function() reload;
  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  late final name = TextEditingController(text: widget.profile.so('public_name') ?? '');
  late final about = TextEditingController(text: widget.profile.so('description') ?? '');
  late final category = TextEditingController(text: widget.profile.so('business_category') ?? '');
  late final address = TextEditingController(text: widget.profile.so('address_line') ?? '');
  late final phone = TextEditingController(text: widget.profile.so('phone') ?? '');
  late final slug = TextEditingController(text: widget.profile.so('store_slug') ?? '');
  bool busy = false;

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await widget.api.saveProfile({
        'public_name': name.text.trim(),
        'description': about.text.trim(),
        'business_category': category.text.trim(),
        'address_line': address.text.trim(),
        'phone': phone.text.trim(),
        'store_slug': slug.text.trim(),
      });
      if (mounted) { showToast(context, 'Profile saved.'); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  Future<void> _image(String kind) async {
    final p = await widget.picker.pick();
    if (p == null) return;
    try {
      await widget.api.uploadListingImage(kind: kind, bytes: p.bytes, contentType: p.contentType);
      await widget.reload();
      if (mounted) showToast(context, kind == 'cover' ? 'Banner updated.' : 'Logo updated.');
    } catch (e) {
      if (mounted) sfToast(context, e);
    }
  }

  Future<void> _imageMenu() async {
    final k = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(LucideIcons.image), title: const Text('Change banner'), onTap: () => Navigator.pop(context, 'cover')),
        ListTile(leading: const Icon(LucideIcons.store), title: const Text('Change logo'), onTap: () => Navigator.pop(context, 'logo')),
      ])),
    );
    if (k != null) await _image(k);
  }

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Business Profile',
        subtitle: 'Your storefront on OneLocal',
        bottom: SfSave('Save Profile', busy: busy, onPressed: name.text.trim().length < 2 ? null : _save),
        children: [
          SfThumb(widget.profile.so('cover_url'), size: 150, width: double.infinity, radius: 18),
          const SizedBox(height: 10),
          Row(children: [
            SfThumb(widget.profile.so('logo_url'), size: 52, width: 84, radius: 12),
            const SizedBox(width: 10),
            Expanded(child: SfSoft('Edit Banner & Logo', onPressed: _imageMenu)),
          ]),
          const SfLabel('Business Name'),
          SfField(controller: name, hint: 'Business name', onChanged: (_) => setState(() {})),
          const SfLabel('About your business'),
          SfField(controller: about, maxLength: 200, lines: 3, hint: 'Tell customers what you sell'),
          const SfLabel('Business Category', top: 8),
          SfField(controller: category, hint: 'For example Snacks & Grocery'),
          const SfLabel('Store Address'),
          SfField(controller: address, hint: 'Store address'),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Phone Number'), SfField(controller: phone, hint: '+91 98765 43210')])),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Store Link'), SfField(controller: slug, hint: 'your-store')])),
          ]),
        ],
      );
}

List<String> _hhmm() => [for (var m = 0; m < 24 * 60; m += 30) '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}'];

/// Figma "Business Hours": show hours, Apply to all, seven days with an open switch and from / to.
class HoursScreen extends StatelessWidget {
  const HoursScreen({super.key, required this.api});
  final StorefrontApi api;
  @override
  Widget build(BuildContext context) => SfLoader<Facts>(load: api.settings, builder: (_, s, _) => _HoursForm(api: api, hours: s.m('hours')));
}

class _HoursForm extends StatefulWidget {
  const _HoursForm({required this.api, required this.hours});
  final StorefrontApi api;
  final Facts hours;
  @override
  State<_HoursForm> createState() => _HoursFormState();
}

class _HoursFormState extends State<_HoursForm> {
  late bool show = widget.hours.raw['show'] != false;
  late final List<Map<String, dynamic>> days = widget.hours.l('days').map((d) => Map<String, dynamic>.from(d.raw)).toList();
  bool busy = false;

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await widget.api.saveHours(show: show, days: [for (final d in days) {'day': d['day'], 'open': d['open'], 'opens': d['opens'], 'closes': d['closes']}]);
      if (mounted) { showToast(context, 'Hours saved.'); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  Widget _time(int i, String key) => Expanded(
        child: DropdownButtonFormField<String>(
          initialValue: '${days[i][key]}',
          isExpanded: true,
          icon: const Icon(LucideIcons.chevronDown, size: 16),
          items: [for (final t in _hhmm()) DropdownMenuItem(value: t, child: Text(clock12(t)))],
          onChanged: days[i]['open'] == true ? (v) => setState(() => days[i][key] = v) : null,
          decoration: InputDecoration(filled: true, fillColor: kSfField, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
        ),
      );

  @override
  Widget build(BuildContext context) => SfPage(
        title: 'Business Hours',
        bottom: SfSave('Save Hours', busy: busy, onPressed: _save),
        children: [
          SfToggle(title: 'Show business hours', sub: 'Let customers know when you\'re open.', value: show, onChanged: (v) => setState(() => show = v)),
          Row(children: [
            Expanded(child: Text('Opening Hours', style: inter(16, 700))),
            TextButton(onPressed: () => setState(() { for (final d in days) { d['open'] = days.first['open']; d['opens'] = days.first['opens']; d['closes'] = days.first['closes']; } }), child: Text('Apply to all', style: inter(14, 700))),
          ]),
          for (var i = 0; i < days.length; i++)
            SfCard(
              child: Column(children: [
                SfToggle(title: kWeekdays[(days[i]['day'] as int) - 1], value: days[i]['open'] == true, onChanged: (v) => setState(() => days[i]['open'] = v)),
                Row(children: [_time(i, 'opens'), Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('to', style: inter(14, 400, color: kMuted))), _time(i, 'closes')]),
              ]),
            ),
          SfNote('Your storefront will show: ${hoursSummary(days)}.'),
        ],
      );
}

/// Figma "Delivery Settings": home delivery and pickup, own or partner, radius, time estimate, fee, minimum order, free above, business hours.
class DeliveryScreen extends StatelessWidget {
  const DeliveryScreen({super.key, required this.api});
  final StorefrontApi api;
  @override
  Widget build(BuildContext context) => SfLoader<Facts>(load: api.settings, builder: (_, s, _) => _DeliveryForm(api: api, d: s.m('delivery'), hours: s.m('hours')));
}

class _DeliveryForm extends StatefulWidget {
  const _DeliveryForm({required this.api, required this.d, required this.hours});
  final StorefrontApi api;
  final Facts d, hours;
  @override
  State<_DeliveryForm> createState() => _DeliveryFormState();
}

class _DeliveryFormState extends State<_DeliveryForm> {
  static const radii = <num>[1, 2, 3, 5, 8, 10, 15, 20, 30];
  static const windows = <(int, int)>[(15, 30), (30, 45), (45, 60), (60, 90), (90, 120)];
  late bool home = widget.d.raw['home_delivery'] == true || !widget.d.b('configured');
  late bool pickup = widget.d.raw['pickup'] == true;
  late String method = widget.d.so('method') ?? 'own';
  late num radius = widget.d.no('radius_km') ?? 5;
  late (int, int) window = (widget.d.no('est_min_minutes')?.toInt() ?? 30, widget.d.no('est_max_minutes')?.toInt() ?? 45);
  late final fee = TextEditingController(text: rupeeText(widget.d.no('delivery_fee_minor')));
  late final minOrder = TextEditingController(text: rupeeText(widget.d.no('min_order_minor')));
  late final freeAbove = TextEditingController(text: rupeeText(widget.d.no('free_above_minor')));
  late bool useHours = widget.d.raw['use_business_hours'] != false;
  bool busy = false;

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await widget.api.saveDelivery({
        'pickup': pickup,
        'home_delivery': home,
        'method': method,
        if (home) ...{
          'radius_km': radius,
          'est_min_minutes': window.$1,
          'est_max_minutes': window.$2,
          'delivery_fee_minor': paise(fee.text),
          'min_order_minor': paise(minOrder.text),
          'free_above_minor': paise(freeAbove.text),
          'use_business_hours': useHours,
          if (!useHours) ...{'delivery_from': widget.d.so('delivery_from') ?? '09:00', 'delivery_to': widget.d.so('delivery_to') ?? '21:00'},
        },
      });
      if (mounted) { showToast(context, 'Delivery settings saved.'); Navigator.of(context).pop(); }
    } catch (e) {
      if (mounted) { setState(() => busy = false); sfToast(context, e); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = widget.hours.l('days').map((d) => d.raw).toList();
    final summary = days.isEmpty ? 'your opening hours' : hoursSummary(days);
    return SfPage(
      title: 'Delivery Settings',
      bottom: SfSave('Save Delivery Settings', busy: busy, onPressed: (home || pickup) ? _save : null),
      children: [
        const SfLabel('How customers get their order', top: 4),
        SfToggle(title: 'Home Delivery', sub: 'Deliver orders to your customers.', value: home, onChanged: (v) => setState(() => home = v)),
        SfToggle(title: 'Store Pickup', sub: 'Customers collect from your store.', value: pickup, onChanged: (v) => setState(() => pickup = v)),
        if (home) ...[
          const SfLabel('Delivery Method'),
          SfChoice<String>(options: const [('own', 'Own Delivery', null), ('partner', 'Delivery Partner', null)], value: method, onChanged: (v) => setState(() => method = v)),
          const SfLabel('Delivery Radius'),
          DropdownButtonFormField<num>(
            initialValue: radii.contains(radius) ? radius : null,
            isExpanded: true,
            items: [for (final r in radii) DropdownMenuItem(value: r, child: Text('$r km'))],
            onChanged: (v) => setState(() => radius = v ?? radius),
            decoration: _fieldDeco,
          ),
          const SfLabel('Estimated Delivery Time'),
          DropdownButtonFormField<(int, int)>(
            initialValue: windows.contains(window) ? window : null,
            isExpanded: true,
            items: [for (final w in windows) DropdownMenuItem(value: w, child: Text('${w.$1}–${w.$2} minutes'))],
            onChanged: (v) => setState(() => window = v ?? window),
            decoration: _fieldDeco,
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Delivery Fee'), SfField(controller: fee, number: true, prefix: '₹')])),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SfLabel('Minimum Order'), SfField(controller: minOrder, number: true, prefix: '₹')])),
          ]),
          const SfLabel('Free Delivery Above', top: 8),
          SfField(controller: freeAbove, number: true, prefix: '₹'),
          SfToggle(title: 'Use business hours', sub: 'Accept deliveries $summary.', value: useHours, onChanged: (v) => setState(() => useHours = v)),
          const SfNote('Customers see the delivery fee and estimated time before placing an order.'),
        ],
      ],
    );
  }
}

final _fieldDeco = InputDecoration(
  filled: true,
  fillColor: const Color(0xFFFAFBF8),
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kLine)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
);
