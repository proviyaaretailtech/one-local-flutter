import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';
import 'settings_api.dart';

// The store's payment QR (founder, 29 Oct 2026): a photo of the shop's own UPI QR, added while setting up the store, changed any time in
// Settings, and shown full size when a bill is paid by UPI on the Bill screen. It is a picture only: nothing is generated from it.

/// The saved QR: a short-lived link to it, and whether it is a PDF (which opens instead of showing).
typedef StoreQr = ({String url, bool pdf});

/// The store's QR, or null when none is saved. Tests replace it.
Future<StoreQr?> Function() loadStoreQr = () async {
  try {
    final r = await SettingsApi().fileLinkInfo('store_qr');
    return (url: r['url'] as String, pdf: r['content_type'] == 'application/pdf');
  } on PartnerApiException catch (e) {
    if (e.status == 404) return null; // none saved yet
    rethrow;
  }
};

/// Saves [file] as the store's QR. Tests replace it.
Future<void> Function(PickedDocument file) saveStoreQr = (file) => SettingsApi().uploadFile(kind: 'store_qr', file: file);

/// Removes the store's QR. Tests replace it.
Future<void> Function() removeStoreQr = () => SettingsApi().removeQr();

/// Picks a photo of the QR (JPG or PNG). Tests replace it.
Future<PickedDocument?> Function() pickQrPhoto = () async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png']);
  if (f == null) return null;
  final ext = f.name.split('.').last.toLowerCase();
  return PickedDocument(name: f.name, bytes: await f.readAsBytes(), contentType: ext == 'png' ? 'image/png' : 'image/jpeg');
};

/// The QR on a card: the picture itself (or a PDF to open), and with [canEdit] Upload / Replace and Remove. [big] makes the picture
/// large enough for a customer to scan from the counter.
class StoreQrCard extends StatefulWidget {
  const StoreQrCard({super.key, this.canEdit = false, this.big = false, this.onChanged, this.openLink, this.emptyHint, this.load, this.save, this.remove, this.pick});
  final bool canEdit, big;

  /// Where the QR comes from and goes to (default: the store's own, through Settings).
  final Future<StoreQr?> Function()? load;
  final Future<void> Function(PickedDocument file)? save;
  final Future<void> Function()? remove;
  final Future<PickedDocument?> Function()? pick;

  /// Called after an upload or a removal (true: a QR is saved now).
  final ValueChanged<bool>? onChanged;

  /// Opens a PDF QR in the browser or viewer.
  final void Function(String url)? openLink;

  /// What to say when there is no QR (default: where to add it).
  final String? emptyHint;
  @override
  State<StoreQrCard> createState() => _StoreQrCardState();
}

class _StoreQrCardState extends State<StoreQrCard> {
  StoreQr? _qr;
  bool _loading = true, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = await (widget.load ?? loadStoreQr)();
      if (mounted) setState(() => _qr = q);
    } catch (e) {
      if (mounted) setState(() => _error = e is PartnerApiException ? e.message : tr('Could not load the QR.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final f = await (widget.pick ?? pickQrPhoto)();
    if (f == null || !mounted) return;
    if (!f.contentType.startsWith('image/')) return showToast(context, tr('Choose a photo of your QR (JPG or PNG).'));
    setState(() => _busy = true);
    try {
      await (widget.save ?? saveStoreQr)(f);
      if (!mounted) return;
      showToast(context, tr('Payment QR saved. It shows when a bill is paid by UPI.'));
      widget.onChanged?.call(true);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not save the QR. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await (widget.remove ?? removeStoreQr)();
      if (!mounted) return;
      setState(() => _qr = null);
      widget.onChanged?.call(false);
    } catch (e) {
      if (mounted) showToast(context, e is PartnerApiException ? e.message : tr('Could not remove the QR. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _qr;
    final side = widget.big ? 240.0 : 150.0;
    Widget picture;
    if (_loading) {
      picture = SizedBox(width: side, height: side, child: const Center(child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (q == null) {
      picture = Container(
        key: const ValueKey('store-qr-empty'),
        width: side,
        height: side,
        decoration: BoxDecoration(color: const Color(0xFFF7F8F4), borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(LucideIcons.qrCode, size: 34, color: kMuted),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _error ?? widget.emptyHint ?? tr(widget.canEdit ? 'No QR yet. Upload a photo of your UPI QR.' : 'No payment QR yet. Add it in Settings → Store → Payment QR.'),
              textAlign: TextAlign.center,
              style: inter(12, 500, color: kMuted, height: 1.35),
            ),
          ),
        ]),
      );
    } else if (q.pdf) {
      picture = OutlinedButton.icon(
        key: const ValueKey('store-qr-open'),
        onPressed: () => widget.openLink?.call(q.url),
        icon: const Icon(LucideIcons.fileText, size: 18),
        label: Text(tr('Open the QR (PDF)'), style: inter(14, 700)),
      );
    } else {
      picture = Container(
        key: const ValueKey('store-qr-image'),
        width: side,
        height: side,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kLine),
          boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 16, offset: Offset(0, 6))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            q.url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Center(child: Text(tr('Could not show the QR.'), textAlign: TextAlign.center, style: inter(12, 500, color: kMuted))),
          ),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Center(child: picture),
      if (widget.canEdit) ...[
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          FilledButton.icon(
            key: const ValueKey('store-qr-upload'),
            onPressed: _busy || _loading ? null : _upload,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(q == null ? LucideIcons.upload : LucideIcons.refreshCw, size: 16),
            label: Text(tr(q == null ? 'Upload QR' : 'Change QR'), style: inter(14, 700)),
            style: FilledButton.styleFrom(backgroundColor: kPrimary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
          if (q != null) ...[
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('store-qr-remove'),
              onPressed: _busy ? null : _remove,
              child: Text(tr('Remove'), style: inter(14, 700, color: const Color(0xFFC62828))),
            ),
          ],
        ]),
      ],
    ]);
  }
}
