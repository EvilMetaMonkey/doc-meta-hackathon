import 'package:dmc_doc/src/summarize.dart';
import 'package:dmc_doc/src/tui/model.dart';
import 'package:test/test.dart';

void main() {
  final show = <String, Object?>{
    'data': {
      'checkpoint': {
        'id': 'cp_mvzr1xvq_0123456789abcdef',
        'status': 'closed',
        'label': 'Make the discount a fraction',
        'source': 'agent',
        'agent': {'name': 'muse-code'},
        'protectedFileCount': 6,
        'changedFileCount': 1,
        'exclusionCount': 6,
        'fatalErrorCount': 0,
      },
      'issues': <Object?>[],
    },
  };
  final diff = <String, Object?>{
    'data': {
      'files': [
        {'path': 'money.py', 'change': 'modified'},
        {'path': 'README.md', 'change': 'unchanged'},
      ],
    },
  };

  group('the summary prompt', () {
    test('forbids dmc internals and lists of what was not touched', () {
      for (final rule in [
        'at most 2 sentences',
        'about 45 words',
        'checkpoint IDs',
        'open or closed',
        'which agent made the change',
        'protected, excluded or fatal',
        'not touched',
        '4 to 6 plain words',
        'JSON object {"title"',
      ]) {
        expect(summarySystemPrompt, contains(rule));
      }
    });

    test('sends no ID, state, agent name or counts the model could repeat', () {
      final facts = summaryMessages(show, diff)[1].content;
      expect(facts, contains('- money.py: modified'));
      expect(
        facts,
        contains('Agent prompt (first line, as recorded by dmc): '),
      );
      for (final internal in [
        'cp_mvzr1xvq',
        'closed',
        'muse-code',
        'xclusion',
        'Protected',
        'fatal',
        '6',
        'README.md',
      ]) {
        expect(facts, isNot(contains(internal)), reason: internal);
      }
    });

    test('an answer like the old wordy one is refused, so it is asked again', () {
      const old =
          '{"title": "Muse turn on money", "summary": "Checkpoint cp_mvzr1xvq is closed. '
          'The agent muse-code modified money.py. Only one file was changed out of six '
          'protected files, with six exclusions and no fatal issues reported."}';
      expect(
        () => parseSummaryAnswer(old, agentName: 'muse-code'),
        throwsA(isA<SummaryAnswerError>()),
      );
      for (final wordy in [
        'No files were deleted and no protection changes, secrets, CI or dependency files were touched.',
        'money.py changed; six exclusions applied.',
        'The muse-code agent changed money.py.',
      ]) {
        expect(
          () => parseSummaryAnswer(
            '{"title": "Discount takes a fraction", "summary": "$wordy"}',
            agentName: 'muse-code',
          ),
          throwsA(isA<SummaryAnswerError>()),
          reason: wordy,
        );
      }
    });

    test('the cache key carries the prompt version', () {
      expect(summaryPromptVersion, greaterThanOrEqualTo(2));
    });
  });

  group('the {title, summary} answer', () {
    test('is parsed, also inside a code fence', () {
      final answer = parseSummaryAnswer(
        '```json\n{"title": "Discount takes a fraction.", "summary": "apply_discount in money.py now takes 0.1 for 10%, so callers passing 10 overcharge."}\n```',
      );
      expect(answer.title, 'Discount takes a fraction');
      expect(answer.summary, startsWith('apply_discount in money.py'));
    });

    test('a missing or long title, prose or a long summary is refused', () {
      for (final bad in [
        'The discount changed.',
        '{"summary": "x"}',
        '{"title": "", "summary": "x"}',
        '{"title": "a b c d e f g h i j", "summary": "x"}',
        '{"title": "Discount", "summary": "${List.filled(80, 'word').join(' ')}"}',
      ]) {
        expect(
          () => parseSummaryAnswer(bad),
          throwsA(isA<SummaryAnswerError>()),
          reason: bad,
        );
      }
    });

    test('the free-text fallback keeps the text, or the "summary" field', () {
      expect(freeTextSummary(' money.py changed. '), 'money.py changed.');
      expect(
        freeTextSummary('{"summary": "money.py \\"changed\\"", "title": '),
        'money.py "changed"',
      );
    });

    test('the TUI reads the title back from doc summarize output', () {
      final parsed = parseSummaryOutput(
        'Title: Discount takes a fraction\nmoney.py now takes a fraction.\n\n(baseten m; 1 in / 2 out)\n',
      );
      expect(parsed.title, 'Discount takes a fraction');
      expect(parsed.text, 'money.py now takes a fraction.');
      expect(parsed.footer, '(baseten m; 1 in / 2 out)');
      // Seen on a cold Glimmer: Doc's log line comes first.
      final cold = parseSummaryOutput(
        '[doc] Waking Muse Glimmer on Modal (can take a couple of minutes)…\n'
        'Title: Add Usage section to README\nREADME.md gained a Usage section.\n\n(modal g)',
      );
      expect(cold.title, 'Add Usage section to README');
      expect(cold.text, 'README.md gained a Usage section.');
      final old = parseSummaryOutput('money.py changed.\n\n(baseten m)');
      expect(old.title, isNull);
      expect(old.text, 'money.py changed.');
    });
  });
}
