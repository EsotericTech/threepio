/// The checks Go's SearXNG client runs on its request configuration, with
/// Go's messages.
///
/// Port of the unexported `validateInSlice` and `validateEngines` of
/// eino-ext `components/tool/searxng`. Internal; not exported.
@internal
library;

import 'package:meta/meta.dart';

import 'searxng_types.dart';

/// The engines Go accepts (`validEngines`), in Go's order: the wire values
/// of [SearxngEngine].
final List<String> searxngValidEngines = List.unmodifiable([
  for (final engine in SearxngEngine.values) engine.wireValue,
]);

/// Throws an [ArgumentError] saying `<paramName> must be one of: [a b c]`
/// when [value] is not among [validValues].
///
/// Port of `validateInSlice`; the list is written as Go's `%+v` writes a
/// slice ([goFormatList]).
void searxngValidateInSlice<T>(
  T value,
  List<T> validValues,
  String paramName,
) {
  for (final valid in validValues) {
    if (value == valid) return;
  }
  throw ArgumentError('$paramName must be one of: ${goFormatList(validValues)}');
}

/// Throws an [ArgumentError] saying `engine '<name>' is not supported. Valid
/// engines are: [google duckduckgo baidu bing 360search yahoo quark]` for
/// the first of [engines] Go does not accept.
///
/// Port of `validateEngines`.
void searxngValidateEngines(List<String> engines) {
  for (final engine in engines) {
    if (!searxngValidEngines.contains(engine)) {
      throw ArgumentError(
        "engine '$engine' is not supported. Valid engines are: "
        '${goFormatList(searxngValidEngines)}',
      );
    }
  }
}

/// [values] as Go's `%+v` writes a slice: `[a b c]`.
String goFormatList(List<Object?> values) =>
    '[${values.map(goFormatValue).join(' ')}]';

/// [value] as Go's `%v` writes it: strings as they are, integers in decimal,
/// floating-point numbers in Go's shortest `%g` form (`1`, `2.5`, `1e+06`),
/// `<nil>` for null.
String goFormatValue(Object? value) => switch (value) {
      null => '<nil>',
      final double number => _goFormatFloat(number),
      _ => '$value',
    };

/// Go's `strconv.FormatFloat(v, 'g', -1, 64)`: the shortest digits, in
/// exponent form when the exponent is below -4 or at least 6.
String _goFormatFloat(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? '+Inf' : '-Inf';
  if (value == 0) return value.isNegative ? '-0' : '0';

  final sign = value.isNegative ? '-' : '';
  // "1.2345e+6": the shortest digits and the decimal exponent.
  final exponential = value.abs().toStringAsExponential();
  final ePosition = exponential.indexOf('e');
  final mantissa = exponential.substring(0, ePosition);
  final exponent = int.parse(exponential.substring(ePosition + 1));
  final digits = mantissa.replaceFirst('.', '');

  if (exponent < -4 || exponent >= 6) {
    final exponentDigits = exponent.abs().toString().padLeft(2, '0');
    return '$sign${mantissa}e${exponent < 0 ? '-' : '+'}$exponentDigits';
  }
  if (exponent < 0) {
    return '${sign}0.${'0' * (-exponent - 1)}$digits';
  }
  final integerLength = exponent + 1;
  if (digits.length <= integerLength) {
    return '$sign${digits.padRight(integerLength, '0')}';
  }
  return '$sign${digits.substring(0, integerLength)}.'
      '${digits.substring(integerLength)}';
}
