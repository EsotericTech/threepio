/// Structured Output Parsing
///
/// **Framework Sources:**
/// - **LangChain**: OutputParser abstractions, retry patterns
/// - **OpenAI**: JSON mode and function calling
/// - **Instructor**: Structured extraction patterns
/// - **Pydantic**: Schema-based validation
///
/// This module provides comprehensive support for parsing and validating
/// LLM outputs into type-safe, structured data. It includes:
///
/// ## Core Parsers
/// - **StringOutputParser**: No-op parser, returns raw string
/// - **JsonOutputParser**: Parse JSON with optional schema validation
/// - **JsonArrayOutputParser**: Parse JSON arrays
/// - **AutoFixingJsonOutputParser**: Automatically fixes common JSON issues
///
/// ## Type-Specific Parsers
/// - **EnumOutputParser**: Parse enum values with normalization
/// - **BooleanOutputParser**: Flexible boolean parsing
/// - **NumberOutputParser**: Numeric parsing with bounds checking
/// - **ListOutputParser**: Split text into lists
/// - **CommaSeparatedListOutputParser**: Parse CSV-style lists
///
/// ## Advanced Parsers
/// - **PydanticOutputParser**: Schema-based parsing with type transformation
/// - **RegexOutputParser**: Extract data using regular expressions
/// - **MultiChoiceOutputParser**: Force selection from predefined choices
/// - **MarkdownCodeBlockParser**: Extract code from markdown
///
/// ## Robust Parsing
/// - **RetryOutputParser**: Auto-retry with LLM when parsing fails
/// - **OutputFixingParser**: Proactively fix output before parsing
/// - **FallbackOutputParser**: Try multiple parsing strategies
/// - **ValidatingOutputParser**: Add custom validation logic
/// - **TransformingOutputParser**: Transform parsed output
///
/// ## Schema Support
/// - **SchemaValidator**: Validate JSON against JSONSchema
/// - **ValidationResult**: Detailed validation results
/// - **ValidationException**: Schema validation errors
///
/// Example usage:
/// ```dart
/// // Simple JSON parsing
/// final parser = JsonOutputParser();
/// final data = await parser.parse(llmOutput);
///
/// // With schema validation
/// final schema = JSONSchema(
///   properties: {
///     'name': JSONSchemaProperty.string(),
///     'age': JSONSchemaProperty.number(),
///   },
///   required: ['name'],
/// );
/// final validatingParser = JsonOutputParser(schema: schema);
///
/// // With auto-retry on errors
/// final retryParser = RetryOutputParser(
///   parser: validatingParser,
///   llm: chatModel,
/// );
///
/// // Pydantic-style parsing
/// final pydanticParser = PydanticOutputParser<Person>(
///   schema: personSchema,
///   fromJson: Person.fromJson,
/// );
/// final person = await pydanticParser.parse(llmOutput);
///
/// // Enum parsing
/// final enumParser = EnumOutputParser<Sentiment>(
///   enumValues: Sentiment.values,
///   enumName: 'Sentiment',
/// );
/// final sentiment = await enumParser.parse('positive');
/// ```
export 'json_output_parser.dart';
export 'output_parser.dart';
export 'retry_parser.dart';
export 'schema_validator.dart';
export 'structured_output_parser.dart';
