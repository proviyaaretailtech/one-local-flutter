import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../ui/theme.dart';
import 'outlet_header.dart' show kOutletOnline, kOutletSquare;
import 'outlets_api.dart';

/// Reads the phone's position for the map pin. Tests replace it.
typedef Locate = Future<(double, double)> Function();

Future<(double, double)> _gps() async {
  var p = await Geolocator.checkPermission();
  if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
  if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw const PartnerApiException(0, 'Allow location to place the pin.');
  final pos = await Geolocator.getCurrentPosition();
  return (pos.latitude, pos.longitude);
}

const _days = [('mon', 'Mon'), ('tue', 'Tue'), ('wed', 'Wed'), ('thu', 'Thu'), ('fri', 'Fri'), ('sat', 'Sat'), ('sun', 'Sun')];

/// "Add another restaurant/store": a short form that creates the outlet as pending and puts it in One Local's verification queue.
/// It opens for orders only after One Local approves it. The server checks every field again; this screen only helps the person.
class AddOutletScreen extends StatefulWidget {
  const AddOutletScreen({super.key, required this.api, required this.needsFssai, this.locate});
  final OutletsApi api;
  final bool needsFssai;
  final Locate? locate;

  @override
  State<AddOutletScreen> createState() => _AddOutletScreenState();
}

class _AddOutletScreenState extends State<AddOutletScreen> {
  // One key per form: sending the same form again (a retry) cannot create two outlets.
  final String _key = 'outlet-${List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  final _name = TextEditingController(), _line = TextEditingController(), _locality = TextEditingController(), _city = TextEditingController();
  final _pin = TextEditingController(), _lat = TextEditingController(), _lng = TextEditingController();
  final _opens = TextEditingController(text: '09:00'), _closes = TextEditingController(text: '23:00');
  final _gstin = TextEditingController(), _fssai = TextEditingController();
  final Set<String> _open = {for (final d in _days) d.$1};
  bool _saving = false, _locating = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _line, _locality, _city, _pin, _lat, _lng, _opens, _closes, _gstin, _fssai]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pinHere() async {
    setState(() => _locating = true);
    try {
      final (lat, lng) = await (widget.locate ?? _gps)();
      _lat.text = lat.toStringAsFixed(6);
      _lng.text = lng.toStringAsFixed(6);
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not read your location. Type the latitude and longitude instead.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  String? _check() {
    final hhmm = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');
    if (_name.text.trim().length < 2) return 'Enter the outlet name.';
    if (_line.text.trim().length < 5) return 'Enter the full address.';
    if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(_pin.text.trim())) return 'The PIN code must be 6 digits.';
    final lat = double.tryParse(_lat.text.trim()), lng = double.tryParse(_lng.text.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return 'Place the map pin on the outlet.';
    if (!hhmm.hasMatch(_opens.text.trim()) || !hhmm.hasMatch(_closes.text.trim())) return 'Opening hours must be HH:MM, for example 09:00.';
    if (_open.isEmpty) return 'Choose at least one day.';
    if (widget.needsFssai && !RegExp(r'^[0-9]{14}$').hasMatch(_fssai.text.trim())) return 'Enter the 14-digit FSSAI licence number.';
    if (_fssai.text.trim().isNotEmpty && !RegExp(r'^[0-9]{14}$').hasMatch(_fssai.text.trim())) return 'The FSSAI licence number must be 14 digits.';
    return null;
  }

  Future<void> _submit() async {
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => (_saving = true, _error = null));
    try {
      final o = await widget.api.add({
        'name': _name.text.trim(),
        'address_line': _line.text.trim(),
        'locality': _locality.text.trim(),
        'city': _city.text.trim(),
        'pin_code': _pin.text.trim(),
        'lat': double.parse(_lat.text.trim()),
        'lng': double.parse(_lng.text.trim()),
        'hours': {'opens': _opens.text.trim(), 'closes': _closes.text.trim(), 'days': [for (final d in _days) if (_open.contains(d.$1)) d.$1]},
        if (_gstin.text.trim().isNotEmpty) 'gstin': _gstin.text.trim().toUpperCase(),
        if (_fssai.text.trim().isNotEmpty) 'fssai': _fssai.text.trim(),
      }, key: _key);
      if (mounted) Navigator.of(context).pop(o);
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send the outlet. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String label, TextEditingController c, {String? hint, TextInputType? type, String? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: ValueKey(key ?? 'outlet-$label'),
          controller: c,
          keyboardType: type,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            filled: true,
            fillColor: Colors.white,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              Semantics(
                button: true,
                label: 'Back',
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kOutletSquare, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(LucideIcons.arrowLeft, size: 20, color: kInk),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Add restaurant/store', style: inter(20, 700))),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
              Text('One Local checks every new outlet before it can take orders. You will see it as “Pending verification” until then.',
                  style: inter(13, 400, color: kMuted)),
              const SizedBox(height: 16),
              _field('Outlet name', _name, key: 'outlet-name'),
              _field('Address', _line, hint: 'Shop no., street', key: 'outlet-address'),
              Row(children: [
                Expanded(child: _field('Locality', _locality, key: 'outlet-locality')),
                const SizedBox(width: 10),
                Expanded(child: _field('City', _city, key: 'outlet-city')),
              ]),
              _field('PIN code', _pin, type: TextInputType.number, key: 'outlet-pin'),
              Text('Map pin', style: inter(14, 600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _field('Latitude', _lat, type: const TextInputType.numberWithOptions(decimal: true, signed: true), key: 'outlet-lat')),
                const SizedBox(width: 10),
                Expanded(child: _field('Longitude', _lng, type: const TextInputType.numberWithOptions(decimal: true, signed: true), key: 'outlet-lng')),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('outlet-pin-here'),
                  onPressed: _locating ? null : _pinHere,
                  icon: const Icon(LucideIcons.mapPin, size: 16, color: kOutletOnline),
                  label: Text(_locating ? 'Finding you…' : 'I am at the outlet: use my location', style: inter(13, 600, color: kOutletOnline)),
                ),
              ),
              const SizedBox(height: 8),
              Text('Opening hours', style: inter(14, 600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _field('Opens', _opens, hint: '09:00', key: 'outlet-opens')),
                const SizedBox(width: 10),
                Expanded(child: _field('Closes', _closes, hint: '23:00', key: 'outlet-closes')),
              ]),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final d in _days)
                  FilterChip(
                    key: ValueKey('outlet-day-${d.$1}'),
                    label: Text(d.$2),
                    selected: _open.contains(d.$1),
                    onSelected: (v) => setState(() => v ? _open.add(d.$1) : _open.remove(d.$1)),
                  ),
              ]),
              const SizedBox(height: 16),
              _field('GSTIN (optional)', _gstin, key: 'outlet-gstin'),
              _field(widget.needsFssai ? 'FSSAI licence number' : 'FSSAI licence number (optional)', _fssai, type: TextInputType.number, key: 'outlet-fssai'),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, key: const ValueKey('outlet-error'), style: inter(13.5, 500, color: kError))),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('outlet-submit'),
                  style: FilledButton.styleFrom(backgroundColor: kCheck, foregroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _saving ? null : _submit,
                  child: Text(_saving ? 'Sending…' : 'Send for verification', style: inter(16, 700)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
