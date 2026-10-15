import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A file the person chose. The server only accepts PDF, JPG and PNG up to 5 MB, and checks again on its side.
class PickedDocument {
  const PickedDocument({required this.name, required this.bytes, required this.contentType});
  final String name;
  final Uint8List bytes;
  final String contentType;
}

abstract class DocumentPicker {
  const DocumentPicker();
  Future<PickedDocument?> pick();
}

class DevicePicker extends DocumentPicker {
  const DevicePicker();
  @override
  Future<PickedDocument?> pick() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png']);
    if (f == null) return null;
    final ext = f.name.split('.').last.toLowerCase();
    final type = ext == 'pdf' ? 'application/pdf' : ext == 'png' ? 'image/png' : 'image/jpeg';
    return PickedDocument(name: f.name, bytes: await f.readAsBytes(), contentType: type);
  }
}
