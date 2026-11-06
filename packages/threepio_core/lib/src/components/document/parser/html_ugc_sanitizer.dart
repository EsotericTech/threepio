/// The last step of eino-ext's HTML parser: bluemonday's UGC policy applied
/// to the text of the page.
///
/// eino-ext `parser/html` passes the text it extracted to
/// `bluemonday.UGCPolicy().Sanitize`. That text is not HTML, but bluemonday
/// reads it as HTML anyway, with the tokenizer of `golang.org/x/net/html`:
/// characters are HTML-escaped (`&` becomes `&amp;`, `<` `&lt;`, `'` `&#39;`,
/// `"` `&#34;`), entity references in the text are decoded first, and
/// whatever looks like a tag is kept, dropped or cut out by the policy. This
/// library ports that behaviour: the tokenizer (`token.go`), the sanitizing
/// loop (`sanitize.go`) and the UGC policy (`policies.go`, `helpers.go`).
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

import 'go_text.dart';

/// [input] sanitized by bluemonday's UGC policy.
///
/// Port of `bluemonday.UGCPolicy().Sanitize(input)` (bluemonday v1.0.27,
/// with the tokenizer of `golang.org/x/net/html` v0.41.0 and the URL
/// parser of Go's `net/url`). Input that is only white space is returned as
/// it is, as bluemonday does.
///
/// Where this differs from bluemonday: entity references are decoded by
/// `package:html`, which follows the HTML5 rules the Go tokenizer follows
/// too (the two may differ on malformed numeric references at the very end
/// of a text); the zone of an IPv6 host in a URL (`%25en0`) is not checked
/// on its own; the input is read as UTF-16 code units where Go reads bytes,
/// which finds the same tokens because every character the tokenizer
/// looks at is ASCII.
@internal
String sanitizeUgcText(String input) {
  if (goTrimSpace(input).isEmpty) return input;

  final out = StringBuffer();
  final tokenizer = _Tokenizer(input);
  var skipElementContent = false;
  var skippingElementsCount = 0;
  var skipClosingTag = false;
  final closingTagToSkipStack = <String>[];
  var mostRecentlyStartedToken = '';

  for (var token = tokenizer.next(); token != null; token = tokenizer.next()) {
    switch (token.type) {
      case _TokenType.doctype || _TokenType.comment:
        // Doctypes and comments are never written by the UGC policy.
        break;

      case _TokenType.startTag:
        mostRecentlyStartedToken = token.data;
        if (token.data == 'script' || token.data == 'style') continue;
        final policies = _ugcElements[token.data];
        if (policies == null) {
          if (_skipContentElements.contains(token.data)) {
            skipElementContent = true;
            skippingElementsCount++;
          }
          break;
        }
        var attrs = token.attrs;
        if (attrs.isNotEmpty) attrs = _sanitizeAttrs(token.data, attrs, policies);
        if (attrs.isEmpty && !_allowedWithoutAttrs.contains(token.data)) {
          skipClosingTag = true;
          closingTagToSkipStack.add(token.data);
          break;
        }
        if (!skipElementContent) out.write('<${_tagString(token.data, attrs)}>');

      case _TokenType.endTag:
        if (mostRecentlyStartedToken == token.data) mostRecentlyStartedToken = '';
        if (token.data == 'script' || token.data == 'style') continue;
        if (skipClosingTag && closingTagToSkipStack.last == token.data) {
          closingTagToSkipStack.removeLast();
          if (closingTagToSkipStack.isEmpty) skipClosingTag = false;
          break;
        }
        if (!_ugcElements.containsKey(token.data)) {
          if (_skipContentElements.contains(token.data)) {
            skippingElementsCount--;
            if (skippingElementsCount == 0) skipElementContent = false;
          }
          break;
        }
        if (!skipElementContent) out.write('</${token.data}>');

      case _TokenType.selfClosingTag:
        if (token.data == 'script' || token.data == 'style') continue;
        final policies = _ugcElements[token.data];
        if (policies == null) break;
        var attrs = token.attrs;
        if (attrs.isNotEmpty) attrs = _sanitizeAttrs(token.data, attrs, policies);
        if (attrs.isEmpty && !_allowedWithoutAttrs.contains(token.data)) break;
        if (!skipElementContent) out.write('<${_tagString(token.data, attrs)}/>');

      case _TokenType.text:
        if (skipElementContent) break;
        // The text of a script or a style is only written by a policy that
        // allows unsafe content, which the UGC policy does not.
        if (mostRecentlyStartedToken == 'script' ||
            mostRecentlyStartedToken == 'style') {
          break;
        }
        out.write(_escape(token.data));
    }
  }
  return out.toString();
}

// --- The UGC policy -------------------------------------------------------

/// An attribute policy: the attribute is allowed when its value matches
/// [pattern], or always when there is no pattern.
final class _AttrPolicy {
  const _AttrPolicy([this.pattern]);

  final RegExp? pattern;

  bool allows(String value) => pattern?.hasMatch(value) ?? true;
}

const _any = _AttrPolicy();

final _cellAlign = _AttrPolicy(
  RegExp(r'^(center|justify|left|right|char)$', caseSensitive: false),
);
final _cellVerticalAlign = _AttrPolicy(
  RegExp(r'^(baseline|bottom|middle|top)$', caseSensitive: false),
);
final _direction = _AttrPolicy(RegExp(r'^(rtl|ltr)$', caseSensitive: false));
final _imageAlign = _AttrPolicy(
  RegExp(
    '^(left|right|top|texttop|middle|absmiddle|baseline|bottom|absbottom)\$',
    caseSensitive: false,
  ),
);
final _integer = _AttrPolicy(RegExp(r'^[0-9]+$'));
final _iso8601 = _AttrPolicy(
  RegExp(
    r'^[0-9]{4}(-[0-9]{2}(-[0-9]{2}([ T][0-9]{2}(:[0-9]{2}){1,2}(.[0-9]{1,6})'
    r'?Z?([+-][0-9]{2}:[0-9]{2})?)?)?)?$',
  ),
);
final _listType = _AttrPolicy(
  RegExp(r'^(circle|disc|square|a|A|i|I|1)$', caseSensitive: false),
);
// Go's `\s` is ASCII white space: tab, newline, form feed, carriage return
// and space.
final _spaceSeparatedTokens =
    _AttrPolicy(RegExp(r'^([\t\n\f\r \p{L}\p{N}_-]+)$', unicode: true));
