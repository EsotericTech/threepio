/// Configuration and value types of the Ollama provider.
///
/// Port of eino-ext `components/model/ollama` (`ChatModelConfig`) and of the
/// types of the Ollama API it uses (`api.Options`, `api.ThinkValue`,
/// `api.Metrics`).
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/message.dart';

/// Configuration of an `OllamaChatModel`.
///
/// Port of eino-ext `ollama.ChatModelConfig`. Go's `HTTPClient` is the
/// model's `httpClient` constructor parameter.
///
/// ```dart
/// final model = OllamaChatModel(
///   config: const OllamaConfig(
///     model: 'qwen3:8b',
///     keepAlive: Duration(minutes: 10),
///     options: OllamaOptions(temperature: 0.2, numCtx: 8192),
///     thinking: OllamaThinkValue.enabled,
///   ),
/// );
/// ```
@immutable
final class OllamaConfig {
  /// The configuration of a model that talks to [model] on the Ollama
  /// server at [baseUrl].
  const OllamaConfig({
    required this.model,
    this.baseUrl = defaultBaseUrl,
    this.timeout,
    this.idleTimeout,
    this.format,
    this.keepAlive,
    this.options,
    this.thinking,
  });

  /// The address of a local Ollama server.
  static const String defaultBaseUrl = 'http://localhost:11434';

  /// The address of the Ollama server (Go: `BaseURL`), without `/api`.
  ///
  /// Defaults to [defaultBaseUrl]; an empty string means the same. A path is
  /// kept: `http://host/ollama` sends to `http://host/ollama/api/chat`.
  final String baseUrl;

  /// The model to use (Go: `Model`), as Ollama names it: `llama3.2`,
  /// `qwen3:8b`. A call can name another one in `ChatModelOptions.model`.
  final String model;

  /// The longest wait for the response (Go: `Timeout`).
  ///
  /// For `generate` it covers the whole response. For `stream` it covers
  /// only the response headers: Go's `http.Client.Timeout` also bounds the
  /// reading of the streamed body, here [idleTimeout] bounds the silence
  /// between two lines instead, so a long answer that keeps flowing is never
  /// cut off. `null`, the default, waits as long as it takes, as Go's zero
  /// `Timeout` does: loading a large model can take minutes.
  final Duration? timeout;

  /// The longest silence between two lines of a streamed response before the
  /// stream fails with a retryable `OllamaException`. `null`, the default,
  /// never gives up. An addition to Go, which has no such limit.
  final Duration? idleTimeout;

  /// The format of the answer (Go: `Format`): JSON, or JSON that follows a
  /// schema.
  final OllamaFormat? format;

  /// How long the model stays loaded after the request (Go: `KeepAlive`).
  ///
  /// [Duration.zero] unloads it at once, a negative duration keeps it loaded
  /// indefinitely. `null` leaves the server's default (five minutes).
  final Duration? keepAlive;

  /// The model options of every request (Go: `Options`). Temperature, top-p,
  /// stop sequences and the maximum number of tokens given in the
  /// `ChatModelOptions` of a call take precedence over the ones here.
  final OllamaOptions? options;

  /// Whether, and how hard, a thinking model thinks before it answers (Go:
  /// `Thinking`). `null` leaves the model's default.
  final OllamaThinkValue? thinking;

  @override
  String toString() => 'OllamaConfig(baseUrl: $baseUrl, model: $model)';
}

/// The answer format of a request: plain JSON, or JSON that follows a schema.
///
/// Port of the `Format json.RawMessage` field of eino-ext
/// `ollama.ChatModelConfig`, which holds either `"json"` or a JSON schema.
@immutable
final class OllamaFormat {
  /// Any valid JSON (`"format": "json"`).
  const OllamaFormat.json() : _value = 'json';

  /// JSON that follows [schema], a JSON schema as a JSON-compatible map.
  const OllamaFormat.schema(Map<String, Object?> schema) : _value = schema;

