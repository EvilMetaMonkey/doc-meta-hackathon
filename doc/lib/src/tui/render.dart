/// Drawing the TUI: `(state, width, height) → lines`. Pure, so tests can
/// check whole frames at fixed sizes.
library;

import 'dart:math';

import '../doctor_command.dart';
import 'model.dart';
import 'text.dart';
import '../plural.dart';

/// Smallest window the TUI draws in.
const int tuiMinWidth = 80;
const int tuiMinHeight = 24;

/// The splash car (each row is a mirror image of itself).
const List<String> splashCar = [
  r'    /\                                             /\    ',
  r'   /  \_________                         _________/  \   ',
  r'  /   /         \                       /         \   \  ',
  r' /   /           \                     /           \   \ ',
  r'/___/             \                   /             \___\',
  r'    \              \_________________/              /    ',
  r'     \_____   _____________________________   _____/     ',
  r'          \ [                               ] /          ',
  r'      ___  \[                               ]/  ___      ',
  r'     /   \  |  ===========================  |  /   \     ',
  r'    | [=] | | [■ ■]      | DMC |      [■ ■] | | [=] |    ',
  r'     \___/  |_______|_______________|_______|  \___/     ',
  r'            (O)                           (O)            ',
  r'             \=============================/             ',
];

const String splashTitle = 'Doc · find it, fix it, remember it';

/// The splash is drawn only in windows this tall.
const int splashMinHeight = 30;

/// One frame: exactly [height] strings, each [width] columns wide.
List<String> renderTui(
  TuiState state,
  int width,
  int height, {
  bool color = true,
}) {
  if (width < tuiMinWidth || height < tuiMinHeight) {
    return [
      pad(
        'Make the window at least $tuiMinWidth×$tuiMinHeight (now $width×$height).',
        width,
      ),
      for (var i = 1; i < height; i++) ' ' * width,
    ];
  }
  final lines = state.splash && height >= splashMinHeight
      ? _splash(state, width, height)
      : _frame(state, width, height);
  return [
    for (final line in lines) renderLine(fitLine(line, width), color: color),
  ];
}

List<Line> _splash(TuiState state, int width, int height) {
  final art = [
    for (final row in splashCar) row,
    '',
    splashTitle,
    'dmc ${state.dmcVersionForSplash ?? ''}'.trimRight(),
  ];
  final top = max(0, (height - art.length) ~/ 2);
  Line centred(String text, Tone tone) {
    final left = max(0, (width - displayWidth(text)) ~/ 2);
    return [Span(' ' * left), Span(text, tone)];
  }

  return [
    for (var i = 0; i < top; i++) <Span>[],
    for (final row in splashCar) centred(row, Tone.normal),
    <Span>[],
    centred(splashTitle, Tone.strong),
    centred(art.last, Tone.dim),
    for (var i = top + art.length; i < height; i++) <Span>[],
  ].take(height).toList();
}

/// Footer rows under the body: separator, voice line, two key lines, and
/// the bottom border.
const int _footerRows = 5;

