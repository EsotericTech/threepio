// Port of eino-ext components/model/agenticopenai/utils_test.go (TestCoalesce,
// TestNewOpenaiStrOpt as putNonEmpty) and of the URL helper tests of
// responses_convertor_test.go (TestResolveURL, TestEnsureDataURL).
//
// Not ported: TestNewOpenaiOpt and TestPtrOf (Go pointer / openai-go
// `param.Opt` helpers; Dart has nullable types), TestInt64ToStr (Dart's
// `int.toString`), TestNewPanicErr (Go panic recovery; an exception thrown
// while a stream is converted ends the stream with that exception, which
// openai_responses_model_test.dart covers).
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_exception.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_utils.dart';

void main() {
  group('TestNewOpenaiStrOpt (putNonEmpty)', () {
    test('non-empty string', () {
      final json = <String, Object?>{};
      putNonEmpty(json, 'k', 'v');
      expect(json, {'k': 'v'});
    });

    test('empty string', () {
      final json = <String, Object?>{};
      putNonEmpty(json, 'k', '');
      expect(json, isEmpty);
    });
  });

  group('TestCoalesce', () {
    test('x is non-zero', () {
      expect(coalesce('a', 'b'), 'a');
      expect(coalesce(1, 2), 1);
    });

    test('x is zero', () {
      expect(coalesce('', 'b'), 'b');
      expect(coalesce(0, 2), 2);
      expect(coalesce<Object?>(null, 'b'), 'b');
    });
  });

  group('TestResolveURL', () {
    test('url', () {
      expect(resolveUrl('http://x', '', ''), 'http://x');
    });

    test('base64_without_mime', () {
      expect(
        () => resolveUrl('', 'abc', ''),
        throwsA(isA<OpenAIResponsesException>()),
      );
    });

    test('base64', () {
      expect(resolveUrl('', 'abc', 'text/plain'), 'data:text/plain;base64,abc');
    });
  });

  group('TestEnsureDataURL', () {
    test('already_data_url', () {
      expect(
        () => ensureDataUrl('data:text/plain;base64,abc', 'text/plain'),
        throwsA(isA<OpenAIResponsesException>()),
      );
    });

    test('missing_mime', () {
      expect(
        () => ensureDataUrl('abc', ''),
        throwsA(isA<OpenAIResponsesException>()),
      );
    });

    test('ok', () {
      expect(ensureDataUrl('abc', 'text/plain'), 'data:text/plain;base64,abc');
    });
  });

  group('resolveInputSource', () {
    test('a URL or inline data wins over a file id', () {
      expect(resolveInputSource('u', '', '', 'f'), (url: 'u', fileId: ''));
      expect(
        resolveInputSource('', 'YWJj', 'image/png', 'f'),
        (url: 'data:image/png;base64,YWJj', fileId: ''),
      );
    });

    test('the file id is used when nothing else is set', () {
      expect(resolveInputSource('', '', '', 'f'), (url: '', fileId: 'f'));
    });

    test('nothing set is an error', () {
      expect(
        () => resolveInputSource('', '', '', ''),
        throwsA(isA<OpenAIResponsesException>()),
      );
    });
  });

  group('lenient JSON readers', () {
    test('missing or mistyped values read as zero values', () {
      final json = <String, Object?>{'s': 1, 'i': 'x', 'l': 'no', 'd': 2};
      expect(jsonString(json, 's'), '');
      expect(jsonInt(json, 'i'), 0);
      expect(jsonStringList(json, 'l'), isEmpty);
      expect(jsonObjectList(json, 'l'), isEmpty);
      expect(jsonDouble(json, 'd'), 2.0);
      expect(jsonObject(null, 'x'), isNull);
    });
  });
}
