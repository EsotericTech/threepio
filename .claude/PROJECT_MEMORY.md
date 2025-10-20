# Threepio Project Memory

## Project Overview

**Threepio** is a Flutter/Dart port of the CloudWeGo Eino LLM application development framework from Golang.

### Purpose
Port the entire Eino framework (including Eino-ext) to Flutter/Dart, maintaining API compatibility while adapting to Dart idioms and leveraging the Flutter ecosystem.

### Repository Structure
```
threepio/
├── eino_modules/              # Original Golang source (for reference)
│   ├── eino/                 # Core Eino framework
│   └── eino-ext/             # Eino extensions
├── packages/                  # Flutter packages (to be created)
│   ├── threepio_core/        # Core framework
│   ├── threepio_extensions/  # Component implementations
│   └── threepio_flows/       # Pre-built flows
├── docs/                      # Documentation
│   └── IMPLEMENTATION_PLAN.md # Comprehensive implementation plan
└── examples/                  # Example applications

```

---

## What is Eino?

Eino is a production-grade Golang framework for building LLM applications. It provides:

1. **Component Abstractions** - Reusable building blocks
2. **Composition Framework** - Chain, Graph, and Workflow orchestration
3. **Stream Processing** - Comprehensive streaming support
4. **Callback System** - Cross-cutting concerns (logging, tracing, metrics)
5. **Component Implementations** - OpenAI, Claude, Gemini, etc.

### Key Eino Concepts

#### 1. Component Types
- **ChatModel** (`BaseChatModel`, `ToolCallingChatModel`) - LLM interfaces
- **Tool** (`InvokableTool`, `StreamableTool`) - Function calling
- **Retriever** - Document retrieval for RAG
- **Embedder** - Text embedding generation
- **Document Loader** - Load documents from various sources
- **Document Transformer** - Transform/split documents
- **Indexer** - Store documents in vector databases
- **ChatTemplate** - Prompt templates

#### 2. Orchestration Types
- **Chain** - Linear composition of components
- **Graph** - Cyclic/acyclic directed graphs with branches
- **Workflow** - Field-level data mapping

#### 3. Execution Modes
- **Invoke** - `I → O` (single input, single output)
- **Stream** - `I → Stream<O>` (single input, streamed output)
- **Collect** - `Stream<I> → O` (streamed input, single output)
- **Transform** - `Stream<I> → Stream<O>` (streamed input/output)

---

## Implementation Status

### Completed Analysis
- ✅ Full codebase review of Eino and Eino-ext
- ✅ Component architecture analysis
- ✅ Dependency mapping to Flutter packages
- ✅ Comprehensive implementation plan created
- ✅ Mermaid diagrams for architecture

### Implementation Plan
See `/docs/IMPLEMENTATION_PLAN.md` for the complete 30-week roadmap.

**Phases**:
1. Foundation (Weeks 1-4) - Schema, Streaming, Interfaces
2. Composition Engine (Weeks 5-8) - Runnable, Chain, Graph
3. Component Implementations (Weeks 9-16) - ChatModels, Tools, RAG
4. Advanced Features (Weeks 17-20) - Callbacks, State, Workflow
5. Pre-built Flows (Weeks 21-24) - ReAct, RAG patterns
6. DevOps & Tooling (Weeks 25-28) - Debugging, evaluation
7. Documentation (Weeks 29-30) - Docs, examples, tests

---

## Key Technical Decisions

### 1. Dart/Flutter Package Choices

| Purpose | Package |
|---------|---------|
| Immutability | `freezed` |
| JSON Serialization | `json_serializable` |
| HTTP Client | `dio` |
| Streaming | Native `Stream<T>` + `rxdart` |
| State Management | `rxdart` |
| Local Storage | `hive` |
| Async Utilities | `async`, `synchronized` |
| Templates | `mustache_template`, `jinja` |
| Document Processing | `pdf`, `markdown`, `csv` |
| Vector Math | `vector_math`, `ml_linalg` |

### 2. Architecture Patterns

**From Golang to Dart**:
- Goroutines → `async`/`await`, `Future`
- Channels → `Stream`, `StreamController`
- Interfaces → Abstract classes + mixins
- Generics `[T any]` → Dart generics `<T>`
- Context → Custom `Context` class
- Error returns → Exceptions or `Result<T, E>`

**Key Principles**:
- Use Dart's null safety rigorously
- Leverage immutable data classes with `@freezed`
- Stream-first approach for reactive data
- Test-driven development (90%+ coverage goal)
- Comprehensive documentation with dartdoc

---

## Component Mapping (Eino → Threepio)

### Core Schema
| Eino File | Threepio File | Status |
|-----------|---------------|--------|
| `schema/message.go` | `lib/src/schema/message.dart` | 📋 Planned |
| `schema/stream.go` | `lib/src/schema/stream.dart` | 📋 Planned |
| `schema/document.go` | `lib/src/schema/document.dart` | 📋 Planned |
| `schema/tool_info.go` | `lib/src/schema/tool_info.dart` | 📋 Planned |