List<Line> _frame(TuiState state, int width, int height) {
  final bodyHeight = height - 1 - _footerRows;
  final split = state.pane == PaneKind.turns && state.emptyReason == null;
  final leftWidth = split ? (((width - 3) * 0.42).round()).clamp(30, 60) : 0;
  final rightWidth = width - 3 - leftWidth;

  final body = <Line>[];
  if (split) {
    final left = _turnsColumn(state, leftWidth, bodyHeight);
    final right = _detailColumn(state, rightWidth, bodyHeight);
    for (var i = 0; i < bodyHeight; i++) {
      body.add([
        const Span('│', Tone.dim),
        ...fitLine(left[i], leftWidth),
        const Span('│', Tone.dim),
        ...fitLine(right[i], rightWidth),
        const Span('│', Tone.dim),
      ]);
    }
  } else {
    final inner = switch (state.pane) {
      _ when state.emptyReason != null && state.pane == PaneKind.turns =>
        _emptyColumn(state, width - 4),
      PaneKind.result => _resultColumn(state.result, width - 4),
      PaneKind.bisect => _bisectColumn(state.bisect, width - 4),
      PaneKind.lessons => _lessonsColumn(state.lessons, width - 4, bodyHeight),
      PaneKind.turns => <Line>[],
    };
    for (var i = 0; i < bodyHeight; i++) {
      body.add([
        const Span('│ ', Tone.dim),
        ...fitLine(i < inner.length ? inner[i] : const [], width - 4),
        const Span(' │', Tone.dim),
      ]);
    }
  }

  // Overlays, top-most last.
  if (state.pager != null) {
    _overlay(body, _pagerBox(state.pager!, width - 8, bodyHeight - 2), width);
  } else if (state.help) {
    _overlay(body, _pagerBox(helpPager(), width - 8, bodyHeight - 2), width);
  }
  if (state.question != null) {
    _overlay(body, _questionBox(state.question!, min(width - 8, 96)), width);
  }

  return [
    _header(state, width),
    ...body,
    _separator(width, split ? leftWidth + 1 : null),
    _voiceLine(state, width),
    ..._keyLines(state, width),
    [Span('└${'─' * (width - 2)}┘', Tone.dim)],
  ];
}

Line _header(TuiState state, int width) {
  final h = state.header;
  final spans = <Span>[
    const Span('┌ ', Tone.dim),
    const Span('Doc', Tone.strong),
    const Span(' · ', Tone.dim),
    Span(h.workspaceName),
    const Span(' · ', Tone.dim),
  ];
  if (!h.loaded) {
    spans.add(const Span('checking…', Tone.dim));
  } else {
    final dmcIssue = h.dmcOk != true;
    spans.add(
      Span(
        h.dmcOk == null ? 'dmc ?' : (dmcIssue ? 'dmc !' : 'dmc ok'),
        dmcIssue ? Tone.warn : Tone.good,
      ),
    );
    spans.add(const Span(' · hooks: ', Tone.dim));
    for (final (name, label) in const [
      ('claude', 'claude'),
      ('muse', 'muse'),
    ]) {
      final on = h.hooks[name];
      spans
        ..add(Span('$label '))
        ..add(
          Span(
            on == null ? '?' : (on ? '✓' : '✗'),
            on == true ? Tone.good : Tone.warn,
          ),
        )
        ..add(const Span(' '));
    }
    final problems = h.problems
        .where((p) => p.level == DoctorLevel.fail)
        .length;
    final warnings = h.problems.length - problems;
    if (problems > 0) {
      spans.add(Span('· ${plural(problems, 'problem')} ', Tone.bad));
    } else if (warnings > 0) {
      spans.add(Span('· $warnings to check ', Tone.warn));
    }
  }
  final used = displayWidth(lineText(spans));
  spans.add(Span('${'─' * max(0, width - used - 1)}┐', Tone.dim));
  return spans;
}

Line _separator(int width, int? junction) {
  if (junction == null) return [Span('├${'─' * (width - 2)}┤', Tone.dim)];
  return [
    Span('├${'─' * (junction - 1)}┴${'─' * (width - junction - 2)}┤', Tone.dim),
  ];
}