  final Object _value;

  /// The value of the request's `format` field.
  Object toJson() => _value;

  @override
  bool operator ==(Object other) =>
      other is OllamaFormat &&
      const DeepCollectionEquality().equals(other._value, _value);

  @override
  int get hashCode => const DeepCollectionEquality().hash(_value);

  @override
  String toString() => 'OllamaFormat($_value)';
}

/// The levels of thinking a model can be asked for.
///
/// Port of the string values of the Ollama API's `ThinkValue`.
enum OllamaThinkLevel {
  /// `"high"`.
  high('high'),

  /// `"medium"`.
  medium('medium'),

  /// `"low"`.
  low('low');

  const OllamaThinkLevel(this.wireValue);

  /// The value on the wire.
  final String wireValue;
}

/// Whether a thinking model thinks: `true`, `false`, or a level.
///
/// Port of the Ollama API's `ThinkValue` (eino-ext `ollama.ThinkValue`). The
/// request's `think` field is a boolean or one of `"high"`, `"medium"` and
/// `"low"`. A value is valid by construction, so Go's `IsValid` has no
/// counterpart.
@immutable
final class OllamaThinkValue {
  /// `think: true` or `think: false`.
  const OllamaThinkValue.boolean({required bool value})
      : _enabled = value,
        level = null;

  /// `think: "high"`, `"medium"` or `"low"`.
  const OllamaThinkValue.level(OllamaThinkLevel this.level) : _enabled = null;

  /// Reads the value of a `think` field.
  ///
  /// Port of `ThinkValue.UnmarshalJSON`. Throws a [ThreepioFormatException]
  /// for anything other than a boolean or one of the three level names.
  factory OllamaThinkValue.fromJson(Object? json) {
    if (json is bool) return OllamaThinkValue.boolean(value: json);
    if (json is String) {
      for (final level in OllamaThinkLevel.values) {
        if (level.wireValue == json) return OllamaThinkValue.level(level);
      }
      throw ThreepioFormatException(
        'invalid think value: "$json" '
        '(must be "high", "medium", "low", true, or false)',
        source: json,
      );
    }
    throw ThreepioFormatException(
      'think must be a boolean or string ("high", "medium", "low")',
      source: json,
    );
  }

  /// `think: true`.
  static const OllamaThinkValue enabled =
      OllamaThinkValue.boolean(value: true);

  /// `think: false`.
  static const OllamaThinkValue disabled =
      OllamaThinkValue.boolean(value: false);

  final bool? _enabled;

  /// The level, or `null` for a boolean value.
  final OllamaThinkLevel? level;

  /// Whether the value is a boolean (Go: `IsBool`).
  bool get isBool => _enabled != null;

  /// Whether the value is a level (Go: `IsString`).
  bool get isLevel => level != null;

  /// Whether thinking is on in any way (Go: `Bool`): `true`, or any level.
  bool get isEnabled => _enabled ?? true;

  /// The value as a level name (Go: `String`): the level's name, `medium`
  /// for `true` and an empty string for `false`.
  String get levelName =>
      level?.wireValue ?? (_enabled! ? OllamaThinkLevel.medium.wireValue : '');

  /// The value of the request's `think` field (Go: `MarshalJSON`).
  Object toJson() => _enabled ?? level!.wireValue;

  @override
  bool operator ==(Object other) =>
      other is OllamaThinkValue &&
      other._enabled == _enabled &&
      other.level == level;

  @override
  int get hashCode => Object.hash(_enabled, level);

  @override
  String toString() => 'OllamaThinkValue(${toJson()})';
}

