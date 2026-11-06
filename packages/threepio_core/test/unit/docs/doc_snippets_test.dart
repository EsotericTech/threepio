// Every ```dart block of the package's Markdown documents must compile.
//
// The analyzer cannot read Markdown, so each block is mirrored in a Dart file
// the analyzer checks (`dart analyze test example`): an example under
// `example/`, or a file under `test/doc_snippets/` written for the purpose.
// This test keeps the documents and the mirrors in step: a block passes when
// some mirror contains it.
//
// What "contains" means, line by line after trimming each line and dropping
// blank lines:
// * the block's `import`/`export`/`library`/`part` lines are directives of
//   the mirror (lines that start in code), in any order;
// * the block's other lines appear in the mirror as one contiguous run, so a
//   mirror may wrap a block in a function and declare what it uses around
//   it, but not change it;
// * every line is compared together with its lexical signature (which of
//   its characters are code, comment or string), so a block hidden in a
//   comment or a string literal of a mirror does not count.
//
// A Dart block is any fenced block whose info string starts with `dart` (any
// case, ``` or ~~~ of any length, inside a list or a block quote). Blocks
// that are not meant to compile are fenced with another language (```text,
// ```go, ```yaml, ```bash). Documents that are kept only as a
// record (the superseded parity plan, the CHANGELOG) are not checked.
import 'dart:io';

import 'package:test/test.dart';

/// Documents whose ```dart blocks are not checked, with the reason.
const _exempt = {
  'CHANGELOG.md': 'release notes; history, not instructions',
  'doc/eino_feature_parity_plan.md': 'superseded design plan, kept as a record',
};

/// Where mirrors are looked for.
const _mirrorDirectories = ['example', 'test/doc_snippets'];

final _directive = RegExp(r'^(import|export|library|part)\b');

void main() {
  final mirrors = _loadMirrors();

  final documents = _documents();

  test('there are mirror files', () {
    expect(mirrors, isNotEmpty);
  });

  test('the documents are found (run from the package directory)', () {
    expect(
      documents.map((d) => d.label),
      containsAll(<String>[
        'README.md',
        'doc/CALLBACKS.md',
        'doc/GRAPHS.md',
        'doc/LANGFUSE_DESIGN.md',
        'doc/MIGRATION.md',
        'doc/NEW_FEATURES.md',
        'doc/RAG.md',
      ]),
    );
  });

  for (final document in documents) {
    final blocks = _dartBlocks(document);
    group(document.label, () {
      for (final block in blocks) {
        test('```dart block at line ${block.line} compiles (has a mirror)', () {
          final match = mirrors.where(block.isContainedIn).firstOrNull;
          expect(
            match,
            isNotNull,
            reason: 'No file under ${_mirrorDirectories.join(' or ')} '
                'contains this block of ${document.label} '
                '(line ${block.line}):\n${block.preview}',
          );
        });
      }
    });
  }
}

/// A Markdown document of the package, read from disk.
final class _Document {
  _Document(this.label, this.file);

  final String label;
  final File file;
}

/// The Markdown documents to check: the package README, `doc/`, `example/`,
/// and the repository README when the package sits in its repository.
List<_Document> _documents() {
  final documents = <_Document>[];
  void add(String label, File file) {
    if (_exempt.containsKey(label) || !file.existsSync()) return;
    documents.add(_Document(label, file));
  }

  for (final entity in Directory('.').listSync()) {
    if (entity is File && entity.path.endsWith('.md')) {
      add(entity.uri.pathSegments.last, entity);
    }
  }
  for (final directory in ['doc', 'example']) {
    final dir = Directory(directory);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.md')) {
        final relative = entity.path.startsWith('./')
            ? entity.path.substring(2)
            : entity.path;
        add(relative, entity);
      }
    }
  }
  add('../../README.md (repository root)', File('../../README.md'));
  documents.sort((a, b) => a.label.compareTo(b.label));
  return documents;
}

/// A ```dart block of a document.
final class _Block {
  _Block(this.line, List<String> lines)
      : directives = {
          for (final l in _significant(lines))
            if (_directive.hasMatch(l)) l,
        },
        body = [
          for (final l in _significant(lines))
            if (!_directive.hasMatch(l)) l,
        ],
        preview = lines.take(12).join('\n');
  // Body and directive entries are "text\u0000signature"; see _significant.

  /// The line of the opening fence, counted from 1.
  final int line;
  final Set<String> directives;
  final List<String> body;
  final String preview;

  bool isContainedIn(_Mirror mirror) =>
      mirror.directives.containsAll(directives) &&
      _containsRun(mirror.lines, body);
}

/// A Dart file that may mirror blocks.
final class _Mirror {
  _Mirror(this.path, List<String> rawLines)
      : lines = _significant(rawLines).toList(),
        directives = {
          for (final l in _significant(rawLines))
            if (_directive.hasMatch(l) && l.contains('\u0000c')) l,
        };

  final String path;
  final List<String> lines;
  final Set<String> directives;
}

