import 'dart:typed_data';

import 'package:zstandard/zstandard.dart';

/// Zstandard codec abstraction so pure VM tests can inject a fake codec while
/// production builds use the native zstandard plugin.
abstract class ZstdCodec {
  Future<Uint8List?> decompress(Uint8List data);
}

class ZstandardZstdCodec implements ZstdCodec {
  const ZstandardZstdCodec();

  @override
  Future<Uint8List?> decompress(Uint8List data) {
    return Zstandard().decompress(data);
  }
}
