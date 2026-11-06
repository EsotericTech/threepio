/// How an embedder reports its calls to the callback handlers of the run it
/// is called in.
library;

import '../callbacks/callback_context.dart';
import '../callbacks/component_callbacks.dart';
import '../callbacks/global_callbacks.dart';
import '../callbacks/run_info.dart';
import '../components/embedding/embedder.dart';
import '../components/embedding/embedding_callbacks.dart';
import '../core/run_context.dart';
import '../schema/message.dart';

/// The result of one embedding request: the vectors, and the token usage
/// when the provider reports it.
typedef EmbeddingResult = ({List<List<double>> vectors, TokenUsage? usage});

/// Port of what the embedders of eino-ext do around `EmbedStrings`:
/// `EnsureRunInfo`, `OnStart` with an `embedding.CallbackInput`, then
/// `OnEnd` with an `embedding.CallbackOutput` (vectors, config and usage) or
/// `OnError`.
///
/// The handlers are those of `options.runContext`; a call without a run
/// context still reports to the handlers of `GlobalCallbacks`. Without any
/// handler nothing is fired and [embed] runs as it would without callbacks.
abstract final class EmbeddingCallCallbacks {
  /// Runs [embed] between the start callback and the end or error callback.
  ///
  /// [typeName] is the embedder's `componentTypeName`, [defaultModel] the
  /// model it uses when the options name none, [encodingFormat] the format it
  /// requests the vectors in. What [embed] throws is reported and rethrown.
  /// [outputExtra], called once [embed] has succeeded, gives the `extra` of
  /// the callback output (eino-ext embedders fill
  /// `embedding.CallbackOutput.Extra`, Ollama with its durations).
  static Future<List<List<double>>> run(
    EmbedderOptions? options, {
    required String typeName,
    required List<String> texts,
    required Future<EmbeddingResult> Function() embed,
    String? defaultModel,
    String? encodingFormat,
    Map<String, Object?>? Function()? outputExtra,
  }) async {
    final base = options?.runContext ??
        (GlobalCallbacks.isEmpty ? null : RunContext.background());
    if (base == null) return (await embed()).vectors;
    var ctx = ensureRunInfo(base, typeName, ComponentType.embedder);
    if (!ctx.hasCallbacks) return (await embed()).vectors;

    final config = EmbeddingCallbackConfig.fromOptions(
      options,
      defaultModel: defaultModel,
      encodingFormat: encodingFormat,
    );
    ctx = await onStart(
      ctx,
      EmbeddingCallbackInput(texts: texts, config: config),
    );
    final EmbeddingResult result;
    try {
      result = await embed();
    } catch (error, stackTrace) {
      await onError(ctx, error, stackTrace);
      rethrow;
    }
    await onEnd(
      ctx,
      EmbeddingCallbackOutput(
        embeddings: result.vectors,
        config: config,
        tokenUsage: result.usage,
        extra: outputExtra?.call(),
      ),
    );
    return result.vectors;
  }
}
