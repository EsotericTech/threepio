import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/chain/base_chain.dart';
import 'package:threepio_core/src/components/prompt/prompt_template.dart';
import 'package:threepio_core/threepio_core.dart';

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

final class _WrappedFailure extends ThreepioException {
  const _WrappedFailure(super.message, {super.cause});
}

/// A wrapper that existed before the base class and has its own `cause`.
final class _Cycle implements ThreepioException {
  @override
  String get message => 'cycle';

  @override
  late final Object? cause = this;
}

void main() {
  final ctx = RunContext.background();

  group('ThreepioException', () {
    test('carries a message and an optional cause', () {
      const plain = ThreepioException('it broke');
      expect(plain.message, 'it broke');
      expect(plain.cause, isNull);
      expect(plain.toString(), 'ThreepioException: it broke');

      final cause = StateError('root');
      final wrapped = ThreepioException('it broke', cause: cause);
      expect(wrapped.cause, same(cause));
      expect(
        wrapped.toString(),
        'ThreepioException: it broke\nCaused by: Bad state: root',
      );
    });

    test('is an Exception and not an Error', () {
      const Object error = ThreepioException('x');
      expect(error, isA<Exception>());
      expect(error, isNot(isA<Error>()));
    });

    test('can be extended, and a subclass is caught as the base', () {
      ThreepioException? caught;
      try {
        throw const _WrappedFailure('node failed');
      } on ThreepioException catch (error) {
        caught = error;
      }
      expect(caught, isA<_WrappedFailure>());
      expect(caught?.message, 'node failed');
    });

    group('findCause', () {
      test('returns the error itself when it has the type', () {
        const error = CancelledException('stop');
        expect(ThreepioException.findCause<CancelledException>(error), same(error));
      });

      test('looks through a chain of causes', () {
        const root = CancelledException('user pressed stop');
        const chain = _WrappedFailure(
          'graph failed',
          cause: _WrappedFailure('node failed', cause: root),
        );

        expect(ThreepioException.findCause<CancelledException>(chain), same(root));
        expect(ThreepioException.findCause<_WrappedFailure>(chain), same(chain));
      });

      test('finds a cause that is not a threepio exception', () {
        final root = FormatException('bad');
        final chain = _WrappedFailure('parse failed', cause: root);
        expect(ThreepioException.findCause<FormatException>(chain), same(root));
      });

      test('finds an interrupt behind a wrapper', () {
        const signal = _Interrupted();
        const chain = _WrappedFailure('tool failed', cause: signal);
        expect(ThreepioException.findCause<InterruptSignal>(chain), same(signal));
      });

      test('returns null when nothing in the chain has the type', () {
        const chain = _WrappedFailure('a', cause: _WrappedFailure('b'));
        expect(ThreepioException.findCause<CancelledException>(chain), isNull);
        expect(ThreepioException.findCause<CancelledException>(null), isNull);
        expect(ThreepioException.findCause<CancelledException>('text'), isNull);
      });

      test('does not look behind an error that is not a threepio exception', () {
        // Only ThreepioException has a cause this function knows about.
        final outer = StateError('outer');
        expect(ThreepioException.findCause<CancelledException>(outer), isNull);
      });

      test('terminates on a chain that refers to itself', () {
        expect(ThreepioException.findCause<CancelledException>(_Cycle()), isNull);
      });
    });
  });

  group('ThreepioFormatException', () {
    test('is a FormatException and a ThreepioException', () {
      const Object error = ThreepioFormatException('bad input');
      expect(error, isA<FormatException>());
      expect(error, isA<ThreepioException>());
      expect(error, isA<Exception>());
    });

    test('keeps message, source, offset and cause', () {
      const cause = FormatException('inner');
      const error = ThreepioFormatException(
        'bad input',
        source: '{"a": }',
        offset: 6,
        cause: cause,
      );
      expect(error.message, 'bad input');
      expect(error.source, '{"a": }');
      expect(error.offset, 6);
      expect(error.cause, same(cause));
      expect(error.toString(), startsWith('FormatException: bad input'));
    });

    test('is what a template that cannot be rendered throws', () async {
      await expectLater(
        Message.user('{missing}').format(ctx, const {}, FormatType.fString),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        const MessagesPlaceholder('history')
            .format(ctx, const {}, FormatType.fString),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        Message.user('{% if %}').format(ctx, const {}, FormatType.jinja2),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.cause, 'cause', isNotNull),
        ),
      );
    });

    test('is what a message parser throws for output that does not parse',
        () async {
      final parser = MessageJsonParser<Map<String, dynamic>>.object(
        fromJson: (json) => json,
      );

      await expectLater(
        parser.parse(ctx, Message.assistant('not json')),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
      await expectLater(
        parser.parse(ctx, Message.assistant('[1]')),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        MessageJsonParser<int>(
          fromJson: (json) => json! as int,
          parseFrom: MessageParseFrom.toolCall,
        ).parse(ctx, Message.assistant('1')),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('wraps a FormatException thrown by the fromJson of a parser',
        () async {
      final parser = MessageJsonParser<int>(
        fromJson: (json) => int.parse(json! as String),
      );

      await expectLater(
        parser.parse(ctx, Message.assistant('"twelve"')),
        throwsA(
          isA<ThreepioFormatException>()
              .having(
                (e) => e.message,
                'message',
                contains('failed to unmarshal content'),
              )
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('is what an unknown data type name throws', () {
      expect(
        () => DataType.parse('date'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  group('the exception types that existed before the base class', () {
    test('are all threepio exceptions with a message', () {
      final exceptions = <ThreepioException>[
        const CancelledException('stop'),
        const StreamClosedException(),
        OpenRouterException('rate limited', statusCode: 429, isRetryable: true),
        OpenAIException('bad request', statusCode: 400),
        GeminiException('quota'),
        GeminiConfigException('no key'),
        OpenAIEmbedderException('failed'),
        VectorStoreException('dimension mismatch'),
        DocumentLoaderException('missing file'),
        const UrlLoaderException('not found', statusCode: 404),
        const NoParserFoundException(extension: '.xyz'),
        OutputParserException('not json'),
        ValidationException(
          const ValidationResult(
            isValid: false,
            errors: ['a is required'],
            data: {},
          ),
        ),
        CallbackException('handler failed'),
        ChainException('step failed'),
        TemplateFormatException('missing variable'),
        GraphExecutionException('node failed', nodeName: 'n'),
        CheckpointNotFoundException('cp-1', threadId: 't-1'),
        CheckpointCorruptedException('cp-1', cause: 'truncated'),
        CheckpointStoreException('disk full', operation: 'save'),
        CheckpointIncompatibleException('schema changed'),
        InvalidHumanInputException(nodeName: 'approve', message: 'yes or no'),
        const ToolNotFoundException(toolName: 'search'),
        const AgentCancelledException(),
        const ContextualToolException('declined'),
        const RunInProgressException('session-1'),
        AgentLimitException('too many iterations'),
      ];

      for (final exception in exceptions) {
        expect(exception, isA<Exception>(), reason: '${exception.runtimeType}');
        expect(
          exception.message,
          isNotEmpty,
          reason: '${exception.runtimeType}',
        );
      }
    });

    test('keep their own fields and their text', () {
      const cancelled = CancelledException('user pressed stop');
      expect(cancelled.reason, 'user pressed stop');
      expect(cancelled.message, 'user pressed stop');
      expect(cancelled.toString(), 'CancelledException(user pressed stop)');
      expect(const CancelledException().message, 'The operation was cancelled');
      expect(const CancelledException().toString(), 'CancelledException');

      const closed = StreamClosedException();
      expect(closed.toString(), 'Attempted to receive from closed stream');
      expect(closed.message, closed.toString());

      const noParser = NoParserFoundException(
        extension: '.xyz',
        availableExtensions: ['.md', '.html'],
      );
      expect(
        noParser.toString(),
        'NoParserFoundException: No parser for extension ".xyz". '
        'Available: .md, .html',
      );
      expect(
        noParser.message,
        'No parser for extension ".xyz". Available: .md, .html',
      );
      expect(
        const NoParserFoundException(mimeType: 'x/y').toString(),
        'NoParserFoundException: No parser for MIME type "x/y"',
      );
      expect(
        const NoParserFoundException().toString(),
        'NoParserFoundException: No parser found',
      );

      final notFound = CheckpointNotFoundException('cp-1', threadId: 't-1');
      expect(notFound.message, 'Checkpoint "cp-1" not found in thread t-1');
      expect(notFound.toString(), 'CheckpointNotFoundException: ${notFound.message}');
      expect(
        CheckpointNotFoundException('cp-2').message,
        'Checkpoint "cp-2" not found',
      );

      final corrupted = CheckpointCorruptedException('cp-1', cause: 'truncated');
      expect(corrupted.message, 'Checkpoint "cp-1" is corrupted');
      expect(corrupted.cause, 'truncated');

      const busy = RunInProgressException('session-1');
      expect(busy.message, 'session session-1 is busy');
      expect(busy.toString(), 'RunInProgressException: session session-1 is busy');
    });

    test('expose the error they wrap as the cause', () {
      final root = StateError('root');
      expect(CallbackException('x', cause: root).cause, same(root));
      expect(ChainException('x', cause: root).cause, same(root));
      expect(GraphExecutionException('x', cause: root).cause, same(root));
      expect(
        ToolExecutionException(toolName: 't', message: 'x', cause: root).cause,
        same(root),
      );
      expect(
        ThreepioException.findCause<StateError>(
          GraphExecutionException('x', cause: ChainException('y', cause: root)),
        ),
        same(root),
      );
      expect(OpenRouterException('x').cause, isNull);
    });

    test('a provider error is still a ChatModelException', () {
      final Object error = OpenRouterException('gone', isModelUnavailable: true);
      expect(error, isA<ChatModelException>());
      expect(error, isA<ThreepioException>());
      expect((error as ChatModelException).isModelUnavailable, isTrue);
    });

    test('one handler catches what a parser registry and a vector store throw',
        () async {
      final caught = <ThreepioException>[];

      try {
        await ParserRegistry().parseFile('notes.nope', Uint8List(0));
      } on ThreepioException catch (error) {
        caught.add(error);
      }
      try {
        await InMemoryVectorStore().addDocuments([Document.simple('no vector')]);
      } on ThreepioException catch (error) {
        caught.add(error);
      }

      expect(caught, [
        isA<NoParserFoundException>(),
        isA<VectorStoreException>(),
      ]);
    });
  });

  group('what is not a threepio exception', () {
    test('the signals of a stream', () {
      expect(const StreamEOFException(), isNot(isA<ThreepioException>()));
      expect(const NoValueException(), isNot(isA<ThreepioException>()));
      expect(SourceEOFException('a'), isNot(isA<ThreepioException>()));
    });

    test('a read loop can catch the end of the stream and failures apart',
        () async {
      final reader = StreamReader.fromIterable([1, 2]);
      final seen = <int>[];
      var failures = 0;

      while (true) {
        try {
          seen.add(await reader.recv());
        } on ThreepioException {
          failures++;
        } on StreamEOFException {
          break;
        }
      }

      expect(seen, [1, 2]);
      expect(failures, 0);
    });

    test('an interrupt signal', () {
      const Object signal = _Interrupted();
      expect(signal, isA<Exception>());
      expect(signal, isNot(isA<ThreepioException>()));
    });
  });

  group('isInterrupt', () {
    test('is true for a signal', () {
      expect(isInterrupt(const _Interrupted()), isTrue);
    });

    test('is true for an exception raised because of a signal', () {
      const wrapped = _WrappedFailure(
        'graph failed',
        cause: _WrappedFailure('node failed', cause: _Interrupted()),
      );
      expect(isInterrupt(wrapped), isTrue);
      expect(
        isInterrupt(GraphExecutionException('x', cause: const _Interrupted())),
        isTrue,
      );
    });

    test('is false for everything else', () {
      expect(isInterrupt(const _WrappedFailure('plain')), isFalse);
      expect(isInterrupt(const CancelledException()), isFalse);
      expect(isInterrupt(StateError('x')), isFalse);
      expect(isInterrupt('text'), isFalse);
      expect(isInterrupt(null), isFalse);
    });
  });
}
