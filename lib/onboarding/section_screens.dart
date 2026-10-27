import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'document_picker.dart';
import 'onboarding_api.dart';
import 'india_cities.dart';
import 'pan_scan.dart';
import 'pin_codes.dart';
import 'onboarding_draft.dart';
import 'onboarding_widgets.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Section 3: address. Figma "Address".
// The map is the illustrative picture the design draws; no map provider or location permission exists yet, so the pin is
// not set and the server stores the address without coordinates.
// ---------------------------------------------------------------------------------------------------------------------
class AddressScreen extends StatefulWidget {
  const AddressScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends State<AddressScreen> {
  late final _line = TextEditingController(text: widget.app.address['address_line'] as String? ?? '');
  late final _area = TextEditingController(text: widget.app.address['locality'] as String? ?? '');
  late final _city = TextEditingController(text: widget.app.address['city'] as String? ?? '');

  /// The city is typed because it is not in the state's list.
  late bool _otherCity = _city.text.isNotEmpty && !citiesOf(widget.app.address['state'] as String?).contains(_city.text);
  late final _pin = TextEditingController(text: widget.app.address['pin_code'] as String? ?? '');
  late String? _state = widget.app.address['state'] as String?;
  late bool _confirmed = widget.app.address['confirmed'] == true;
  late final Future<Taxonomy> _tax = widget.api.taxonomy();
  bool _saving = false;
  final _draft = OnbDraft('address');

  // what was typed before the app closed, where the server has nothing yet
  @override
  void initState() {
    super.initState();
    _draft.load().then((d) {
      if (!mounted || d.isEmpty) return;
      setState(() {
        for (final (c, k) in [(_line, 'line'), (_area, 'area'), (_city, 'city'), (_pin, 'pin')]) {
          if (c.text.isEmpty) c.text = d[k] ?? '';
        }
        _state ??= d['state'];
        _otherCity = _city.text.isNotEmpty && !citiesOf(_state).contains(_city.text);
      });
    });
  }

  void _keep() => _draft.keep({'line': _line.text, 'area': _area.text, 'city': _city.text, 'pin': _pin.text, 'state': _state});

  @override
  void dispose() {
    _draft.dispose();
    for (final c in [_line, _area, _city, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_line.text.trim().length < 3) return showToast(context, 'Enter your address line.');
    if (_area.text.trim().length < 2) return showToast(context, 'Enter your area or locality.');
    if (_state == null) return showToast(context, 'Choose your state.');
    if (_city.text.trim().length < 2) return showToast(context, _otherCity ? 'Enter your city.' : 'Choose your city.');
    if (!pinLooksValid(_pin.text)) return showToast(context, 'PIN code must be 6 digits.');
    if (!pinFitsState(_pin.text, _state)) return showToast(context, 'This PIN code is not in $_state. Check the PIN code or the state.');
    if (!_confirmed) return showToast(context, 'Confirm that the address identifies your business.');
    setState(() => _saving = true);
    final saved = await guarded(
      context,
      () => widget.api.saveAddress({
        'address_line': _line.text.trim(),
        'locality': _area.text.trim(),
        'city': _city.text.trim(),
        'state': _state,
        'pin_code': _pin.text,
        'confirmed': true,
      }),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) return;
    await _draft.clear();
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    _keep(); // every change rebuilds the screen: keep what is typed (a moment later, not on every key)
    return OnbPage(
      kicker: 'Business setup',
      title: 'Locate your business.',
      caption: 'Section 3 of 7',
      subtitle: 'Confirm your business address and map pin. You can always enter the address manually.',
      children: [
        Container(
          height: 160,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFFE8ECDA), borderRadius: BorderRadius.circular(16)),
          child: Stack(children: [
            Align(
              alignment: Alignment.center,
              child: Container(width: 44, height: 44, decoration: const BoxDecoration(color: kPrimary, shape: BoxShape.circle), child: const Icon(Icons.location_on_outlined, color: kCheck, size: 24)),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Text([_area.text, _city.text].where((s) => s.trim().isNotEmpty).join(' · '), style: inter(13, 600)),
            ),
            Align(alignment: Alignment.bottomRight, child: Text('Illustrative map', style: inter(11, 400, color: kMuted))),
          ]),
        ),
        LabeledField(label: 'Address line', controller: _line, labelSize: 13, labelWeight: 500, onChanged: (_) => setState(() {})),
        LabeledField(label: 'Area / locality', controller: _area, labelSize: 13, labelWeight: 500, onChanged: (_) => setState(() {})),
        // the state first, then its cities (founder, 27 Oct 2026)
        FutureBuilder<Taxonomy>(
          future: _tax,
          builder: (_, s) => SelectField(
            key: const ValueKey('address-state'),
            label: 'State',
            value: _state,
            options: s.data?.states ?? const [],
            hint: s.hasError ? 'Could not load states' : 'Choose',
            onChanged: (v) => setState(() {
              if (v != _state && !_otherCity) _city.clear(); // a city of the old state
              _state = v;
            }),
          ),
        ),
        SelectField(
          key: const ValueKey('address-city'),
          label: 'City',
          value: _otherCity ? kOtherCity : (_city.text.isEmpty ? null : _city.text),
          options: _state == null ? const [] : citiesOf(_state),
          hint: _state == null ? 'Choose your state first' : 'Choose',
          onChanged: (v) => setState(() {
            _otherCity = v == kOtherCity;
            _city.text = _otherCity ? '' : v;
          }),
        ),
        if (_otherCity) LabeledField(label: 'Your city or town', controller: _city, labelSize: 13, labelWeight: 500, onChanged: (_) => setState(() {})),
        LabeledField(
          label: 'PIN code',
          controller: _pin,
          keyboardType: TextInputType.number,
          labelSize: 13,
          labelWeight: 500,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
        ),
        // checked as it is typed: 6 digits, and in the chosen state
        if (_pin.text.length == 6 && (!pinLooksValid(_pin.text) || !pinFitsState(_pin.text, _state)))
          Text(
            !pinLooksValid(_pin.text) ? 'A PIN code does not start with 0.' : 'This PIN code is not in $_state.',
            key: const ValueKey('pin-error'),
            style: inter(13, 500, color: const Color(0xFFC62828)),
          ),
        CheckRow(value: _confirmed, onChanged: (v) => setState(() => _confirmed = v), text: 'The address and map pin identify my business location.'),
      ],
      actions: [PrimaryAction(label: _saving ? 'Saving…' : 'Confirm address', onPressed: _saving ? null : _save)],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Section 4: tax. Figma "Tax Details". PAN is encrypted on the server; only the masked form comes back, so it is typed
// again whenever the section is saved again.
// ---------------------------------------------------------------------------------------------------------------------
class TaxScreen extends StatefulWidget {
  const TaxScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<TaxScreen> createState() => _TaxScreenState();
}

class _TaxScreenState extends State<TaxScreen> {
  final _pan = TextEditingController();
  final _gstin = TextEditingController();
  late bool? _gst = widget.app.tax['gst_registered'] as bool?;
  bool _saving = false;
  final _draft = OnbDraft('tax');

  @override
  void initState() {
    super.initState();
    _draft.load().then((d) {
      if (!mounted || d.isEmpty) return;
      setState(() {
        _gst ??= d['gst'] == null ? null : d['gst'] == 'true';
        if (_gstin.text.isEmpty) _gstin.text = d['gstin'] ?? '';
      });
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    _pan.dispose();
    _gstin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final pan = _pan.text.trim().toUpperCase();
    final keepSaved = pan.isEmpty && widget.app.tax['pan_masked'] != null;
    if (!keepSaved && !RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$').hasMatch(pan)) return showToast(context, 'PAN looks wrong. It has 5 letters, 4 digits and 1 letter.');
    if (_gst == null) return showToast(context, 'Tell us whether your business is GST-registered.');
    if (_gst == true && _gstin.text.trim().length != 15) return showToast(context, 'Enter your 15-character GSTIN.');
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.saveTax({'pan': pan, 'gst_registered': _gst, if (_gst == true) 'gstin': _gstin.text.trim().toUpperCase()}));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) return;
    await _draft.clear();
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    _draft.keep({'gst': _gst?.toString(), 'gstin': _gstin.text}); // never the PAN
    final masked = widget.app.tax['pan_masked'] as String?;
    final gstMasked = widget.app.tax['gstin_masked'] as String?;
    final upper = TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase()));
    return OnbPage(
      kicker: 'Business setup',
      title: 'Tax information.',
      caption: 'Section 4 of 7',
      subtitle: 'Share the tax details that apply to your business in India.',
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(label: 'PAN', controller: _pan, labelWeight: 500, maxLength: 10, hint: masked ?? 'ABCDE1234F', inputFormatters: [upper, FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))]),
          const SizedBox(height: 8),
          Text(masked == null ? 'Use the PAN associated with this business or proprietor, as applicable.' : 'Saved as $masked. Leave this blank to keep it, or type a new one.', style: inter(13, 400, color: kMuted, height: 1.5)),
        ]),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Is your business GST-registered?', style: inter(17, 600)),
          const SizedBox(height: 14),
          ChoiceCard(icon: Icons.task_outlined, title: 'GST registered', body: 'Add the registration details for this business.', selected: _gst == true, onTap: () => setState(() => _gst = true)),
          const SizedBox(height: 12),
          ChoiceCard(icon: Icons.insert_drive_file_outlined, title: 'Not registered / not applicable', body: 'Continue with the details relevant to you.', selected: _gst == false, onTap: () => setState(() => _gst = false)),
        ]),
        if (_gst == true)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(label: 'GSTIN', controller: _gstin, labelWeight: 500, maxLength: 15, hint: gstMasked ?? '29ABCDE1234F1Z5', inputFormatters: [upper, FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))]),
            const SizedBox(height: 8),
            Text('Shown because GST registered is selected.', style: inter(13, 400, color: kMuted)),
          ]),
        const NoteCard(title: 'Only applicable information', body: 'GST registration is not assumed for every merchant. Review your own tax situation; this screen is not tax advice.'),
      ],
      actions: [
        PrimaryAction(label: _saving ? 'Saving…' : 'Save & continue', onPressed: _saving ? null : _save),
        const SizedBox(height: 12),
        const FooterNote('Tax applicability depends on your business circumstances.'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Section 5a: identity. Figma "KYC / KYB". Records consent and the optional Aadhaar last four, then opens the documents.
// ---------------------------------------------------------------------------------------------------------------------
class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key, required this.api, required this.app, this.picker = const DevicePicker()});
  final OnboardingApi api;
  final Application app;
  final DocumentPicker picker;
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  late Application _app = widget.app;
  late final _last4 = TextEditingController(text: _app.identity['aadhaar_last4'] as String? ?? '');
  late bool _consent = _app.identity['consent'] == true;
  late String? _structure = _app.app['business_structure'] as String?;
  bool _saving = false;

  static const _structures = ['Sole proprietorship', 'Partnership', 'LLP', 'Private limited company', 'Other'];

  @override
  void dispose() {
    _last4.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_saving) return;
    if (!_consent) return showToast(context, 'Please consent to the use of your details for verification.');
    final l4 = _last4.text.trim();
    if (l4.isNotEmpty && !RegExp(r'^[0-9]{4}$').hasMatch(l4)) return showToast(context, 'Enter only the last 4 digits of your Aadhaar. Never share the full number.');
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.saveIdentity({'consent': true, if (l4.isNotEmpty) 'aadhaar_last4': l4, if (_structure != null) 'business_structure': _structure}));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) return;
    _app = saved;
    final after = await Navigator.of(context).push<Application>(MaterialPageRoute(builder: (_) => DocumentsScreen(api: widget.api, app: saved, picker: widget.picker)));
    if (mounted) Navigator.of(context).pop(after ?? saved);
  }

  @override
  Widget build(BuildContext context) {
    final pan = _app.identity['pan_masked'] as String?;
    final proof = _app.document('business_proof');
    return OnbPage(
      kicker: 'Business setup',
      title: 'Verify who’s behind your business.',
      caption: 'Section 5 of 7 · Identity',
      subtitle: 'Individual identity and business verification are separate checks. Provide only what applies to your profile.',
      children: [
        Text('KYC · Individual identity', style: inter(17, 600)),
        SectionCard(
          title: _app.ownerName,
          lines: ['Proprietor · Primary account owner', 'PAN: ${pan ?? 'not added yet'}', 'Aadhaar context: ${_last4.text.length == 4 ? '•••• •••• ${_last4.text}' : 'optional'}'],
          chip: StatusChip(pan == null ? 'Add PAN in tax details' : 'Details saved', pan == null ? Tone.warn : Tone.neutral),
        ),
        LabeledField(label: 'Aadhaar last 4 digits (optional)', controller: _last4, keyboardType: TextInputType.number, maxLength: 4, labelWeight: 500, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: (_) => setState(() {})),
        Text('KYB · Business identity', style: inter(17, 600)),
        SectionCard(
          title: _app.businessName,
          action: 'Add proof',
          onAction: _next,
          lines: [
            '${_structure ?? 'Business type not chosen'} · ${_app.partnerType == 'restaurant' ? ((_app.app['subcategories'] as List?) ?? const []).join(', ') : (_app.app['subcategories'] as List?)?.firstOrNull ?? _app.app['category'] ?? ''}',
            proof == null ? 'Business proof: not yet uploaded' : 'Business proof: ${proof['file_name']}',
            'Shop Act or other applicable business proof',
          ],
          chip: StatusChip(proof == null ? 'Document needed' : 'Uploaded', proof == null ? Tone.warn : Tone.neutral),
        ),
        SelectField(label: 'Business type', value: _structure, options: _structures, onChanged: (v) => setState(() => _structure = v)),
        const NoteCard(title: 'Requirements vary by profile', body: 'Food License details are relevant only to applicable food activities. We’ll show the document options for your category.'),
        CheckRow(value: _consent, onChanged: (v) => setState(() => _consent = v), text: 'I consent to use of the details and documents I provide for identity and business verification.', sub: 'Review how verification information is handled in the privacy notice.'),
      ],
      actions: [
        PrimaryAction(label: _saving ? 'Saving…' : 'Continue to documents', onPressed: _saving ? null : _next),
        const SizedBox(height: 12),
        const FooterNote('Never share an OTP or full Aadhaar number in support messages.'),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Section 5b: documents. Figma "Document Upload". PDF, JPG or PNG up to 5 MB.
// ---------------------------------------------------------------------------------------------------------------------
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.api, required this.app, this.picker = const DevicePicker(), this.scanner = const MlKitPanScanner()});
  final OnboardingApi api;
  final Application app;
  final DocumentPicker picker;
  final PanScanner scanner;
  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late Application _app = widget.app;
  String? _busy;

  static const _max = 5 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    // nothing added yet: say what to keep ready before starting (founder, 27 Oct 2026)
    if (_app.documents.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? showDocumentsNeeded(context, _app) : null);
  }

  Future<void> _upload(String kind, [PickedDocument? given]) async {
    if (_busy != null) return;
    final f = given ?? await widget.picker.pick();
    if (f == null || !mounted) return;
    if (f.bytes.isEmpty) return showToast(context, 'That file is empty.');
    if (f.bytes.length > _max) return showToast(context, 'Each file can be up to 5 MB.');
    setState(() => _busy = kind);
    final saved = await guarded(context, () => widget.api.uploadDocument(kind: kind, bytes: f.bytes, fileName: f.name, contentType: f.contentType));
    if (!mounted) return;
    setState(() {
      _busy = null;
      if (saved != null) _app = saved;
    });
  }

  /// The camera with the built-in document scanner: it finds the card's edges and straightens it, then the text is read to make
  /// sure it is a PAN card (and the same PAN as in tax details).
  Future<void> _scanPan() async {
    if (_busy != null) return;
    final s = await widget.scanner.scan(context);
    if (s == null || !mounted) return;
    final masked = _app.tax['pan_masked'] as String? ?? _app.identity['pan_masked'] as String?;
    final tail = masked == null ? null : masked.replaceAll('•', '');
    String? problem;
    if (!s.looksLikePan) {
      problem = 'This does not look like a PAN card. Make sure the whole card is in the photo and the text is sharp.';
    } else if (s.panNumber != null && tail != null && tail.isNotEmpty && !s.panNumber!.endsWith(tail)) {
      problem = 'The PAN on this card (${s.panNumber}) is not the one in your tax details ($masked).';
    }
    if (problem != null) {
      final use = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Check the photo', style: inter(18, 700)),
          content: Text(problem!, style: inter(14, 400, color: kMuted, height: 1.4)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Scan again', style: inter(14, 600))),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Use it anyway', style: inter(14, 600, color: kMuted))),
          ],
        ),
      );
      if (use != true || !mounted) {
        if (use == false && mounted) return _scanPan();
        return;
      }
    }
    await _upload('pan_copy', s.file);
    if (mounted && s.panNumber != null && problem == null) showToast(context, 'PAN card scanned · ${s.panNumber}');
  }

  Future<void> _remove(String kind, String what) async {
    if (_busy != null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove $what?', style: inter(18, 700)),
        content: Text('The file is deleted. You can add it again.', style: inter(14, 400, color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Keep', style: inter(14, 600))),
          TextButton(key: const ValueKey('confirm-remove'), onPressed: () => Navigator.pop(c, true), child: Text('Remove', style: inter(14, 600, color: const Color(0xFFC62828)))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = kind);
    final saved = await guarded(context, () => widget.api.removeDocument(kind));
    if (!mounted) return;
    setState(() {
      _busy = null;
      if (saved != null) _app = saved;
    });
  }

  /// The PAN card, compact (founder, 27 Oct 2026): scan with the camera or upload a file; once added, view, replace or remove.
  Widget _panCard() {
    final pan = _app.document('pan_copy');
    final busy = _busy == 'pan_copy';
    final camera = widget.scanner.available;
    Widget small(String label, IconData icon, VoidCallback? onTap, {Key? key, Color color = kInk}) => Expanded(
          child: OutlinedButton.icon(
            key: key,
            onPressed: busy ? null : onTap,
            icon: Icon(icon, size: 18, color: color),
            label: Text(label, style: inter(13.5, 600, color: color)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: kLine),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        );
    return WhiteCard(
      padding: 16,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: pan == null ? const Color(0xFFF1F2F4) : kNote, borderRadius: BorderRadius.circular(12)),
            child: Icon(pan == null ? Icons.badge_outlined : Icons.check_circle_outline, size: 24, color: pan == null ? kMuted : const Color(0xFF15803D)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PAN card', style: inter(16, 700)),
              const SizedBox(height: 2),
              Text(
                busy ? 'Working…' : pan == null ? 'Scan the card with your camera, or upload a copy.' : '${pan['file_name']} · ${_sizeLabel(pan).replaceAll(' · Upload complete', '')}',
                style: inter(12.5, 400, color: kMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          if (pan != null) const StatusChip('Not yet reviewed', Tone.neutral) else const StatusChip('To do', Tone.warn),
        ]),
        const SizedBox(height: 14),
        if (pan == null)
          Row(children: [
            if (camera) ...[
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('pan-scan'),
                  onPressed: busy ? null : _scanPan,
                  icon: const Icon(Icons.document_scanner_outlined, size: 18),
                  label: Text('Scan with camera', style: inter(13.5, 600, color: Colors.white)),
                  style: FilledButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            small(camera ? 'Upload file' : 'Upload PAN copy', Icons.upload_file_outlined, () => _upload('pan_copy'), key: const ValueKey('pan-upload')),
          ])
        else
          Row(children: [
            small('View', Icons.visibility_outlined, () => _preview('pan_copy'), key: const ValueKey('pan-view')),
            const SizedBox(width: 8),
            small('Replace', camera ? Icons.document_scanner_outlined : Icons.upload_file_outlined, camera ? _scanPan : () => _upload('pan_copy'), key: const ValueKey('pan-replace')),
            const SizedBox(width: 8),
            small('Remove', Icons.delete_outline, () => _remove('pan_copy', 'the PAN copy'), key: const ValueKey('pan-remove'), color: const Color(0xFFC62828)),
          ]),
      ]),
    );
  }

  Future<void> _preview(String kind) async {
    final url = await guarded(context, () => widget.api.previewUrl(kind));
    if (url == null || !mounted) return;
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication) && mounted) showToast(context, 'The preview could not be opened.');
  }

  String _sizeLabel(Map<String, dynamic> d) {
    final b = (d['size_bytes'] ?? 0) as num;
    final type = (d['mime_type'] as String? ?? '').split('/').last.toUpperCase();
    final mb = b >= 1024 * 1024 ? '${(b / 1024 / 1024).toStringAsFixed(1)} MB' : '${(b / 1024).ceil()} KB';
    return '${type == 'JPEG' ? 'JPG' : type} · $mb · Upload complete';
  }

  Widget _small(String title, String kind, String blurb, String idle, {required String actionIdle, bool optional = false}) {
    final d = _app.document(kind);
    return SectionCard(
      title: title,
      action: _busy == kind ? 'Uploading…' : d == null ? actionIdle : 'Replace',
      onAction: () => _upload(kind),
      lines: [blurb, d == null ? idle : '${d['file_name']} · ${_sizeLabel(d)}'],
      chip: d == null ? StatusChip(optional ? 'Conditional' : 'To do', optional ? Tone.neutral : Tone.warn) : const StatusChip('Uploaded · Not yet reviewed', Tone.neutral),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      kicker: 'Business setup',
      title: 'Add your documents.',
      caption: 'Section 5 of 7 · Documents',
      subtitle: 'Add clear, readable copies of applicable documents.',
      onBack: () => Navigator.of(context).pop(_app),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('docs-needed'),
            onPressed: () => showDocumentsNeeded(context, _app),
            icon: const Icon(Icons.checklist_rounded, size: 18, color: kLink),
            label: Text('What you’ll need', style: inter(14, 600, color: kLink)),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ),
        _panCard(),
        _small('Business proof', 'business_proof', 'Shop Act certificate or applicable alternative', 'Pending · No file added', actionIdle: 'Upload'),
        _small('Food License · if applicable', 'food_license', 'Add for applicable food activities only.', 'Applicability has not been confirmed.', actionIdle: 'Review', optional: true),
        const NoteCard(green: true, title: 'Protect your identity', body: 'Use masked identity copies where supported. Do not upload a full Aadhaar number.'),
      ],
      actions: [
        PrimaryAction(label: 'Save & continue', onPressed: () {
          if (_app.document('pan_copy') == null || _app.document('business_proof') == null) return showToast(context, 'Add your PAN copy and business proof to continue.');
          Navigator.of(context).pop(_app);
        }),
        const SizedBox(height: 12),
        const FooterNote('Upload limits: PDF, JPG or PNG · up to 5 MB each.'),
      ],
    );
  }
}

