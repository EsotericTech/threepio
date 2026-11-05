/// What the parsers share.
library;

import 'dart:typed_data';

/// Reads [bytes] to the end and returns them as one list.
///
/// The counterpart of Go's `io.ReadAll` for the input of a `Parser`.
Future<Uint8List> readAllBytes(Stream<List<int>> bytes) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in bytes) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// The file extension of [uri]: the last dot of its last path segment and
/// what follows, or `''` when that segment has no dot.
///
/// Port of Go's `filepath.Ext`, which is what Eino's `ExtParser` uses. The
/// URI is taken as a plain path, as in Go: a query string is not cut off. A
/// path with backslashes is understood as well.
String fileExtensionOf(String uri) {
  for (var i = uri.length - 1; i >= 0; i--) {
    final char = uri[i];
    if (char == '/' || char == r'\') break;
    if (char == '.') return uri.substring(i);
  }
  return '';
}
