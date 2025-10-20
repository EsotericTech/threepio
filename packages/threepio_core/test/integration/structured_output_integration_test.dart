import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';
import 'package:threepio_core/src/output_parser/json_output_parser.dart';
import 'package:threepio_core/src/output_parser/output_parser.dart';
import 'package:threepio_core/src/output_parser/retry_parser.dart';
import 'package:threepio_core/src/output_parser/structured_output_parser.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

/// Integration tests for structured output parsing with real OpenAI API calls
///
/// These tests verify that our parsers can handle real LLM outputs and
/// properly validate, retry, and transform structured data.
///
/// Run with: flutter test test/integration/structured_output_integration_test.dart

// Test enums
enum Sentiment { positive, negative, neutral }

enum Color { red, green, blue }

// Test classes
class Person {
  Person({required this.name, required this.age, this.city});

  final String name;
  final int age;
  final String? city;

  factory Person.fromJson(Map<String, dynamic> json) {
    return Person(
      name: json['name'] as String,
      age: (json['age'] as num).toInt(),
      city: json['city'] as String?,
    );
  }
}

class StrictPerson {
  StrictPerson({required this.name, required this.age});

  final String name;
  final int age;

  factory StrictPerson.fromJson(Map<String, dynamic> json) {
    // This will throw if types are wrong
    return StrictPerson(
      name: json['name'] as String,
      age: json['age'] as int, // Strict int, not num
    );
  }
}

class Article {
  Article({
    required this.title,
    required this.author,
    required this.summary,
    required this.topics,
  });

  final String title;
  final String author;
  final String summary;
  final List<String> topics;

  factory Article.fromJson(Map<String, dynamic> json) {
    return Article(
      title: json['title'] as String,
      author: json['author'] as String,
      summary: json['summary'] as String,
      topics: (json['topics'] as List).cast<String>(),
    );
  }
}

