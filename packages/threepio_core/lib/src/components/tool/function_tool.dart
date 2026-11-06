/// Tools made from a function.
///
/// Port of eino `components/tool/utils` (`invokable_func.go`,
/// `streamable_func.go`). Go infers the parameter schema of a tool from the
/// struct tags of its input type (`InferTool`). Dart has no reflection, so a
/// tool is given its parameters, and a function that builds the input from
/// the decoded arguments, explicitly.
library;

import 'dart:async';
import 'dart:convert';

import '../../core/run_context.dart';
import '../../errors.dart';
import '../../internal/go_json.dart';
import '../../internal/naming.dart';
import '../../schema/tool_info.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import '../component_type.dart';
import 'enhanced_tool.dart';
import 'invokable_tool.dart';
import 'tool_options.dart';

/// Builds the typed input of a tool from its decoded JSON arguments.
///
/// The counterpart of eino's `utils.WithUnmarshalArguments`. Usually the
/// `fromJson` constructor of the input class.
typedef ToolInputDecoder<I> = I Function(Map<String, Object?> json);

/// Turns the output of a tool into something `jsonEncode` accepts.
///
/// The counterpart of eino's `utils.WithMarshalOutput`. Usually the `toJson`
/// method of the output class. A returned `String` is passed to the model as
/// it is.
typedef ToolOutputEncoder<O> = Object? Function(O output);

/// An [InvokableTool] made from a function.
///
/// Port of eino `utils.NewTool`, `utils.InferTool` and
/// `utils.InferOptionableTool`. The tool decodes the JSON arguments the model
/// wrote, builds the input of type [I] from them, calls the function and
/// encodes what it returns:
///
/// ```dart
/// final weather = FunctionTool<WeatherQuery, Weather>(
///   name: 'get_weather',
///   description: 'The current weather in a city',
///   params: const ParamsOneOf.params({
///     'city': ParameterInfo(type: DataType.string, required: true),
///   }),
///   fromJson: WeatherQuery.fromJson,
///   invoke: (ctx, query, options) => service.lookUp(query.city),
///   toJson: (weather) => weather.toJson(),
/// );
/// ```
///
/// * The arguments must be a JSON object, as every model API sends them. An
///   empty argument string counts as `{}`.
/// * Arguments that are not valid JSON, that are not an object, or that
///   `fromJson` rejects make the call fail with a [ThreepioFormatException].
///   Give the tool to `wrapToolWithErrorHandler` to report that to the model
///   instead.
/// * A `String` result is returned as it is. Everything else is encoded as
///   JSON the way Go's sonic writes it (as `jsonEncode` does, except that
///   backspace and form feed are written `\u0008` and `\u000c`), after
///   [ToolOutputEncoder] if there is one; without one, the `toJson()` method
///   of the output is called.
/// * What the function throws is thrown by the call, unchanged.
///
/// There is nothing that checks the parameters against [I]: keeping the two
/// in step is up to the author of the tool.
final class FunctionTool<I, O> extends InvokableTool implements TypedComponent {
  /// A tool called [name] that takes [params].
  ///
  /// [description] tells the model what the tool does and when to use it.
  /// [extra] is kept in the tool's [ToolInfo] and is not shown to the model.
  FunctionTool({
    required String name,
    required String description,
    required ParamsOneOf params,
    required ToolInputDecoder<I> fromJson,
    required FutureOr<O> Function(RunContext ctx, I input, ToolOptions? options)
        invoke,
    ToolOutputEncoder<O>? toJson,
    Map<String, Object?>? extra,
  }) : this.fromInfo(
          _toolInfo(name, description, params, extra),
          fromJson: fromJson,
          invoke: invoke,
          toJson: toJson,
        );

  /// A tool described by an existing [ToolInfo], for example one made with
  /// `ToolInfo.simple` or `ToolInfoBuilder`.
  ///
  /// Port of eino `utils.NewTool(desc, fn)`.
  FunctionTool.fromInfo(
    ToolInfo info, {
    required ToolInputDecoder<I> fromJson,
    required FutureOr<O> Function(RunContext ctx, I input, ToolOptions? options)
        invoke,
    ToolOutputEncoder<O>? toJson,
  })  : _info = info,
        _fromJson = fromJson,
        _invoke = invoke,
        _toJson = toJson;