/// The turns list: status glyph, agent, label; the selection marked ▶.
List<Line> _turnsColumn(TuiState state, int width, int height) {
  final rows = <Line>[plain(' AGENT TURNS (newest first)', Tone.dim)];
  if (!state.turnsLoaded) {
    rows.add(plain(' loading…', Tone.dim));
  } else if (state.turns.isEmpty) {
    rows
      ..add(plain(' No agent turns yet.', Tone.warn))
      ..add(plain(' Install hooks: a turn appears here', Tone.dim))
      ..add(plain(' when an agent finishes one.', Tone.dim))
      ..add(plain(' (: then dmc hooks status)', Tone.dim));
  } else {
    final visible = height - 1;
    final start = (state.selected - visible + 1)
        .clamp(0, max(0, state.turns.length - visible))
        .toInt();
    for (var i = start; i < min(state.turns.length, start + visible); i++) {
      final turn = state.turns[i];
      final glyph = glyphFor(turn, firstBad: state.firstBad);
      final selected = i == state.selected;
      final suffix = turn.undone ? ' undone' : '';
      final labelRoom = width - 12 - suffix.length;
      // The title from the summary call when there is one, else the prompt.
      final title = state.details[turn.id]?.title;
      rows.add([
        Span(selected ? ' ▶ ' : '   ', selected ? Tone.strong : Tone.normal),
        Span(glyph.symbol, glyph.tone),
        Span(' ${pad(turn.who, 6)} ', Tone.dim),
        Span(
          fit(title ?? screenLabel(turn.label), labelRoom),
          selected ? Tone.strong : (turn.undone ? Tone.dim : Tone.normal),
        ),
        if (suffix.isNotEmpty) Span(suffix, Tone.dim),
      ]);
    }
  }
  while (rows.length < height) {
    rows.add(const []);
  }
  return rows.take(height).toList();
}

String _clock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The selected turn: who and when, the plain-English summary, files with
/// +/− counts, and the first lines of the diff.
List<Line> _detailColumn(TuiState state, int width, int height) {
  final rows = <Line>[];
  final turn = state.currentTurn;
  if (turn == null) {
    return [for (var i = 0; i < height; i++) const []];
  }
  final glyph = glyphFor(turn, firstBad: state.firstBad);
  rows.add([
    Span(' ${turn.who}', Tone.strong),
    Span(' · ${_clock(turn.time)} · ${shortId(turn.id)}', Tone.dim),
    if (glyph == TurnGlyph.broke) const Span(' · broke the tests', Tone.bad),
    if (glyph == TurnGlyph.undone) const Span(' · undone', Tone.dim),
    if (glyph == TurnGlyph.open) const Span(' · open', Tone.warn),
  ]);
  final detail = state.details[turn.id];
  // With a title, the raw prompt moves to details (d).
  rows.add(
    detail?.title != null
        ? plain(' ${fit(detail!.title!, width - 2)}', Tone.strong)
        : plain(' ${fit(screenLabel(turn.label), width - 2)}', Tone.dim),
  );
  rows.add(const []);
  if (detail?.summary != null) {
    for (final line in wrap(shortenIds(detail!.summary!), width - 2).take(4)) {
      rows.add(plain(' $line'));
    }
  } else if (detail?.summarizing ?? false) {
    rows.add(plain(' summarizing…', Tone.warn));
  } else if (detail?.summaryError != null) {
    rows.add(plain(' ${fit(detail!.summaryError!, width - 2)}', Tone.bad));
  } else {
    rows.add(plain(' s: summarize in plain English', Tone.dim));
  }
  rows.add(const []);
  if (detail == null ||
      detail.loadingDiff ||
      (detail.diff == null && detail.diffError == null && !turn.open)) {
    rows.add(plain(' reading the change…', Tone.dim));
  } else if (detail.diffError != null) {
    rows.add(plain(' ${fit(detail.diffError!, width - 2)}', Tone.dim));
  } else {
    final files = detail.files;
    if (files.isEmpty) {
      rows.add(plain(' no files changed', Tone.dim));
    }
    for (final file in files.take(4)) {
      rows.add([
        const Span(' files: ', Tone.dim),
        Span(fit(file.path, width - 22)),
        Span(' +${file.added}', Tone.good),
        Span(' −${file.removed}', Tone.bad),
      ]);
    }
    if (files.length > 4) {
      rows.add(plain('        … and ${files.length - 4} more (d)', Tone.dim));
    }
    for (final line in diffPreview(
      detail.diff ?? '',
      min(12, max(0, height - rows.length)),
    )) {
      rows.add([const Span(' '), ...line]);
    }
  }
  while (rows.length < height) {
    rows.add(const []);
  }
  return rows.take(height).toList();
}

List<Line> _emptyColumn(TuiState state, int width) => [
  const [],
  for (final (i, line) in state.emptyReason!.indexed)
    plain(line, i == 0 ? Tone.warn : Tone.normal),
];

