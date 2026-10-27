import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'document_picker.dart';

/// A scanned PAN card: the cropped photo, and what was read off it.
class PanScan {
  const PanScan({required this.file, required this.panNumber, required this.looksLikePan});
  final PickedDocument file;

  /// The PAN printed on the card (ABCDE1234F), when it could be read.
  final String? panNumber;

  /// The card reads like a PAN card (the PAN pattern, or "Income Tax Department" / "Permanent Account Number").
  final bool looksLikePan;
}

/// Reads a PAN card from photo text: the number, and whether it is a PAN card at all.
({String? pan, bool looksLikePan}) readPanText(String text) {
  final flat = text.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  final pan = RegExp(r'\b[A-Z]{5}[0-9]{4}[A-Z]\b').firstMatch(flat)?.group(0);
  final words = flat.contains('INCOME TAX') || flat.contains('PERMANENT ACCOUNT NUMBER');
  return (pan: pan, looksLikePan: pan != null || words);
}

/// Takes the PAN card's photo with the camera (founder, 27 Oct 2026).
abstract class PanScanner {
  const PanScanner();

  /// The built-in document scanner is there (Android): it finds the card's edges, crops and straightens it.
  bool get available;
  Future<PanScan?> scan();
}

/// Google's ML Kit document scanner (Android): the camera finds the card, then the text on it is read on the phone, so nothing
/// leaves the phone until it is uploaded.
class MlKitPanScanner extends PanScanner {
  const MlKitPanScanner();

  @override
  bool get available => !kIsWeb && Platform.isAndroid;

  @override
  Future<PanScan?> scan() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(documentFormats: {DocumentFormat.jpeg}, mode: ScannerMode.filter, pageLimit: 1, isGalleryImport: false),
    );
    try {
      final path = (await scanner.scanDocument()).images?.firstOrNull;
      if (path == null) return null;
      final recogniser = TextRecognizer(script: TextRecognitionScript.latin);
      var read = (pan: null as String?, looksLikePan: false);
      try {
        read = readPanText((await recogniser.processImage(InputImage.fromFilePath(path))).text);
      } catch (_) {
        // could not read the text: the photo is still kept, and someone reviews it
      } finally {
        await recogniser.close();
      }
      final bytes = await File(path).readAsBytes();
      return PanScan(file: PickedDocument(name: 'pan_card_scan.jpg', bytes: bytes, contentType: 'image/jpeg'), panNumber: read.pan, looksLikePan: read.looksLikePan);
    } catch (_) {
      return null; // closed without a photo, or no camera
    } finally {
      await scanner.close();
    }
  }
}