### Component Interfaces
| Eino File | Threepio File | Status |
|-----------|---------------|--------|
| `components/model/interface.go` | `lib/src/components/model/base_chat_model.dart` | 📋 Planned |
| `components/tool/interface.go` | `lib/src/components/tool/invokable_tool.dart` | 📋 Planned |
| `components/retriever/interface.go` | `lib/src/components/retriever/retriever.dart` | 📋 Planned |
| `components/embedding/interface.go` | `lib/src/components/embedding/embedder.dart` | 📋 Planned |

### Composition
| Eino File | Threepio File | Status |
|-----------|---------------|--------|
| `compose/chain.go` | `lib/src/compose/chain.dart` | 📋 Planned |
| `compose/graph.go` | `lib/src/compose/graph.dart` | 📋 Planned |
| `compose/types.go` | `lib/src/compose/runnable.dart` | 📋 Planned |

---

## API Examples (Eino Go → Threepio Dart)

### Simple Chain
**Eino (Go)**:
```go
chain, _ := compose.NewChain[map[string]any, *schema.Message]().
    AppendChatTemplate(prompt).
    AppendChatModel(model).
    Compile(ctx)

result, _ := chain.Invoke(ctx, map[string]any{"query": "Hello"})
```

**Threepio (Dart)**:
```dart
final chain = Chain<Map<String, dynamic>, Message>()
  .appendChatTemplate(prompt)
  .appendChatModel(model);

final runnable = await chain.compile();
final result = await runnable.invoke({'query': 'Hello'});
```

### Graph with Branches
**Eino (Go)**:
```go
graph := NewGraph[map[string]any, *schema.Message]()
graph.AddChatModelNode("model", chatModel)
graph.AddToolsNode("tools", toolsNode)
graph.AddEdge(START, "model")
graph.AddBranch("model", branch)
graph.AddEdge("tools", END)
```

**Threepio (Dart)**:
```dart
final graph = Graph<Map<String, dynamic>, Message>()
  .addChatModelNode("model", chatModel)
  .addToolsNode("tools", toolsNode)
  .addEdge(START, "model")
  .addBranch("model", branch)
  .addEdge("tools", END);
```

---

## Important Notes for Future Work

### When Working on This Project

1. **Always reference the original Eino code** in `eino_modules/` for behavior details
2. **Follow the implementation plan** in `docs/IMPLEMENTATION_PLAN.md`
3. **Maintain API compatibility** while adapting to Dart idioms
4. **Test everything** - aim for 90%+ coverage
5. **Document as you go** - use dartdoc comments

### Key Files to Reference
- `/docs/IMPLEMENTATION_PLAN.md` - Complete roadmap
- `/eino_modules/eino/README.md` - Original Eino documentation
- `/eino_modules/eino/compose/` - Orchestration implementation
- `/eino_modules/eino/schema/` - Core data types
- `/eino_modules/eino-ext/components/` - Component implementations

### Streaming is Critical
- Eino's streaming infrastructure is complex and well-designed
- Pay special attention to `schema/stream.go` when implementing streams
- Test stream concatenation, merging, copying, and boxing thoroughly

### Graph Execution Modes
- **Pregel mode** - Can have cycles, suitable for agent loops
- **DAG mode** - Acyclic only, all predecessors must complete before node runs
- The framework handles both - this is a key differentiator

### Tool Calling
- Use `ToolCallingChatModel` interface (not deprecated `ChatModel`)
- `withTools()` returns a new instance - immutable pattern
- Tool execution happens in `ToolsNode`

---

## Next Steps

### Immediate Actions
1. Create Flutter package structure (`packages/`)
2. Set up CI/CD with GitHub Actions
3. Configure linting and analysis
4. Begin Phase 1: Foundation (see implementation plan)

### First Milestone: Foundation Complete (Week 4)
- Schema models implemented
- Stream utilities working
- All component interfaces defined
- Comprehensive tests passing

### First Usable Version: Phase 2 Complete (Week 8)
- Chain and Graph working
- Lambda support
- Can compose simple flows
- Basic examples working

### Production Ready: Phase 5 Complete (Week 24)
- All component types implemented
- ReAct agent working
- RAG patterns available
- Real-world examples

---

## Project Metadata

- **Created**: 2025-10-10
- **Original Framework**: Eino (CloudWeGo)
- **Source Language**: Golang
- **Target Language**: Dart/Flutter
- **Implementation Plan**: 30 weeks
- **Current Status**: Planning complete, ready for implementation
- **Documentation**: docs/IMPLEMENTATION_PLAN.md

---

## Resources

### Eino Documentation
- Eino GitHub: https://github.com/cloudwego/eino
- Eino-ext GitHub: https://github.com/cloudwego/eino-ext
- CloudWeGo Docs: https://www.cloudwego.io/docs/eino/

### Flutter/Dart Resources
- Dart Language Tour: https://dart.dev/guides/language/language-tour
- Flutter Docs: https://docs.flutter.dev/
- pub.dev: https://pub.dev/

---

**Last Updated**: 2025-10-10