// bluemonday's `^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$`, written so that
// Dart's backtracking matcher fails in linear time (Go's RE2 always does) on
// a long run of digits that does not match.
final _number = _AttrPolicy(
  RegExp(r'^[-+]?(?:[0-9]+|[0-9]*\.[0-9]+)(?:[eE][-+]?[0-9]+)?$'),
);
final _numberOrPercent = _AttrPolicy(RegExp(r'^[0-9]+[%]?$'));
final _paragraph = _AttrPolicy(
  RegExp(r"^[\p{L}\p{N}\t\n\f\r \-_',\[\]!\./\\\(\)]*$", unicode: true),
);

/// The global attributes of `AllowStandardAttributes`. Go matches the `lang`
/// and `id` patterns anywhere in the value; so does `hasMatch`.
final Map<String, List<_AttrPolicy>> _globalAttrs = {
  'dir': [_direction],
  'lang': [_AttrPolicy(RegExp('[a-zA-Z]{2,20}'))],
  'id': [_AttrPolicy(RegExp(r'[a-zA-Z0-9:\-_.]+'))],
  'title': [_paragraph],
};

/// The elements of `UGCPolicy()` and their attribute policies.
final Map<String, Map<String, List<_AttrPolicy>>> _ugcElements = () {
  final elements = <String, Map<String, List<_AttrPolicy>>>{};
  void allow(List<String> names) {
    for (final name in names) {
      elements.putIfAbsent(name, () => {});
    }
  }

  void attrs(List<String> attrNames, _AttrPolicy policy, List<String> names) {
    for (final name in names) {
      final element = elements.putIfAbsent(name, () => {});
      for (final attr in attrNames) {
        element.putIfAbsent(attr, () => []).add(policy);
      }
    }
  }

  allow(['article', 'aside']);
  attrs(
    ['open'],
    _AttrPolicy(RegExp(r'^(|open)$', caseSensitive: false)),
    ['details'],
  );
  allow(['figure', 'section', 'summary']);
  allow(['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hgroup']);
  attrs(['cite'], _any, ['blockquote']);
  allow(['br', 'div', 'hr', 'p', 'span', 'wbr']);
  attrs(['href'], _any, ['a']);
  attrs(
    ['name'],
    _AttrPolicy(RegExp(r'^([\p{L}\p{N}_-]+)$', unicode: true)),
    ['map'],
  );
  attrs(['alt'], _paragraph, ['area']);
  attrs(['coords'], _AttrPolicy(RegExp(r'^([0-9]+,)+[0-9]+$')), ['area']);
  attrs(['href'], _any, ['area']);
  attrs(['rel'], _spaceSeparatedTokens, ['area']);
  attrs(
    ['shape'],
    _AttrPolicy(
      RegExp(r'^(default|circle|rect|poly)$', caseSensitive: false),
    ),
    ['area'],
  );
  attrs(
    ['usemap'],
    _AttrPolicy(
      RegExp(r'^#[\p{L}\p{N}_-]+$', caseSensitive: false, unicode: true),
    ),
    ['img'],
  );
  allow([
    'abbr', 'acronym', 'cite', 'code', 'dfn', 'em', 'figcaption', 'mark', //
    's', 'samp', 'strong', 'sub', 'sup', 'var',
  ]);
  attrs(['cite'], _any, ['q']);
  attrs(['datetime'], _iso8601, ['time']);
  allow(['b', 'i', 'pre', 'small', 'strike', 'tt', 'u']);
  attrs(['dir'], _direction, ['bdi', 'bdo']);
  allow(['rp', 'rt', 'ruby']);
  attrs(['cite'], _paragraph, ['del', 'ins']);
  attrs(['datetime'], _iso8601, ['del', 'ins']);
  // AllowLists
  attrs(['type'], _listType, ['ol', 'ul']);
  attrs(['type'], _listType, ['li']);
  attrs(['value'], _integer, ['li']);
  allow(['dl', 'dt', 'dd']);
  // AllowTables
  attrs(['height', 'width'], _numberOrPercent, ['table']);
  attrs(['summary'], _paragraph, ['table']);
  allow(['caption']);
  attrs(['align'], _cellAlign, ['col', 'colgroup']);
  attrs(['height', 'width'], _numberOrPercent, ['col', 'colgroup']);
  attrs(['span'], _integer, ['colgroup', 'col']);
  attrs(['valign'], _cellVerticalAlign, ['col', 'colgroup']);
  attrs(['align'], _cellAlign, ['thead', 'tr']);
  attrs(['valign'], _cellVerticalAlign, ['thead', 'tr']);
  attrs(['abbr'], _paragraph, ['td', 'th']);
  attrs(['align'], _cellAlign, ['td', 'th']);
  attrs(['colspan', 'rowspan'], _integer, ['td', 'th']);
  attrs(['headers'], _spaceSeparatedTokens, ['td', 'th']);
  attrs(['height', 'width'], _numberOrPercent, ['td', 'th']);
  attrs(
    ['scope'],
    _AttrPolicy(RegExp('(?:row|col)(?:group)?', caseSensitive: false)),
    ['td', 'th'],
  );
  attrs(['valign'], _cellVerticalAlign, ['td', 'th']);
  // Go's `(?i)|nowrap` has an empty alternative: it matches every value.
  attrs(['nowrap'], _any, ['td', 'th']);
  attrs(['align'], _cellAlign, ['tbody', 'tfoot']);
  attrs(['valign'], _cellVerticalAlign, ['tbody', 'tfoot']);
  // Forms: meter and progress only.
  attrs(
    ['value', 'min', 'max', 'low', 'high', 'optimum'],
    _number,
    ['meter'],
  );
  attrs(['value', 'max'], _number, ['progress']);
  // AllowImages
  attrs(['align'], _imageAlign, ['img']);
  attrs(['alt'], _paragraph, ['img']);
  attrs(['height', 'width'], _numberOrPercent, ['img']);
  attrs(['src'], _any, ['img']);
  return elements;
}();

