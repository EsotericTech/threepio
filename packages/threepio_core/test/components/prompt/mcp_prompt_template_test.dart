// Ports eino-ext components/prompt/mcp/mcp_test.go: TestConvMessage (through
// format, against a fake server that returns the same six messages; the
// private convMessage has no Dart counterpart) and TestFormat.
//
// Deviations the expectations follow: the multimodal parts land in
// userInputMultiContent (Go fills the deprecated MultiContent), and an image
// block's base64 data goes to MessagePartCommon.base64Data (Go puts it in
// the URL field of its legacy ChatMessageImageURL, which has no data field).
//
// Written for the port: assistant messages, the conversion failures
// (unknown role, audio, resource link, unsupported MIME type), how
// variables become arguments, a server error, cancellation, the component
// type.
import 'package:test/test.dart';
import 'package:threepio_core/src/components/component_type.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/prompt/chat_template.dart';
import 'package:threepio_core/src/components/prompt/mcp_prompt_template.dart';
import 'package:threepio_core/src/components/tool/mcp/mcp_client.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/schema/message.dart';

import '../../support/fake_mcp_server.dart';

Map<String, Object?> _resource(String mimeType) => {
      'role': 'user',
      'content': {
        'type': 'resource',
        'resource': {'uri': 'test uri', 'mimeType': mimeType, 'text': 'test text'},
      },
    };

Future<(McpPromptTemplate Function(String name), FakeMcpServer)> _setUp(
  List<FakePrompt> prompts,
) async {
  final server = FakeMcpServer(prompts: prompts);
  final client = await McpClient.connect(FakeInMemoryTransport(server));
  addTearDown(client.close);
  return (
    (String name) => McpPromptTemplate(client: client, name: name),
    server,
  );
}

FakePrompt _prompt(String name, List<Map<String, Object?>> messages) =>
    FakePrompt(name: name, messages: (_) => messages);

