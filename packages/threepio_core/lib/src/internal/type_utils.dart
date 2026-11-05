/// Runtime checks on type arguments.
///
/// Dart generics are reified, so the checks Eino makes with Go's `reflect`
/// package (do the types of two connected nodes line up? is this value a
/// `map[string]any`?) are ordinary `is` tests on type parameters here.
library;

/// Whether [S] is a subtype of [T], for example `isSubtype<int, num>()`.
///
/// Every type is a subtype of itself, of `Object?` and of `dynamic`.
bool isSubtype<S, T>() => <S>[] is List<T>;

/// Whether [S] and [T] are the same type, up to mutual subtyping.
bool isSameType<S, T>() => isSubtype<S, T>() && isSubtype<T, S>();

/// Whether [value] is a [T].
///
/// A function form of `value is T` that can be stored with its type argument
/// (`final accepts = isInstance<Message>;`), which is how registries match a
/// value without looking at its `runtimeType`. Runtime types are often
/// private implementation classes (`_Message`, `_GrowableList`) and never
/// equal the public type.
bool isInstance<T>(Object? value) => value is T;

/// Whether `null` is a value of [T].
bool isNullable<T>() => null is T;
