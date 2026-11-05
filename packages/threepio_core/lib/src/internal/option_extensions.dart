/// What the `extensions` list of every component option class shares.
library;

/// The first of [extensions] that is a [T], or `null`.
///
/// The lookup goes by `is T`, never by `runtimeType`: a subclass of the
/// options type a component asks for is found too.
T? findExtension<T extends Object>(List<Object> extensions) {
  for (final extension in extensions) {
    if (extension is T) return extension;
  }
  return null;
}

/// The extensions of merged options: those of [other] first, so that
/// [findExtension] prefers them, then those of [base].
List<Object> mergeExtensions(List<Object> base, List<Object> other) {
  if (other.isEmpty) return base;
  if (base.isEmpty) return other;
  return List.unmodifiable([...other, ...base]);
}
