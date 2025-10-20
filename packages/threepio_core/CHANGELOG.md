# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-10-19

### Added

#### Core Components
- **Runnables & Lambda**: Composable execution units with type-safe transformations
- **Message Schema**: Comprehensive message types (System, User, Assistant, Tool)
- **Prompt Templates**: Dynamic prompt generation with variable substitution
- **Chat Models**: OpenAI integration with streaming support
- **Tool Calling**: Function calling with JSON schema validation

#### RAG (Retrieval Augmented Generation)
- **Document Loaders**: Text file and directory loaders
- **Text Splitters**: Character and recursive splitting strategies
- **Embeddings**: OpenAI embeddings support
- **Vector Stores**: In-memory vector store with similarity search
- **Retrievers**: Document retrieval with configurable parameters

#### Advanced Features
- **Graph Orchestration**: Build complex workflows with conditional routing and parallel execution
- **Agents**: ReAct agent with tool execution and iterative problem-solving
- **Memory & Persistence**: Multiple memory strategies (buffer, window, token-limited, summarization)
- **Callbacks**: Lifecycle hooks for monitoring and debugging
- **Streaming**: Full support for streaming responses

#### Observability & Cost Tracking
- **Langfuse Integration**: Production-ready observability with traces, spans, and generations
- **Cost Tracking Models**: Token usage tracking and cost calculation infrastructure
- **Batch Processing**: Efficient event batching with configurable flush intervals
- **Retry Logic**: Exponential backoff for robust API communication

#### Structured Output Parsing
- **Output Parsers**: JSON, List, Enum, Boolean, Number parsers
- **Schema Validation**: JSON Schema validation with detailed error messages
- **Auto-Retry**: LLM-powered error correction
- **Type-Safe**: Pydantic-style transformations to Dart objects

### Documentation
- Comprehensive README with 3,600+ lines covering all features
- Code examples for every major component
- API documentation with usage patterns
- Architecture overview and design principles

### Testing
- Unit tests for core components
- Integration tests with real OpenAI API calls
- Structured output parsing test suite (25 tests)
- Langfuse client tests (18 tests)

[0.1.0]: https://github.com/EsotericTech/threepio/releases/tag/v0.1.0