/// bluemonday's `addDefaultElementsWithoutAttrs`: the elements that may
/// appear without any attribute.
const Set<String> _allowedWithoutAttrs = {
  'abbr', 'acronym', 'address', 'article', 'aside', 'audio', 'b', 'bdi', //
  'blockquote', 'body', 'br', 'button', 'canvas', 'caption', 'center',
  'cite', 'code', 'col', 'colgroup', 'datalist', 'dd', 'del', 'details',
  'dfn', 'div', 'dl', 'dt', 'em', 'fieldset', 'figcaption', 'figure',
  'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hgroup',
  'hr', 'html', 'i', 'ins', 'kbd', 'li', 'mark', 'marquee', 'nav', 'ol',
  'optgroup', 'option', 'p', 'picture', 'pre', 'q', 'rp', 'rt', 'ruby', 's',
  'samp', 'script', 'section', 'select', 'small', 'span', 'strike', 'strong',
  'style', 'sub', 'summary', 'sup', 'svg', 'table', 'tbody', 'td',
  'textarea', 'tfoot', 'th', 'thead', 'title', 'time', 'tr', 'tt', 'u', 'ul',
  'var', 'video', 'wbr',
};

/// bluemonday's `addDefaultSkipElementContent`: elements dropped with their
/// content.
const Set<String> _skipContentElements = {
  'frame', 'frameset', 'iframe', 'noembed', 'noframes', 'noscript', //
  'nostyle', 'object', 'script', 'style', 'title',
};

const Set<String> _allowedUrlSchemes = {'mailto', 'http', 'https'};

/// The attributes of [element] that the policy keeps. Port of bluemonday's
/// `sanitizeAttrs` for the UGC policy (no data attributes, no styles,
/// parseable URLs, `rel="nofollow"` on links).
List<_Attr> _sanitizeAttrs(
  String element,
  List<_Attr> attrs,
  Map<String, List<_AttrPolicy>> policies,
) {
  var clean = <_Attr>[];
  for (final attr in attrs) {
    final own = policies[attr.key];
    if (own != null && own.any((p) => p.allows(attr.value))) {
      clean.add(attr);
      continue;
    }
    final global = _globalAttrs[attr.key];
    if (global != null && global.any((p) => p.allows(attr.value))) {
      clean.add(attr);
    }
  }
  if (clean.isEmpty) return clean;

  final urlAttr = switch (element) {
    'a' || 'area' || 'base' || 'link' => 'href',
    'blockquote' || 'del' || 'ins' || 'q' => 'cite',
    'audio' || 'embed' || 'iframe' || 'img' || 'script' || 'source' ||
    'track' || 'video' =>
      'src',
    _ => null,
  };
  if (urlAttr != null) {
    clean = [
      for (final attr in clean)
        if (attr.key != urlAttr)
          attr
        else if (_validUrl(attr.value) case final url?)
          _Attr(attr.key, url),
    ];
  }

  // RequireNoFollowOnLinks: a link with an href gets rel="nofollow".
  if (clean.isNotEmpty &&
      const {'a', 'area', 'base', 'link'}.contains(element) &&
      clean.any((attr) => attr.key == 'href')) {
    var relFound = false;
    final withRel = <_Attr>[];
    for (final attr in clean) {
      if (attr.key != 'rel') {
        withRel.add(attr);
        continue;
      }
      relFound = true;
      withRel.add(
        attr.value.contains('nofollow')
            ? attr
            : _Attr('rel', '${attr.value} nofollow'),
      );
    }
    if (!relFound) withRel.add(const _Attr('rel', 'nofollow'));
    clean = withRel;
  }
  return clean;
}

/// The URL in [raw] if the policy accepts it, or `null`. Port of
/// bluemonday's `validURL` for `RequireParseableURLs(true)`,
/// `AllowRelativeURLs(true)` and the schemes `mailto`, `http`, `https`:
/// the URL is parsed as Go's `url.Parse` parses it and written back as
/// `URL.String` writes it.
String? _validUrl(String raw) {
  final url = goTrimSpace(raw);
  // URLs cannot contain white space, except data URIs, whose scheme the
  // policy does not allow anyway.
  if (url.contains(' ') || url.contains('\t') || url.contains('\n')) {
    return null;
  }
  final parsed = _GoUrl.parse(url);
  if (parsed == null) return null;
  if (parsed.scheme.isNotEmpty) {
    return _allowedUrlSchemes.contains(parsed.scheme) ? parsed.toString() : null;
  }
  final relative = parsed.toString();
  return relative.isEmpty ? null : relative;
}

/// The escaping modes of Go's `net/url` (`encoding`) that [_GoUrl] needs.
enum _UrlMode { path, host, userPassword, fragment }

/// A URL as Go's `url.Parse` reads it, written back by [toString] as
/// `URL.String` writes it. Only what bluemonday's use needs: a URL that Go
/// rejects is `null`, the zone of an IPv6 host is not validated on its own.
final class _GoUrl {
  _GoUrl._({
    required this.scheme,
    required this.opaque,
    required this.userinfo,
    required this.host,
    required this.rawPath,
    required this.omitHost,
    required this.forceQuery,
    required this.rawQuery,
    required this.rawFragment,
  });