/// The model options of an Ollama request.
///
/// Port of the Ollama API's `Options` (with the embedded `Runner` options),
/// eino-ext `ollama.Options`. Every field is optional; only the ones that are
/// set are sent. Unlike Go, where a zero value means "not set" and can
/// therefore never be sent, a field set to `0` is sent as `0`.
@immutable
final class OllamaOptions {
  /// Options with the given fields set.
  const OllamaOptions({
    this.numCtx,
    this.numBatch,
    this.numGpu,
    this.mainGpu,
    this.useMmap,
    this.numThread,
    this.numKeep,
    this.seed,
    this.numPredict,
    this.topK,
    this.topP,
    this.minP,
    this.typicalP,
    this.repeatLastN,
    this.temperature,
    this.repeatPenalty,
    this.presencePenalty,
    this.frequencyPenalty,
    this.stop,
  });

  /// The size of the context window in tokens (`num_ctx`).
  final int? numCtx;

  /// The batch size for prompt processing (`num_batch`).
  final int? numBatch;

  /// The number of layers to offload to the GPU (`num_gpu`).
  final int? numGpu;

  /// The GPU that holds small tensors (`main_gpu`).
  final int? mainGpu;

  /// Whether to map the model file into memory (`use_mmap`).
  final bool? useMmap;

  /// The number of CPU threads (`num_thread`).
  final int? numThread;

  /// The number of prompt tokens kept when the context overflows
  /// (`num_keep`).
  final int? numKeep;

  /// The random seed, for reproducible answers (`seed`).
  final int? seed;

  /// The most tokens to generate (`num_predict`).
  final int? numPredict;

  /// Top-k sampling (`top_k`).
  final int? topK;

  /// Top-p (nucleus) sampling (`top_p`).
  final double? topP;

  /// Min-p sampling (`min_p`).
  final double? minP;

  /// Locally typical sampling (`typical_p`).
  final double? typicalP;

  /// How far back repetitions are penalised (`repeat_last_n`).
  final int? repeatLastN;

  /// The sampling temperature (`temperature`).
  final double? temperature;

  /// The penalty for repetitions (`repeat_penalty`).
  final double? repeatPenalty;

  /// The presence penalty (`presence_penalty`).
  final double? presencePenalty;

  /// The frequency penalty (`frequency_penalty`).
  final double? frequencyPenalty;

  /// Sequences that end the answer (`stop`). An empty list is not sent.
  final List<String>? stop;

  /// The `options` object of a request, with the fields that are set.
  Map<String, Object?> toJson() {
    final stop = this.stop;
    return {
      if (numCtx != null) 'num_ctx': numCtx,
      if (numBatch != null) 'num_batch': numBatch,
      if (numGpu != null) 'num_gpu': numGpu,
      if (mainGpu != null) 'main_gpu': mainGpu,
      if (useMmap != null) 'use_mmap': useMmap,
      if (numThread != null) 'num_thread': numThread,
      if (numKeep != null) 'num_keep': numKeep,
      if (seed != null) 'seed': seed,
      if (numPredict != null) 'num_predict': numPredict,
      if (topK != null) 'top_k': topK,
      if (topP != null) 'top_p': topP,
      if (minP != null) 'min_p': minP,
      if (typicalP != null) 'typical_p': typicalP,
      if (repeatLastN != null) 'repeat_last_n': repeatLastN,
      if (temperature != null) 'temperature': temperature,
      if (repeatPenalty != null) 'repeat_penalty': repeatPenalty,
      if (presencePenalty != null) 'presence_penalty': presencePenalty,
      if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
      if (stop != null && stop.isNotEmpty) 'stop': [...stop],
    };
  }

  @override
  String toString() => 'OllamaOptions(${toJson()})';
}

/// The key under which an Ollama response carries its [OllamaMetrics] in
/// [Message.extra].
///
/// Port of eino-ext `ollama.CallbackMetricsExtraKey`.
const String ollamaMetricsExtraKey = 'ollama_metrics';

