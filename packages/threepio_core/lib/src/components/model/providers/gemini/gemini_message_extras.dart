/// What eino-ext's `gemini` chat model keeps in the `extra` maps of messages,
/// tool calls and message parts: thought signatures, grounding metadata,
/// code execution parts, video metadata and display names.
///
/// Port of eino-ext `components/model/gemini/message_extra.go`. Go stores
/// genai values (`[]byte`, `*genai.GroundingMetadata`, …) under its keys;
/// here the values are the JSON of the Gemini REST API (a base64 string, a
/// map), so a message keeps them through a JSON round trip (checkpoints).
/// The keys are Go's. [Message] is immutable, so every setter returns a copy.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../../schema/message.dart';

/// Go `videoMetaDataKey`.
@internal
const geminiVideoMetaDataKey = 'gemini_video_meta_data';

/// Go `thoughtSignatureKey`.
@internal
const geminiThoughtSignatureKey = 'gemini_thought_signature';

/// Go `specialParteKey`: the code execution part an output part came from.
@internal
const geminiSpecialPartKey = 'gemini_special_part';

/// Go `groundMetadataKey`.
@internal
const geminiGroundMetadataKey = 'gemini_ground_metadata';

/// Go `displayNameKey`.
@internal
const geminiDisplayNameKey = 'gemini_display_name';

/// The thought signature stored in [extra], and whether [extra] has the key
/// at all.
///
/// Port of eino-ext `gemini.GetThoughtSignatureFromExtra`. Read it from
/// `ToolCall.extra` (signatures on function calls),
/// `MessageOutputPart.extra` (signatures on generated media and code parts)
/// or `Message.extra` (the signature of the text of a response). The value
/// may be a base64 string (what this port stores, and what a JSON round trip
/// leaves of Go's `[]byte`) or a list of bytes. `signature` is `null` when
/// the value is empty or cannot be decoded; `present` says whether the key
/// exists.
({Uint8List? signature, bool present}) geminiThoughtSignatureFromExtra(
  Map<String, dynamic>? extra,
) {
  if (extra == null || !extra.containsKey(geminiThoughtSignatureKey)) {
    return (signature: null, present: false);
  }
  final value = extra[geminiThoughtSignatureKey];
  if (value is String) {
    if (value.isEmpty) return (signature: null, present: true);
    try {
      final decoded = base64Decode(value);
      return (signature: decoded.isEmpty ? null : decoded, present: true);
    } on FormatException {
      return (signature: null, present: true);
    }
  }
  if (value is List && value.every((byte) => byte is int)) {
    if (value.isEmpty) return (signature: null, present: true);
    return (signature: Uint8List.fromList(value.cast<int>()), present: true);
  }
  return (signature: null, present: true);
}

