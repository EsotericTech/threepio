import 'dart:io';

import 'package:test/test.dart';

/// Environment variable that opts in to the tests tagged `integration`.
///
/// Those tests call live provider APIs, so they cost money and need network
/// access. They run only when this variable is set to `1`.
const integrationSwitch = 'THREEPIO_INTEGRATION';

/// Returns the API key stored in the environment variable [keyVariable] when
/// integration tests are enabled and the key is present.
///
/// Otherwise declares a single skipped test named after [suite] that explains
/// what is missing, and returns `null`; the caller then returns from `main`
/// without declaring its tests.
String? integrationApiKey(String keyVariable, {required String suite}) {
  final environment = Platform.environment;
  final String reason;

  if (environment[integrationSwitch] != '1') {
    reason = 'set $integrationSwitch=1 to run tests against live APIs';
  } else {
    final key = environment[keyVariable];
    if (key != null && key.isNotEmpty) return key;
    reason = '$keyVariable is not set';
  }

  test(suite, () {}, skip: reason);
  return null;
}
