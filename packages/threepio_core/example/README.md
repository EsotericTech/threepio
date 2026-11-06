# Threepio examples

Each file is a program: `dart run example/<file>.dart` from
`packages/threepio_core` (`example/eino_examples/<file>.dart` for the ports).

## Model and keys

Most examples get their chat model from
[`support/example_model.dart`](support/example_model.dart):

| Variable | Effect |
|---|---|
| `OPENROUTER_API_KEY` | use OpenRouter; the model is `OPENROUTER_MODEL` (default `openai/gpt-4o-mini`) |
| `OPENAI_API_KEY` | otherwise use OpenAI; the model is `OPENAI_MODEL` (default `gpt-4o-mini`), the endpoint `OPENAI_BASE_URL` (any OpenAI-compatible server) |

Without a key an example says what is missing and exits. The other examples
read their own variables, named in each file's header:

| Example | Variables |
|---|---|
| `mcp_tools_example.dart` | the model as above; the MCP server: `MCP_SERVER_URL` (streamable HTTP), else a command from the arguments or `MCP_SERVER_COMMAND`, else `npx -y @modelcontextprotocol/server-everything` (stdio, needs Node.js) |
| `agentic_agent_example.dart` | `OPENAI_API_KEY` (optional `OPENAI_RESPONSES_MODEL`, default `gpt-5-mini`; `OPENAI_BASE_URL`), else `OPENROUTER_API_KEY` (OpenRouter's Responses endpoint; optional `OPENROUTER_RESPONSES_MODEL`, default `openai/gpt-4o-mini`) |
| `basic_chat_example.dart` | `OPENAI_API_KEY` |
| `openrouter_example.dart` | `OPENROUTER_API_KEY` |
| `gemini_example.dart`, `adk_agents_example.dart` | `GEMINI_API_KEY` |
| `advanced_rag_example.dart` | `GEMINI_API_KEY` and `OPENAI_API_KEY` |
| `eino_examples/compose_graph_state.dart`, `checkpoint_example.dart` | none (no model) |

The Eino-shaped examples, the eino-examples ports and
`checkpoint_example.dart` keep their logic in functions that take the model
(and anything interactive) as parameters; `test/unit/examples/` runs those
functions with scripted models on each test run. The provider examples,
`advanced_rag_example.dart` and `adk_agents_example.dart` are only analyzed.

## Eino-shaped API (0.9)

| Example | Shows | Eino counterpart |
|---|---|---|
| [`graph_react_example.dart`](graph_react_example.dart) | A ReAct agent built by hand: a `Graph` with local state, a chat model node, a tools node and a branch; invoke, stream, Mermaid | `flow/agent/react` |
| [`workflow_example.dart`](workflow_example.dart) | A `Workflow` with field mapping and fan-in | `compose.NewWorkflow` |
| [`hitl_approval_example.dart`](hitl_approval_example.dart) | A tool that interrupts itself for approval; `Runner` with a checkpoint store; `resumeWithParams` | `compose.StatefulInterrupt`, `adk.Runner.ResumeWithParams` |
| [`deep_agent_example.dart`](deep_agent_example.dart) | `DeepAgent` with todos, filesystem tools on an in-memory backend, and a sub-agent | `adk/prebuilt/deep` |
| [`turn_loop_example.dart`](turn_loop_example.dart) | `TurnLoop`: pushed inputs become agent turns; preemption and stop | `adk.TurnLoop` |
| [`mcp_tools_example.dart`](mcp_tools_example.dart) | Tools from an MCP server (stdio or streamable HTTP) given to an agent | eino-ext `tool/mcp` |
| [`agentic_agent_example.dart`](agentic_agent_example.dart) | The agentic path (beta): `OpenAIResponsesModel`, `AgenticChatModelAgent`, content blocks | `adk` agentic agent, eino-ext `model/agenticopenai` |

### Ports of eino-examples

| Example | Port of |
|---|---|
| [`eino_examples/quickstart_chat.dart`](eino_examples/quickstart_chat.dart) | `quickstart/chat`: template, generate, stream; a template → model chain |
| [`eino_examples/quickstart_todoagent.dart`](eino_examples/quickstart_todoagent.dart) | `quickstart/todoagent`: a chain of a tool-calling model and a tools node, four ways to make a tool, global callbacks |
| [`eino_examples/compose_graph_state.dart`](eino_examples/compose_graph_state.dart) | `compose/graph/state`: state handlers and `processState` in a translate → review loop (runs without a model) |
| [`eino_examples/adk_hitl_approval.dart`](eino_examples/adk_hitl_approval.dart) | `adk/human-in-the-loop/1_approval`: `ApprovableTool`, interrupt, approve or reject, resume |

## Providers and the older API

| Example | Shows |
|---|---|
| [`basic_chat_example.dart`](basic_chat_example.dart) | `OpenAIChatModel.generate` |
| [`openrouter_example.dart`](openrouter_example.dart) | `OpenRouterChatModel`: text, streaming, images |
| [`gemini_example.dart`](gemini_example.dart) | `GeminiChatModel` |
| [`advanced_rag_example.dart`](advanced_rag_example.dart) | Retrieval-augmented generation with threepio's own retrieval components: Markdown-aware splitting, vector and hybrid retrieval, MMR reranking, multi-query retrieval, rank fusion |
| [`adk_agents_example.dart`](adk_agents_example.dart) | The umbrella's Kortney runtime (`ChatModelAgent`, `Runner`) and the legacy agents; new code uses `adk.dart` |
| [`checkpoint_example.dart`](checkpoint_example.dart) | Checkpoints and human input of the legacy `StateGraph` (`HumanInputNode`, `resumeWithHumanInput`); new code uses the compose checkpoints |

See the package [README](../README.md) for the quick start and the mapping
from Eino's Go names.
