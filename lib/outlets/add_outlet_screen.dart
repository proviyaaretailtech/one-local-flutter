import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'outlet_header.dart' show kOutletOnline;
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
const _stepTitles = {
  'state': 'Where is the new outlet?',
  'details': 'Outlet details',
  'tax': 'Tax and licence',
  'contact': 'Who runs this outlet?',
  'review': 'Check and send',
};

/// "Add another restaurant/store" (founder, 20 Oct 2026): a stepped form saved as a draft at every step, so "Save and continue later"
/// brings the owner back to the same step. Step 1 asks the state: the business's own state reuses its GSTIN; another state needs the
/// outlet's own GSTIN and a contact who becomes the outlet's admin. Sending creates the outlet as pending until One Local approves it.
/// Every rule is checked again by the server (migration 0523); this screen only guides.
class AddOutletScreen extends StatefulWidget {
  const AddOutletScreen({super.key, required this.api, required this.needsFssai, this.locate, this.draftId});
  final OutletsApi api;
  final bool needsFssai;
  final Locate? locate;

  /// The draft to continue; without it the newest open draft is continued, or a new one starts.
  final String? draftId;

  @override
  State<AddOutletScreen> createState() => _AddOutletScreenState();
}

class _AddOutletScreenState extends State<AddOutletScreen> {
  // One key per new draft: sending the first step again (a retry) cannot create two drafts.
  final String _key = 'outlet-${List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  final _name = TextEditingController(), _line = TextEditingController(), _locality = TextEditingController(), _city = TextEditingController();
  final _pin = TextEditingController(), _lat = TextEditingController(), _lng = TextEditingController();
  final _opens = TextEditingController(text: '09:00'), _closes = TextEditingController(text: '23:00');
  final _gstin = TextEditingController(), _fssai = TextEditingController();
  final _cName = TextEditingController(), _cMobile = TextEditingController(), _cEmail = TextEditingController();
  final Set<String> _open = {for (final d in _days) d.$1};

  DraftStart? _start;
  OutletDraft? _draft;
  String? _state;
  String _step = 'state';
  bool _busy = false, _locating = false;
  String? _error;

  List<TextEditingController> get _all => [_name, _line, _locality, _city, _pin, _lat, _lng, _opens, _closes, _gstin, _fssai, _cName, _cMobile, _cEmail];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _needsFssai => _start?.needsFssai ?? widget.needsFssai;
  String? get _home => _start?.homeStateCode;
  bool get _inter => _home != null && _state != null && _state != _home;
  List<String> get _steps => ['state', 'details', 'tax', if (_inter) 'contact', 'review'];

  Future<void> _load() async {
    try {
      final s = await widget.api.draftGet(id: widget.draftId);
      if (!mounted) return;
      setState(() {
        _start = s;
        _error = null;
        final d = s.draft;
        if (d != null) _fill(d);
      });
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the form. Check your connection and try again.');
    }
  }

  void _fill(OutletDraft d) {
    _draft = d;
    _state = d.stateCode.isEmpty ? null : d.stateCode;
    _step = d.step;
    void put(TextEditingController c, String v) => c.text = v;
    for (final (c, k) in [(_name, 'name'), (_line, 'address_line'), (_locality, 'locality'), (_city, 'city'), (_pin, 'pin_code'), (_gstin, 'gstin'), (_fssai, 'fssai'),
      (_cName, 'contact_name'), (_cMobile, 'contact_mobile'), (_cEmail, 'contact_email')]) {
      put(c, d.raw[k] == null ? '' : d.s(k));
    }
    if (d.d('lat') != null) _lat.text = d.d('lat')!.toStringAsFixed(6);
    if (d.d('lng') != null) _lng.text = d.d('lng')!.toStringAsFixed(6);
    final h = d.hours;
    if (h['opens'] != null) _opens.text = '${h['opens']}';
    if (h['closes'] != null) _closes.text = '${h['closes']}';
    if (h['days'] is List) {
      _open
        ..clear()
        ..addAll((h['days'] as List).map((e) => '$e'));
    }
  }

  /// The fields of one step, as the server takes them ("" clears).
  Map<String, dynamic> _fields(String step) => switch (step) {
        'state' => {'state_code': _state ?? ''},
        'details' => {
            'name': _name.text.trim(),
            'address_line': _line.text.trim(),
            'locality': _locality.text.trim(),
            'city': _city.text.trim(),
            'pin_code': _pin.text.trim(),
            if (double.tryParse(_lat.text.trim()) != null && double.tryParse(_lng.text.trim()) != null) ...{
              'lat': double.parse(_lat.text.trim()),
              'lng': double.parse(_lng.text.trim()),
            },
            'hours': {'opens': _opens.text.trim(), 'closes': _closes.text.trim(), 'days': [for (final d in _days) if (_open.contains(d.$1)) d.$1]},
          },
        'tax' => {if (_inter) 'gstin': _gstin.text.trim().toUpperCase(), 'fssai': _fssai.text.trim()},
        'contact' => {'contact_name': _cName.text.trim(), 'contact_mobile': _cMobile.text.trim(), 'contact_email': _cEmail.text.trim()},
        _ => const {},
      };