/// The thought signature in [extra] as the base64 text the REST API takes,
/// or `null` when there is none (or it cannot be decoded).
@internal
String? geminiThoughtSignatureBase64(Map<String, dynamic>? extra) {
  final value = extra?[geminiThoughtSignatureKey];
  if (value is String) {
    if (value.isEmpty) return null;
    try {
      return base64Decode(value).isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }
  final signature = geminiThoughtSignatureFromExtra(extra).signature;
  return signature == null ? null : base64Encode(signature);
}

Map<String, dynamic>? _withSignature(
  Map<String, dynamic>? extra,
  List<int> signature,
) =>
    signature.isEmpty
        ? extra
        : {...?extra, geminiThoughtSignatureKey: base64Encode(signature)};

/// The Gemini extras of a [Message].
extension GeminiMessageExtras on Message {
  /// The thought signature of the text of this response, or `null`.
  ///
  /// Port of eino-ext `getMessageThoughtSignature`. Gemini puts it on the
  /// last text part of a response (or on an empty part of its own); the
  /// model sends it back on the text of the message.
  Uint8List? get geminiThoughtSignature =>
      geminiThoughtSignatureFromExtra(extra).signature;

  /// A copy with [signature] as the thought signature of its text; an empty
  /// [signature] returns this message unchanged.
  ///
  /// Port of eino-ext `setMessageThoughtSignature`.
  Message withGeminiThoughtSignature(List<int> signature) =>
      signature.isEmpty
          ? this
          : copyWith(extra: _withSignature(extra, signature));

  /// The grounding metadata of this response (Google Search, Maps, URL
  /// context, file search): the REST `groundingMetadata` object, or `null`.
  ///
  /// Port of eino-ext `gemini.GetGroundMetadata`.
  Map<String, Object?>? get geminiGroundingMetadata {
    final value = extra?[geminiGroundMetadataKey];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  /// A copy with [metadata] (a REST `groundingMetadata` object) as its
  /// grounding metadata.
  ///
  /// Port of eino-ext `setGroundMetadata`.
  Message withGeminiGroundingMetadata(Map<String, Object?> metadata) =>
      copyWith(extra: {...?extra, geminiGroundMetadataKey: metadata});
}

/// The Gemini extras of a [ToolCall].
extension GeminiToolCallExtras on ToolCall {
  /// The thought signature of this function call, or `null`.
  ///
  /// Port of eino-ext `getToolCallThoughtSignature`. Gemini 3 requires it
  /// back on the function call: of parallel calls only the first has one, of
  /// sequential calls each has its own.
  Uint8List? get geminiThoughtSignature =>
      geminiThoughtSignatureFromExtra(extra).signature;

  /// A copy with [signature] as the thought signature of this call; an empty
  /// [signature] returns this call unchanged.
  ///
  /// Port of eino-ext `setToolCallThoughtSignature`.
  ToolCall withGeminiThoughtSignature(List<int> signature) =>
      signature.isEmpty
          ? this
          : copyWith(extra: _withSignature(extra, signature));
}

/// Code the model wrote and ran with the code execution tool.
///
/// Port of genai `ExecutableCode`.
@immutable
final class GeminiExecutableCode {
  /// [code] in [language].
  const GeminiExecutableCode({required this.code, this.language});

  /// Reads the REST `executableCode` object.
  factory GeminiExecutableCode.fromJson(Map<String, dynamic> json) =>
      GeminiExecutableCode(
        code: json['code'] as String? ?? '',
        language: json['language'] as String?,
      );

  /// The code.
  final String code;

  /// The language of the code (`PYTHON`).
  final String? language;

  /// The REST `executableCode` object.
  Map<String, Object?> toJson() => {
        if (language != null) 'language': language,
        'code': code,
      };
}

/// The result of running [GeminiExecutableCode].
///
/// Port of genai `CodeExecutionResult`.
@immutable
final class GeminiCodeExecutionResult {
  /// [output] with [outcome].
  const GeminiCodeExecutionResult({required this.output, this.outcome});

  /// Reads the REST `codeExecutionResult` object.
  factory GeminiCodeExecutionResult.fromJson(Map<String, dynamic> json) =>
      GeminiCodeExecutionResult(
        output: json['output'] as String? ?? '',
        outcome: json['outcome'] as String?,
      );

  /// What the code printed, or the error.
  final String output;

  /// `OUTCOME_OK`, `OUTCOME_FAILED` or `OUTCOME_DEADLINE_EXCEEDED`.
  final String? outcome;

  /// The REST `codeExecutionResult` object.
  Map<String, Object?> toJson() => {
        if (outcome != null) 'outcome': outcome,
        'output': output,
      };
}

/// The Gemini extras of a [MessageOutputPart].
extension GeminiOutputPartExtras on MessageOutputPart {
  /// The thought signature of this generated part, or `null`.
  Uint8List? get geminiThoughtSignature =>
      geminiThoughtSignatureFromExtra(extra).signature;

  /// A copy with [signature] as the thought signature of this part; an empty
  /// [signature] returns this part unchanged.
  ///
  /// Port of eino-ext `setMessageOutputPartThoughtSignature`.
  MessageOutputPart withGeminiThoughtSignature(List<int> signature) =>
      signature.isEmpty
          ? this
          : copyWith(extra: _withSignature(extra, signature));

  /// The code this text part shows, when it came from an `executableCode`
  /// part of the response; `null` otherwise.
  GeminiExecutableCode? get geminiExecutableCode {
    final special = extra?[geminiSpecialPartKey];
    if (special is! Map) return null;
    final code = special['executableCode'];
    return code is Map
        ? GeminiExecutableCode.fromJson(Map<String, dynamic>.from(code))
        : null;
  }

  /// The code execution result this text part shows, when it came from a
  /// `codeExecutionResult` part of the response; `null` otherwise.
  GeminiCodeExecutionResult? get geminiCodeExecutionResult {
    final special = extra?[geminiSpecialPartKey];
    if (special is! Map) return null;
    final result = special['codeExecutionResult'];
    return result is Map
        ? GeminiCodeExecutionResult.fromJson(Map<String, dynamic>.from(result))
        : null;
  }
}

/// Which part of a video the model looks at, and at what frame rate.
///
/// Port of genai `VideoMetadata`.
@immutable
final class GeminiVideoMetadata {
  /// Every field is optional.
  const GeminiVideoMetadata({this.startOffset, this.endOffset, this.fps});

  /// Reads the REST `videoMetadata` object (`{"startOffset": "1s", …}`).
  factory GeminiVideoMetadata.fromJson(Map<String, dynamic> json) =>
      GeminiVideoMetadata(
        startOffset: _parseDuration(json['startOffset']),
        endOffset: _parseDuration(json['endOffset']),
        fps: (json['fps'] as num?)?.toDouble(),
      );

  /// Where the model starts watching.
  final Duration? startOffset;

  /// Where the model stops watching.
  final Duration? endOffset;

  /// Frames per second sent to the model, in (0, 24]; the default is 1.
  final double? fps;

  /// The REST `videoMetadata` object.
  ///
  /// As genai's `VideoMetadata.MarshalJSON`, offsets are whole seconds, and an
  /// end offset without a start offset starts at `0s`.
  Map<String, Object?> toJson() {
    String seconds(Duration d) =>
        '${(d.inMicroseconds / Duration.microsecondsPerSecond).round()}s';
    final start = startOffset ?? Duration.zero;
    final end = endOffset ?? Duration.zero;
    final hasStart = start != Duration.zero;
    final hasEnd = end != Duration.zero;
    return {
      if (hasStart)
        'startOffset': seconds(start)
      else if (hasEnd)
        'startOffset': '0s',
      if (hasEnd) 'endOffset': seconds(end),
      if (fps != null) 'fps': fps,
    };
  }

  static Duration? _parseDuration(Object? value) {
    if (value is num) {
      return Duration(microseconds: (value * Duration.microsecondsPerSecond).round());
    }
    if (value is! String || !value.endsWith('s')) return null;
    final seconds = double.tryParse(value.substring(0, value.length - 1));
    return seconds == null
        ? null
        : Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
  }

  @override
  bool operator ==(Object other) =>
      other is GeminiVideoMetadata &&
      other.startOffset == startOffset &&
      other.endOffset == endOffset &&
      other.fps == fps;

  @override
  int get hashCode => Object.hash(startOffset, endOffset, fps);

  @override
  String toString() => 'GeminiVideoMetadata(${toJson()})';
}

/// The Gemini extras of a [MessageInputPart].
extension GeminiInputPartExtras on MessageInputPart {
  /// The video metadata of this video part, or `null`.
  ///
  /// Port of eino-ext `gemini.GetInputVideoMetaData`.
  GeminiVideoMetadata? get geminiInputVideoMetadata {
    final value = extra?[geminiVideoMetaDataKey];
    if (value is GeminiVideoMetadata) return value;
    return value is Map
        ? GeminiVideoMetadata.fromJson(Map<String, dynamic>.from(value))
        : null;
  }

  /// A copy of this video part with [metadata].
  ///
  /// Port of eino-ext `gemini.SetInputVideoMetaData`. The metadata is stored
  /// as its REST JSON.
  MessageInputPart withGeminiInputVideoMetadata(GeminiVideoMetadata metadata) =>
      copyWith(extra: {...?extra, geminiVideoMetaDataKey: metadata.toJson()});

  /// The display name of this media part of a tool result, or `null`.
  ///
  /// Port of eino-ext `getMultiModalToolResultDisplayName`.
  String? get geminiToolResultDisplayName {
    final value = extra?[geminiDisplayNameKey];
    return value is String ? value : null;
  }

  /// A copy of this media part of a tool result with [displayName], the name
  /// the model sees for it.
  ///
  /// Port of eino-ext `gemini.SetMultiModalToolResultDisplayName`.
  MessageInputPart withGeminiToolResultDisplayName(String displayName) =>
      copyWith(extra: {...?extra, geminiDisplayNameKey: displayName});
}