List<Line> _resultColumn(ActionResult? result, int width) {
  if (result == null) return const [];
  final status = result.running
      ? const Span('running…', Tone.warn)
      : result.failed
      ? Span('failed (exit ${result.exitCode})', Tone.bad)
      : const Span('done', Tone.good);
  return [
    [Span(result.title, Tone.strong), const Span(' · ', Tone.dim), status],
    const [],
    for (final line in result.summary)
      for (final wrapped
          in displayWidth(line) <= width ? [line] : wrap(line, width))
        plain(wrapped, result.failed ? Tone.bad : Tone.normal),
    if (result.summary.isEmpty && !result.running)
      plain('(no output)', Tone.dim),
  ];
}

List<Line> _bisectColumn(BisectPane? pane, int width) {
  if (pane == null) return const [];
  final rows = <Line>[
    [
      const Span('BISECT', Tone.strong),
      Span(' · test: ${pane.test}', Tone.dim),
      if (pane.setup != null) Span(' · setup: ${pane.setup}', Tone.dim),
      if (pane.running) const Span(' · running…', Tone.warn),
    ],
    plain('oldest → newest', Tone.dim),
  ];
  // The strip: one cell per point, wrapped to the width.
  const cellWidth = 19;
  final perRow = max(1, width ~/ cellWidth);
  for (var i = 0; i < pane.strip.length; i += perRow) {
    final row = <Span>[];
    for (final (k, point) in pane.strip.skip(i).take(perRow).indexed) {
      final n = i + k;
      final name = n == 0 && point.state == 'before' ? 'start' : 'turn $n';
      row
        ..add(Span(pad(name, 7), Tone.dim))
        ..add(Span(pad(point.cell.text, cellWidth - 7), point.cell.tone));
    }
    rows.add(row);
  }
  rows.add(const []);
  if (pane.headline != null) {
    rows.add(plain(pane.headline!, pane.found ? Tone.bad : Tone.warn));
  }
  if (pane.files.isNotEmpty) {
    rows.add([const Span('files: ', Tone.dim), Span(pane.files.join(', '))]);
  }
  if (pane.failure.isNotEmpty) {
    rows.add(const []);
    for (final line in pane.failure) {
      rows.add(plain('  $line', Tone.bad));
    }
  }
  if (pane.explanation != null) {
    rows.add(const []);
    for (final line in wrap(pane.explanation!, width).take(6)) {
      rows.add(plain(line));
    }
  }
  return rows;
}

List<Line> _lessonsColumn(LessonsPane? pane, int width, int height) {
  if (pane == null) return const [];
  final rows = <Line>[
    plain('LESSONS', Tone.strong),
    if (pane.items.isEmpty) ...[
      const [],
      plain(
        'No lessons yet. After a restore, Doc offers to draft one.',
        Tone.dim,
      ),
    ],
  ];
  for (final (i, item) in pane.items.indexed) {
    final selected = i == pane.selected;
    rows.add([
      Span(selected ? '▶ ' : '  ', Tone.strong),
      Span(item.draft ? '◌ ' : '✓ ', item.draft ? Tone.warn : Tone.good),
      Span(fit(item.title, width - 40), selected ? Tone.strong : Tone.normal),
      if (item.draft) const Span(' (draft)', Tone.warn),
      Span('  ${fit(item.files.join(', '), 30)}', Tone.dim),
    ]);
  }
  if (pane.message != null) {
    rows.add(const []);
    for (final line in wrap(pane.message!, width)) {
      rows.add(plain(line, pane.messageTone));
    }
  }
  return rows;
}

/// A centred box drawn over [body].
class _Box {
  final List<Line> rows;
  final int width;
  const _Box(this.rows, this.width);
}