  /// The scheme, in lower case; `''` for a relative URL.
  final String scheme;
  final String opaque;

  /// The user information as written (before the `@`), or `null`.
  final String? userinfo;

  /// The host (with its port), decoded.
  final String host;
  final String rawPath;
  final bool omitHost;
  final bool forceQuery;
  final String rawQuery;
  final String rawFragment;

  /// Port of Go's `url.Parse` (`parse` with `viaRequest` false), or `null`
  /// where Go returns an error.
  static _GoUrl? parse(String rawUrl) {
    final hash = rawUrl.indexOf('#');
    final u = hash < 0 ? rawUrl : rawUrl.substring(0, hash);
    final fragment = hash < 0 ? '' : rawUrl.substring(hash + 1);
    for (final unit in u.codeUnits) {
      if (unit < 0x20 || unit == 0x7F) return null;
    }
    if (_unescape(fragment, _UrlMode.fragment) == null) return null;
    if (u == '*') {
      return _GoUrl._(
        scheme: '',
        opaque: '',
        userinfo: null,
        host: '',
        rawPath: '*',
        omitHost: false,
        forceQuery: false,
        rawQuery: '',
        rawFragment: fragment,
      );
    }

    final scheme = _schemeOf(u);
    if (scheme == null) return null; // missing protocol scheme
    var rest = scheme.isEmpty ? u : u.substring(scheme.length + 1);
    var forceQuery = false;
    var rawQuery = '';
    final question = rest.indexOf('?');
    if (rest.endsWith('?') && question == rest.length - 1) {
      forceQuery = true;
      rest = rest.substring(0, rest.length - 1);
    } else if (question >= 0) {
      rawQuery = rest.substring(question + 1);
      rest = rest.substring(0, question);
    }

    if (!rest.startsWith('/')) {
      if (scheme.isNotEmpty) {
        // A rootless path is opaque, and Go checks nothing of it.
        return _GoUrl._(
          scheme: scheme.toLowerCase(),
          opaque: rest,
          userinfo: null,
          host: '',
          rawPath: '',
          omitHost: false,
          forceQuery: forceQuery,
          rawQuery: rawQuery,
          rawFragment: fragment,
        );
      }
      // The first segment of a relative path cannot contain a colon.
      if (rest.split('/').first.contains(':')) return null;
    }

    String? userinfo;
    var host = '';
    var omitHost = false;
    if ((scheme.isNotEmpty || !rest.startsWith('///')) &&
        rest.startsWith('//')) {
      var authority = rest.substring(2);
      final slash = authority.indexOf('/');
      if (slash >= 0) {
        rest = authority.substring(slash);
        authority = authority.substring(0, slash);
      } else {
        rest = '';
      }
      final at = authority.lastIndexOf('@');
      if (at >= 0) {
        userinfo = authority.substring(0, at);
        if (!_validUserinfo(userinfo) ||
            _unescape(userinfo, _UrlMode.userPassword) == null) {
          return null;
        }
      }
      final parsedHost = _parseHost(authority.substring(at + 1));
      if (parsedHost == null) return null;
      host = parsedHost;
    } else if (scheme.isNotEmpty && rest.startsWith('/')) {
      omitHost = true;
    }
    if (_unescape(rest, _UrlMode.path) == null) return null;

    return _GoUrl._(
      scheme: scheme.toLowerCase(),
      opaque: '',
      userinfo: userinfo,
      host: host,
      rawPath: rest,
      omitHost: omitHost,
      forceQuery: forceQuery,
      rawQuery: rawQuery,
      rawFragment: fragment,
    );
  }

  /// Port of Go's `URL.String`.
  @override
  String toString() {
    final out = StringBuffer();
    if (scheme.isNotEmpty) out.write('$scheme:');
    if (opaque.isNotEmpty) {
      out.write(opaque);
    } else {
      final user = userinfo;
      if (scheme.isNotEmpty || host.isNotEmpty || user != null) {
        if (!(omitHost && host.isEmpty && user == null)) {
          if (host.isNotEmpty || rawPath.isNotEmpty || user != null) {
            out.write('//');
          }
          if (user != null) out.write('${_userinfoString(user)}@');
          if (host.isNotEmpty) out.write(_urlEscape(host, _UrlMode.host));
        }
      }
      final path = _escaped(rawPath, _UrlMode.path);
      if (path.isNotEmpty && !path.startsWith('/') && host.isNotEmpty) {
        out.write('/');
      }
      if (out.isEmpty && path.split('/').first.contains(':')) out.write('./');
      out.write(path);
    }
    if (forceQuery || rawQuery.isNotEmpty) out.write('?$rawQuery');
    if (rawFragment.isNotEmpty) {
      out.write('#${_escaped(rawFragment, _UrlMode.fragment)}');
    }
    return out.toString();
  }

  /// Go's `Userinfo.String` of the user information [raw]: the user name
  /// and the password, each decoded and escaped again.
  static String _userinfoString(String raw) {
    final colon = raw.indexOf(':');
    final name = colon < 0 ? raw : raw.substring(0, colon);
    final out = StringBuffer(
      _urlEscape(_unescape(name, _UrlMode.userPassword)!, _UrlMode.userPassword),
    );
    if (colon >= 0) {
      final password = raw.substring(colon + 1);
      out
        ..write(':')
        ..write(
          _urlEscape(
            _unescape(password, _UrlMode.userPassword)!,
            _UrlMode.userPassword,
          ),
        );
    }
    return out.toString();
  }

