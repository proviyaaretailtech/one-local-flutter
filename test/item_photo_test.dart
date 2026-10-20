import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';

void main() {
  final photo = ItemPhoto(bytes: Uint8List.fromList(const [1, 2, 3, 4]), contentType: 'image/jpeg');

  DeviceItemPhotos photos(http.Response Function(http.Request r) answer, List<http.Request> seen) => DeviceItemPhotos(
        rpc: RpcClient(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        })),
      );

  test('remove background sends the photo to the server and keeps the transparent PNG it answers', () async {
    final seen = <http.Request>[];
    final p = photos((_) => http.Response(jsonEncode({'image_b64': base64Encode([9, 9]), 'content_type': 'image/png'}), 200), seen);
    final out = await p.removeBackground(photo);
    expect(seen.single.url.path, '/rpc/cat_image_remove_bg');
    expect(jsonDecode(seen.single.body), {'image_b64': base64Encode([1, 2, 3, 4]), 'content_type': 'image/jpeg'});
    expect(out.bytes, [9, 9]);
    expect(out.contentType, 'image/png');
    expect(out.backgroundRemoved, isTrue);
  });

  test('when the server cannot, its own sentence is what the person sees', () async {
    final p = photos((_) => http.Response(jsonEncode({'detail': 'Background removal is not set up yet. Your photo is kept as it is.', 'code': 'bg_not_configured'}), 503), []);
    await expectLater(p.removeBackground(photo),
        throwsA(isA<ItemPhotoUnavailable>().having((e) => e.message, 'message', 'Background removal is not set up yet. Your photo is kept as it is.')));
  });
}
