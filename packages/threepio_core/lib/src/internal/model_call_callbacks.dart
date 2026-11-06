/// How a chat model provider reports its calls to the callback handlers of
/// the run it is called in.
library;

import '../callbacks/callback_context.dart';
import '../callbacks/component_callbacks.dart';
import '../callbacks/global_callbacks.dart';
import '../callbacks/run_info.dart';
import '../components/model/chat_model_options.dart';
import '../components/model/model_callbacks.dart';
import '../core/run_context.dart';
import '../schema/message.dart';
import '../streaming/stream_reader.dart';

/// The callbacks of one call of a chat model.
///
/// Port of what the providers of eino-ext do around `Generate` and `Stream`:
/// `EnsureRunInfo`, `OnStart` with a `model.CallbackInput`, then `OnEnd` with
/// a `model.CallbackOutput`, `OnEndWithStreamOutput` or `OnError`.
///
/// The handlers are those of `options.runContext`. A call without a run
/// context still reports to the handlers of `GlobalCallbacks`, as every call
/// does in Go, where there is always a context.
final class ModelCallCallbacks {
  ModelCallCallbacks._(this._ctx, this._config, this._outputExtra);

  /// What a provider adds to `ModelCallbackOutput.extra` for a message
  /// (eino-ext providers fill `model.CallbackOutput.Extra`, Ollama with its
  /// metrics for example). `null` adds nothing.
  final Map<String, Object?>? Function(Message message)? _outputExtra;

  /// Sets the callbacks of a call up, or returns `null` when nobody listens.
  ///
  /// [typeName] is the provider's `componentTypeName` and [defaultModel] the
  /// model that is used when [options] names none.
  static ModelCallCallbacks? of(
    ChatModelOptions options, {
    required String typeName,
    String? defaultModel,
    Map<String, Object?>? Function(Message message)? outputExtra,
  }) {
    final base = options.runContext ??
        (GlobalCallbacks.isEmpty ? null : RunContext.background());
    if (base == null) return null;
    final ctx = ensureRunInfo(base, typeName, ComponentType.chatModel);
    if (!ctx.hasCallbacks) return null;
    return ModelCallCallbacks._(
      ctx,
      ModelCallbackConfig.fromOptions(options, defaultModel: defaultModel),
      outputExtra,
    );
  }

  RunContext _ctx;
  final ModelCallbackConfig _config;

  /// Runs [generate] between the start callback and the end or error
  /// callback. What [generate] throws is rethrown.
  static Future<Message> generate(
    ChatModelOptions options, {
    required String typeName,
    required List<Message> input,
    required Future<Message> Function() generate,
    String? defaultModel,
    Map<String, Object?>? Function(Message message)? outputExtra,
  }) async {
    final callbacks = of(
      options,
      typeName: typeName,
      defaultModel: defaultModel,
      outputExtra: outputExtra,
    );
    if (callbacks == null) return generate();

    await callbacks._start(input, options);
    final Message message;
    try {
      message = await generate();
    } catch (error, stackTrace) {
      await onError(callbacks._ctx, error, stackTrace);
      rethrow;
    }
    await onEnd(callbacks._ctx, callbacks._output(message));
    return message;
  }

  /// Runs [stream] after the start callback and gives every handler that
  /// wants it a copy of the stream it returns. What [stream] throws is
  /// reported to the error callback and rethrown; an error inside the stream
  /// reaches the handlers through their copies.
  static Future<StreamReader<Message>> stream(
    ChatModelOptions options, {
    required String typeName,
    required List<Message> input,
    required Future<StreamReader<Message>> Function() stream,
    String? defaultModel,
    Map<String, Object?>? Function(Message message)? outputExtra,
  }) async {
    final callbacks = of(
      options,
      typeName: typeName,
      defaultModel: defaultModel,
      outputExtra: outputExtra,
    );
    if (callbacks == null) return stream();

    await callbacks._start(input, options);
    final StreamReader<Message> chunks;
    try {
      chunks = await stream();
    } catch (error, stackTrace) {
      await onError(callbacks._ctx, error, stackTrace);
      rethrow;
    }
    final (_, reported) = await onEndWithStreamOutput<ModelCallbackOutput>(
      callbacks._ctx,
      chunks.convert(callbacks._output),
    );
    return reported.convert((output) => output.message!);
  }

  Future<void> _start(List<Message> input, ChatModelOptions options) async {
    _ctx = await onStart(
      _ctx,
      ModelCallbackInput(
        messages: input,
        tools: options.tools,
        toolChoice: options.toolChoice,
        config: _config,
      ),
    );
  }

  ModelCallbackOutput _output(Message message) => ModelCallbackOutput(
        message: message,
        config: _config,
        tokenUsage: message.responseMeta?.usage,
        extra: _outputExtra?.call(message),
      );
}