  /// A friendly first check of the step; the server checks again.
  String? _check(String step) {
    final hhmm = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');
    switch (step) {
      case 'state':
        if (_state == null) return 'Choose the state the outlet is in.';
      case 'details':
        if (_name.text.trim().length < 2) return 'Enter the outlet name.';
        if (_line.text.trim().length < 5) return 'Enter the full address.';
        if (_locality.text.trim().isEmpty) return 'Enter the locality.';
        if (!RegExp(r'^[1-9][0-9]{5}$').hasMatch(_pin.text.trim())) return 'The PIN code must be 6 digits.';
        final lat = double.tryParse(_lat.text.trim()), lng = double.tryParse(_lng.text.trim());
        if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return 'Place the map pin on the outlet.';
        if (!hhmm.hasMatch(_opens.text.trim()) || !hhmm.hasMatch(_closes.text.trim())) return 'Opening hours must be HH:MM, for example 09:00.';
        if (_open.isEmpty) return 'Choose at least one day.';
      case 'tax':
        if (_inter && !RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$').hasMatch(_gstin.text.trim().toUpperCase())) {
          return 'Enter this outlet\'s GSTIN.';
        }
        if (_inter && !_gstin.text.trim().startsWith(_state!)) return 'A GSTIN for this state starts with $_state.';
        if (_needsFssai && !RegExp(r'^[0-9]{14}$').hasMatch(_fssai.text.trim())) return 'Enter the 14-digit FSSAI licence number.';
        if (_fssai.text.trim().isNotEmpty && !RegExp(r'^[0-9]{14}$').hasMatch(_fssai.text.trim())) return 'The FSSAI licence number must be 14 digits.';
      case 'contact':
        if (_cName.text.trim().length < 2) return 'Enter the contact\'s full name.';
        final digits = _cMobile.text.replaceAll(RegExp(r'[^0-9]'), '');
        if (!RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits.length > 10 ? digits.substring(digits.length - 10) : digits)) return 'Enter a valid 10-digit mobile number.';
        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_cEmail.text.trim())) return 'Enter the contact\'s email: the invitation is sent there.';
    }
    return null;
  }

  /// Saves this step and moves to [to] (the step the owner comes back to). [leave] closes the form afterwards.
  Future<void> _save({required String to, bool leave = false, bool checkFirst = true}) async {
    final problem = checkFirst ? _check(_step) : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => (_busy = true, _error = null));
    try {
      final d = await widget.api.draftSave({..._fields(_step), 'step': to}, id: _draft?.id, key: _key);
      if (!mounted) return;
      if (leave) {
        showToast(context, 'Saved. You can continue from “${outletNounTitle()} status”.');
        Navigator.of(context).pop();
        return;
      }
      setState(() => (_draft = d, _step = to));
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    final i = _steps.indexOf(_step);
    await _save(to: _steps[min(i + 1, _steps.length - 1)]);
  }

  void _back() {
    final i = _steps.indexOf(_step);
    if (i <= 0) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => (_step = _steps[i - 1], _error = null));
    }
  }

  Future<void> _send() async {
    final id = _draft?.id;
    if (id == null) return;
    setState(() => (_busy = true, _error = null));
    try {
      final o = await widget.api.draftSubmit(id);
      if (mounted) Navigator.of(context).pop(o);
    } on PartnerApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send the outlet. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startOver() async {
    final id = _draft?.id;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.draftDiscard(id);
      if (!mounted) return;
      setState(() {
        _draft = null;
        _state = null;
        _step = 'state';
        for (final c in _all) {
          c.clear();
        }
        _opens.text = '09:00';
        _closes.text = '23:00';
        _open
          ..clear()
          ..addAll(_days.map((d) => d.$1));
      });
    } on PartnerApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Widget _field(String label, TextEditingController c, {String? hint, TextInputType? type, required String key}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          key: ValueKey(key),
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

  Widget _note(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: inter(13, 500, color: const Color(0xFF166534))),
      );

  List<Widget> _body() {
    final s = _start!;
    switch (_step) {
      case 'state':
        return [
          if (s.homeStateName != null) Text('Your business GSTIN is registered in ${s.homeStateName}.', style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: const ValueKey('outlet-state'),
            initialValue: _state,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'State',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            items: [for (final (code, name) in s.states) DropdownMenuItem(value: code, child: Text(name))],
            onChanged: (v) => setState(() => _state = v),
          ),
          const SizedBox(height: 14),
          if (_state != null)
            _note(_inter
                ? 'Another state: this outlet needs its own GSTIN (starting $_state), its own locality and address, and a contact who will be its admin.'
                : s.homeStateName == null
                    ? 'Your business has no GSTIN on file, so the outlet\'s own GSTIN is optional.'
                    : 'Same state: your business GSTIN is used for this outlet. Only the outlet\'s details are needed.'),
        ];
      case 'details':
        return [
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
        ];
      case 'tax':
        return [
          if (_inter)
            _field('GSTIN of this outlet', _gstin, hint: 'Starts with $_state', key: 'outlet-gstin')
          else
            _note(s.homeStateName == null ? 'No business GSTIN on file.' : 'GSTIN: your business GSTIN (${s.homeStateName}) is used.'),
          _field(_needsFssai ? 'FSSAI licence number' : 'FSSAI licence number (optional)', _fssai, type: TextInputType.number, key: 'outlet-fssai'),
        ];
      case 'contact':
        return [
          _note('This person will be the admin of this outlet only, after One Local approves it. They get an invitation to sign in.'),
          _field('Full name', _cName, key: 'outlet-contact-name'),
          _field('Mobile number', _cMobile, type: TextInputType.phone, key: 'outlet-contact-mobile'),
          _field('Email (the invitation is sent here)', _cEmail, type: TextInputType.emailAddress, key: 'outlet-contact-email'),
        ];
      default:
        final d = _draft;
        String v(String k) => d == null || d.raw[k] == null ? '—' : d.s(k);
        return [
          _row('State', d?.stateName ?? '—'),
          _row('Outlet', v('name')),
          _row('Address', [v('address_line'), v('locality'), v('city'), v('pin_code')].where((e) => e != '—').join(', ')),
          _row('GSTIN', _inter ? v('gstin') : (s.homeStateName == null ? '—' : 'Business GSTIN')),
          _row('FSSAI', v('fssai')),
          if (_inter) _row('Outlet admin', '${v('contact_name')} · ${v('contact_mobile')} · ${v('contact_email')}'),
          if (d != null && d.missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Still missing: ${d.missing.map((m) => m.replaceAll('_', ' ')).join(', ')}', key: const ValueKey('outlet-missing'), style: inter(13, 500, color: kError)),
            ),
        ];
    }
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: inter(13, 500, color: kMuted))),
          Expanded(child: Text(v, style: inter(14, 600))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = _start;
    final i = _steps.indexOf(_step);
    final last = _step == 'review';
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          AppHeader(
            title: 'Add ${outletNoun()}',
            safeTop: false,
            back: true,
            backKey: const ValueKey('outlet-form-back'),
            onBack: () {
              if (!_busy) _back();
            },
            under: Row(children: [
              Expanded(
                child: s == null
                    ? const SizedBox.shrink()
                    : Text('Step ${i + 1} of ${_steps.length} · ${_stepTitles[_step]}', key: const ValueKey('outlet-step'), style: inter(12.5, 500, color: kMuted)),
              ),
              if (_draft != null)
                TextButton(key: const ValueKey('outlet-start-over'), onPressed: _busy ? null : _startOver, child: Text('Start over', style: inter(13, 600, color: kMuted))),
            ]),
          ),
          Expanded(
            child: s == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kError)),
                              const SizedBox(height: 10),
                              OutlinedButton(onPressed: _load, child: const Text('Try again')),
                            ]),
                          ))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
                    Text(_stepTitles[_step]!, style: inter(17, 700)),
                    const SizedBox(height: 12),
                    ..._body(),
                    if (_error != null)
                      Padding(padding: const EdgeInsets.only(top: 4, bottom: 12), child: Text(_error!, key: const ValueKey('outlet-error'), style: inter(13.5, 500, color: kError))),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        key: const ValueKey('outlet-submit'),
                        style: FilledButton.styleFrom(backgroundColor: kCheck, foregroundColor: kInk, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        onPressed: _busy ? null : (last ? _send : _next),
                        child: Text(_busy ? 'Saving…' : last ? 'Send for verification' : 'Next', style: inter(16, 700)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        key: const ValueKey('outlet-save-later'),
                        style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        onPressed: _busy ? null : () => _save(to: _step, leave: true, checkFirst: false),
                        child: Text('Save and continue later', style: inter(15, 600)),
                      ),
                    ),
                  ]),
          ),
        ]),
      ),
    );
  }
}