void main() {
  test('TestConvMessage', () async {
    final (template, _) = await _setUp([
      _prompt('all', [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 'hello world'},
        },
        {
          'role': 'user',
          'content': {
            'type': 'image',
            'data': 'test data',
            'mimeType': 'image/jpeg',
          },
        },
        _resource('text/plain'),
        _resource('image/jpeg'),
        _resource('audio/mpeg'),
        _resource('video/mpeg'),
      ]),
    ]);

    final output = await template('all').format({});
    expect(output, [
      Message.user('hello world'),
      const Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessageInputImage(
              common: MessagePartCommon(
                base64Data: 'test data',
                mimeType: 'image/jpeg',
              ),
            ),
          ),
        ],
      ),
      const Message(role: RoleType.user, content: 'test uri'),
      const Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessageInputImage(
              common: MessagePartCommon(url: 'test uri', mimeType: 'image/jpeg'),
            ),
          ),
        ],
      ),
      const Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart(
            type: ChatMessagePartType.audioUrl,
            audio: MessageInputAudio(
              common: MessagePartCommon(url: 'test uri', mimeType: 'audio/mpeg'),
            ),
          ),
        ],
      ),
      const Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart(
            type: ChatMessagePartType.videoUrl,
            video: MessageInputVideo(
              common: MessagePartCommon(url: 'test uri', mimeType: 'video/mpeg'),
            ),
          ),
        ],
      ),
    ]);
  });

  test('TestFormat', () async {
    final (template, _) = await _setUp([
      _prompt('', [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 'hello world'},
        },
      ]),
    ]);
    final result = await template('').format({});
    expect(result, hasLength(1));
    expect(result.single.content, 'hello world');
  });

  test('assistant messages carry their parts as generated output', () async {
    final (template, _) = await _setUp([
      _prompt('a', [
        {
          'role': 'assistant',
          'content': {'type': 'text', 'text': 'sure'},
        },
        {
          'role': 'assistant',
          'content': {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
        },
        {
          'role': 'assistant',
          'content': {
            'type': 'resource',
            'resource': {'uri': 'mem://a', 'mimeType': 'audio/wav', 'blob': 'AA=='},
          },
        },
      ]),
    ]);
    final output = await template('a').format({});
    expect(output, [
      const Message(role: RoleType.assistant, content: 'sure'),
      const Message(
        role: RoleType.assistant,
        assistantGenMultiContent: [
          MessageOutputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessagePartCommon(base64Data: 'aGk=', mimeType: 'image/png'),
          ),
        ],
      ),
      const Message(
        role: RoleType.assistant,
        assistantGenMultiContent: [
          MessageOutputPart(
            type: ChatMessagePartType.audioUrl,
            audio: MessagePartCommon(url: 'mem://a', mimeType: 'audio/wav'),
          ),
        ],
      ),
    ]);
  });

  group('conversion failures', () {
    Future<void> expectFailure(Map<String, Object?> message, String reason) async {
      final (template, _) = await _setUp([
        _prompt('bad', [message]),
      ]);
      await expectLater(
        template('bad').format({}),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('convert mcp message fail'), contains(reason)),
          ),
        ),
      );
    }

    test('an unknown role', () => expectFailure(
          {
            'role': 'system',
            'content': {'type': 'text', 'text': 'x'},
          },
          'unknown mcp role system',
        ));

    test('audio content', () => expectFailure(
          {
            'role': 'user',
            'content': {'type': 'audio', 'data': 'AA==', 'mimeType': 'audio/wav'},
          },
          'unknown mcp prompt content type: audio',
        ));

    test('a resource link', () => expectFailure(
          {
            'role': 'user',
            'content': {'type': 'resource_link', 'uri': 'file:///x', 'name': 'x'},
          },
          'unknown mcp prompt content type: resource_link',
        ));

    test('an unsupported MIME type', () => expectFailure(
          _resource('application/pdf'),
          'unsupported mcp resource mime type application/pdf',
        ));
  });

  test('variables become string arguments as fmt.Sprint writes them',
      () async {
    final (template, server) = await _setUp([
      _prompt('vars', const []),
    ]);
    await template('vars').format({
      'text': 'plain',
      'int': 7,
      'whole': 1.0,
      'fraction': 1.5,
      'flag': true,
      'none': null,
      'list': [1, 'a'],
      'map': {'k': 'v'},
    });
    expect(server.receivedOf('prompts/get').single.params, {
      'name': 'vars',
      'arguments': {
        'text': 'plain',
        'int': '7',
        'whole': '1',
        'fraction': '1.5',
        'flag': 'true',
        'none': '<nil>',
        'list': '[1,"a"]',
        'map': '{"k":"v"}',
      },
    });

    await template('vars').format({});
    expect(server.receivedOf('prompts/get').last.params, {'name': 'vars'},
        reason: 'no arguments, none sent (omitempty)');
  });

  test('doubles are written as Go %v writes them', () async {
    final (template, server) = await _setUp([_prompt('f', const [])]);
    await template('f').format({
      'a': 1000000.0,
      'b': 0.00001,
      'c': 123456789.0,
      'd': 1e21,
      'e': 100000.0,
      'f': 0.0001,
      'g': -2.5e-7,
      'h': 3.25,
    });
    expect(server.receivedOf('prompts/get').single.params['arguments'], {
      'a': '1e+06',
      'b': '1e-05',
      'c': '1.23456789e+08',
      'd': '1e+21',
      'e': '100000',
      'f': '0.0001',
      'g': '-2.5e-07',
      'h': '3.25',
    });
  });

  test('a prompt the server cannot render', () async {
    final (template, _) = await _setUp([]);
    await expectLater(
      template('missing').format({}),
      throwsA(
        isA<ThreepioException>()
            .having((e) => e.message, 'message', contains('get mcp prompt fail'))
            .having((e) => e.cause, 'cause', isA<McpException>()),
      ),
    );
  });

  test('the cancel token of the run context cancels the request', () async {
    final (template, _) = await _setUp([_prompt('p', const [])]);
    final token = CancelToken()..cancel('stop');
    await expectLater(
      template('p').format(
        {},
        options: ChatTemplateOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      ),
      throwsA(isA<CancelledException>()),
    );
  });

  test('the component type is MCP; the graph fires its callbacks', () async {
    final (template, _) = await _setUp([]);
    final t = template('x');
    expect(componentTypeNameOf(t), 'MCP');
    expect(isCallbacksEnabled(t), isFalse);
    expect(t, isA<ChatTemplate>());
    expect(t.name, 'x');
  });
}
