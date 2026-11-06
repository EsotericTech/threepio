/// Splitting HTML documents at their header elements (`h1`, `h2`, …), with
/// the text of the enclosing headers as metadata of every chunk.
///
/// Port of eino-ext `components/document/transformer/splitter/html`.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

import '../../../../core/run_context.dart';
import '../../../../errors.dart';
import '../../../../schema/document.dart';
import '../../../component_type.dart';
import '../../transformer.dart';
import 'split_id_generator.dart';

/// The configuration of eino-ext's HTML header splitter, created with
/// `HtmlSplitter.fromHeaderConfig`.
///
/// Port of eino-ext `html.HeaderConfig`. With
///
/// ```dart
/// final splitter = HtmlSplitter.fromHeaderConfig(
///   const HtmlHeaderSplitterConfig(
///     headers: {'h1': 'Chapter', 'h2': 'Section'},
///   ),
/// );
/// ```
///
/// the document
/// `'<h1>Chapter 1</h1><p>Intro</p><h2>Section 1.1</h2><p>Body</p>'` gives
/// the chunks `'Intro'` with metadata `{'Chapter': 'Chapter 1'}` and `'Body'`
/// with `{'Chapter': 'Chapter 1', 'Section': 'Section 1.1'}`.
///
/// The document is parsed with `package:html`, whose HTML5 tree is the one
/// Go's x/net/html builds except around a `<main>`, `<dialog>` or `<search>`
/// element next to an unclosed `<p>`, for `<isindex>`, and inside
/// `<template>`; there the chunks can differ from Eino's (see
/// `HtmlSplitter.fromHeaderConfig`).
@immutable
final class HtmlHeaderSplitterConfig {
  /// A configuration that cuts at the header elements named in [headers].
  const HtmlHeaderSplitterConfig({required this.headers, this.idGenerator});

  /// The header elements to cut at, by tag name (lower case: `'h1'`, `'h2'`,
  /// …; the level is the number after the first letter), mapped to the
  /// metadata key under which the chunks below the header get its text.
  /// Port of `Headers`.
  ///
  /// The names are not checked here, as in Go: an element whose name is a
  /// key but has no number after its first letter (`'div'`) makes
  /// `transform` throw.
  final Map<String, String> headers;

  /// Makes the ids of the chunks. `null` means every chunk keeps the id of
  /// its document. Port of `IDGenerator`.
  final SplitIdGenerator? idGenerator;
}