  /// The text Go writes for a path or fragment written as [raw]
  /// (`EscapedPath`, `EscapedFragment`): [raw] itself when it is validly
  /// encoded, otherwise its decoded text escaped again.
  static String _escaped(String raw, _UrlMode mode) =>
      _validEncoded(raw, mode) ? raw : _urlEscape(_unescape(raw, mode)!, mode);

  /// Port of Go's `parseHost`: the decoded host, or `null`.
  static String? _parseHost(String host) {
    if (host.startsWith('[')) {
      final close = host.lastIndexOf(']');
      if (close < 0) return null; // missing ']' in host
      if (!_validOptionalPort(host.substring(close + 1))) return null;
    } else {
      final colon = host.lastIndexOf(':');
      if (colon >= 0 && !_validOptionalPort(host.substring(colon))) {
        return null;
      }
    }
    return _unescape(host, _UrlMode.host);
  }

  static bool _validOptionalPort(String port) {
    if (port.isEmpty) return true;
    if (port.codeUnitAt(0) != 0x3A) return false;
    for (final unit in port.codeUnits.skip(1)) {
      if (unit < 0x30 || unit > 0x39) return false;
    }
    return true;
  }

  /// Port of Go's `validUserinfo`.
  static bool _validUserinfo(String value) {
    for (final rune in value.runes) {
      if (_isAlphanumeric(rune)) continue;
      if (!"-._:~!\$&'()*+,;=%@".codeUnits.contains(rune)) return false;
    }
    return true;
  }
}

bool _isAlphanumeric(int c) =>
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39);

/// Port of Go's `url.unescape`: [value] with its `%` escapes decoded (as
/// UTF-8, invalid sequences as U+FFFD), or `null` where Go fails.
String? _unescape(String value, _UrlMode mode) {
  final runes = value.runes.toList();
  final bytes = <int>[];
  for (var i = 0; i < runes.length;) {
    final c = runes[i];
    if (c == 0x25) {
      if (i + 2 >= runes.length || !_isHex(runes[i + 1]) || !_isHex(runes[i + 2])) {
        return null;
      }
      final byte = int.parse(String.fromCharCodes(runes, i + 1, i + 3), radix: 16);
      // A host can only escape bytes that are not ASCII, or a percent sign.
      if (mode == _UrlMode.host && byte < 0x80 && byte != 0x25) return null;
      bytes.add(byte);
      i += 3;
      continue;
    }
    if (mode == _UrlMode.host && c < 0x80 && _shouldEscape(c, mode)) {
      return null;
    }
    bytes.addAll(utf8.encode(String.fromCharCode(c)));
    i++;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Port of Go's `url.escape`: the bytes Go escapes in [mode] as `%XX`.
String _urlEscape(String value, _UrlMode mode) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (_shouldEscape(byte, mode)) {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      out.writeCharCode(byte);
    }
  }
  return out.toString();
}

/// Port of Go's `url.validEncoded`.
bool _validEncoded(String value, _UrlMode mode) {
  for (final unit in value.codeUnits) {
    if ("!\$&'()*+,;=:@[]%".codeUnits.contains(unit)) continue;
    if (unit >= 0x80 || _shouldEscape(unit, mode)) return false;
  }
  return true;
}

/// Port of Go's `url.shouldEscape` for the modes of [_UrlMode].
bool _shouldEscape(int c, _UrlMode mode) {
  if (_isAlphanumeric(c)) return false;
  if (mode == _UrlMode.host &&
      "!\$&'()*+,;=:[]<>\"".codeUnits.contains(c)) {
    return false;
  }
  switch (c) {
    case 0x2D || 0x5F || 0x2E || 0x7E: // - _ . ~
      return false;
    case 0x24 || 0x26 || 0x2B || 0x2C || 0x2F || 0x3A || 0x3B || 0x3D || //
          0x3F || 0x40: // $ & + , / : ; = ? @
      return switch (mode) {
        _UrlMode.path => c == 0x3F,
        _UrlMode.userPassword =>
          c == 0x40 || c == 0x2F || c == 0x3F || c == 0x3A,
        _UrlMode.fragment => false,
        _UrlMode.host => true,
      };
  }
  if (mode == _UrlMode.fragment &&
      (c == 0x21 || c == 0x28 || c == 0x29 || c == 0x2A)) {
    return false;
  }
  return true;
}

/// The scheme of [url] as Go's `url.getScheme` finds it: `''` when there is
/// none, `null` when the URL starts with `:` (an error in Go).
String? _schemeOf(String url) {
  for (var i = 0; i < url.length; i++) {
    final c = url.codeUnitAt(i);
    final isLetter = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);
    if (isLetter) continue;
    final isRest = (c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2D || c == 0x2E;
    if (isRest) {
      if (i == 0) return '';
      continue;
    }
    if (c == 0x3A) return i == 0 ? null : url.substring(0, i);
    return '';
  }
  return '';
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46);

