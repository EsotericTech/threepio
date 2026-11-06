/// The prompts and markers of the tool reduction middleware, copied
/// verbatim from eino `adk/middlewares/reduction/consts.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../../eino/language.dart';
import '../internal/go_compat.dart';

/// The `extra` flag of an assistant message whose tool calls the clear
/// phase has handled. Port of `msgClearedFlag`.
const String msgClearedFlag = '_reduction_mw_processed';

const _truncFmt = r'''
<persisted-output>
Output too large ({original_size}). Full output saved to: {file_path}
Preview (first {preview_size}):
{preview_first}

Preview (last {preview_size}):
{preview_last}

Use {read_tool_name} to view
</persisted-output>''';

const _truncFmtZh = r'''
<persisted-output>
输出结果过大 ({original_size}). 完整输出保存到: {file_path}
预览 (前 {preview_size}):
{preview_first}

预览 (后 {preview_size}):
{preview_last}

使用 {read_tool_name} 进行查看
</persisted-output>''';

const _streamTruncFmt = r'''
<persisted-output>
Output truncated after {preview_size} bytes were streamed. {offload_notify} {error_msg_notify}
</persisted-output>''';

const _streamTruncFmtZh = r'''
<persisted-output>
输出结果在流式传输 {preview_size} 字节后被截断。{offload_notify} {error_msg_notify}
</persisted-output>''';

const _clearWithOffloadingFmt = '<persisted-output>Tool result saved to: {file_path}\nUse {read_tool_name} to view</persisted-output>';

const _clearWithOffloadingFmtZh = '<persisted-output>工具结果已保存至: {file_path}\n使用 {read_tool_name} 进行查看</persisted-output>';

const _clearWithoutOffloadingFmt = '[Old tool result content cleared]';

const _clearWithoutOffloadingFmtZh = '[工具输出结果已清理]';

String _pick(String english, String chinese) =>
    selectPrompt(I18nPrompts(english: english, chinese: chinese));

/// Port of `getTruncFmt`.
String getTruncFmt() => _pick(_truncFmt, _truncFmtZh);

/// Port of `getStreamTruncFmt`.
String getStreamTruncFmt() => _pick(_streamTruncFmt, _streamTruncFmtZh);

/// Port of `formatStreamOffloadSavedNotify`.
String formatStreamOffloadSavedNotify(String filePath, String readFileToolName) => goSprintf(
      _pick('Full output saved to: %s. Use %s to view.', '完整输出保存到: %s。使用 %s 进行查看。'),
      [filePath, readFileToolName],
    );

/// Port of `formatStreamOffloadFailedNotify`; `''` for no error.
String formatStreamOffloadFailedNotify(Object? error) {
  if (error == null) return '';
  return goSprintf(_pick('Failed to save full output: %v.', '完整输出保存失败: %v。'), [error]);
}

/// Port of `getClearWithOffloadingFmt`.
String getClearWithOffloadingFmt() => _pick(_clearWithOffloadingFmt, _clearWithOffloadingFmtZh);

/// Port of `getClearWithoutOffloadingFmt`.
String getClearWithoutOffloadingFmt() =>
    _pick(_clearWithoutOffloadingFmt, _clearWithoutOffloadingFmtZh);
