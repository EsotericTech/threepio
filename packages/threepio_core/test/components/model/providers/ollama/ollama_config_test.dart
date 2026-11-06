// Tests written for the port of eino-ext components/model/ollama
// (ChatModelConfig, call_option.go WithSeed) and of the Ollama API types it
// uses (api.Options, api.ThinkValue, api.Metrics). The Go package has no tests
// of these types (they live in the Ollama client, whose own tests exercise its
// JSON encoding, which is what is checked here).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_config.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_options.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('OllamaConfig', () {
    test('defaults: the local server and nothing else set', () {
      const config = OllamaConfig(model: 'llama3.2');
      expect(config.baseUrl, 'http://localhost:11434');
      expect(OllamaConfig.defaultBaseUrl, 'http://localhost:11434');
      expect(config.model, 'llama3.2');
      expect(config.timeout, isNull);
      expect(config.idleTimeout, isNull);
      expect(config.format, isNull);
      expect(config.keepAlive, isNull);
      expect(config.options, isNull);
      expect(config.thinking, isNull);
      expect(config.toString(), contains('llama3.2'));
    });
  });

  group('OllamaFormat', () {
    test('json is the string "json"', () {
      expect(const OllamaFormat.json().toJson(), 'json');
    });

    test('a schema is sent as it is', () {
      const schema = {
        'type': 'object',
        'properties': {
          'age': {'type': 'integer'},
        },
        'required': ['age'],
      };
      expect(const OllamaFormat.schema(schema).toJson(), schema);
    });

    test('equality is by value', () {
      expect(const OllamaFormat.json(), const OllamaFormat.json());
      expect(
        const OllamaFormat.schema({'type': 'object'}),
        OllamaFormat.schema(Map.of({'type': 'object'})),
      );
      expect(
        const OllamaFormat.schema({'type': 'object'}).hashCode,
        OllamaFormat.schema(Map.of({'type': 'object'})).hashCode,
      );
      expect(const OllamaFormat.json(), isNot(const OllamaFormat.schema({})));
    });
  });

  group('OllamaThinkValue', () {
    test('booleans (Go: IsBool, Bool, String)', () {
      expect(OllamaThinkValue.enabled.isBool, isTrue);
      expect(OllamaThinkValue.enabled.isLevel, isFalse);
      expect(OllamaThinkValue.enabled.isEnabled, isTrue);
      expect(OllamaThinkValue.enabled.levelName, 'medium');
      expect(OllamaThinkValue.enabled.toJson(), true);
      expect(OllamaThinkValue.disabled.isEnabled, isFalse);
      expect(OllamaThinkValue.disabled.levelName, '');
      expect(OllamaThinkValue.disabled.toJson(), false);
      expect(OllamaThinkValue.disabled.level, isNull);
    });

    test('levels (Go: IsString, Bool, String)', () {
      for (final level in OllamaThinkLevel.values) {
        final value = OllamaThinkValue.level(level);
        expect(value.isLevel, isTrue);
        expect(value.isBool, isFalse);
        expect(value.isEnabled, isTrue);
        expect(value.levelName, level.wireValue);
        expect(value.toJson(), level.wireValue);
        expect(value.level, level);
      }
      expect(
        [for (final level in OllamaThinkLevel.values) level.wireValue],
        ['high', 'medium', 'low'],
      );
    });

    test('fromJson reads what toJson writes (Go: UnmarshalJSON)', () {
      expect(OllamaThinkValue.fromJson(true), OllamaThinkValue.enabled);
      expect(OllamaThinkValue.fromJson(false), OllamaThinkValue.disabled);
      expect(
        OllamaThinkValue.fromJson('high'),
        const OllamaThinkValue.level(OllamaThinkLevel.high),
      );
    });

    test('fromJson rejects anything else, with Go messages', () {
      expect(
        () => OllamaThinkValue.fromJson('extreme'),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            startsWith('invalid think value: "extreme"'),
          ),
        ),
      );
      expect(
        () => OllamaThinkValue.fromJson(3),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            startsWith('think must be a boolean or string'),
          ),
        ),
      );
    });

    test('equality and toString', () {
      expect(
        const OllamaThinkValue.boolean(value: true),
        OllamaThinkValue.enabled,
      );
      expect(
        const OllamaThinkValue.boolean(value: true).hashCode,
        OllamaThinkValue.enabled.hashCode,
      );
      expect(
        OllamaThinkValue.enabled,
        isNot(const OllamaThinkValue.level(OllamaThinkLevel.medium)),
      );
      expect(OllamaThinkValue.enabled.toString(), 'OllamaThinkValue(true)');
    });
  });

  group('OllamaOptions', () {
    test('nothing set is an empty options object', () {
      expect(const OllamaOptions().toJson(), isEmpty);
    });

    test('every field under its Ollama name', () {
      const options = OllamaOptions(
        numCtx: 8192,
        numBatch: 512,
        numGpu: -1,
        mainGpu: 0,
        useMmap: false,
        numThread: 8,
        numKeep: 4,
        seed: 42,
        numPredict: 128,
        topK: 40,
        topP: 0.9,
        minP: 0.05,
        typicalP: 0.7,
        repeatLastN: 64,
        temperature: 0.8,
        repeatPenalty: 1.1,
        presencePenalty: 0.5,
        frequencyPenalty: 0.25,
        stop: ['\n\n', 'User:'],
      );
      expect(options.toJson(), {
        'num_ctx': 8192,
        'num_batch': 512,
        'num_gpu': -1,
        'main_gpu': 0,
        'use_mmap': false,
        'num_thread': 8,
        'num_keep': 4,
        'seed': 42,
        'num_predict': 128,
        'top_k': 40,
        'top_p': 0.9,
        'min_p': 0.05,
        'typical_p': 0.7,
        'repeat_last_n': 64,
        'temperature': 0.8,
        'repeat_penalty': 1.1,
        'presence_penalty': 0.5,
        'frequency_penalty': 0.25,
        'stop': ['\n\n', 'User:'],
      });
    });

    test('a zero is sent, unlike Go where zero means unset', () {
      expect(const OllamaOptions(temperature: 0, seed: 0).toJson(), {
        'seed': 0,
        'temperature': 0.0,
      });
    });

    test('an empty stop list is not sent', () {
      expect(const OllamaOptions(stop: []).toJson(), isEmpty);
    });

    test('toString shows the fields', () {
      expect(const OllamaOptions(topK: 3).toString(), contains('top_k: 3'));
    });
  });

  group('OllamaRequestOptions', () {
    test('applyTo puts them ahead of the existing extensions', () {
      const other = 'another provider option';
      final options = const OllamaRequestOptions(seed: 7).applyTo(
        const ChatModelOptions(temperature: 0.1, extensions: [other]),
      );
      expect(options.temperature, 0.1);
      expect(options.extensions.first, const OllamaRequestOptions(seed: 7));
      expect(options.extensions, contains(other));
      expect(options.extension<OllamaRequestOptions>()!.seed, 7);
    });

    test('equality and toString', () {
      expect(const OllamaRequestOptions(seed: 1), const OllamaRequestOptions(seed: 1));
      expect(
        const OllamaRequestOptions(seed: 1).hashCode,
        const OllamaRequestOptions(seed: 1).hashCode,
      );
      expect(const OllamaRequestOptions(), isNot(const OllamaRequestOptions(seed: 1)));
      expect(const OllamaRequestOptions(seed: 1).toString(), contains('seed: 1'));
    });
  });

  group('OllamaMetrics', () {
    test('reads nanoseconds and counts; missing fields are zero', () {
      expect(
        OllamaMetrics.fromJson(const {
          'total_duration': 30318500,
          'load_duration': 17898200,
          'prompt_eval_count': 2,
        }),
        const OllamaMetrics(
          totalDurationNanos: 30318500,
          loadDurationNanos: 17898200,
          promptEvalCount: 2,
        ),
      );
      expect(OllamaMetrics.fromJson(const {}), const OllamaMetrics());
    });

    test('nanoseconds are kept; the Duration getters round down', () {
      // Go's mock metrics: durations of a few nanoseconds.
      final metrics = OllamaMetrics.fromJson(const {
        'eval_count': 1,
        'eval_duration': 2,
        'load_duration': 3,
        'prompt_eval_count': 4,
        'prompt_eval_duration': 5,
        'total_duration': 6,
      });
      expect(metrics.evalDurationNanos, 2);
      expect(metrics.loadDurationNanos, 3);
      expect(metrics.promptEvalDurationNanos, 5);
      expect(metrics.totalDurationNanos, 6);
      expect(metrics.totalDuration, Duration.zero);

      const long = OllamaMetrics(
        totalDurationNanos: 4883583458,
        loadDurationNanos: 1334875,
        promptEvalDurationNanos: 342546000,
        evalDurationNanos: 4535599000,
      );
      expect(long.totalDuration, const Duration(microseconds: 4883583));
      expect(long.loadDuration, const Duration(microseconds: 1334));
      expect(long.promptEvalDuration, const Duration(milliseconds: 342, microseconds: 546));
      expect(long.evalDuration, const Duration(microseconds: 4535599));
    });

    test('toJson writes what fromJson reads', () {
      const metrics = OllamaMetrics(
        totalDurationNanos: 5000001,
        loadDurationNanos: 3,
        promptEvalCount: 4,
        promptEvalDurationNanos: 5,
        evalCount: 1,
        evalDurationNanos: 2,
      );
      expect(metrics.toJson(), {
        'total_duration': 5000001,
        'load_duration': 3,
        'prompt_eval_count': 4,
        'prompt_eval_duration': 5,
        'eval_count': 1,
        'eval_duration': 2,
      });
      expect(OllamaMetrics.fromJson(metrics.toJson()), metrics);
      expect(OllamaMetrics.fromJson(metrics.toJson()).hashCode, metrics.hashCode);
      expect(metrics, isNot(const OllamaMetrics(totalDurationNanos: 5000000)));
      expect(metrics.toString(), contains('eval_count: 1'));
    });

    test('a message carries them in extra and survives a JSON round trip', () {
      const metrics = OllamaMetrics(evalCount: 9, promptEvalCount: 3);
      final message = Message(
        role: RoleType.assistant,
        content: 'hi',
        extra: {ollamaMetricsExtraKey: metrics.toJson()},
      );
      expect(ollamaMetricsExtraKey, 'ollama_metrics');
      expect(message.ollamaMetrics, metrics);

      final restored = Message.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      expect(restored.ollamaMetrics, metrics);
    });

    test('a message without them has none', () {
      expect(Message.user('hi').ollamaMetrics, isNull);
      expect(
        const Message(role: RoleType.assistant, extra: {'ollama_metrics': 1})
            .ollamaMetrics,
        isNull,
      );
    });
  });
}