/// eino-ext's HTML header splitter, as `HtmlSplitter.fromHeaderConfig`
/// returns it.
///
/// Port of the unexported `html.headerSplitter`. The document is parsed with
/// `package:html`, which builds the HTML5 tree Go's `golang.org/x/net/html`
/// (v0.41) builds for ordinary documents: implied `html`, `head` and `body`
/// elements, text nodes, white space. `package:html` follows an older
/// version of the HTML5 parsing rules, and its tree differs in a few places:
///
/// * A `<main>`, `<dialog>` or `<search>` start tag does not close an open
///   `<p>`, and their end tag is ignored while a `<p>` inside them is open
///   (x/net/html closes the `<p>` in both cases). With an unclosed `<p>`,
///   text after such an element can therefore belong to a different chunk
///   than in Go: `<main><h1>T</h1><p>x</main>y` gives one chunk `xy` here,
///   two (`x` and `y`) in Go.
/// * `<isindex>` is expanded into a form with the prompt "This is a
///   searchable index. Enter search keywords: ", which becomes chunk text;
///   x/net/html treats it as an ordinary element.
/// * `<template>` has no template insertion modes (its content is parsed as
///   ordinary children, as x/net/html keeps them, but table-related tags
///   inside it are placed differently).
///
/// The text of the chunks is the text of the tree's text nodes,
/// those made of white space left out and the others kept untrimmed and
/// concatenated without a separator; comments and attributes do not count.
///
/// Every chunk is a new document with the id from the config's
/// `idGenerator`, the chunk as its content, a copy of its document's
/// metadata (a shallow one, as Go's `deepCopyAnyMap`) with the texts of the
/// headers above the chunk added, and its document's `source`; the input
/// documents are left as they are.
@internal
final class HtmlHeaderSplitterTransformer
    implements DocumentTransformer, TypedComponent {
  /// The splitter [config] describes. Port of eino-ext
  /// `html.NewHeaderSplitter`, which checks nothing.
  HtmlHeaderSplitterTransformer(HtmlHeaderSplitterConfig config)
      : _headers = Map.unmodifiable(config.headers),
        _idGenerator = config.idGenerator ?? defaultSplitIdGenerator;

  final Map<String, String> _headers;
  final SplitIdGenerator _idGenerator;

  /// Port of `html.headerSplitter.GetType`.
  @override
  String get componentTypeName => 'HTMLHeaderSplitter';

  /// Cuts every document at its header elements. Port of
  /// `headerSplitter.Transform`.
  ///
  /// The `runContext` of [options] (or a background context) is what the
  /// id generator gets. The metadata of a chunk holds its document's entries
  /// first and then the header entries, in the order the headers were met.
  ///
  /// Throws [ThreepioException] `calculate header level fail: <tag>` when an
  /// element named in the config's headers has no level (Go's
  /// `strconv.Atoi` fails on what follows its first letter).
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final result = <Document>[];
    for (final doc in documents) {
      final splits = _splitText(doc.content);
      for (final (i, split) in splits.indexed) {
        result.add(
          Document(
            id: _idGenerator(ctx, doc.id, i),
            content: split.chunk,
            metadata: <String, dynamic>{...doc.metadata, ...split.meta},
            source: doc.source,
          ),
        );
      }
    }
    return result;
  }

  /// Port of `headerSplitter.splitText`.
  List<_SplitResult> _splitText(String text) {
    final currentText = StringBuffer();
    final result = <_SplitResult>[];

    // Go's html.Parse fails only when reading fails; package:html's parse
    // does not fail at all outside its strict mode.
    final tree = html_parser.parse(text);

    _dfs(tree, currentText, result);
    if (currentText.isNotEmpty) {
      result.add(_SplitResult(currentText.toString(), const {}));
    }
    return result;
  }

  /// Port of `headerSplitter.dfs`, without the recursion.
  ///
  /// Go's `dfs(node, …)` walks `node` and its following siblings and calls
  /// itself on the first child of each one that is not a header, with copies
  /// of the header records. Here each such call is a [_Level] on an explicit
  /// stack, so a deeply nested document cannot overflow the Dart stack; the
  /// order in which nodes are visited and chunks are emitted is Go's. The
  /// loop visits every node once and pops a level per sibling list, so it
  /// ends.
  void _dfs(dom.Node root, StringBuffer currentText, List<_SplitResult> out) {
    final stack = <_Level>[
      _Level([root], <_MetaRecord>[], <String, String>{}),
    ];
    while (stack.isNotEmpty) {
      final level = stack.last;
      if (level.index >= level.siblings.length) {
        // The end of Go's sibling loop.
        if (level.hasHeader && currentText.isNotEmpty) {
          out.add(_SplitResult(currentText.toString(), Map.of(level.metaMap)));
          currentText.clear();
        }
        stack.removeLast();
        continue;
      }
      final node = level.siblings[level.index++];

      if (node is dom.Element && _headers.containsKey(node.localName)) {
        final tag = node.localName!;
        level.hasHeader = true;

        if (currentText.isNotEmpty) {
          out.add(_SplitResult(currentText.toString(), Map.of(level.metaMap)));
          currentText.clear();
        }

        final newLevel = _headerLevel(tag);
        if (newLevel == null) {
          throw ThreepioException('calculate header level fail: $tag');
        }
        final metaList = level.metaList;
        for (var i = metaList.length - 1; i >= 0; i--) {
          if (metaList[i].level >= newLevel) {
            level.metaMap.remove(metaList[i].name);
            metaList.removeRange(i, metaList.length);
          } else {
            break;
          }
        }

        final name = _headers[tag]!;
        metaList.add(_MetaRecord(name, newLevel));
        level.metaMap[name] = _extractText(node);
        continue;
      }
      if (node is dom.Text && splitterGoTrimSpace(node.data).isNotEmpty) {
        currentText.write(node.data);
      }

      // Go recurses here with copies of the records; the loop of this level
      // goes on with the next sibling afterwards.
      stack.add(
        _Level(
          node.nodes,
          List.of(level.metaList),
          Map.of(level.metaMap),
        ),
      );
    }
  }

  /// The text of the descendants of [node]: the text nodes not made of
  /// white space, in document order, untrimmed and concatenated.
  ///
  /// Port of `extractText` (an iterative pre-order walk).
  static String _extractText(dom.Node node) {
    final buffer = StringBuffer();
    final stack = <dom.Node>[...node.nodes.reversed];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (current is dom.Text && splitterGoTrimSpace(current.data).isNotEmpty) {
        buffer.write(current.data);
      }
      stack.addAll(current.nodes.reversed);
    }
    return buffer.toString();
  }

  /// The level of the header element [tag]: what follows its first letter,
  /// read as Go's `strconv.Atoi` reads it (an optional sign and decimal
  /// digits, within 64 bits), or `null`. Port of `calHLevel`.
  static int? _headerLevel(String tag) {
    if (tag.isEmpty) return null;
    final digits = tag.substring(1);
    if (!_atoiPattern.hasMatch(digits)) return null;
    return int.tryParse(digits, radix: 10);
  }

  static final _atoiPattern = RegExp(r'^[+-]?[0-9]+$');

  @override
  String toString() => 'HtmlHeaderSplitterTransformer(headers: $_headers)';
}

/// One sibling list being walked: a call of Go's `dfs` with its own copies
/// of the header records.
final class _Level {
  _Level(this.siblings, this.metaList, this.metaMap);

  final List<dom.Node> siblings;
  final List<_MetaRecord> metaList;
  final Map<String, String> metaMap;
  int index = 0;
  bool hasHeader = false;
}

/// One chunk and the header texts above it. Port of `splitResult`.
final class _SplitResult {
  const _SplitResult(this.chunk, this.meta);

  final String chunk;
  final Map<String, String> meta;
}

/// A header that is in effect. Port of `metaRecord` (whose `data` field Go
/// writes but never reads).
final class _MetaRecord {
  const _MetaRecord(this.name, this.level);

  final String name;
  final int level;
}