/// "Keep these handy": the documents and details the verification needs, shown before the first upload and from "What you'll need".
Future<void> showDocumentsNeeded(BuildContext context, Application app) {
  final food = app.partnerType == 'restaurant';
  final items = <(IconData, String, String)>[
    (Icons.badge_outlined, 'PAN card', 'The original card, to scan with your camera, or a clear copy. Your own PAN, or the firm’s if it has one.'),
    (Icons.storefront_outlined, 'Business proof', 'One of: Shop Act (Gumasta) certificate, Udyam registration, GST certificate or trade licence.'),
    (Icons.restaurant_outlined, food ? 'FSSAI food licence' : 'FSSAI food licence (if you sell food)', food ? 'Your FSSAI licence or registration certificate.' : 'Only if you make or sell food items.'),
    (Icons.account_balance_outlined, 'Bank details', 'Account number and IFSC. A cheque or passbook has both. The account should be in your or the business’s name.'),
    (Icons.phone_android_outlined, 'Your phone', 'The mobile number linked to your Aadhaar, for any verification code.'),
  ];
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (c) => SafeArea(
      child: Padding(
        key: const ValueKey('docs-needed-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Keep these handy', style: inter(22, 700)),
          const SizedBox(height: 6),
          Text('You’ll need them to verify your business. Clear, readable copies get approved faster.', style: inter(14, 400, color: kMuted, height: 1.4)),
          const SizedBox(height: 16),
          for (final (icon, title, body) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 38, height: 38, decoration: BoxDecoration(color: kNote, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 20, color: kInk)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: inter(15, 600)),
                    const SizedBox(height: 2),
                    Text(body, style: inter(13, 400, color: kMuted, height: 1.35)),
                  ]),
                ),
              ]),
            ),
          Text('Never share your full Aadhaar number or any OTP in messages.', style: inter(12.5, 500, color: kMuted)),
          const SizedBox(height: 14),
          PrimaryAction(key: const ValueKey('docs-needed-ok'), label: 'I have them ready', onPressed: () => Navigator.of(c).pop()),
        ]),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Section 6: bank. Figma "Bank Details". The account number is encrypted on the server; only the last four come back.