_Box _questionBox(Question question, int width) {
  final inner = width - 4;
  final rows = <Line>[
    [Span('┌${'─' * (width - 2)}┐', Tone.warn)],
  ];
  Line row(Line content) => [
    const Span('│ ', Tone.warn),
    ...fitLine(content, inner),
    const Span(' │', Tone.warn),
  ];
  // Context wraps (a brief is one long line); diff-like lines are cut.
  final contextRows = <Line>[];
  for (final line in question.shownContext) {
    final text = shortenIds(line);
    final pieces =
        text.startsWith('+') ||
            text.startsWith('-') ||
            displayWidth(text) <= inner
        ? [text]
        : wrap(text, inner);
    for (final piece in pieces) {
      contextRows.add(diffLineOrPlain(piece));
    }
  }
  for (final line
      in contextRows.length > 16
          ? contextRows.sublist(contextRows.length - 16)
          : contextRows) {
    rows.add(row(line));
  }
  if (question.shownContext.isNotEmpty) rows.add(row(const []));
  final prompt = shortenIds(question.prompt.trimRight());
  for (final piece
      in displayWidth(prompt) <= inner ? [prompt] : wrap(prompt, inner)) {
    rows.add(row(plain(piece, Tone.warn)));
  }
  if (!question.yesNo) {
    rows.add(row([Span('> ${question.value}'), const Span('▏', Tone.warn)]));
  } else if (question.oneLine &&
      !question.showDetails &&
      question.context.isNotEmpty) {
    rows.add(row(plain('d: every file', Tone.dim)));
  }
  rows.add([Span('└${'─' * (width - 2)}┘', Tone.warn)]);
  return _Box(rows, width);
}

/// Preview lines keep their meaning: red/green for files that change.
Line diffLineOrPlain(String line) {
  if (line.startsWith('+') || line.startsWith('-')) return diffLine(line);
  if (RegExp(r'(FAIL|conflict|error)', caseSensitive: false).hasMatch(line)) {
    return plain(line, Tone.bad);
  }
  return plain(line);
}

_Box _pagerBox(Pager pager, int width, int height) {
  final inner = width - 4;
  final visible = max(1, height - 3);
  final maxOffset = max(0, pager.lines.length - visible);
  pager.offset = pager.offset.clamp(0, maxOffset);
  final rows = <Line>[
    [
      const Span('┌ ', Tone.dim),
      Span(pager.title, Tone.strong),
      Span(
        ' ${'─' * max(0, width - displayWidth(pager.title) - 4)}┐',
        Tone.dim,
      ),
    ],
  ];
  for (var i = 0; i < visible; i++) {
    final index = pager.offset + i;
    rows.add([
      const Span('│ ', Tone.dim),
      ...fitLine(
        index < pager.lines.length ? pager.lines[index] : const [],
        inner,
      ),
      const Span(' │', Tone.dim),
    ]);
  }
  final position = pager.lines.length <= visible
      ? 'all'
      : '${pager.offset + 1}-${min(pager.lines.length, pager.offset + visible)} of ${pager.lines.length}';
  final bottom = '└ ↑↓ PgUp PgDn scroll · Esc close · $position ';
  rows.add([
    Span('$bottom${'─' * max(0, width - displayWidth(bottom) - 1)}┘', Tone.dim),
  ]);
  return _Box(rows, width);
}

void _overlay(List<Line> body, _Box box, int width) {
  final top = max(0, (body.length - box.rows.length) ~/ 2);
  final left = max(0, (width - box.width) ~/ 2);
  for (var i = 0; i < box.rows.length && top + i < body.length; i++) {
    // Beside the box only the frame's border stays, so nothing half
    // hidden peeks out.
    final base = fitLine(body[top + i], width);
    final right = width - left - box.width;
    body[top + i] = [
      ...sliceLine(base, 0, 1),
      Span(' ' * max(0, left - 1)),
      ...fitLine(box.rows[i], box.width),
      Span(' ' * max(0, right - 1)),
      ...sliceLine(base, width - 1, 1),
    ];
  }
}

/// [length] columns of [line] starting at column [start].
Line sliceLine(Line line, int start, int length) {
  final out = <Span>[];
  var column = 0;
  final end = start + length;
  for (final span in line) {
    final buffer = StringBuffer();
    for (final rune in span.text.runes) {
      final w = runeWidth(rune);
      if (column >= start && column + w <= end) buffer.writeCharCode(rune);
      column += w;
    }
    if (buffer.isNotEmpty) out.add(Span(buffer.toString(), span.tone));
  }
  return fitLine(out, length);
}