/// How long an Ollama request took and how many tokens it processed.
///
/// Port of the Ollama API's `Metrics`. Ollama reports them on the last
/// response of a request (`done: true`); `OllamaChatModel` puts them into
/// that message's [Message.extra] under [ollamaMetricsExtraKey], as the
/// numbers Ollama sent (durations in nanoseconds), where
/// [OllamaMessageMetrics.ollamaMetrics] reads them, and reports the same map
/// in the callback output's `extra`.
///
/// The durations are kept in nanoseconds, as Go keeps them; the [Duration]
/// getters round them down to microseconds.
@immutable
final class OllamaMetrics {
  /// Metrics with the given values.
  const OllamaMetrics({
    this.totalDurationNanos = 0,
    this.loadDurationNanos = 0,
    this.promptEvalCount = 0,
    this.promptEvalDurationNanos = 0,
    this.evalCount = 0,
    this.evalDurationNanos = 0,
  });

  /// Reads the metrics fields of an Ollama response. Missing fields are
  /// zero, as in Go.
  factory OllamaMetrics.fromJson(Map<String, Object?> json) => OllamaMetrics(
        totalDurationNanos: _int(json['total_duration']),
        loadDurationNanos: _int(json['load_duration']),
        promptEvalCount: _int(json['prompt_eval_count']),
        promptEvalDurationNanos: _int(json['prompt_eval_duration']),
        evalCount: _int(json['eval_count']),
        evalDurationNanos: _int(json['eval_duration']),
      );

  /// The time the whole request took, in nanoseconds (`total_duration`).
  final int totalDurationNanos;

  /// The time spent loading the model, in nanoseconds (`load_duration`).
  final int loadDurationNanos;

  /// The number of prompt tokens (`prompt_eval_count`).
  final int promptEvalCount;

  /// The time spent on the prompt, in nanoseconds
  /// (`prompt_eval_duration`).
  final int promptEvalDurationNanos;

  /// The number of generated tokens (`eval_count`).
  final int evalCount;

  /// The time spent generating, in nanoseconds (`eval_duration`).
  final int evalDurationNanos;

  /// [totalDurationNanos] as a [Duration].
  Duration get totalDuration => _duration(totalDurationNanos);

  /// [loadDurationNanos] as a [Duration].
  Duration get loadDuration => _duration(loadDurationNanos);

  /// [promptEvalDurationNanos] as a [Duration].
  Duration get promptEvalDuration => _duration(promptEvalDurationNanos);

  /// [evalDurationNanos] as a [Duration].
  Duration get evalDuration => _duration(evalDurationNanos);

  /// The metrics as Ollama sends them, durations in nanoseconds.
  Map<String, Object?> toJson() => {
        'total_duration': totalDurationNanos,
        'load_duration': loadDurationNanos,
        'prompt_eval_count': promptEvalCount,
        'prompt_eval_duration': promptEvalDurationNanos,
        'eval_count': evalCount,
        'eval_duration': evalDurationNanos,
      };

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  static Duration _duration(int nanos) => Duration(microseconds: nanos ~/ 1000);

  @override
  bool operator ==(Object other) =>
      other is OllamaMetrics &&
      other.totalDurationNanos == totalDurationNanos &&
      other.loadDurationNanos == loadDurationNanos &&
      other.promptEvalCount == promptEvalCount &&
      other.promptEvalDurationNanos == promptEvalDurationNanos &&
      other.evalCount == evalCount &&
      other.evalDurationNanos == evalDurationNanos;

  @override
  int get hashCode => Object.hash(
        totalDurationNanos,
        loadDurationNanos,
        promptEvalCount,
        promptEvalDurationNanos,
        evalCount,
        evalDurationNanos,
      );

  @override
  String toString() => 'OllamaMetrics(${toJson()})';
}

/// Reads the [OllamaMetrics] an `OllamaChatModel` stored in a message.
extension OllamaMessageMetrics on Message {
  /// The metrics of the Ollama response this message is (or ends with), or
  /// `null` when it carries none.
  OllamaMetrics? get ollamaMetrics {
    final raw = extra?[ollamaMetricsExtraKey];
    if (raw is! Map) return null;
    return OllamaMetrics.fromJson(raw.cast<String, Object?>());
  }
}
