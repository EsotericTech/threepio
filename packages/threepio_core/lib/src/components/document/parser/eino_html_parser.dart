/// eino-ext's HTML parser: the text of a page, sanitized, with its title,
/// description, language and charset as metadata.
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import 'go_text.dart';
import 'html_ugc_sanitizer.dart';
import 'parser.dart';
import 'text_parser.dart';

/// The metadata key of the page title (the text of its `<title>`).
///
/// Port of eino-ext `html.MetaKeyTitle`.
const String htmlMetaKeyTitle = '_title';

/// The metadata key of the page description (the `content` of its
/// `<meta name="description">`).
///
/// Port of eino-ext `html.MetaKeyDesc`.
const String htmlMetaKeyDescription = '_description';

/// The metadata key of the page language (the `lang` of its `<html>`).
///
/// Port of eino-ext `html.MetaKeyLang`.
const String htmlMetaKeyLanguage = '_language';

/// The metadata key of the page charset (the `charset` of its
/// `<meta charset>`).
///
/// Port of eino-ext `html.MetaKeyCharset`.
const String htmlMetaKeyCharset = '_charset';

/// The selector of the `<body>` element, the one the URL loader parses by
/// default.
///
/// Port of eino-ext `html.BodySelector`.
const String htmlBodySelector = 'body';

/// The configuration of [HtmlContentParser].
///
/// Port of eino-ext `html.Config`.
@immutable
final class HtmlParserConfig {
  /// A configuration that takes the content from the elements [selector]
  /// matches, or from the whole document when it is `null`.
  const HtmlParserConfig({this.selector});

  /// The CSS selector of the elements whose content becomes the content of
  /// the document: `body` for `<body>`, `#id` for `<div id="id">`. `null`
  /// takes the whole document, `<head>` included (Go: a `nil` selector).
  ///
  /// As with goquery, a selector that cannot be parsed matches nothing, so
  /// the content is empty. Selectors are evaluated by `package:html`, not by
  /// cascadia: one it cannot evaluate (some pseudo-classes cascadia knows,
  /// such as `:contains()`, `:has()` or `:nth-child(2n)`) matches nothing
  /// here either. An element matched together with one of its ancestors
  /// gives its text twice, as goquery's `Contents` does.
  final String? selector;
}

/// Parses HTML into one document: the text of the page, sanitized, and its
/// metadata.
///
/// Port of eino-ext `parser/html` (`html.NewParser`, `Parser.Parse`), the
/// default parser of the URL loader. Get one with `HtmlParser.fromConfig` or
/// construct it directly.
///
/// The content is the text of the selected nodes (all text nodes, those of
/// `<script>` and `<style>` included, concatenated as they are), passed
/// through bluemonday's UGC policy and trimmed. bluemonday treats that text
/// as HTML, so it comes out HTML-escaped (`&` as `&amp;`, `<` as `&lt;`, `'`
/// as `&#39;`, `"` as `&#34;`), exactly as eino-ext returns it.
///
/// The metadata has the page's title ([htmlMetaKeyTitle]), description
/// ([htmlMetaKeyDescription]), language ([htmlMetaKeyLanguage]) and charset
/// ([htmlMetaKeyCharset]) when the page has them, the URI of the call under
/// [metaKeySource] and, on top, the [ParserOptions.extraMeta] of the call.
///
/// The bytes are read as UTF-8, as Go's HTML parser does (a `<meta
/// charset>` does not change that); invalid bytes become U+FFFD.
///
/// The tree is walked without recursion, so a deeply nested page is parsed
/// like any other, except that a selector other than a plain element name
/// fails with a [ThreepioFormatException] on a page nested so deeply that
/// `package:html`'s recursive evaluation overflows the stack (about ten
/// thousand levels).
final class HtmlContentParser implements Parser {
  /// A parser configured by [config].
  ///
  /// Port of eino-ext `html.NewParser`.
  const HtmlContentParser([this.config = const HtmlParserConfig()]);

  /// The configuration of this parser.
  final HtmlParserConfig config;

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final data = await readAllBytes(bytes);
    final page = html_parser.parse(utf8.decode(data, allowMalformed: true));

    final selector = config.selector;
    final contents = selector == null
        ? page.nodes.toList()
        : _contentsOf(_select(page, selector));

