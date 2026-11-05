// Port of what eino `components/types.go` defines: the component kinds,
// Typer / GetType and Checker / IsCallbacksEnabled.
import 'package:test/test.dart';
import 'package:threepio_core/components.dart';
import 'package:threepio_core/threepio_core.dart' show RunInfo;

final class _Typed implements TypedComponent {
  @override
  String get componentTypeName => 'OpenAI';
}

final class _Aware implements CallbackAwareComponent {
  _Aware({required this.isCallbacksEnabled});

  @override
  final bool isCallbacksEnabled;
}

final class _Both implements TypedComponent, CallbackAwareComponent {
  @override
  String get componentTypeName => 'Both';

  @override
  bool get isCallbacksEnabled => true;
}

void main() {
  group('ComponentType', () {
    test('keeps the values it had, in their order', () {
      // Consumers use these by name; persisted indexes must not shift.
      expect(ComponentType.values.take(9), [
        ComponentType.chatModel,
        ComponentType.tool,
        ComponentType.chain,
        ComponentType.retriever,
        ComponentType.embedder,
        ComponentType.promptTemplate,
        ComponentType.runnable,
        ComponentType.agent,
        ComponentType.custom,
      ]);
      expect(ComponentType.chain.name, 'chain');
      expect(ComponentType.chain.toString(), 'ComponentType.chain');
    });

    test('has the kinds of eino components and compose', () {
      expect(
        ComponentType.values.skip(9),
        [
          ComponentType.indexer,
          ComponentType.loader,
          ComponentType.documentTransformer,
          ComponentType.graph,
          ComponentType.workflow,
          ComponentType.lambda,
          ComponentType.toolsNode,
        ],
      );
    });

    test('einoName is the name Eino gives each kind', () {
      expect(
        {for (final type in ComponentType.values) type: type.einoName},
        {
          // components/types.go
          ComponentType.promptTemplate: 'ChatTemplate',
          ComponentType.chatModel: 'ChatModel',
          ComponentType.embedder: 'Embedding',
          ComponentType.indexer: 'Indexer',
          ComponentType.retriever: 'Retriever',
          ComponentType.loader: 'Loader',
          ComponentType.documentTransformer: 'DocumentTransformer',
          ComponentType.tool: 'Tool',
          // compose/types.go
          ComponentType.graph: 'Graph',
          ComponentType.workflow: 'Workflow',
          ComponentType.chain: 'Chain',
          ComponentType.toolsNode: 'ToolsNode',
          ComponentType.lambda: 'Lambda',
          ComponentType.custom: 'Unknown',
          // adk/interface.go
          ComponentType.agent: 'Agent',
          // threepio only
          ComponentType.runnable: 'Runnable',
        },
      );
    });

    test('can be used in a const RunInfo, as before', () {
      const info = RunInfo(
        name: 'job',
        type: 'ActionGraph',
        componentType: ComponentType.chain,
      );
      expect(info.componentType.einoName, 'Chain');
    });
  });

  group('componentTypeNameOf (eino GetType)', () {
    test('returns the name of a typed component', () {
      expect(componentTypeNameOf(_Typed()), 'OpenAI');
      expect(componentTypeNameOf(_Both()), 'Both');
    });

    test('returns null for anything else', () {
      expect(componentTypeNameOf(_Aware(isCallbacksEnabled: true)), isNull);
      expect(componentTypeNameOf('a string'), isNull);
      expect(componentTypeNameOf(null), isNull);
    });
  });

  group('isCallbacksEnabled (eino IsCallbacksEnabled)', () {
    test('is what a callback-aware component says', () {
      expect(isCallbacksEnabled(_Aware(isCallbacksEnabled: true)), isTrue);
      expect(isCallbacksEnabled(_Aware(isCallbacksEnabled: false)), isFalse);
      expect(isCallbacksEnabled(_Both()), isTrue);
    });

    test('is false for anything else', () {
      expect(isCallbacksEnabled(_Typed()), isFalse);
      expect(isCallbacksEnabled(42), isFalse);
      expect(isCallbacksEnabled(null), isFalse);
    });
  });
}
