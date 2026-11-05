/// The parser for plain text.
library;

import 'dart:convert';

import '../../../core/run_context.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import 'parser.dart';

/// The metadata key under which a parser records where a document comes
/// from: the [ParserOptions.uri] of the call.
///
/// Port of eino `parser.MetaKeySource`.
const String metaKeySource = '_source';

/// Reads the bytes as UTF-8 text and returns them as one document.
///
/// Port of eino `parser.TextParser`. The metadata of the document has the
/// source under [metaKeySource] and, on top of it, the
/// [ParserOptions.extraMeta] of the call. `ExtParser` falls back to this
/// parser for file extensions it has no parser for.
///
/// Bytes that are not valid UTF-8 become U+FFFD, the replacement character,
/// instead of failing the call.
final class TextParser implements Parser, TypedComponent {
  /// A text parser.
  const TextParser();

  @override
  String get componentTypeName => 'Text';

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final data = await readAllBytes(bytes);

    return [
      Document(
        content: utf8.decode(data, allowMalformed: true),
        metadata: {
          metaKeySource: options?.uri ?? '',
          ...?options?.extraMeta,
        },
      ),
    ];
  }
}