  final ToolInfo _info;
  final ToolInputDecoder<I> _fromJson;
  final FutureOr<O> Function(RunContext ctx, I input, ToolOptions? options)
      _invoke;
  final ToolOutputEncoder<O>? _toJson;

  /// The name of the tool.
  String get name => _info.name;

  @override
  String get componentTypeName => snakeToUpperCamel(_info.name);

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final input = _decodeInput(_info.name, argumentsJson, _fromJson);
    final output = await _invoke(ctx, input, options);
    return _encodeOutput(output, _toJson);
  }

  /// The same as [invokableRun] with a context that is never cancelled and
  /// without options, for code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);
}

/// A [StreamableTool] made from a function that returns a stream.
///
/// Port of eino `utils.NewStreamTool`, `utils.InferStreamTool` and
/// `utils.InferOptionableStreamTool`. Like [FunctionTool], except that the
/// function returns a [StreamReader] of [O] and every chunk is encoded on its
/// own, when it is read. Errors in the stream of the function are passed on.
final class StreamFunctionTool<I, O> extends StreamableTool
    implements TypedComponent {
  /// A streaming tool called [name] that takes [params].
  StreamFunctionTool({
    required String name,
    required String description,
    required ParamsOneOf params,
    required ToolInputDecoder<I> fromJson,
    required FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
    ToolOutputEncoder<O>? toJson,
    Map<String, Object?>? extra,
  }) : this.fromInfo(
          _toolInfo(name, description, params, extra),
          fromJson: fromJson,
          invoke: invoke,
          toJson: toJson,
        );

  /// A streaming tool described by an existing [ToolInfo].
  ///
  /// Port of eino `utils.NewStreamTool(desc, fn)`.
  StreamFunctionTool.fromInfo(
    ToolInfo info, {
    required ToolInputDecoder<I> fromJson,
    required FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
    ToolOutputEncoder<O>? toJson,
  })  : _info = info,
        _fromJson = fromJson,
        _invoke = invoke,
        _toJson = toJson;

  final ToolInfo _info;
  final ToolInputDecoder<I> _fromJson;
  final FutureOr<StreamReader<O>> Function(
    RunContext ctx,
    I input,
    ToolOptions? options,
  ) _invoke;
  final ToolOutputEncoder<O>? _toJson;

  /// The name of the tool.
  String get name => _info.name;

  @override
  String get componentTypeName => snakeToUpperCamel(_info.name);

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final input = _decodeInput(_info.name, argumentsJson, _fromJson);
    final chunks = await _invoke(ctx, input, options);
    return chunks.convert((chunk) => _encodeOutput(chunk, _toJson));
  }

  /// The same as [streamableRun] with a context that is never cancelled and
  /// without options, for code that still calls the tool the old way.
  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}

/// An [EnhancedInvokableTool] made from a function that returns a
/// [ToolResult].
///
/// Port of eino `utils.NewEnhancedTool`, `utils.InferEnhancedTool` and
/// `utils.InferOptionableEnhancedTool`. The arguments are decoded as in
/// [FunctionTool]; the result of the function is the result of the tool.
final class EnhancedFunctionTool<I>
    implements EnhancedInvokableTool, TypedComponent {
  /// An enhanced tool called [name] that takes [params].
  EnhancedFunctionTool({
    required String name,
    required String description,
    required ParamsOneOf params,
    required ToolInputDecoder<I> fromJson,
    required FutureOr<ToolResult> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
    Map<String, Object?>? extra,
  }) : this.fromInfo(
          _toolInfo(name, description, params, extra),
          fromJson: fromJson,
          invoke: invoke,
        );

  /// An enhanced tool described by an existing [ToolInfo].
  ///
  /// Port of eino `utils.NewEnhancedTool(desc, fn)`.
  EnhancedFunctionTool.fromInfo(
    ToolInfo info, {
    required ToolInputDecoder<I> fromJson,
    required FutureOr<ToolResult> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
  })  : _info = info,
        _fromJson = fromJson,
        _invoke = invoke;

  final ToolInfo _info;
  final ToolInputDecoder<I> _fromJson;
  final FutureOr<ToolResult> Function(
    RunContext ctx,
    I input,
    ToolOptions? options,
  ) _invoke;

  /// The name of the tool.
  String get name => _info.name;

  @override
  String get componentTypeName => snakeToUpperCamel(_info.name);

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async {
    final input = _decodeInput(_info.name, argument.text, _fromJson);
    return _invoke(ctx, input, options);
  }
}

