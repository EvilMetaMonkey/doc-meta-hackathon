/// Keys for the TUI: decoding the raw bytes of one stdin read into key
/// events. Pure, so tests can feed bytes.
library;

import 'dart:convert';

enum KeyKind {
  char,
  enter,
  escape,
  space,
  backspace,
  tab,
  up,
  down,
  left,
  right,
  pageUp,
  pageDown,
  home,
  end,
  delete,
  ctrlC,
  ctrlD,
  ctrlL,

  /// Bytes Doc does not use.
  unknown,
}

class KeyEvent {
  final KeyKind kind;

  /// The character for [KeyKind.char].
  final String char;

  const KeyEvent(this.kind, [this.char = '']);

  const KeyEvent.char(this.char) : kind = KeyKind.char;

  bool isChar(String c) => kind == KeyKind.char && char == c;

  @override
  bool operator ==(Object other) =>
      other is KeyEvent && other.kind == kind && other.char == char;

  @override
  int get hashCode => Object.hash(kind, char);

  @override
  String toString() => kind == KeyKind.char ? 'char($char)' : kind.name;
}

const Map<String, KeyKind> _csi = {
  'A': KeyKind.up,
  'B': KeyKind.down,
  'C': KeyKind.right,
  'D': KeyKind.left,
  'H': KeyKind.home,
  'F': KeyKind.end,
  '5~': KeyKind.pageUp,
  '6~': KeyKind.pageDown,
  '3~': KeyKind.delete,
  '1~': KeyKind.home,
  '4~': KeyKind.end,
  '7~': KeyKind.home,
  '8~': KeyKind.end,
};

/// The key events in one read from a raw-mode terminal. A read that is a
/// lone ESC is Esc; ESC followed by `[` or `O` is an escape sequence
/// (arrows, PgUp/PgDn, Home/End, Delete); ESC followed by anything else is
/// Esc and then that key. Text is decoded as UTF-8.
List<KeyEvent> decodeKeys(List<int> bytes) {
  final events = <KeyEvent>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      if (i + 1 < bytes.length &&
          (bytes[i + 1] == 0x5b || bytes[i + 1] == 0x4f)) {
        // CSI / SS3: parameters (digits, ;) then a final byte.
        var j = i + 2;
        final params = StringBuffer();
        while (j < bytes.length &&
            ((bytes[j] >= 0x30 && bytes[j] <= 0x39) || bytes[j] == 0x3b)) {
          params.writeCharCode(bytes[j]);
          j++;
        }
        if (j < bytes.length) {
          final last = String.fromCharCode(bytes[j]);
          final raw = params.toString();
          final key = _csi[last == '~' ? '$raw~' : last];
          events.add(KeyEvent(key ?? KeyKind.unknown));
          i = j + 1;
          continue;
        }
        events.add(const KeyEvent(KeyKind.unknown));
        break;
      }
      events.add(const KeyEvent(KeyKind.escape));
      i++;
      continue;
    }
    if (b == 0x0d || b == 0x0a) {
      events.add(const KeyEvent(KeyKind.enter));
      // CR LF from a paste is one Enter.
      if (b == 0x0d && i + 1 < bytes.length && bytes[i + 1] == 0x0a) i++;
      i++;
      continue;
    }
    final control = switch (b) {
      0x20 => KeyKind.space,
      0x7f || 0x08 => KeyKind.backspace,
      0x09 => KeyKind.tab,
      0x03 => KeyKind.ctrlC,
      0x04 => KeyKind.ctrlD,
      0x0c => KeyKind.ctrlL,
      _ => null,
    };
    if (control != null) {
      events.add(KeyEvent(control));
      i++;
      continue;
    }
    if (b < 0x20) {
      events.add(const KeyEvent(KeyKind.unknown));
      i++;
      continue;
    }
    // One UTF-8 character.
    final length = b < 0x80
        ? 1
        : b >= 0xf0
        ? 4
        : b >= 0xe0
        ? 3
        : 2;
    final end = (i + length).clamp(0, bytes.length);
    events.add(
      KeyEvent.char(utf8.decode(bytes.sublist(i, end), allowMalformed: true)),
    );
    i = end;
  }
  return events;
}
