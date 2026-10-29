import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import 'photo_capture_screen.dart';

/// A product photo chosen on the item form, before it is saved.
class ItemPhoto {
  const ItemPhoto({required this.bytes, required this.contentType, this.backgroundRemoved = false});
  final Uint8List bytes;
  final String contentType;
  final bool backgroundRemoved;
}

/// Something the photo tools cannot do yet; [message] is shown to the person as it is.
class ItemPhotoUnavailable implements Exception {
  const ItemPhotoUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The item form's photo tools: choose a picture, remove its background (AI), attach it to the saved item or take it off.
/// Kept behind one interface so the screens can be tested without a camera, storage or remove.bg.
abstract class ItemPhotoService {
  const ItemPhotoService();
  Future<ItemPhoto?> pick();

  /// A new photo, camera first (founder, 26 Oct 2026): the camera opens at once, the latest gallery photo sits in its corner, and
  /// after the shot the background can be removed before it is used. Null when closed.
  Future<ItemPhoto?> capture(BuildContext context) => showPhotoCapture(context, this);
  /// The photo cut out by AI: on transparency, or set on [bgColor] (hex, no #) for a clean studio backdrop.
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor});
  Future<void> attach(String itemId, ItemPhoto photo);
  /// Takes the saved photo off the item.
  Future<void> remove(String itemId);

  /// The bytes of a photo already saved (the dish's own), to work on it. JPG, PNG or WebP, as served.
  Future<ItemPhoto> load(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) throw const ItemPhotoUnavailable('The dish photo could not be loaded.');
    if (r.bodyBytes.length > DeviceItemPhotos.maxBytes) throw const ItemPhotoUnavailable('This photo is over 5 MB. Choose a smaller one.');
    final type = (r.headers['content-type'] ?? '').split(';').first.trim();
    return ItemPhoto(bytes: r.bodyBytes, contentType: const ['image/png', 'image/webp'].contains(type) ? type : 'image/jpeg');
  }
}

/// JPG, PNG or WebP up to 5 MB, the same limits the server uses for pictures.
class DeviceItemPhotos extends ItemPhotoService {
  const DeviceItemPhotos({this.rpc, this.client});
  final RpcClient? rpc;
  final http.Client? client; // the upload to storage
  static const maxBytes = 5 * 1024 * 1024;

  @override
  Future<ItemPhoto?> pick() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp']);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) throw const ItemPhotoUnavailable('Each photo can be up to 5 MB.');
    final ext = f.name.split('.').last.toLowerCase();
    return ItemPhoto(bytes: bytes, contentType: ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg');
  }

  // On the phone (founder, 26 Oct 2026): Google's on-device subject segmentation cuts the product out — free, offline, nothing leaves
  // the phone — and answers a transparent PNG. In the browser the server sends it to remove.bg instead (its key stays on the server);
  // the server's own sentence is shown when it cannot (not set up, out of credits, busy, no product found in the photo).
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async {
    if (bgColor == null && !kIsWeb && Platform.isAndroid) return _cutOutOnPhone(photo);
    try {
      final r = await (rpc ?? RpcClient())
          .callMap('cat_image_remove_bg', {'image_b64': base64Encode(photo.bytes), 'content_type': photo.contentType, 'bg_color': ?bgColor});
      final b64 = r['image_b64'];
      if (b64 is! String || b64.isEmpty) throw const ItemPhotoUnavailable('The background could not be removed.');
      return ItemPhoto(bytes: base64Decode(b64), contentType: r['content_type'] == 'image/jpeg' ? 'image/jpeg' : 'image/png', backgroundRemoved: true);
    } on PartnerApiException catch (e) {
      throw ItemPhotoUnavailable(e.message);
    }
  }

  static Future<ItemPhoto> _cutOutOnPhone(ItemPhoto photo) async {
    final dir = await Directory.systemTemp.createTemp('cutout');
    final file = File('${dir.path}/photo.${photo.contentType == 'image/png' ? 'png' : 'jpg'}');
    final segmenter = SubjectSegmenter(options: SubjectSegmenterOptions(
      enableForegroundBitmap: true,
      enableForegroundConfidenceMask: false,
      enableMultipleSubjects: SubjectResultOptions(enableConfidenceMask: false, enableSubjectBitmap: false),
    ));
    try {
      await file.writeAsBytes(photo.bytes);
      final r = await segmenter.processImage(InputImage.fromFilePath(file.path));
      final png = r.foregroundBitmap;
      if (png == null || png.isEmpty) throw const ItemPhotoUnavailable('No product was found in the photo. Try again with the product in the middle.');
      if (png.length > maxBytes) throw const ItemPhotoUnavailable('The cut-out is too large to save. Take the photo a little further away.');
      return ItemPhoto(bytes: png, contentType: 'image/png', backgroundRemoved: true);
    } on ItemPhotoUnavailable {
      rethrow;
    } catch (_) {
      // the first time, the phone downloads the cut-out tool from Google Play; it needs a moment and the internet once
      throw const ItemPhotoUnavailable('The background could not be removed right now. Try again in a minute.');
    } finally {
      await segmenter.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  // Three steps through the server: a signed upload slot for this item, the bytes straight to storage, then confirm, which puts the
  // photo's link on the item (and deletes the photo it replaced). The server checks the person may change this item first.
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async {
    final api = rpc ?? RpcClient();
    try {
      final ask = {'item_id': itemId, 'content_type': photo.contentType, 'size': photo.bytes.length};
      final slot = await api.callMap('cat_item_photo_slot', ask);
      final put = await (client ?? http.Client())
          .put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': photo.contentType, 'x-upsert': 'true'}, body: photo.bytes)
          .timeout(const Duration(seconds: 120));
      if (put.statusCode < 200 || put.statusCode >= 300) throw const ItemPhotoUnavailable('The photo did not finish uploading. Please try again.');
      await api.callMap('cat_item_photo_attach', {...ask, 'path': slot['path']});
    } on PartnerApiException catch (e) {
      throw ItemPhotoUnavailable(e.message);
    }
  }

  @override
  Future<void> remove(String itemId) async {
    try {
      await (rpc ?? RpcClient()).callMap('cat_item_photo_remove', {'item_id': itemId});
    } on PartnerApiException catch (e) {
      throw ItemPhotoUnavailable(e.message);
    }
  }
}