/// An [EnhancedStreamableTool] made from a function that returns a stream of
/// [ToolResult]s.
///
/// Port of eino `utils.NewEnhancedStreamTool`,
/// `utils.InferEnhancedStreamTool` and
/// `utils.InferOptionableEnhancedStreamTool`.
final class EnhancedStreamFunctionTool<I>
    implements EnhancedStreamableTool, TypedComponent {
  /// An enhanced streaming tool called [name] that takes [params].
  EnhancedStreamFunctionTool({
    required String name,
    required String description,
    required ParamsOneOf params,
    required ToolInputDecoder<I> fromJson,
    required FutureOr<StreamReader<ToolResult>> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
    Map<String, Object?>? extra,
  }) : this.fromInfo(
          _toolInfo(name, description, params, extra),
          fromJson: fromJson,
          invoke: invoke,
        );

  /// An enhanced streaming tool described by an existing [ToolInfo].
  ///
  /// Port of eino `utils.NewEnhancedStreamTool(desc, fn)`.
  EnhancedStreamFunctionTool.fromInfo(
    ToolInfo info, {
    required ToolInputDecoder<I> fromJson,
    required FutureOr<StreamReader<ToolResult>> Function(
      RunContext ctx,
      I input,
      ToolOptions? options,
    ) invoke,
  })  : _info = info,
        _fromJson = fromJson,
        _invoke = invoke;

  final ToolInfo _info;
  final ToolInputDecoder<I> _fromJson;
  final FutureOr<StreamReader<ToolResult>> Function(
    RunContext ctx,
    I input,
    ToolOptions? options,
  ) _invoke;

  /// The name of the tool.
  String get name => _info.name;

  @override
  String get componentTypeName => snakeToUpperCamel(_info.name);

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async {
    final input = _decodeInput(_info.name, argument.text, _fromJson);
    return _invoke(ctx, input, options);
  }
}

ToolInfo _toolInfo(
  String name,
  String description,
  ParamsOneOf params,
  Map<String, Object?>? extra,
) =>
    ToolInfo.fromParamsOneOf(
      name: name,
      desc: description,
      params: params,
      extra: extra,
    );

I _decodeInput<I>(
  String toolName,
  String argumentsJson,
  ToolInputDecoder<I> fromJson,
) {
  final Object? decoded;
  try {
    decoded = argumentsJson.trim().isEmpty
        ? const <String, Object?>{}
        : jsonDecode(argumentsJson);
  } on FormatException catch (error) {
    throw ThreepioFormatException(
      'The arguments of tool "$toolName" are not valid JSON: ${error.message}',
      source: argumentsJson,
      offset: error.offset,
      cause: error,
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ThreepioFormatException(
      'The arguments of tool "$toolName" must be a JSON object, not '
      '${_jsonKind(decoded)}',
      source: argumentsJson,
    );
  }

  try {
    return fromJson(decoded);
    // The arguments come from a model. A decoder that trips over them, with
    // a failed cast for example, has found bad input, not a bug.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioFormatException(
        'The arguments of tool "$toolName" could not be decoded: $error',
        source: argumentsJson,
        cause: error,
      ),
      stackTrace,
    );
  }
}

String _jsonKind(Object? value) => switch (value) {
      null => 'null',
      String() => 'a string',
      num() => 'a number',
      bool() => 'a boolean',
      List<Object?>() => 'an array',
      _ => 'a ${value.runtimeType}',
    };

/// The string a tool hands to the model for [output].
///
/// Port of eino's `marshalString`: a `String` is the result as it is,
/// everything else is encoded as JSON the way `sonic.MarshalString` writes
/// it, so `null` becomes `null` and `42` becomes `42`. [toJson], when given,
/// is applied first.
String _encodeOutput<O>(O output, ToolOutputEncoder<O>? toJson) {
  final encodable = toJson == null ? output : toJson(output);
  return encodable is String ? encodable : goSonicMarshal(encodable);
}