// ---------------------------------------------------------------------------------------------------------------------
class BankScreen extends StatefulWidget {
  const BankScreen({super.key, required this.api, required this.app});
  final OnboardingApi api;
  final Application app;
  @override
  State<BankScreen> createState() => _BankScreenState();
}

class _BankScreenState extends State<BankScreen> {
  late final _holder = TextEditingController(text: widget.app.bank?['holder_name'] as String? ?? widget.app.ownerName);
  final _acct = TextEditingController();
  final _confirm = TextEditingController();
  late final _ifsc = TextEditingController(text: widget.app.bank?['ifsc'] as String? ?? '');
  late String? _bank = widget.app.bank?['bank_name'] as String?;
  late String? _type = widget.app.bank?['account_type'] as String?;
  late bool _auth = widget.app.bank?['authorised'] == true;
  late final Future<Taxonomy> _tax = widget.api.taxonomy();
  bool _saving = false;
  final _draft = OnbDraft('bank');

  @override
  void initState() {
    super.initState();
    _draft.load().then((d) {
      if (!mounted || d.isEmpty) return;
      setState(() {
        if (_ifsc.text.isEmpty) _ifsc.text = d['ifsc'] ?? '';
        if ((d['holder'] ?? '').isNotEmpty && widget.app.bank?['holder_name'] == null) _holder.text = d['holder']!;
        _bank ??= d['bank'];
        _type ??= d['type'];
      });
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    for (final c in [_holder, _acct, _confirm, _ifsc]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _body({required bool draft}) => {
        'holder_name': _holder.text.trim(),
        if (_bank != null) 'bank_name': _bank,
        if (_acct.text.isNotEmpty) 'account_number': _acct.text.trim(),
        if (_confirm.text.isNotEmpty) 'confirm_account_number': _confirm.text.trim(),
        if (_ifsc.text.trim().isNotEmpty) 'ifsc': _ifsc.text.trim().toUpperCase(),
        if (_type != null) 'account_type': _type,
        'authorised': _auth,
        if (draft) 'draft': true,
      };

  Future<void> _save({required bool draft}) async {
    if (_saving) return;
    if (!draft) {
      if (_holder.text.trim().length < 2) return showToast(context, 'Enter the account holder name.');
      if (_bank == null) return showToast(context, 'Choose your bank.');
      if (_acct.text.trim().length < 9) return showToast(context, 'Account number must be 9 to 18 digits.');
      if (_acct.text.trim() != _confirm.text.trim()) return showToast(context, 'The account numbers do not match.');
      if (!RegExp(r'^[A-Za-z]{4}0[A-Za-z0-9]{6}$').hasMatch(_ifsc.text.trim())) return showToast(context, 'IFSC looks wrong. It has 4 letters, a 0, then 6 characters.');
      if (_type == null) return showToast(context, 'Choose the account type.');
      if (!_auth) return showToast(context, 'Confirm that you are authorized to use this account for this business.');
    }
    setState(() => _saving = true);
    final saved = await guarded(context, () => widget.api.saveBank(_body(draft: draft)));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) return;
    if (!draft) await _draft.clear();
    // straight on (founder, 27 Oct 2026): the verification status is on the application status page, not a stop here
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    _draft.keep({'holder': _holder.text, 'bank': _bank, 'ifsc': _ifsc.text, 'type': _type}); // never the account number
    final saved = widget.app.bank;
    return OnbPage(
      kicker: 'Business setup',
      title: 'Add your bank details.',
      caption: 'Section 6 of 7',
      subtitle: 'Use an account associated with the business or proprietor, as applicable.',
      children: [
        if (saved != null)
          WhiteCard(
            padding: 14,
            radius: 12,
            child: Row(children: [
              const Icon(Icons.account_balance_outlined, color: kLink),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Account ownership', style: inter(15, 600)),
                Text('${saved['bank_name'] ?? ''} · ${saved['account_masked'] ?? ''}', style: inter(13, 400, color: kMuted)),
              ])),
            ]),
          ),
        const NoteCard(title: 'Ownership will be checked separately.', body: 'Saved details are not the same as verified details.'),
        LabeledField(label: 'Account holder name', controller: _holder, labelWeight: 500),
        FutureBuilder<Taxonomy>(future: _tax, builder: (_, s) => SelectField(label: 'Bank name', value: _bank, options: s.data?.banks ?? const [], hint: s.hasError ? 'Could not load banks' : 'Choose', onChanged: (v) => setState(() => _bank = v))),
        LabeledField(label: 'Account number', controller: _acct, labelWeight: 500, obscure: true, keyboardType: TextInputType.number, maxLength: 18, hint: saved?['account_masked'] as String?, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
        LabeledField(label: 'Confirm account number', controller: _confirm, labelWeight: 500, keyboardType: TextInputType.number, maxLength: 18, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
        LabeledField(label: 'IFSC', controller: _ifsc, labelWeight: 500, maxLength: 11, hint: 'e.g. HDFC0001234', inputFormatters: [TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase()))]),
        SelectField(
          label: 'Account type',
          value: _type == null ? null : (_type == 'current' ? 'Current account' : 'Savings account'),
          options: const ['Savings account', 'Current account'],
          onChanged: (v) => setState(() => _type = v.startsWith('Current') ? 'current' : 'savings'),
        ),
        CheckRow(value: _auth, onChanged: (v) => setState(() => _auth = v), text: 'I confirm that I am authorized to use this account for this business.'),
        const NoteCard(green: true, title: 'No banking passwords needed', body: 'OneLocal does not ask for your PIN, OTP or internet banking password on this form.'),
      ],
      actions: [
        PrimaryAction(label: _saving ? 'Saving…' : 'Save & continue', onPressed: _saving ? null : () => _save(draft: false)),
        const SizedBox(height: 12),
        SecondaryAction(label: 'Save for later', onPressed: _saving ? null : () => _save(draft: true)),
      ],
    );
  }
}