    final metadata = <String, Object?>{
      ..._metadataOf(page),
      metaKeySource: options?.uri ?? '',
      ...?options?.extraMeta,
    };

    final text = StringBuffer();
    for (final node in contents) {
      _writeText(node, text);
    }

    return [
      Document(
        content: goTrimSpace(sanitizeUgcText(text.toString())),
        metadata: metadata,
      ),
    ];
  }

  /// The elements of [page] that [selector] matches, in document order;
  /// none when the selector cannot be parsed (goquery's invalid matcher).
  ///
  /// A type selector (`body`, `article`) is matched here, by walking the
  /// tree without recursion; any other selector is evaluated by
  /// `package:html`, whose evaluation recurses once per level of the tree:
  /// on a page nested so deeply that it overflows the stack, the parse
  /// fails with a [ThreepioFormatException] (Go has no such limit).
  static List<dom.Element> _select(dom.Document page, String selector) {
    if (_typeSelector.hasMatch(selector)) {
      final name = _lowerAscii(selector);
      return [
        for (final element in _elementsOf(page))
          if (element.localName == name) element,
      ];
    }
    try {
      return page.querySelectorAll(selector);
    } on FormatException {
      return const [];
    }
    // package:html throws an UnimplementedError for a selector it parses but
    // cannot match (a pseudo-class it does not implement).
    // ignore: avoid_catching_errors
    on UnimplementedError {
      return const [];
    }
    // ignore: avoid_catching_errors
    on StackOverflowError catch (error) {
      throw ThreepioFormatException(
        'the page is nested too deeply to evaluate the selector',
        source: selector,
        cause: error,
      );
    }
  }

  /// A selector that is only an element name: cascadia's tag selector,
  /// which matches the element name in lower case.
  static final _typeSelector = RegExp(r'^[A-Za-z][A-Za-z0-9-]*$');

  static String _lowerAscii(String value) => String.fromCharCodes(
        value.codeUnits
            .map((unit) => unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit),
      );

  /// The elements under [root], in document order, found without
  /// recursion.
  static Iterable<dom.Element> _elementsOf(dom.Node root) sync* {
    final pending = <dom.Node>[...root.nodes.reversed];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is dom.Element) yield node;
      pending.addAll(node.nodes.reversed);
    }
  }

  /// The child nodes of [elements], each once: goquery's `Contents`.
  static List<dom.Node> _contentsOf(List<dom.Element> elements) {
    final seen = Set<dom.Node>.identity();
    return [
      for (final element in elements)
        for (final child in element.nodes)
          if (seen.add(child)) child,
    ];
  }

  /// Writes the data of every text node in [node] to [out], in document
  /// order: goquery's `Text`, without recursion.
  static void _writeText(dom.Node node, StringBuffer out) {
    final pending = <dom.Node>[node];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (next is dom.Text) {
        out.write(next.data);
      } else {
        pending.addAll(next.nodes.reversed);
      }
    }
  }

  /// The title, description, language and charset of [page], each when it
  /// is not empty. Port of eino-ext's `getMetaData`, whose selectors
  /// (`title`, `meta[name=description]`, `html`, `meta[charset]`) are
  /// matched here as cascadia matches them, by walking the tree once.
  static Map<String, Object?> _metadataOf(dom.Document page) {
    final title = StringBuffer();
    String? description;
    String? language;
    String? charset;
    for (final element in _elementsOf(page)) {
      final attributes = element.attributes;
      switch (element.localName) {
        case 'title':
          // goquery: the text of every <title>, not just the first one.
          _writeText(element, title);
        case 'meta':
          // goquery's AttrOr reads the first element the selector matches.
          if (description == null && attributes['name'] == 'description') {
            description = attributes['content'] ?? '';
          }
          if (charset == null && attributes.containsKey('charset')) {
            charset = attributes['charset'];
          }
        case 'html':
          language ??= attributes['lang'] ?? '';
      }
    }
    return {
      if (title.isNotEmpty) htmlMetaKeyTitle: title.toString(),
      if (description case final value? when value.isNotEmpty)
        htmlMetaKeyDescription: value,
      if (language case final value? when value.isNotEmpty)
        htmlMetaKeyLanguage: value,
      if (charset case final value? when value.isNotEmpty)
        htmlMetaKeyCharset: value,
    };
  }
}
