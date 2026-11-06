/// How an agentic model provider reports its calls to the callback handlers
/// of the run it is called in. The agentic twin of `ModelCallCallbacks`.
library;

import 'package:meta/meta.dart';

import '../callbacks/callback_context.dart';
import '../callbacks/component_callbacks.dart';
import '../callbacks/global_callbacks.dart';
import '../callbacks/run_info.dart';
import '../components/model/agentic_model.dart';
import '../components/model/chat_model_options.dart';
import '../core/run_context.dart';
import '../schema/agentic_message.dart';
import '../streaming/stream_reader.dart';

/// Fires the start, end and error callbacks of one agentic model call, with
/// [ComponentType.agenticModel] and the typed payloads
/// [AgenticModelCallbackInput] and [AgenticModelCallbackOutput].
///
/// The handlers are those of `options.runContext` plus the global ones;
/// without any, the call runs untouched. Port of the `callbacks.OnStart` /
/// `OnEnd` / `OnError` / `OnEndWithStreamOutput` calls of eino-ext's
/// agentic providers.
@internal
final class AgenticModelCallCallbacks {
  AgenticModelCallCallbacks._(this._ctx, this._config, this._outputExtra);

  final Map<String, Object?>? Function(AgenticMessage message)? _outputExtra;
  RunContext _ctx;
  final AgenticModelCallbackConfig _config;

  static AgenticModelCallCallbacks? _of(
    ChatModelOptions options, {
    required String typeName,
    String? defaultModel,
    Map<String, Object?>? Function(AgenticMessage message)? outputExtra,
  }) {
    final base = options.runContext ??
        (GlobalCallbacks.isEmpty ? null : RunContext.background());
    if (base == null) return null;
    final ctx = ensureRunInfo(base, typeName, ComponentType.agenticModel);
    if (!ctx.hasCallbacks) return null;
    return AgenticModelCallCallbacks._(
      ctx,
      AgenticModelCallbackConfig.fromOptions(
        options,
        defaultModel: defaultModel,
      ),
      outputExtra,
    );
  }

  /// Runs [generate] between the start and the end (or error) callbacks.
  static Future<AgenticMessage> generate(
    ChatModelOptions options, {
    required String typeName,
    required List<AgenticMessage> input,
    required Future<AgenticMessage> Function() generate,
    String? defaultModel,
    Map<String, Object?>? Function(AgenticMessage message)? outputExtra,
  }) async {
    final callbacks = _of(
      options,
      typeName: typeName,
      defaultModel: defaultModel,
      outputExtra: outputExtra,
    );
    if (callbacks == null) return generate();

    await callbacks._start(input, options);
    final AgenticMessage message;
    try {
      message = await generate();
    } catch (error, stackTrace) {
      await onError(callbacks._ctx, error, stackTrace);
      rethrow;
    }
    await onEnd(callbacks._ctx, callbacks._output(message));
    return message;
  }

  /// Runs [stream] after the start callback and hands its chunks to the end
  /// callback as they arrive.
  static Future<StreamReader<AgenticMessage>> stream(
    ChatModelOptions options, {
    required String typeName,
    required List<AgenticMessage> input,
    required Future<StreamReader<AgenticMessage>> Function() stream,
    String? defaultModel,
    Map<String, Object?>? Function(AgenticMessage message)? outputExtra,
  }) async {
    final callbacks = _of(
      options,
      typeName: typeName,
      defaultModel: defaultModel,
      outputExtra: outputExtra,
    );
    if (callbacks == null) return stream();

    await callbacks._start(input, options);
    final StreamReader<AgenticMessage> chunks;
    try {
      chunks = await stream();
    } catch (error, stackTrace) {
      await onError(callbacks._ctx, error, stackTrace);
      rethrow;
    }
    final (_, reported) =
        await onEndWithStreamOutput<AgenticModelCallbackOutput>(
      callbacks._ctx,
      chunks.convert(callbacks._output),
    );
    return reported.convert((output) => output.message!);
  }

  Future<void> _start(
    List<AgenticMessage> input,
    ChatModelOptions options,
  ) async {
    _ctx = await onStart(
      _ctx,
      AgenticModelCallbackInput(
        messages: input,
        tools: options.tools,
        config: _config,
      ),
    );
  }

  AgenticModelCallbackOutput _output(AgenticMessage message) =>
      AgenticModelCallbackOutput(
        message: message,
        config: _config,
        tokenUsage: message.responseMeta?.tokenUsage,
        extra: _outputExtra?.call(message),
      );
}
