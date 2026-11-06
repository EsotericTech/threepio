// Tests written for the port (no Go counterpart): eino-ext leaves error
// classification to each provider SDK's error type. threepio's HTTP providers
// share `isRetryableHttpStatus`, `looksLikeModelUnavailable` and
// `ProviderErrorDetail.parse`, which these tests pin, with the error bodies
// of OpenAI, Anthropic, Gemini and Ollama as those APIs document them.
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/errors.dart';

void main() {
  group('isRetryableHttpStatus', () {
    test('408, 429 and every 5xx are worth retrying', () {
      for (final status in [408, 429, 500, 502, 503, 504, 529, 599]) {
        expect(isRetryableHttpStatus(status), isTrue, reason: '$status');
      }
    });

    test('other statuses and no status are not', () {
      for (final status in [200, 400, 401, 402, 403, 404, 409, 422]) {
        expect(isRetryableHttpStatus(status), isFalse, reason: '$status');
      }
      expect(isRetryableHttpStatus(null), isFalse);
    });
  });

  group('looksLikeModelUnavailable', () {
    test('a 404 always means the model is unavailable', () {
      expect(looksLikeModelUnavailable(404, ''), isTrue);
      expect(looksLikeModelUnavailable(404, 'anything'), isTrue);
    });

    test('the words gateways use say so, in any case', () {
      for (final message in [
        'gpt-9 is not a valid model ID',
        'No endpoints found for x/y.',
        'Model not found',
        'error code: model_not_found',
        'The model `gpt-9` does not exist or you do not have access to it.',
      ]) {
        expect(looksLikeModelUnavailable(400, message), isTrue, reason: message);
        expect(looksLikeModelUnavailable(null, message), isTrue, reason: message);
      }
    });

    test('other failures are not', () {
      expect(looksLikeModelUnavailable(400, 'Invalid value for temperature'), isFalse);
      expect(looksLikeModelUnavailable(429, 'Rate limit reached'), isFalse);
      expect(looksLikeModelUnavailable(null, ''), isFalse);
    });
  });

  group('ProviderErrorDetail.parse', () {
    test('reads the OpenAI shape', () {
      final detail = ProviderErrorDetail.parse(
        '{"error":{"message":"Incorrect API key provided.",'
        '"type":"invalid_request_error","param":null,"code":"invalid_api_key"}}',
      );
      expect(detail.message, 'Incorrect API key provided.');
      expect(detail.type, 'invalid_request_error');
      expect(detail.code, 'invalid_api_key');
      expect(detail.status, isNull);
      expect(detail.toString(), 'Incorrect API key provided.');
    });

    test('reads the Anthropic shape', () {
      final detail = ProviderErrorDetail.parse(
        '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
      );
      expect(detail.message, 'Overloaded');
      expect(detail.type, 'overloaded_error');
      expect(detail.code, isNull);
    });

    test('reads the Gemini shape, keeping a numeric code a number', () {
      final detail = ProviderErrorDetail.parse(
        '{"error":{"code":429,"message":"Resource has been exhausted",'
        '"status":"RESOURCE_EXHAUSTED"}}',
      );
      expect(detail.message, 'Resource has been exhausted');
      expect(detail.code, 429);
      expect(detail.status, 'RESOURCE_EXHAUSTED');
    });

    test('reads the Ollama shape', () {
      final detail =
          ProviderErrorDetail.parse('{"error":"model \\"llama9\\" not found"}');
      expect(detail.message, 'model "llama9" not found');
      expect(detail.type, isNull);
    });

    test('reads a top-level message', () {
      expect(ProviderErrorDetail.parse('{"message":"Forbidden"}').message, 'Forbidden');
    });

    test('an error object without a message keeps the body', () {
      const body = '{"error":{"type":"server_error"}}';
      final detail = ProviderErrorDetail.parse(body);
      expect(detail.message, body);
      expect(detail.type, 'server_error');
    });

    test('a body that is not JSON, or JSON of another shape, is the message',
        () {
      expect(ProviderErrorDetail.parse('Bad Gateway').message, 'Bad Gateway');
      expect(ProviderErrorDetail.parse('').message, '');
      expect(ProviderErrorDetail.parse('[1,2]').message, '[1,2]');
      expect(ProviderErrorDetail.parse('{"ok":false}').message, '{"ok":false}');
    });

    test('non-string type and status are dropped', () {
      final detail = ProviderErrorDetail.parse(
        '{"error":{"message":"m","type":1,"status":2}}',
      );
      expect(detail.type, isNull);
      expect(detail.status, isNull);
    });

    test('the constructor keeps what it is given', () {
      const detail = ProviderErrorDetail('m', type: 't', code: 1, status: 's');
      expect(
        [detail.message, detail.type, detail.code, detail.status],
        ['m', 't', 1, 's'],
      );
    });
  });
}
