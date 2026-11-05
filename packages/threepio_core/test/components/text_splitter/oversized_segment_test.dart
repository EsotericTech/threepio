import 'package:test/test.dart';
import 'package:threepio_core/src/components/text_splitter/fixed_size_split.dart';
import 'package:threepio_core/src/components/text_splitter/html_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/markdown_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/recursive_character_text_splitter.dart';
import 'package:threepio_core/src/components/text_splitter/text_splitter.dart';

/// A run of [length] characters without whitespace or punctuation, so no
/// splitter finds a separator in it. The characters vary so that a chunk can be
/// located in the original text.
String unsplittable(int length) => String.fromCharCodes(
      Iterable.generate(length, (i) => 0x61 + (i * 7 + i ~/ 26) % 26),
    );

/// Rebuilds the text from windows that overlap by [chunkOverlap] characters.
String joinOverlapping(List<String> chunks, int chunkOverlap) {
  if (chunks.isEmpty) return '';
  final buffer = StringBuffer(chunks.first);
  for (final chunk in chunks.skip(1)) {
    buffer.write(chunk.substring(chunkOverlap));
  }
  return buffer.toString();
}

void main() {
  // Before the fix each of these looped forever, appending the tail of the
  // segment until the process ran out of memory.
  group('oversized segment without separators and chunkOverlap > 0', () {
    const options = TextSplitterOptions(chunkSize: 100, chunkOverlap: 50);
    final segment = unsplittable(1000);

    test('MarkdownSplitter terminates', () {
      final chunks = MarkdownSplitter().splitText(
        '# Title\n\n$segment\n',
        options: options,
      );

      expect(chunks, isNotEmpty);
      expect(chunks.length, lessThan(segment.length));
      expect(chunks.every((c) => c.length <= options.chunkSize), isTrue);
      expect(chunks.join(), contains(segment.substring(0, 50)));
      expect(chunks.last, endsWith(segment.substring(950)));
    });

    test('HtmlSplitter terminates', () {
      final chunks = HtmlSplitter().splitText(
        '<p>$segment</p>',
        options: options,
      );

      expect(chunks, hasLength(19));
      expect(chunks.every((c) => c.length == options.chunkSize), isTrue);
      expect(joinOverlapping(chunks, options.chunkOverlap), segment);
    });

    test('RecursiveCharacterTextSplitter terminates when separators run out',
        () {
      final splitter = RecursiveCharacterTextSplitter(
        separators: ['\n\n', '\n', ' '],
      );

      final chunks = splitter.splitText(segment, options: options);

      expect(chunks, hasLength(19));
      expect(joinOverlapping(chunks, options.chunkOverlap), segment);
    });

    test('RecursiveCharacterTextSplitter terminates with default separators',
        () {
      final chunks = RecursiveCharacterTextSplitter().splitText(
        segment,
        options: options,
      );

      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.length <= options.chunkSize), isTrue);
      expect(chunks.first, startsWith(segment.substring(0, 50)));
      expect(chunks.last, endsWith(segment.substring(950)));
    });
  });

  group('splitByLength', () {
    test('returns nothing for empty text', () {
      expect(splitByLength('', chunkSize: 10, chunkOverlap: 5), isEmpty);
    });

    test('returns text that fits as one chunk', () {
      expect(
        splitByLength('abcdef', chunkSize: 6, chunkOverlap: 3),
        ['abcdef'],
      );
    });

    test('stops after the window that reaches the end of the text', () {
      expect(
        splitByLength('abcdefghij', chunkSize: 4, chunkOverlap: 2),
        ['abcd', 'cdef', 'efgh', 'ghij'],
      );
      expect(
        splitByLength('abcdefghi', chunkSize: 4, chunkOverlap: 2),
        ['abcd', 'cdef', 'efgh', 'ghi'],
      );
    });

    test('splits without overlap', () {
      expect(
        splitByLength('abcdefg', chunkSize: 3, chunkOverlap: 0),
        ['abc', 'def', 'g'],
      );
    });

    test('throws instead of looping when a window cannot advance', () {
      expect(
        () => splitByLength('abcdefghij', chunkSize: 4, chunkOverlap: 4),
        throwsStateError,
      );
      expect(
        () => splitByLength('abcdefghij', chunkSize: 4, chunkOverlap: 9),
        throwsStateError,
      );
    });

    test('covers the text exactly for every small size, overlap and length',
        () {
      for (var chunkSize = 1; chunkSize <= 8; chunkSize++) {
        for (var chunkOverlap = 0; chunkOverlap < chunkSize; chunkOverlap++) {
          for (var length = 0; length <= 40; length++) {
            final text = unsplittable(length);
            final reason = 'chunkSize: $chunkSize, chunkOverlap: $chunkOverlap, '
                'length: $length';

            final chunks = splitByLength(
              text,
              chunkSize: chunkSize,
              chunkOverlap: chunkOverlap,
            );

            final step = chunkSize - chunkOverlap;
            final expectedCount = length <= chunkSize
                ? (length == 0 ? 0 : 1)
                : ((length - chunkSize) / step).ceil() + 1;
            expect(chunks, hasLength(expectedCount), reason: reason);
            expect(joinOverlapping(chunks, chunkOverlap), text, reason: reason);
            if (chunks.length > 1) {
              expect(
                chunks.take(chunks.length - 1).map((c) => c.length).toSet(),
                {chunkSize},
                reason: reason,
              );
              expect(
                chunks.last.length,
                inInclusiveRange(chunkOverlap + 1, chunkSize),
                reason: reason,
              );
            }
          }
        }
      }
    });
  });
}
