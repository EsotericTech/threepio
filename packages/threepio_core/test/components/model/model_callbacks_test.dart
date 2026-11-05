// Port of eino `components/model/callback_extra_test.go` (TestConvModel).
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('TestConvModel', () {
    test('ModelCallbackInput.from', () {
      const input = ModelCallbackInput(messages: []);
      expect(ModelCallbackInput.from(input), same(input));

      expect(ModelCallbackInput.from(<Message>[]), isNotNull);
      expect(ModelCallbackInput.from('asd'), isNull);
      expect(ModelCallbackInput.from(null), isNull);
    });

    test('ModelCallbackOutput.from', () {
      const output = ModelCallbackOutput();
      expect(ModelCallbackOutput.from(output), same(output));

      expect(ModelCallbackOutput.from(Message.assistant('')), isNotNull);
      expect(ModelCallbackOutput.from('asd'), isNull);
      expect(ModelCallbackOutput.from(null), isNull);
    });
  });

  group('ModelCallbackInput.from', () {
    test('wraps the messages a graph node reports', () {
      final messages = [Message.system('be brief'), Message.user('hi')];

      final input = ModelCallbackInput.from(messages)!;
      expect(input.messages, same(messages));
      expect(input.tools, isNull);
      expect(input.toolChoice, isNull);
      expect(input.config, isNull);
      expect(input.extra, isNull);
    });

    test('accepts a list that holds only messages but is not typed so', () {
      final List<Object?> items = [Message.user('hi')];
      expect(ModelCallbackInput.from(items)?.messages, [Message.user('hi')]);
    });

    test('rejects other lists', () {
      expect(ModelCallbackInput.from(<Object?>[]), isNull);
      expect(ModelCallbackInput.from(<Object?>[Message.user('hi'), 'x']), isNull);
      expect(ModelCallbackInput.from(<String>['hi']), isNull);
    });
  });

  group('ModelCallbackOutput.from', () {
    test('wraps the message a graph node reports', () {
      final message = Message.assistant('hello');
      final output = ModelCallbackOutput.from(message)!;
      expect(output.message, same(message));
      expect(output.tokenUsage, isNull);
      expect(output.config, isNull);
    });

    test('takes the token usage from the metadata of the message', () {
      const usage = TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
      );
      final message = Message.assistant('hello').copyWith(
        responseMeta: const ResponseMeta(finishReason: 'stop', usage: usage),
      );

      expect(ModelCallbackOutput.from(message)?.tokenUsage, usage);
    });
  });

  group('payloads', () {
    test('a model reports what it was called with', () {
      final tool = ToolInfo.fromParams(name: 'search', params: const {});
      const config = ModelCallbackConfig(
        model: 'gpt',
        maxTokens: 100,
        temperature: 0.5,
        topP: 0.9,
        stop: ['END'],
      );

      final input = ModelCallbackInput(
        messages: [Message.user('hi')],
        tools: [tool],
        toolChoice: ToolChoice.allowed,
        config: config,
        extra: const {'request_id': 'r-1'},
      );

      expect(input.tools, [tool]);
      expect(input.toolChoice, ToolChoice.allowed);
      expect(input.config?.model, 'gpt');
      expect(input.config?.maxTokens, 100);
      expect(input.config?.temperature, 0.5);
      expect(input.config?.topP, 0.9);
      expect(input.config?.stop, ['END']);
      expect(input.extra, {'request_id': 'r-1'});
      expect(input.toString(), contains('messages: 1'));
    });

    test('ModelCallbackConfig.fromOptions reads the options of a call', () {
      final config = ModelCallbackConfig.fromOptions(
        const ChatModelOptions(
          temperature: 0.1,
          maxTokens: 64,
          topP: 0.7,
          stop: ['.'],
        ),
        defaultModel: 'provider-default',
      );

      expect(config.model, 'provider-default');
      expect(config.temperature, 0.1);
      expect(config.maxTokens, 64);
      expect(config.topP, 0.7);
      expect(config.stop, ['.']);

      expect(
        ModelCallbackConfig.fromOptions(const ChatModelOptions(model: 'named'),
            defaultModel: 'provider-default').model,
        'named',
      );
      expect(ModelCallbackConfig.fromOptions(null).model, isNull);
    });

    test('an output carries message, config and usage', () {
      const usage = TokenUsage(
        promptTokens: 1,
        completionTokens: 2,
        totalTokens: 3,
      );
      final output = ModelCallbackOutput(
        message: Message.assistant('done'),
        config: const ModelCallbackConfig(model: 'gpt'),
        tokenUsage: usage,
        extra: const {'cached': true},
      );

      expect(output.message?.content, 'done');
      expect(output.config?.model, 'gpt');
      expect(output.tokenUsage, usage);
      expect(output.extra, {'cached': true});
    });
  });
}