/// [value] escaped like Go's `html.EscapeString`.
String _escape(String value) {
  final out = StringBuffer();
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x26:
        out.write('&amp;');
      case 0x27:
        out.write('&#39;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      case 0x22:
        out.write('&#34;');
      case 0x0D:
        out.write('&#13;');
      default:
        out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// The name and attributes of a tag, as Go's `Token.tagString` writes them.
String _tagString(String name, List<_Attr> attrs) {
  if (attrs.isEmpty) return name;
  final out = StringBuffer(name);
  for (final attr in attrs) {
    out.write(' ${attr.key}="${_escape(attr.value)}"');
  }
  return out.toString();
}

// --- The tokenizer ----------------------------------------------------------

enum _TokenType { text, startTag, endTag, selfClosingTag, comment, doctype }

/// The states of Go's `readScript`, named after its labels.
enum _ScriptState {
  data,
  lessThanSign,
  endTagOpen,
  escapeStart,
  escapeStartDash,
  escaped,
  escapedDash,
  escapedDashDash,
  escapedLessThanSign,
  escapedEndTagOpen,
  doubleEscapeStart,
  doubleEscaped,
  doubleEscapedDash,
  doubleEscapedDashDash,
  doubleEscapedLessThanSign,
  doubleEscapeEnd,
}

final class _Attr {
  const _Attr(this.key, this.value);

  final String key;
  final String value;
}

final class _Token {
  const _Token(this.type, [this.data = '', this.attrs = const []]);

  final _TokenType type;

  /// The text of a text token, the lower-case name of a tag.
  final String data;

  final List<_Attr> attrs;
}

/// Port of the tokenizer of `golang.org/x/net/html` (`token.go`), reading
/// a string instead of bytes. Every character the tokenizer looks at is
/// ASCII, so working on UTF-16 code units finds the same tokens.
///
/// [next] returns `null` where Go returns an `ErrorToken`: at the end of the
/// input, and also when the input ends inside a tag (Go drops that tag and
/// bluemonday stops there).
final class _Tokenizer {
  _Tokenizer(this._s);

  final String _s;

  /// `raw.end`: the read position.
  int _pos = 0;
  int _rawStart = 0;
  int _dataStart = 0;
  int _dataEnd = 0;

  /// Set once a read hits the end of the input (Go: `z.err = io.EOF`).
  bool _eof = false;
  String _rawTag = '';
  bool _textIsRaw = false;
  bool _convertNul = false;
  final List<(int, int, int, int)> _attrs = [];
  int _keyStart = 0;
  int _keyEnd = 0;
  int _valStart = 0;
  int _valEnd = 0;

  int _readByte() {
    if (_pos >= _s.length) {
      _eof = true;
      return 0;
    }
    return _s.codeUnitAt(_pos++);
  }

  static bool _isWhite(int c) =>
      c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C;

  static bool _isLetter(int c) =>
      (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);

  _Token? next() {
    _rawStart = _pos;
    _dataStart = _pos;
    _dataEnd = _pos;
    if (_eof) return null;
    if (_rawTag.isNotEmpty) {
      if (_rawTag == 'plaintext') {
        while (!_eof) {
          _readByte();
        }
        _dataEnd = _pos;
        _textIsRaw = true;
      } else {
        _readRawOrRcdata();
      }
      if (_dataEnd > _dataStart) {
        _convertNul = true;
        return _Token(_TokenType.text, _text());
      }
    }
    _textIsRaw = false;
    _convertNul = false;

    while (true) {
      var c = _readByte();
      if (_eof) break;
      if (c != 0x3C) continue; // '<'
      c = _readByte();
      if (_eof) break;
      final _TokenType type;
      if (_isLetter(c)) {
        type = _TokenType.startTag;
      } else if (c == 0x2F) {
        type = _TokenType.endTag;
      } else if (c == 0x21 || c == 0x3F) {
        type = _TokenType.comment;
      } else {
        _pos--;
        continue;
      }
      // A tag-like sequence follows text: return the text first.
      final x = _pos - 2;
      if (_rawStart < x) {
        _pos = x;
        _dataEnd = x;
        return _Token(_TokenType.text, _text());
      }
      switch (type) {
        case _TokenType.startTag:
          return _readStartTag();
        case _TokenType.endTag:
          c = _readByte();
          if (_eof) return _textAtEnd();
          if (c == 0x3E) return const _Token(_TokenType.comment); // '</>'
          if (_isLetter(c)) {
            _readTag(saveAttrs: false);
            if (_eof) return null;
            return _Token(_TokenType.endTag, _tagName());
          }
          _pos--;
          _readUntilCloseAngle();
          return const _Token(_TokenType.comment);
        default: // comment
          if (c == 0x21) return _readMarkupDeclaration();
          _pos--;
          _readUntilCloseAngle();
          return const _Token(_TokenType.comment);
      }
    }
    return _textAtEnd();
  }

  /// What Go's `Next` returns once the input has ended in the main loop.
  _Token? _textAtEnd() {
    if (_rawStart < _pos) {
      _dataEnd = _pos;
      return _Token(_TokenType.text, _text());
    }
    return null;
  }

  void _skipWhiteSpace() {
    if (_eof) return;
    while (true) {
      final c = _readByte();
      if (_eof) return;
      if (!_isWhite(c)) {
        _pos--;
        return;
      }
    }
  }

  /// Raw text or RCDATA up to the end tag of [_rawTag]. Port of Go's
  /// `readRawOrRCDATA`.
  void _readRawOrRcdata() {
    if (_rawTag == 'script') {
      _readScript();
      _textIsRaw = true;
      _rawTag = '';
      return;
    }
    while (true) {
      var c = _readByte();
      if (_eof) break;
      if (c != 0x3C) continue;
      c = _readByte();
      if (_eof) break;
      if (c != 0x2F) {
        _pos--;
        continue;
      }
      if (_readRawEndTag() || _eof) break;
    }
    _dataEnd = _pos;
    _textIsRaw = _rawTag != 'textarea' && _rawTag != 'title';
    _rawTag = '';
  }

  /// Script data up to its end tag, with the escape states of the HTML5
  /// tokenizer (`<!--` and `<script>` inside a script). Port of Go's
  /// `readScript`, its labels as the states of a loop.
  void _readScript() {
    var state = _ScriptState.data;
    while (true) {
      switch (state) {
        case _ScriptState.data:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x3C) state = _ScriptState.lessThanSign;
          continue;
        case _ScriptState.lessThanSign:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2F) {
            state = _ScriptState.endTagOpen;
          } else if (c == 0x21) {
            state = _ScriptState.escapeStart;
          } else {
            _pos--;
            state = _ScriptState.data;
          }
          continue;
        case _ScriptState.endTagOpen:
          if (_readRawEndTag() || _eof) break;
          state = _ScriptState.data;
          continue;
        case _ScriptState.escapeStart:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2D) {
            state = _ScriptState.escapeStartDash;
          } else {
            _pos--;
            state = _ScriptState.data;
          }
          continue;
        case _ScriptState.escapeStartDash:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2D) {
            state = _ScriptState.escapedDashDash;
          } else {
            _pos--;
            state = _ScriptState.data;
          }
          continue;
        case _ScriptState.escaped:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2D) {
            state = _ScriptState.escapedDash;
          } else if (c == 0x3C) {
            state = _ScriptState.escapedLessThanSign;
          }
          continue;
        case _ScriptState.escapedDash:
          final c = _readByte();
          if (_eof) break;
          state = switch (c) {
            0x2D => _ScriptState.escapedDashDash,
            0x3C => _ScriptState.escapedLessThanSign,
            _ => _ScriptState.escaped,
          };
          continue;
        case _ScriptState.escapedDashDash:
          final c = _readByte();
          if (_eof) break;
          state = switch (c) {
            0x2D => _ScriptState.escapedDashDash,
            0x3C => _ScriptState.escapedLessThanSign,
            0x3E => _ScriptState.data,
            _ => _ScriptState.escaped,
          };
          continue;
        case _ScriptState.escapedLessThanSign:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2F) {
            state = _ScriptState.escapedEndTagOpen;
          } else if (_isLetter(c)) {
            state = _ScriptState.doubleEscapeStart;
          } else {
            _pos--;
            state = _ScriptState.data;
          }
          continue;
        case _ScriptState.escapedEndTagOpen:
          if (_readRawEndTag() || _eof) break;
          state = _ScriptState.escaped;
          continue;
        case _ScriptState.doubleEscapeStart:
          _pos--;
          state = _ScriptState.doubleEscaped;
          for (var i = 0; i < 6; i++) {
            final c = _readByte();
            if (_eof) break;
            if (c != 'script'.codeUnitAt(i) && c != 'SCRIPT'.codeUnitAt(i)) {
              _pos--;
              state = _ScriptState.escaped;
              break;
            }
          }
          if (_eof) break;
          if (state == _ScriptState.escaped) continue;
          final c = _readByte();
          if (_eof) break;
          if (!_isWhite(c) && c != 0x2F && c != 0x3E) {
            _pos--;
            state = _ScriptState.escaped;
          }
          continue;
        case _ScriptState.doubleEscaped:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2D) {
            state = _ScriptState.doubleEscapedDash;
          } else if (c == 0x3C) {
            state = _ScriptState.doubleEscapedLessThanSign;
          }
          continue;
        case _ScriptState.doubleEscapedDash:
          final c = _readByte();
          if (_eof) break;
          state = switch (c) {
            0x2D => _ScriptState.doubleEscapedDashDash,
            0x3C => _ScriptState.doubleEscapedLessThanSign,
            _ => _ScriptState.doubleEscaped,
          };
          continue;
        case _ScriptState.doubleEscapedDashDash:
          final c = _readByte();
          if (_eof) break;
          state = switch (c) {
            0x2D => _ScriptState.doubleEscapedDashDash,
            0x3C => _ScriptState.doubleEscapedLessThanSign,
            0x3E => _ScriptState.data,
            _ => _ScriptState.doubleEscaped,
          };
          continue;
        case _ScriptState.doubleEscapedLessThanSign:
          final c = _readByte();
          if (_eof) break;
          if (c == 0x2F) {
            state = _ScriptState.doubleEscapeEnd;
          } else {
            _pos--;
            state = _ScriptState.doubleEscaped;
          }
          continue;
        case _ScriptState.doubleEscapeEnd:
          if (_readRawEndTag()) {
            _pos += '</script>'.length;
            state = _ScriptState.escaped;
            continue;
          }
          if (_eof) break;
          state = _ScriptState.doubleEscaped;
          continue;
      }
      break;
    }
    _dataEnd = _pos;
  }

  bool _readRawEndTag() {
    for (var i = 0; i < _rawTag.length; i++) {
      final c = _readByte();
      if (_eof) return false;
      final want = _rawTag.codeUnitAt(i);
      if (c != want && c != want - 0x20) {
        _pos--;
        return false;
      }
    }
    final c = _readByte();
    if (_eof) return false;
    if (_isWhite(c) || c == 0x2F || c == 0x3E) {
      _pos -= 3 + _rawTag.length;
      return true;
    }
    _pos--;
    return false;
  }

  void _readComment() {
    var dashCount = 0;
    var beginning = true;
    while (true) {
      var c = _readByte();
      if (_eof) return;
      if (c == 0x2D) {
        dashCount++;
        continue;
      }
      if (c == 0x3E && (dashCount >= 2 || beginning)) return;
      if (c == 0x21 && dashCount >= 2) {
        c = _readByte();
        if (_eof || c == 0x3E) return;
        if (c == 0x2D) {
          dashCount = 1;
          beginning = false;
          continue;
        }
      }
      dashCount = 0;
      beginning = false;
    }
  }

  void _readUntilCloseAngle() {
    _dataStart = _pos;
    while (true) {
      final c = _readByte();
      if (_eof) {
        _dataEnd = _pos;
        return;
      }
      if (c == 0x3E) {
        _dataEnd = _pos - 1;
        return;
      }
    }
  }

  _Token _readMarkupDeclaration() {
    _dataStart = _pos;
    final first = _readByte();
    if (_eof) return const _Token(_TokenType.comment);
    final second = _readByte();
    if (_eof) return const _Token(_TokenType.comment);
    if (first == 0x2D && second == 0x2D) {
      _readComment();
      return const _Token(_TokenType.comment);
    }
    _pos -= 2;
    if (_readDoctype()) return const _Token(_TokenType.doctype);
    _readUntilCloseAngle();
    return const _Token(_TokenType.comment);
  }

  bool _readDoctype() {
    const doctype = 'DOCTYPE';
    for (var i = 0; i < doctype.length; i++) {
      final c = _readByte();
      if (_eof) return false;
      final want = doctype.codeUnitAt(i);
      if (c != want && c != want + 0x20) {
        _pos = _dataStart;
        return false;
      }
    }
    _skipWhiteSpace();
    if (_eof) return true;
    _readUntilCloseAngle();
    return true;
  }

  _Token? _readStartTag() {
    _readTag(saveAttrs: true);
    if (_eof) return null;
    final name = _lower(_s.substring(_dataStart, _dataEnd));
    if (const {
      'iframe', 'noembed', 'noframes', 'noscript', 'plaintext', 'script', //
      'style', 'textarea', 'title', 'xmp',
    }.contains(name)) {
      _rawTag = name;
    }
    final attrs = [
      for (final (keyStart, keyEnd, valStart, valEnd) in _attrs)
        _Attr(
          _lower(_s.substring(keyStart, keyEnd)),
          _unescapeAttr(_convertNewlines(_s.substring(valStart, valEnd))),
        ),
    ];
    final selfClosing = _s.codeUnitAt(_pos - 2) == 0x2F &&
        (_attrs.isEmpty || _pos - 2 != _attrs.last.$4 - 1);
    return _Token(
      selfClosing ? _TokenType.selfClosingTag : _TokenType.startTag,
      name,
      attrs,
    );
  }

  String _tagName() => _lower(_s.substring(_dataStart, _dataEnd));

  void _readTag({required bool saveAttrs}) {
    _attrs.clear();
    _readTagName();
    _skipWhiteSpace();
    if (_eof) return;
    while (true) {
      final c = _readByte();
      if (_eof || c == 0x3E) break;
      _pos--;
      _readTagAttrKey();
      _readTagAttrVal();
      if (saveAttrs && _keyStart != _keyEnd) {
        _attrs.add((_keyStart, _keyEnd, _valStart, _valEnd));
      }
      _skipWhiteSpace();
      if (_eof) break;
    }
  }

  void _readTagName() {
    _dataStart = _pos - 1;
    while (true) {
      final c = _readByte();
      if (_eof) {
        _dataEnd = _pos;
        return;
      }
      if (_isWhite(c)) {
        _dataEnd = _pos - 1;
        return;
      }
      if (c == 0x2F || c == 0x3E) {
        _pos--;
        _dataEnd = _pos;
        return;
      }
    }
  }

  void _readTagAttrKey() {
    _keyStart = _pos;
    while (true) {
      final c = _readByte();
      if (_eof) {
        _keyEnd = _pos;
        return;
      }
      if (c == 0x3D && _keyStart + 1 == _pos) continue; // a leading '='
      if (c == 0x3D || _isWhite(c) || c == 0x2F || c == 0x3E) {
        _pos--;
        _keyEnd = _pos;
        return;
      }
    }
  }

  void _readTagAttrVal() {
    _valStart = _pos;
    _valEnd = _pos;
    _skipWhiteSpace();
    if (_eof) return;
    var c = _readByte();
    if (_eof) return;
    if (c == 0x2F) return;
    if (c != 0x3D) {
      _pos--;
      return;
    }
    _skipWhiteSpace();
    if (_eof) return;
    final quote = _readByte();
    if (_eof) return;
    if (quote == 0x3E) {
      _pos--;
      return;
    }
    if (quote == 0x27 || quote == 0x22) {
      _valStart = _pos;
      while (true) {
        c = _readByte();
        if (_eof) {
          _valEnd = _pos;
          return;
        }
        if (c == quote) {
          _valEnd = _pos - 1;
          return;
        }
      }
    }
    _valStart = _pos - 1;
    while (true) {
      c = _readByte();
      if (_eof) {
        _valEnd = _pos;
        return;
      }
      if (_isWhite(c)) {
        _valEnd = _pos - 1;
        return;
      }
      if (c == 0x3E) {
        _pos--;
        _valEnd = _pos;
        return;
      }
    }
  }

  /// The data of the current text token, as Go's `Tokenizer.Text` returns
  /// it: newlines normalized, NUL replaced in raw text, entity references
  /// decoded unless the text is raw.
  String _text() {
    var text = _convertNewlines(_s.substring(_dataStart, _dataEnd));
    final nul = String.fromCharCode(0);
    if (_convertNul && text.contains(nul)) {
      text = text.replaceAll(nul, String.fromCharCode(0xFFFD));
    }
    return _textIsRaw ? text : _unescapeText(text);
  }

  static String _lower(String value) {
    final out = StringBuffer();
    for (final unit in value.codeUnits) {
      out.writeCharCode(unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit);
    }
    return out.toString();
  }

  /// Go's `convertNewlines`: `\r\n` and lone `\r` become `\n`.
  static String _convertNewlines(String value) => value.contains('\r')
      ? value.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
      : value;

  /// Character references in text decoded the way HTML5 decodes them in
  /// data (Go's `unescape(s, false)`), by `package:html`. The text holds no
  /// tag: the tokenizer cut it before anything that starts one.
  static String _unescapeText(String text) {
    if (!text.contains('&')) return text;
    return html_parser.parseFragment(text).text ?? text;
  }

  /// Character references in an attribute value decoded the way HTML5
  /// decodes them in attributes (Go's `unescape(s, true)`).
  static String _unescapeAttr(String value) {
    if (!value.contains('&')) return value;
    final fragment =
        html_parser.parseFragment('<i a="${value.replaceAll('"', '&quot;')}">');
    final element = fragment.nodes.whereType<dom.Element>().firstOrNull;
    return element?.attributes['a'] ?? value;
  }
}
