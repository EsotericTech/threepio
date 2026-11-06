// Workflow field mapping into and out of an AgenticMessage: Go's mapping
// reaches the fields of `*schema.AgenticMessage` by reflection and creates
// an empty one for a destination of that type; here `AgenticMessage`
// implements `FieldAddressable` and is a built-in blank of the mapping.
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/compose/field_mapping.dart';

/// A class with a field of type [AgenticMessage] that starts out empty.
final class _Turn implements FieldAddressable {
  const _Turn({this.reply});

  final AgenticMessage? reply;

  @override
  Object? getField(String name) => switch (name) {
        'reply' => reply,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  _Turn withField(String name, Object? value) => switch (name) {
        'reply' => _Turn(reply: value as AgenticMessage?),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };
}

void main() {
  final ctx = RunContext.background();

  setUpAll(() => FieldAddressable.registerBlank<_Turn>(() => const _Turn()));

  test('an empty field of type AgenticMessage is filled from its blank, '
      'after the classic candidates refused', () {
    final blocks = [ContentBlock(const AssistantGenText(text: 'hi'))];
    final turn = assembleFromFields<_Turn>({'reply\x1FcontentBlocks': blocks});
    expect(
      turn.reply,
      AgenticMessage(role: AgenticRoleType.user, contentBlocks: blocks),
    );
  });

  test('the blank of AgenticMessage is a user message without blocks', () {
    expect(blankOf<AgenticMessage>(), AgenticMessage(role: AgenticRoleType.user));
    // The classic blanks are found first, as before.
    expect(blankOf<Message>(), const Message(role: RoleType.user));
  });

  test('a workflow maps fields of an agentic message into a new one',
      () async {
    final workflow = Workflow<AgenticMessage, AgenticMessage>();
    workflow
        .addLambdaNode(
          'reply',
          Lambda.invokable(
            (RunContext ctx, List<ContentBlock> blocks) => [
              for (final block in blocks)
                ContentBlock(
                  AssistantGenText(
                    text: block.userInputText!.text.toUpperCase(),
                  ),
                ),
            ],
          ),
        )
        .addInput(Graph.start, [FieldMapping.fromField('contentBlocks')]);
    workflow.end()
      ..addInput('reply', [FieldMapping.toField('contentBlocks')])
      ..setStaticValue(['role'], AgenticRoleType.assistant);
    final runnable = await workflow.compile(ctx);
    expect(
      await runnable.invoke(ctx, AgenticMessage.user('hello')),
      AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [ContentBlock(const AssistantGenText(text: 'HELLO'))],
      ),
    );
  });
}
