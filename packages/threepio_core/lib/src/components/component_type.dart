/// What a component can tell the framework about itself.
///
/// Port of eino `components/types.go`. The component kinds themselves are the
/// `ComponentType` enum of the callback library.
library;

/// A component that names its implementation.
///
/// Port of eino `components.Typer`. The name becomes the `type` of the
/// component's `RunInfo` and, joined with its kind, the name it shows up
/// under in traces: a chat model that returns `'OpenAI'` is displayed as
/// `OpenAIChatModel`. Use UpperCamelCase.
// ignore: one_member_abstracts
abstract interface class TypedComponent {
  /// The name of this implementation, without the kind of component.
  String get componentTypeName;
}

/// A component that says whether it fires its callbacks itself.
///
/// Port of eino `components.Checker`. A graph wraps every node in the start
/// and end callbacks. A component that returns `true` here is trusted to do
/// that on its own, with payloads that say more than its plain input and
/// output (a chat model reports its token usage, for example), and the graph
/// leaves it alone.
// ignore: one_member_abstracts
abstract interface class CallbackAwareComponent {
  /// Whether this component fires the callbacks of its own calls.
  bool get isCallbacksEnabled;
}

/// The implementation name of [component], or `null` when it does not say.
///
/// Port of eino `components.GetType`.
String? componentTypeNameOf(Object? component) =>
    component is TypedComponent ? component.componentTypeName : null;

/// Whether [component] fires its callbacks itself.
///
/// Port of eino `components.IsCallbacksEnabled`: `false` for everything that
/// is not a [CallbackAwareComponent].
bool isCallbacksEnabled(Object? component) =>
    component is CallbackAwareComponent && component.isCallbacksEnabled;
