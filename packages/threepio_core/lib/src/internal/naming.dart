/// Names derived from other names.
library;

/// The UpperCamelCase form of a snake_case [name]: `google_search_3` becomes
/// `GoogleSearch3`.
///
/// Port of eino's `snakeToCamel`, which names the type of a tool after the
/// tool. Every part starts with a capital letter and continues in lower case;
/// empty parts are dropped.
String snakeToUpperCamel(String name) {
  final buffer = StringBuffer();
  for (final part in name.split('_')) {
    if (part.isEmpty) continue;
    buffer
      ..write(part[0].toUpperCase())
      ..write(part.substring(1).toLowerCase());
  }
  return buffer.toString();
}