List<_Mirror> _loadMirrors() => [
      for (final directory in _mirrorDirectories)
        if (Directory(directory).existsSync())
          for (final entity in Directory(directory).listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.dart'))
              _Mirror(entity.path, entity.readAsLinesSync()),
    ];

/// The ```dart blocks of [document]. Fences may be indented (inside lists)
/// or quoted (inside a `>` block quote); the same prefix is taken off the
/// lines of the block.
List<_Block> _dartBlocks(_Document document) {
  final lines = document.file.readAsLinesSync();
  final blocks = <_Block>[];
  final opening = RegExp(r'^((?:\s*>)*\s*)(`{3,}|~{3,})\s*dart\b[^`]*$',
      caseSensitive: false);
  final quote = RegExp(r'^(?:\s*>)+ ?');
  for (var i = 0; i < lines.length; i++) {
    final open = opening.firstMatch(lines[i]);
    if (open == null) continue;
    final prefix = open.group(1)!;
    final fence = open.group(2)!;
    final closing =
        RegExp('^${RegExp.escape(fence[0])}{${fence.length},}' r'\s*$');
    String strip(String l) {
      if (l.startsWith(prefix)) return l.substring(prefix.length);
      return prefix.contains('>') ? l.replaceFirst(quote, '') : l;
    }

    final body = <String>[];
    var j = i + 1;
    while (j < lines.length && !closing.hasMatch(strip(lines[j]).trimLeft())) {
      body.add(strip(lines[j]));
      j++;
    }
    blocks.add(_Block(i + 1, body));
    i = j;
  }
  return blocks;
}

/// The lines that count: trimmed, without blank lines, each followed by
/// NUL and its lexical signature (one of c/m/s per non-blank character), so
/// a line only matches a line that is code (or comment, or string) in the
/// same places: a block hidden in a comment or a string does not match.
Iterable<String> _significant(Iterable<String> lines) {
  final list = lines.toList();
  final classes = _lex(list.join('\n'));
  final out = <String>[];
  var pos = 0;
  for (final l in list) {
    final sig = StringBuffer();
    for (var k = 0; k < l.length; k++) {
      if (l[k].trim().isNotEmpty) sig.write(classes[pos + k]);
    }
    pos += l.length + 1;
    if (l.trim().isNotEmpty) out.add('${l.trim()}\u0000$sig');
  }
  return out;
}

/// The class of every character of [text]: c code, m comment, s string.
/// Handles nested block comments, raw and triple-quoted strings and
/// `${...}` interpolation.
List<String> _lex(String text) {
  final cls = List.filled(text.length, 'c');
  final stack = <List<Object>>[['code', 0, false]];
  bool ident(int i) => i >= 0 && RegExp(r'[\w$]').hasMatch(text[i]);
  var i = 0;
  while (i < text.length) {
    final top = stack.last;
    final ch = text[i];
    if (top[0] == 'code') {
      if (text.startsWith('//', i)) {
        while (i < text.length && text[i] != '\n') {
          cls[i++] = 'm';
        }
      } else if (text.startsWith('/*', i)) {
        stack.add(['bc', 1]);
        cls[i] = cls[i + 1] = 'm';
        i += 2;
      } else if (ch == "'" || ch == '"') {
        final raw = i > 0 && text[i - 1] == 'r' && !ident(i - 2);
        final q = text.startsWith(ch * 3, i) ? ch * 3 : ch;
        if (raw) cls[i - 1] = 's';
        for (var k = 0; k < q.length; k++) {
          cls[i + k] = 's';
        }
        stack.add(['str', q, raw]);
        i += q.length;
      } else {
        if (ch == '{') top[1] = (top[1] as int) + 1;
        if (ch == '}') {
          if (top[2] == true && top[1] == 0) {
            stack.removeLast();
            cls[i++] = 's';
            continue;
          }
          top[1] = (top[1] as int) - 1;
        }
        i++;
      }
    } else if (top[0] == 'bc') {
      if (text.startsWith('/*', i) || text.startsWith('*/', i)) {
        top[1] = (top[1] as int) + (text[i] == '/' ? 1 : -1);
        cls[i] = cls[i + 1] = 'm';
        i += 2;
        if (top[1] == 0) stack.removeLast();
      } else {
        cls[i++] = 'm';
      }
    } else {
      final q = top[1] as String;
      final raw = top[2] as bool;
      if (!raw && ch == r'\' && i + 1 < text.length) {
        cls[i] = cls[i + 1] = 's';
        i += 2;
      } else if (!raw && text.startsWith(r'${', i)) {
        cls[i] = cls[i + 1] = 's';
        stack.add(['code', 0, true]);
        i += 2;
      } else if (text.startsWith(q, i)) {
        for (var k = 0; k < q.length; k++) {
          cls[i + k] = 's';
        }
        stack.removeLast();
        i += q.length;
      } else if (ch == '\n' && q.length == 1) {
        stack.removeLast();
        i++;
      } else {
        cls[i++] = 's';
      }
    }
  }
  return cls;
}

/// Whether [needle] occurs in [haystack] as one contiguous run.
bool _containsRun(List<String> haystack, List<String> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var k = 0;
    while (k < needle.length && haystack[start + k] == needle[k]) {
      k++;
    }
    if (k == needle.length) return true;
  }
  return false;
}
