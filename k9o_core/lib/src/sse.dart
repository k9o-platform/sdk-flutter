/// One server-sent-events frame with its control fields.
class SseFrame {
  final String? id;
  final String? event;

  /// The assembled `data:` text, or null for a frame that carries none.
  final String? data;

  /// The `retry:` hint in milliseconds, when the frame carries a valid one.
  final int? retry;
  const SseFrame({this.id, this.event, this.data, this.retry});
}

/// Incremental SSE parser. Feed decoded text; frames are separated by a blank line.
class SseParser {
  String _buffer = '';

  /// Add text and return the frames it completed.
  List<SseFrame> add(String chunk) {
    _buffer += chunk;
    final out = <SseFrame>[];
    while (true) {
      final lf = _buffer.indexOf('\n\n');
      final crlf = _buffer.indexOf('\r\n\r\n');
      final int sep;
      if (lf == -1) {
        sep = crlf;
      } else if (crlf == -1) {
        sep = lf;
      } else {
        sep = lf < crlf ? lf : crlf;
      }
      if (sep == -1) break;
      final raw = _buffer.substring(0, sep);
      _buffer = _buffer.substring(sep).replaceFirst(RegExp(r'^(\r?\n)+'), '');
      final f = _frameFrom(raw);
      if (f != null) out.add(f);
    }
    return out;
  }

  /// A trailing frame without its blank line, if any.
  List<SseFrame> close() {
    final tail = _buffer.trim();
    _buffer = '';
    if (tail.isEmpty) return const [];
    final f = _frameFrom(tail);
    return f == null ? const [] : [f];
  }

  static SseFrame? _frameFrom(String raw) {
    String? id;
    String? event;
    int? retry;
    final data = <String>[];
    var seen = false;
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      if (line.isEmpty || line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      final val = colon == -1
          ? ''
          : line.substring(colon + 1).replaceFirst(RegExp(r'^ '), '');
      if (field == 'data') {
        data.add(val);
      } else if (field == 'id') {
        id = val;
      } else if (field == 'event') {
        event = val;
      } else if (field == 'retry' && RegExp(r'^[0-9]+$').hasMatch(val)) {
        retry = int.parse(val);
      } else {
        continue;
      }
      seen = true;
    }
    if (!seen) return null;
    return SseFrame(
      id: id,
      event: event,
      data: data.isEmpty ? null : data.join('\n'),
      retry: retry,
    );
  }
}
