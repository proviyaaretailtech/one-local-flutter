import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

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

/// The item form's photo tools: choose a picture, remove its background (AI), and attach it to the saved item.
/// Kept behind one interface so the background-removal service and the item-photo storage can be plugged in without
/// touching the form; until they are, the default says plainly what is not set up.
abstract class ItemPhotoService {
  const ItemPhotoService();
  Future<ItemPhoto?> pick();
  Future<ItemPhoto> removeBackground(ItemPhoto photo);
  Future<void> attach(String itemId, ItemPhoto photo);
}

/// JPG, PNG or WebP up to 5 MB, the same limits the server uses for pictures.
class DeviceItemPhotos extends ItemPhotoService {
  const DeviceItemPhotos({this.rpc});
  final RpcClient? rpc;
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

  // The server sends the photo to remove.bg (its key stays on the server) and answers a transparent PNG; nothing is saved there.
  // The server's own sentence is shown when it cannot (not set up, out of credits, busy, no product found in the photo).
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo) async {
    try {
      final r = await (rpc ?? RpcClient()).callMap('cat_image_remove_bg', {'image_b64': base64Encode(photo.bytes), 'content_type': photo.contentType});
      final b64 = r['image_b64'];
      if (b64 is! String || b64.isEmpty) throw const ItemPhotoUnavailable('The background could not be removed.');
      return ItemPhoto(bytes: base64Decode(b64), contentType: 'image/png', backgroundRemoved: true);
    } on PartnerApiException catch (e) {
      throw ItemPhotoUnavailable(e.message);
    }
  }

  // Needs item-photo storage in the database (the catalogue save has no photo yet).
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async =>
      throw const ItemPhotoUnavailable('Saving product photos is not set up yet.');
}
