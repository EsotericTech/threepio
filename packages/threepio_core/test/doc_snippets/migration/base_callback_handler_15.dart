// Mirror of doc/MIGRATION.md, legacy: BaseCallbackHandler (before).
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

/// Prints how long each component takes.
class TimingHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async =>
      {...context, 'started': DateTime.now()};

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final started = context['started'] as DateTime?;
    if (started != null) {
      print('${info.name} took ${DateTime.now().difference(started)}');
    }
    return context;
  }
}

Future<Message> ask(BaseChatModel model) => model.generate(
      [Message.user('Hello')],
      options: ChatModelOptions(callbackManager: CallbackManager([TimingHandler()])),
    );