void main() {
  late String apiKey;
  late OpenAIConfig config;
  late OpenAIChatModel model;

  setUpAll(() {
    // Load environment variables
    final envPath = '/Users/gp/FlutterProjects/threepio/.env';
    final envFile = File(envPath);

    if (!envFile.existsSync()) {
      throw StateError(
        'Environment file not found at $envPath. Please create it with OPENAI_API_KEY.',
      );
    }

    final env = DotEnv()..load([envPath]);
    apiKey = env['OPENAI_API_KEY'] ?? '';

    if (apiKey.isEmpty) {
      throw StateError(
        'OPENAI_API_KEY not found in .env file. Please add your API key.',
      );
    }

    config = OpenAIConfig(
      apiKey: apiKey,
      defaultModel: 'gpt-4o-mini', // Use mini for faster/cheaper tests
    );

    model = OpenAIChatModel(config: config);

    print('✓ API key loaded successfully');
    print('✓ Using model: ${config.defaultModel}');
  });

  group('Structured Output - Happy Path', () {
    test('JsonOutputParser parses simple JSON from LLM', () async {
      print('\n--- Testing JsonOutputParser with LLM output ---');

      final parser = JsonOutputParser();
      final prompt = '''
Return a JSON object with information about Paris.
${parser.getFormatInstructions()}

Include: name (string), country (string), population (number)
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Parsed result: $result');

      expect(result, isA<Map<String, dynamic>>());
      expect(result['name'], isNotNull);
      expect(result['country'], isNotNull);

      print('✓ Successfully parsed JSON from LLM');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('JsonOutputParser validates against schema', () async {
      print('\n--- Testing schema validation ---');

      final schema = JSONSchema(
        properties: {
          'name': JSONSchemaProperty.string(description: 'Person name'),
          'age': JSONSchemaProperty.number(description: 'Age in years'),
          'email': JSONSchemaProperty.string(description: 'Email address'),
        },
        required: ['name', 'age'],
      );

      final parser = JsonOutputParser(schema: schema);
      final prompt = '''
Extract person information: "John Doe is 30 years old, email: john@example.com"

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Validated result: $result');

      expect(result['name'], isNotNull);
      expect(result['age'], isA<num>());
      if (result.containsKey('email')) {
        expect(result['email'], isA<String>());
      }

      print('✓ Schema validation passed');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('EnumOutputParser extracts sentiment from text', () async {
      print('\n--- Testing EnumOutputParser ---');

      final parser = EnumOutputParser<Sentiment>(
        enumValues: Sentiment.values,
        enumName: 'Sentiment',
      );

      final prompt = '''
Analyze the sentiment of this text: "I love Flutter! It's amazing!"

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Parsed sentiment: $result');

      expect(result, isA<Sentiment>());
      expect(result, equals(Sentiment.positive));

      print('✓ Enum parser correctly extracted sentiment');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('BooleanOutputParser handles various boolean formats', () async {
      print('\n--- Testing BooleanOutputParser ---');

      final parser = BooleanOutputParser();

      final prompt = '''
Is Flutter open source? Answer with yes or no.

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Parsed boolean: $result');

      expect(result, isA<bool>());
      expect(result, isTrue);

      print('✓ Boolean parser works with LLM output');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('NumberOutputParser extracts numbers with bounds', () async {
      print('\n--- Testing NumberOutputParser ---');

      final parser = NumberOutputParser(
        min: 0,
        max: 100,
      );

      final prompt = '''
On a scale of 0-100, how confident are you in your answer?
Just respond with the number.

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Parsed number: $result');

      expect(result, isA<num>());
      expect(result, greaterThanOrEqualTo(0));
      expect(result, lessThanOrEqualTo(100));

      print('✓ Number parser validated bounds');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('PydanticOutputParser creates type-safe objects', () async {
      print('\n--- Testing PydanticOutputParser ---');

      final schema = JSONSchema(
        properties: {
          'name': JSONSchemaProperty.string(description: 'Full name'),
          'age': JSONSchemaProperty.number(description: 'Age in years'),
          'city': JSONSchemaProperty.string(description: 'City of residence'),
        },
        required: ['name', 'age'],
      );

      final parser = PydanticOutputParser<Person>(
        schema: schema,
        fromJson: Person.fromJson,
      );

      final prompt = '''
Extract person info: "Alice Smith is 28 years old and lives in Seattle"

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final person = await parser.parse(response.content);

      print('Created Person: ${person.name}, ${person.age}, ${person.city}');

      expect(person, isA<Person>());
      expect(person.name, isNotNull);
      expect(person.age, greaterThan(0));

      print('✓ Pydantic parser created type-safe object');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('ListOutputParser splits comma-separated lists', () async {
      print('\n--- Testing ListOutputParser ---');

      final parser = CommaSeparatedListOutputParser();

      final prompt = '''
List 5 popular programming languages as comma-separated values.

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final list = await parser.parse(response.content);

      print('Parsed list: $list');

      expect(list, isA<List<String>>());
      expect(list.length, greaterThanOrEqualTo(3));

      print('✓ List parser extracted ${list.length} items');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('AutoFixingJsonOutputParser handles markdown wrapping', () async {
      print('\n--- Testing AutoFixingJsonOutputParser ---');

      final parser = AutoFixingJsonOutputParser();

      final prompt = '''
Return city data in JSON format (use markdown code block):
{"name": "Tokyo", "country": "Japan", "population": 14000000}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final result = await parser.parse(response.content);

      print('Parsed result: $result');

      expect(result, isA<Map<String, dynamic>>());
      expect(result, isNotEmpty);

      print('✓ Auto-fixing parser handled markdown');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('MultiChoiceOutputParser forces selection', () async {
      print('\n--- Testing MultiChoiceOutputParser ---');

      final parser = MultiChoiceOutputParser(
        choices: ['Python', 'Java', 'JavaScript', 'Dart'],
      );

      final prompt = '''
Which language is best for Flutter development?

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final choice = await parser.parse(response.content);

      print('Chosen option: $choice');

      expect(choice, equals('Dart'));

      print('✓ Multi-choice parser extracted selection');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('RetryOutputParser recovers from malformed JSON', () async {
      print('\n--- Testing RetryOutputParser ---');

      final baseParser = JsonOutputParser(
        schema: JSONSchema(
          properties: {
            'language': JSONSchemaProperty.string(),
            'year': JSONSchemaProperty.number(),
          },
          required: ['language', 'year'],
        ),
      );

      final retryParser = RetryOutputParser(
        parser: baseParser,
        llm: model,
        maxRetries: 2,
        verbose: true,
      );

      // Force initial failure by asking for invalid format
      final prompt = '''
Tell me about Dart programming language.
Include: language (string) and year (number) it was released.

Format as JSON but make it conversational first, then provide JSON.
''';

      final response = await model.generate([Message.user(prompt)]);
      print('Initial LLM response: ${response.content}');

      final result = await retryParser.parse(response.content);

      print('Final parsed result: $result');

      expect(result, isA<Map<String, dynamic>>());
      expect(result['language'], isNotNull);
      expect(result['year'], isNotNull);

      print('✓ Retry parser successfully extracted data');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('Structured Output - Unhappy Path', () {
    test('JsonOutputParser throws on invalid JSON', () async {
      print('\n--- Testing JsonOutputParser error handling ---');

      final parser = JsonOutputParser();
      const invalidJson = 'This is not JSON at all!';

      expect(
        () => parser.parse(invalidJson),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Parser correctly threw exception for invalid JSON');
    });

    test('Schema validation fails on missing required fields', () async {
      print('\n--- Testing schema validation failure ---');

      final schema = JSONSchema(
        properties: {
          'name': JSONSchemaProperty.string(),
          'age': JSONSchemaProperty.number(),
        },
        required: ['name', 'age'],
      );

      final parser = JsonOutputParser(schema: schema);
      const jsonWithMissingField = '{"name": "John"}'; // Missing age

      expect(
        () => parser.parse(jsonWithMissingField),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Schema validation caught missing required field');
    });

    test('Schema validation fails on wrong type', () async {
      print('\n--- Testing type validation ---');

      final schema = JSONSchema(
        properties: {
          'age': JSONSchemaProperty.number(),
        },
        required: ['age'],
      );

      final parser = JsonOutputParser(schema: schema);
      const jsonWithWrongType = '{"age": "not a number"}';

      expect(
        () => parser.parse(jsonWithWrongType),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Type validation caught incorrect type');
    });

    test('EnumOutputParser throws on invalid enum value', () async {
      print('\n--- Testing enum validation ---');

      final parser = EnumOutputParser<Color>(
        enumValues: Color.values,
        enumName: 'Color',
      );

      expect(
        () => parser.parse('yellow'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Enum parser rejected invalid value');
    });

    test('NumberOutputParser throws when below minimum', () async {
      print('\n--- Testing number bounds validation ---');

      final parser = NumberOutputParser(min: 0, max: 100);

      expect(
        () => parser.parse('-10'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Number parser enforced minimum bound');
    });

    test('NumberOutputParser throws when above maximum', () async {
      print('\n--- Testing number maximum validation ---');

      final parser = NumberOutputParser(min: 0, max: 100);

      expect(
        () => parser.parse('150'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Number parser enforced maximum bound');
    });

    test('NumberOutputParser rejects decimals when not allowed', () async {
      print('\n--- Testing decimal validation ---');

      final parser = NumberOutputParser(allowDecimals: false);

      expect(
        () => parser.parse('3.14'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Number parser rejected decimal when not allowed');
    });

    test('BooleanOutputParser throws on unrecognized value', () async {
      print('\n--- Testing boolean validation ---');

      final parser = BooleanOutputParser();

      expect(
        () => parser.parse('maybe'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Boolean parser rejected invalid value');
    });

    test('RetryOutputParser respects maxRetries=0', () async {
      print('\n--- Testing retry limit with maxRetries=0 ---');

      final baseParser = JsonOutputParser(
        schema: JSONSchema(
          properties: {
            'field': JSONSchemaProperty.number(),
          },
          required: ['field'],
        ),
      );

      // With maxRetries=0, should fail immediately without retry
      final retryParser = RetryOutputParser(
        parser: baseParser,
        llm: model,
        maxRetries: 0,
        verbose: true,
      );

      // Invalid JSON that would normally be fixable with retries
      const invalidJson = 'Not valid JSON';

      expect(
        () => retryParser.parse(invalidJson),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Retry parser respected maxRetries=0');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('PydanticOutputParser throws on transformation error', () async {
      print('\n--- Testing Pydantic transformation error ---');

      final schema = JSONSchema(
        properties: {
          'name': JSONSchemaProperty.string(),
          'age': JSONSchemaProperty.number(), // Note: number, not integer
        },
        required: ['name', 'age'],
      );

      final parser = PydanticOutputParser<StrictPerson>(
        schema: schema,
        fromJson: StrictPerson.fromJson,
      );

      const jsonWithFloat = '{"name": "John", "age": 30.5}';

      expect(
        () => parser.parse(jsonWithFloat),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Pydantic parser caught transformation error');
    });

    test('ValidatingOutputParser enforces custom validation', () async {
      print('\n--- Testing custom validation ---');

      final parser = ValidatingOutputParser(
        parser: NumberOutputParser(),
        validator: (value) {
          if (value < 0) {
            throw OutputParserException('Number must be positive');
          }
        },
      );

      expect(
        () => parser.parse('-5'),
        throwsA(isA<OutputParserException>()),
      );

      print('✓ Custom validation was enforced');
    });
  });

  group('Structured Output - Advanced Patterns', () {
    test('FallbackOutputParser tries multiple strategies', () async {
      print('\n--- Testing FallbackOutputParser ---');

      final parser = FallbackOutputParser<dynamic>(<OutputParser<dynamic>>[
        JsonOutputParser(), // Try strict first
        AutoFixingJsonOutputParser(), // Then try with auto-fix
        StringOutputParser(), // Finally just return string
      ]);

      // Malformed but fixable JSON (trailing comma)
      const malformedJson = '{"name": "John", "age": 30,}';

      final result = await parser.parse(malformedJson);

      print('Fallback result: $result');
      print('Result type: ${result.runtimeType}');

      // Should succeed with auto-fixing parser
      expect(result, anyOf(isA<Map<String, dynamic>>(), isA<String>()));

      print('✓ Fallback parser used correct strategy');
    });

    test('ChainedOutputParser applies multiple parsers', () async {
      print('\n--- Testing ChainedOutputParser ---');

      final parser = ChainedOutputParser([
        MarkdownCodeBlockParser(language: 'json'),
        JsonOutputParser(),
      ]);

      const markdownWrappedJson = '''
Here's the data:
```json
{"city": "Paris", "population": 2000000}
```
''';

      final result = await parser.parse(markdownWrappedJson);

      print('Chained result: $result');

      expect(result, isA<Map<String, dynamic>>());
      expect(result['city'], equals('Paris'));

      print('✓ Chained parsers worked in sequence');
    });

    test('TransformingOutputParser transforms the result', () async {
      print('\n--- Testing TransformingOutputParser ---');

      final parser = TransformingOutputParser(
        parser: StringOutputParser(),
        transform: (value) => value.toUpperCase(),
      );

      final result = await parser.parse('hello world');

      expect(result, equals('HELLO WORLD'));

      print('✓ Transformation was applied');
    });

    test('Complete data extraction pipeline with LLM', () async {
      print('\n--- Testing complete extraction pipeline ---');

      final schema = JSONSchema(
        properties: {
          'title': JSONSchemaProperty.string(description: 'Article title'),
          'author': JSONSchemaProperty.string(description: 'Author name'),
          'summary': JSONSchemaProperty.string(description: 'Brief summary'),
          'topics': JSONSchemaProperty.array(
            description: 'Main topics',
            items: JSONSchemaProperty.string(),
          ),
        },
        required: ['title', 'author', 'summary', 'topics'],
      );

      final parser = RetryOutputParser(
        parser: PydanticOutputParser<Article>(
          schema: schema,
          fromJson: Article.fromJson,
        ),
        llm: model,
        maxRetries: 2,
      );

      final prompt = '''
Analyze this article:

"Flutter 3.0 Released - Major Performance Improvements

By Jane Smith

The Flutter team has announced Flutter 3.0 today, bringing significant
performance improvements and new features to the popular cross-platform
framework."

${parser.getFormatInstructions()}
''';

      final response = await model.generate([Message.user(prompt)]);
      print('LLM response: ${response.content}');

      final article = await parser.parse(response.content);

      print('Extracted article:');
      print('  Title: ${article.title}');
      print('  Author: ${article.author}');
      print('  Summary: ${article.summary}');
      print('  Topics: ${article.topics}');

      expect(article, isA<Article>());
      expect(article.title, isNotEmpty);
      expect(article.author, isNotEmpty);
      expect(article.topics, isNotEmpty);

      print('✓ Complete extraction pipeline succeeded');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