Line _voiceLine(TuiState state, int width) {
  final inner = width - 4;
  Line content;
  if (state.command != null) {
    content = [
      const Span(': ', Tone.warn),
      Span(state.command!),
      const Span('▏', Tone.warn),
      const Span('   Enter run · Esc cancel', Tone.dim),
    ];
  } else if (state.voice.state == 'recording') {
    content = [
      const Span('● REC ', Tone.bad),
      Span(
        state.voice.text.isEmpty
            ? 'listening… (Space/Enter stop · Esc cancel)'
            : '… ${state.voice.text}',
      ),
    ];
  } else if (state.voice.state == 'thinking') {
    content = [const Span('◉ ', Tone.warn), Span(state.voice.text, Tone.warn)];
  } else if (state.note != null && !state.help && state.pager == null) {
    content = [const Span('◉ ', Tone.dim), Span(state.note!, state.noteTone)];
  } else {
    content = [
      const Span('◉ ', Tone.strong),
      const Span('Space', Tone.strong),
      const Span(': talk to Doc'),
    ];
  }
  return [
    const Span('│ ', Tone.dim),
    ...fitLine(content, inner),
    const Span(' │', Tone.dim),
  ];
}

/// The key hints for the current pane, in two lines.
List<String> keyHints(TuiState state) => switch (state.pane) {
  _ when state.question != null => [
    state.question!.yesNo
        ? 'y yes · n / Enter / Esc no'
        : 'type · Enter answer · Esc cancel',
    '',
  ],
  _ when state.pager != null || state.help => [
    '↑↓ PgUp PgDn scroll · Esc close',
    '',
  ],
  PaneKind.turns => [
    '↑↓ select · s summary · d details · o log · r restore · u redo · / restore by words',
    'b bisect · l lessons · a start agent · t timelines · : command · ? help · q quit',
  ],
  PaneKind.result => [
    'd details · o log · Esc back to turns',
    ': command · ? help · q quit',
  ],
  PaneKind.bisect => [
    'd details · o log · r restore to before the bad turn · Esc back',
    ': command · ? help · q quit',
  ],
  PaneKind.lessons => [
    '↑↓ select · Enter show · y approve · e edit · x reject · Esc back',
    ': command · ? help · q quit',
  ],
};

List<Line> _keyLines(TuiState state, int width) => [
  for (final hint in keyHints(state))
    [
      const Span('│ ', Tone.dim),
      ...fitLine(plain(hint, Tone.dim), width - 4),
      const Span(' │', Tone.dim),
    ],
];

/// Every key and the command bar, for `?`.
Pager helpPager() => Pager('Doc · keys', [
  for (final (key, what) in tuiKeyHelp)
    [Span(pad(key, 14), Tone.strong), Span(what)],
]);

/// The help text: every key, then the command bar.
const List<(String, String)> tuiKeyHelp = [
  ('Space', 'talk to Doc (Space/Enter stops, Esc cancels); anywhere'),
  ('↑ ↓', 'select a turn (or a lesson)'),
  ('s', 'summarize the selected turn in plain English'),
  ('d', 'details: full diff, ids, times, model and cost'),
  ('o', 'the raw log of the selected item'),
  ('r', 'restore the selected turn (dmc preview, then y)'),
  ('u', 'redo an undone turn (dmc preview, then y)'),
  ('/', 'restore by words ("before it touched auth")'),
  ('b', 'bisect: find the turn that broke the tests'),
  ('l', 'lessons: approve, edit, reject'),
  ('a', 'start an agent with the matching lessons'),
  ('t', 'timelines: three agents try three fixes'),
  (':', 'command bar: any doc … command, or a read-only dmc … one'),
  ('?', 'this help'),
  ('Esc', 'close, cancel, or back to the turns'),
  ('q', 'quit (Ctrl-C also quits and restores the terminal)'),
];
