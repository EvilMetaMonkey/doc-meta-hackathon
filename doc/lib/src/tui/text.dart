/// Text for the TUI: styled spans, display widths and fitting text into a
/// number of terminal columns. Pure; nothing here touches the terminal.
library;

/// What a span means; the renderer maps it to a colour.
enum Tone {
  normal,

  /// Good: PASS, restored, ok, `+` lines.
  good,

  /// Bad: FAIL, the turn that broke it, errors, `-` lines.
  bad,

  /// Needs you: questions, warnings, stalled.
  warn,

  /// Secondary: times, short ids, hints.
  dim,

  /// Titles and the selected row.
  strong,

  /// The selection bar.
  selected,
}

/// A run of text in one tone.
class Span {
  final String text;
  final Tone tone;

  const Span(this.text, [this.tone = Tone.normal]);

  @override
  String toString() => text;
}

/// One screen line: spans, left to right.
typedef Line = List<Span>;

Line plain(String text, [Tone tone = Tone.normal]) => [Span(text, tone)];

/// The plain text of a line.
String lineText(Line line) => line.map((s) => s.text).join();

/// Columns one code point takes, with wcwidth semantics: combining marks
/// and zero-width characters 0, East Asian wide and fullwidth characters
/// and emoji 2, everything else 1. East Asian "ambiguous" characters
/// (for example ■ U+25A0) are 1, as in iTerm2 and Terminal.app by default.
int runeWidth(int rune) {
  if (rune == 0) return 0;
  if (rune < 32 || (rune >= 0x7f && rune < 0xa0)) return 0;
  if ((rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x200b && rune <= 0x200f) ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      rune == 0x20e3) {
    return 0;
  }
  if ((rune >= 0x1100 && rune <= 0x115f) ||
      (rune >= 0x2e80 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe30 && rune <= 0xfe4f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1f64f) ||
      (rune >= 0x1f900 && rune <= 0x1f9ff) ||
      (rune >= 0x20000 && rune <= 0x3fffd)) {
    return 2;
  }
  return 1;
}

/// Columns [text] takes on screen.
int displayWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    width += runeWidth(rune);
  }
  return width;
}

/// [text] cut to at most [width] columns, ending in "…" when cut.
String fit(String text, int width) {
  if (width <= 0) return '';
  if (displayWidth(text) <= width) return text;
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final w = runeWidth(rune);
    if (used + w > width - 1) break;
    buffer.writeCharCode(rune);
    used += w;
  }
  return '$buffer…';
}

/// [text] padded with spaces to exactly [width] columns (cut if longer).
String pad(String text, int width) {
  final cut = fit(text, width);
  return cut + ' ' * (width - displayWidth(cut));
}

/// [line] cut and padded to exactly [width] columns.
Line fitLine(Line line, int width) {
  final out = <Span>[];
  var used = 0;
  for (final span in line) {
    if (used >= width) break;
    final room = width - used;
    final w = displayWidth(span.text);
    if (w <= room) {
      out.add(span);
      used += w;
    } else {
      final cut = fit(span.text, room);
      out.add(Span(cut, span.tone));
      used += displayWidth(cut);
      break;
    }
  }
  if (used < width) out.add(Span(' ' * (width - used)));
  return out;
}

/// Words of [text] wrapped to [width] columns (long words are cut).
List<String> wrap(String text, int width) {
  final lines = <String>[];
  for (final paragraph in text.split('\n')) {
    var current = '';
    for (final word in paragraph.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final candidate = current.isEmpty ? word : '$current $word';
      if (displayWidth(candidate) <= width) {
        current = candidate;
      } else {
        if (current.isNotEmpty) lines.add(current);
        current = displayWidth(word) <= width ? word : fit(word, width);
      }
    }
    lines.add(current);
  }
  while (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// A checkpoint id for people: `cp_mvygprjf` (the prefix and its first
/// part, without the random suffix).
String shortId(String id) {
  final parts = id.split('_');
  return parts.length >= 2 ? '${parts[0]}_${parts[1]}' : id;
}

/// A label for the screen: dmc's "…" cut marker is kept as is (never
/// "(truncated by dmc)"), and only the first line is shown.
String screenLabel(String? label) {
  if (label == null || label.trim().isEmpty) return '(no label)';
  return label.trim().split('\n').first;
}

/// ANSI SGR codes per tone.
const Map<Tone, String> _codes = {
  Tone.normal: '',
  Tone.good: '32',
  Tone.bad: '31',
  Tone.warn: '33',
  Tone.dim: '2',
  Tone.strong: '1',
  Tone.selected: '7',
};

/// [line] as terminal text: with ANSI colour when [color], else plain.
String renderLine(Line line, {required bool color}) {
  if (!color) return lineText(line);
  final buffer = StringBuffer();
  for (final span in line) {
    final code = _codes[span.tone]!;
    if (code.isEmpty) {
      buffer.write(span.text);
    } else {
      buffer.write('\x1b[${code}m${span.text}\x1b[0m');
    }
  }
  return buffer.toString();
}

/// Whether to colour: `--color always|never|auto`; auto colours a terminal
/// unless NO_COLOR is set (https://no-color.org).
bool useColor(String? option, Map<String, String> env, {required bool tty}) =>
    switch (option) {
      'always' => true,
      'never' => false,
      _ => tty && (env['NO_COLOR'] ?? '').isEmpty,
    };
