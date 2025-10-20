import 'package:test/test.dart';
import 'package:threepio_core/src/components/prompt/chat_prompt_template.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('MessageTemplate', () {
    test('system template creates system message', () {
      final template = MessageTemplate.system('You are a {role}.');
      final message = template.format({'role': 'teacher'});

      expect(message.role, equals(RoleType.system));
      expect(message.content, equals('You are a teacher.'));
    });

    test('user template creates user message', () {
      final template = MessageTemplate.user('Hello {name}!');
      final message = template.format({'name': 'World'});

      expect(message.role, equals(RoleType.user));
      expect(message.content, equals('Hello World!'));
    });

    test('assistant template creates assistant message', () {
      final template = MessageTemplate.assistant('I am {name}.');
      final message = template.format({'name': 'Assistant'});

      expect(message.role, equals(RoleType.assistant));
      expect(message.content, equals('I am Assistant.'));
    });
  });

  group('ChatPromptTemplate', () {
    test('formats multiple messages', () async {
      final template = ChatPromptTemplate.fromMessages([
        MessageTemplate.system('You are a {role}.'),
        MessageTemplate.user('My name is {name}. {question}'),
      ]);

      final messages = await template.format({
        'role': 'assistant',
        'name': 'Alice',
        'question': 'How are you?',
      });

      expect(messages, hasLength(2));
      expect(messages[0].role, equals(RoleType.system));
      expect(messages[0].content, equals('You are a assistant.'));
      expect(messages[1].role, equals(RoleType.user));
      expect(messages[1].content, equals('My name is Alice. How are you?'));
    });

    test('throws on missing variable', () async {
      final template = ChatPromptTemplate.fromMessages([
        MessageTemplate.user('Hello {name}!'),
      ]);

      expect(
        () => template.format({}),
        throwsArgumentError,
      );
    });

    test('fromTemplate creates simple template', () async {
      final template = ChatPromptTemplate.fromTemplate(
        systemTemplate: 'You are helpful.',
        userTemplate: 'Question: {question}',
      );

      final messages = await template.format({'question': 'What is AI?'});

      expect(messages, hasLength(2));
      expect(messages[0].role, equals(RoleType.system));
      expect(messages[0].content, equals('You are helpful.'));
      expect(messages[1].role, equals(RoleType.user));
      expect(messages[1].content, equals('Question: What is AI?'));
    });

    test('fromTemplate without system message', () async {
      final template = ChatPromptTemplate.fromTemplate(
        userTemplate: 'Question: {question}',
      );

      final messages = await template.format({'question': 'Hello?'});

      expect(messages, hasLength(1));
      expect(messages[0].role, equals(RoleType.user));
    });

    test('partial variables work', () async {
      final template = ChatPromptTemplate.fromMessages(
        [
          MessageTemplate.system('You are a {role}.'),
          MessageTemplate.user('{question}'),
        ],
        partialVariables: {'role': 'helper'},
      );

      final messages = await template.format({'question': 'Help me!'});

      expect(messages[0].content, equals('You are a helper.'));
      expect(messages[1].content, equals('Help me!'));
    });

    test('partial() creates new template', () async {
      final template = ChatPromptTemplate.fromTemplate(
        systemTemplate: 'You are a {role}.',
        userTemplate: '{question}',
      );

      final partial = template.partial({'role': 'teacher'});
      final messages = await partial.format({'question': 'Teach me.'});

      expect(messages[0].content, equals('You are a teacher.'));
    });

    test('extracts all variables from multiple messages', () async {
      final template = ChatPromptTemplate.fromMessages([
        MessageTemplate.system('Role: {role}'),
        MessageTemplate.user('Name: {name}, Question: {question}'),
      ]);

      // Access private method via format to test variable extraction
      expect(
        () => template.format({}),
        throwsArgumentError,
      );
    });

    test('handles complex variable patterns', () async {
      final template = ChatPromptTemplate.fromMessages([
        MessageTemplate.user('Hi {name}, you are {age} years old in {city}.'),
      ]);

      final messages = await template.format({
        'name': 'Bob',
        'age': 25,
        'city': 'Paris',
      });

      expect(
        messages[0].content,
        equals('Hi Bob, you are 25 years old in Paris.'),
      );
    });
  });
}
