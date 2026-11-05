// Ports of TestMessageTemplate and TestFormatUserInputMultiContent of eino
// `schema/message_test.go` and of TestMediaFileID and
// TestMessageMediaTemplateReuse of `schema/message_file_id_test.go`
// (v0.9.22), plus the details of the f-string syntax.
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

final ctx = RunContext.background();

Future<String> fString(String template, Map<String, Object?> vars) async {
  final messages =
      await Message.user(template).format(ctx, vars, FormatType.fString);
  return messages.single.content;
}

Future<String> jinja(String template, Map<String, Object?> vars) async {
  final messages =
      await Message.user(template).format(ctx, vars, FormatType.jinja2);
  return messages.single.content;
}

Matcher throwsFormatError(String text) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', contains(text)),
    );

void main() {
  group('Message.format (TestMessageTemplate)', () {
    const question = "what's the weather today";
    final expected = [Message.user('input: $question')];

    test('f-string', () async {
      final messages = await Message.user('input: {question}')
          .format(ctx, {'question': question}, FormatType.fString);

      expect(messages, expected);
    });

    test('jinja2', () async {
      final messages = await Message.user('input: {{question}}')
          .format(ctx, {'question': question}, FormatType.jinja2);

      expect(messages, expected);
    });

    test('go templates are not available in Dart', () async {
      await expectLater(
        Message.user('input: {{.question}}')
            .format(ctx, {'question': question}, FormatType.goTemplate),
        throwsUnsupportedError,
      );
    });

    test('keeps everything but the text', () async {
      const template = Message(
        role: RoleType.assistant,
        content: 'hi {name}',
        name: 'bot',
        reasoningContent: 'not a {template}',
        extra: {'k': 'v'},
      );

      final message =
          (await template.format(ctx, {'name': 'eino'}, FormatType.fString))
              .single;

      expect(message, template.copyWith(content: 'hi eino'));
      expect(template.content, 'hi {name}');
    });

    test('a message is a MessagesTemplate', () {
      final MessagesTemplate template = Message.system('you are {role}');

      expect(template, isA<Message>());
    });
  });

  group('MessagesPlaceholder (TestMessageTemplate)', () {
    final m1 = Message.user('how are you?');
    final m2 = Message.assistant("I'm good. how about you?");

    test('renders to the messages under its key', () async {
      const placeholder = MessagesPlaceholder('chat_history');

      final messages = await placeholder.format(
        ctx,
        {
          'chat_history': [m1, m2],
        },
        FormatType.fString,
      );

      expect(messages, [m1, m2]);
    });

    test('accepts a list that is not typed as messages', () async {
      final messages = await const MessagesPlaceholder('history').format(
        ctx,
        {
          'history': <Object?>[m1, m2],
        },
        FormatType.jinja2,
      );

      expect(messages, [m1, m2]);
    });

    test('fails when the key is missing', () async {
      await expectLater(
        const MessagesPlaceholder('history').format(ctx, {}, FormatType.fString),
        throwsFormatError('history not found'),
      );
    });

    test('renders to nothing when optional and missing', () async {
      const placeholder = MessagesPlaceholder('history', optional: true);

      expect(await placeholder.format(ctx, {}, FormatType.fString), isEmpty);
    });

    test('fails for a value that is not a list of messages', () async {
      await expectLater(
        const MessagesPlaceholder('history')
            .format(ctx, {'history': 'text'}, FormatType.fString),
        throwsFormatError('only messages can be used'),
      );
      await expectLater(
        const MessagesPlaceholder('history').format(
          ctx,
          {
            'history': [m1, 'text'],
          },
          FormatType.fString,
        ),
        throwsFormatError('only messages can be used'),
      );
    });

    test('has value equality', () {
      expect(
        const MessagesPlaceholder('a', optional: true),
        MessagesPlaceholder('a', optional: 1 + 1 == 2),
      );
      expect(
        const MessagesPlaceholder('a'),
        isNot(const MessagesPlaceholder('b')),
      );
    });
  });

  group('user input parts (TestFormatUserInputMultiContent)', () {
    const vars = {
      'x': 'world',
      'img': 'https://example.com/i.png',
      'b64': 'YmFzZTY0',
      'aid': '99',
      'vid': '77',
      'file': 'abc',
    };

    Future<List<MessageInputPart>?> format(List<MessageInputPart>? parts) async =>
        (await Message(role: RoleType.user, userInputMultiContent: parts)
                .format(ctx, vars, FormatType.fString))
            .single
            .userInputMultiContent;

    test('empty input', () async {
      expect(await format(null), isNull);
      expect(await format(const []), isEmpty);
    });

    test('render text and both URL/Base64 for each type', () async {
      final out = await format([
        MessageInputPart.text('hello {x}'),
        const MessageInputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessageInputImage(
            common: MessagePartCommon(url: '{img}', base64Data: '{b64}'),
            detail: ImageURLDetail.high,
          ),
        ),
        MessageInputPart.audio(url: 'http://a/{aid}.wav', base64Data: '{b64}'),
        MessageInputPart.video(url: 'http://v/{vid}.mp4', base64Data: '{b64}'),
        MessageInputPart.file(
          url: '/f/{file}.txt',
          base64Data: '{b64}',
          name: '{x}.txt',
        ),
      ]);

      expect(out, hasLength(5));
      expect(out![0].text, 'hello world');
      expect(out[1].image!.common.url, 'https://example.com/i.png');
      expect(out[1].image!.common.base64Data, 'YmFzZTY0');
      expect(out[1].image!.detail, ImageURLDetail.high);
      expect(out[2].audio!.common.url, 'http://a/99.wav');
      expect(out[2].audio!.common.base64Data, 'YmFzZTY0');
      expect(out[3].video!.common.url, 'http://v/77.mp4');
      expect(out[3].video!.common.base64Data, 'YmFzZTY0');
      expect(out[4].file!.common.url, '/f/abc.txt');
      expect(out[4].file!.common.base64Data, 'YmFzZTY0');
      expect(out[4].file!.name, '{x}.txt', reason: 'names are not templates');
    });

    test('empty string should not be formatted', () async {
      final out = await format([
        const MessageInputPart(
          type: ChatMessagePartType.imageUrl,
          image: MessageInputImage(
            common: MessagePartCommon(url: '', base64Data: ''),
          ),
        ),
      ]);

      expect(out!.single.image!.common.url, '');
      expect(out.single.image!.common.base64Data, '');
    });

    test('a part without its content is left alone', () async {
      const parts = [
        MessageInputPart(type: ChatMessagePartType.imageUrl),
        MessageInputPart(type: ChatMessagePartType.text),
        MessageInputPart(type: ChatMessagePartType.toolSearchResult),
      ];

      expect(await format(parts), parts);
    });
  });

  // TestMediaFileID
  group('file ids are templates too', () {
    const fileId = 'provider-file-123';

    for (final (name, type, template) in [
      ('fstring', FormatType.fString, '{file_id}'),
      ('jinja2', FormatType.jinja2, '{{file_id}}'),
    ]) {
      test(name, () async {
        final message = Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: MessagePartCommon(fileId: template),
              ),
            ),
            MessageInputPart.audio(fileId: template),
            MessageInputPart.video(fileId: template),
            MessageInputPart.file(fileId: template),
          ],
        );

        final formatted =
            (await message.format(ctx, {'file_id': fileId}, type)).single;
        final parts = formatted.userInputMultiContent!;

        expect(
          [
            parts[0].image!.common.fileId,
            parts[1].audio!.common.fileId,
            parts[2].video!.common.fileId,
            parts[3].file!.common.fileId,
          ],
          everyElement(fileId),
        );
        expect(
          message.userInputMultiContent![0].image!.common.fileId,
          template,
        );

        final json = formatted.toJson();
        expect('$json', contains('fileId: $fileId'));
        expect(Message.fromJson(json), formatted);
      });
    }
  });

  // TestMessageMediaTemplateReuse
  group('a template can be formatted again and again', () {
    Message makeMessage(MessagePartCommon common) => Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: common,
                detail: ImageURLDetail.high,
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.audioUrl,
              audio: MessageInputAudio(common: common),
            ),
            MessageInputPart(
              type: ChatMessagePartType.videoUrl,
              video: MessageInputVideo(common: common),
            ),
            MessageInputPart(
              type: ChatMessagePartType.fileUrl,
              file: MessageInputFile(common: common, name: 'document.pdf'),
            ),
          ],
        );

    for (final (name, common) in <(String, MessagePartCommon Function(String))>[
      ('url', (value) => MessagePartCommon(url: value)),
      ('base64', (value) => MessagePartCommon(base64Data: value)),
      ('file_id', (value) => MessagePartCommon(fileId: value)),
    ]) {
      test(name, () async {
        final template = makeMessage(common('{value}'));

        final first =
            await template.format(ctx, {'value': 'first'}, FormatType.fString);
        final second =
            await template.format(ctx, {'value': 'second'}, FormatType.fString);

        expect(first.single, makeMessage(common('first')));
        expect(second.single, makeMessage(common('second')));
        expect(template, makeMessage(common('{value}')));

        // An earlier part formats fine before a later one fails.
        final broken = template.copyWith(
          userInputMultiContent: [
            template.userInputMultiContent![0],
            MessageInputPart(
              type: ChatMessagePartType.audioUrl,
              audio: MessageInputAudio(common: common('{missing}')),
            ),
          ],
        );
        final before = broken.toJson().toString();
        await expectLater(
          broken.format(ctx, {'value': 'first'}, FormatType.fString),
          throwsFormatError('could not find key: missing'),
        );
        expect(broken.toJson().toString(), before);
      });
    }
  });

  group('f-string syntax', () {
    test('replaces every field', () async {
      expect(
        await fString('{a}-{b}-{a}', {'a': 1, 'b': 'two'}),
        '1-two-1',
      );
    });

    test('leaves text without fields alone', () async {
      expect(await fString('', {}), '');
      expect(await fString('no fields here', {}), 'no fields here');
    });

    test('doubled braces are literal braces', () async {
      expect(
        await fString('{{"name": "{name}"}}', {'name': 'eino'}),
        '{"name": "eino"}',
      );
      expect(await fString('{{{{}}}}', {}), '{{}}');
    });

    test('a single brace is an error', () async {
      await expectLater(
        fString('oops }', {}),
        throwsFormatError("Single '}' encountered"),
      );
      await expectLater(
        fString('oops {name', {'name': 1}),
        throwsFormatError("Single '{' encountered"),
      );
      await expectLater(
        fString('json: {"a": 1}', {}),
        throwsFormatError('could not find key'),
      );
    });

    test('a missing variable is an error', () async {
      await expectLater(
        fString('hello {name}', {'other': 1}),
        throwsFormatError('could not find key: name'),
      );
    });

    test('the error carries the template', () async {
      await expectLater(
        fString('hello {name}', {}),
        throwsA(
          isA<FormatException>()
              .having((e) => e.source, 'source', 'hello {name}'),
        ),
      );
    });

    test('dots and brackets look into maps and lists', () async {
      final vars = {
        'user': {
          'name': 'Ada',
          'tags': ['x', 'y'],
          'address': {'city': 'London'},
        },
        'items': [
          {'title': 'first'},
          {'title': 'second'},
        ],
      };

      expect(await fString('{user.name}', vars), 'Ada');
      expect(await fString('{user[name]}', vars), 'Ada');
      expect(await fString('{user.address.city}', vars), 'London');
      expect(await fString('{user.tags[1]}', vars), 'y');
      expect(await fString('{user.tags.0}', vars), 'x');
      expect(await fString('{items[1].title}', vars), 'second');
      expect(await fString('{items[0][title]}', vars), 'first');
    });

    test('a bad path is an error', () async {
      final vars = {
        'user': {'name': 'Ada'},
        'items': [1],
      };

      await expectLater(
        fString('{user.age}', vars),
        throwsFormatError('could not find key: age'),
      );
      await expectLater(
        fString('{items[3]}', vars),
        throwsFormatError('index out of bounds'),
      );
      await expectLater(
        fString('{items.first}', vars),
        throwsFormatError('could not parse index'),
      );
      await expectLater(
        fString('{user.name.length}', vars),
        throwsFormatError('neither a map nor a list'),
      );
      await expectLater(
        fString('{items[0}', vars),
        throwsFormatError('unmatched ['),
      );
      await expectLater(
        fString('{items]0}', vars),
        throwsFormatError('unmatched ]'),
      );
      await expectLater(
        fString('{items[0]x}', vars),
        throwsFormatError('must begin a new subfield'),
      );
    });

    test('values are written with toString', () async {
      expect(
        await fString('{i} {d} {b} {n} {l}', {
          'i': 42,
          'd': 1.5,
          'b': true,
          'n': null,
          'l': [1, 2],
        }),
        '42 1.5 true null [1, 2]',
      );
    });

    test('an empty field stands for the variables themselves', () async {
      expect(await fString('{}', {'a': 1}), '{a: 1}');
      expect(await fString('{0.a}', {'a': 1}), '1');
      expect(await fString('{.a}', {'a': 1}), '1');
      await expectLater(
        fString('{1}', {'a': 1}),
        throwsFormatError('index out of bounds: 1'),
      );
    });

    test('there is only one positional argument', () async {
      await expectLater(
        fString('{} {}', {'a': 1}),
        throwsFormatError('too large offset: 1'),
      );
    });

    test('empty and named fields cannot be mixed', () async {
      await expectLater(
        fString('{} {a}', {'a': 1}),
        throwsFormatError(
          'cannot switch from automatic field numbering to manual',
        ),
      );
      await expectLater(
        fString('{a} {}', {'a': 1}),
        throwsFormatError(
          'cannot switch from manual field specification to automatic',
        ),
      );
    });

    test('a dot at the end of a field is ignored', () async {
      expect(await fString('{a.}', {'a': 1}), '1');
      expect(
        await fString('{user.name.}', {
          'user': {'name': 'Ada'},
        }),
        'Ada',
      );
      await expectLater(
        fString('{a..b}', {
          'a': {'b': 1},
        }),
        throwsFormatError('could not find key: '),
      );
    });

    test('format specifications: width, alignment and fill', () async {
      final vars = {'s': 'ab', 'n': 42};

      expect(await fString('[{s:5}]', vars), '[   ab]');
      expect(await fString('[{s:<5}]', vars), '[ab   ]');
      expect(await fString('[{s:>5}]', vars), '[   ab]');
      expect(await fString('[{s:^6}]', vars), '[  ab  ]');
      expect(await fString('[{s:*^7}]', vars), '[**ab***]');
      expect(await fString('[{n:5}]', vars), '[   42]');
      expect(await fString('[{n:05}]', vars), '[00042]');
      expect(await fString('[{n:x<5}]', vars), '[42xxx]');
      expect(await fString('[{s:1}]', vars), '[ab]');
    });

    test('format specifications: numbers', () async {
      final vars = {'n': 255, 'neg': -7, 'pi': 3.14159, 'ratio': 0.256};

      expect(await fString('{n:d}', vars), '255');
      expect(await fString('{n:+d}', vars), '+255');
      expect(await fString('{neg:+d}', vars), '-7');
      expect(await fString('{n: d}', vars), ' 255');
      expect(await fString('{neg:05d}', vars), '-0007');
      expect(await fString('{n:x}', vars), 'ff');
      expect(await fString('{n:X}', vars), 'FF');
      expect(await fString('{n:#x}', vars), '0xff');
      expect(await fString('{n:b}', vars), '11111111');
      expect(await fString('{n:#b}', vars), '0b11111111');
      expect(await fString('{n:#010x}', vars), '0x000000ff');
      expect(await fString('{n:#012b}', vars), '0b0011111111');
      expect(await fString('{neg:#06x}', vars), '-0x007');
      expect(await fString('{n:#8x}', vars), '    0xff');
      expect(await fString('{n:o}', vars), '377');
      expect(await fString('{pi:.2f}', vars), '3.14');
      expect(await fString('{pi:8.3f}', vars), '   3.142');
      expect(await fString('{pi:f}', vars), '3.141590');
      expect(await fString('{pi:.3}', vars), '3.14');
      expect(await fString('{pi:.2e}', vars), '3.14e+00');
      expect(await fString('{n:.1e}', vars), '2.6e+02');
      expect(await fString('{n:.2f}', vars), '255.00');
      expect(await fString('{ratio:.1%}', vars), '25.6%');
    });

    test('format specifications: strings', () async {
      expect(await fString('{s:.3}', {'s': 'abcdef'}), 'abc');
      expect(await fString('{s:s}', {'s': 'abc'}), 'abc');
      expect(await fString('{n:s}', {'n': 12}), '12');
    });

    test('a bad format specification is an error', () async {
      await expectLater(
        fString('{s:d}', {'s': 'text'}),
        throwsFormatError('needs a number'),
      );
      await expectLater(
        fString('{pi:d}', {'pi': 3.5}),
        throwsFormatError('needs an integer'),
      );
      await expectLater(
        fString('{n:q}', {'n': 1}),
        throwsFormatError('Invalid format specification'),
      );
    });

    test('long templates are formatted in one pass', () async {
      final template = List.filled(20000, 'a{x}{{}}').join();

      final formatted = await fString(template, {'x': 'b'});

      expect(formatted, List.filled(20000, 'ab{}').join());
    });
  });

  group('jinja2 syntax', () {
    test('supports expressions, filters and control structures', () async {
      expect(
        await jinja(
          '{% for item in items %}{{ loop.index }}:{{ item | upper }} '
          '{% endfor %}{% if admin %}admin{% else %}user{% endif %}',
          {
            'items': ['a', 'b'],
            'admin': false,
          },
        ),
        '1:A 2:B user',
      );
      expect(await jinja('{{ user.name }}', {'user': {'name': 'Ada'}}), 'Ada');
    });

    test('a syntax error is a FormatException', () async {
      await expectLater(
        jinja('{% if %}', {}),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', startsWith('jinja2:')),
        ),
      );
    });

    test('a failure while rendering is a FormatException', () async {
      await expectLater(
        jinja('{{ 1 / 0 | upper | missing_filter }}', {}),
        throwsFormatException,
      );
      await expectLater(
        jinja('{{ value.foo.bar() }}', {'value': 3}),
        throwsFormatException,
      );
    });

    test('an undefined variable renders as nothing', () async {
      expect(await jinja('[{{ missing }}]', {}), '[]');
    });

    test('templates cannot pull in other templates', () async {
      for (final template in [
        '{% include "secret.txt" %}',
        '{% extends "base.html" %}',
        '{% import "macros.html" as m %}',
        '{% from "macros.html" import field %}',
      ]) {
        await expectLater(
          jinja(template, {}),
          throwsFormatException,
          reason: template,
        );
      }
    });
  });
}
