import 'dart:io';

import 'package:matcher/expect.dart';
import 'package:test_api/scaffolding.dart';

// Source contract for the reviewed 9b09a541 candidate. Reads the checkout under
// test, never git-show output or a synthetic Rust replacement. This does not
// compile Rust, exercise delivery, or establish authenticated provenance.
void main() {
  test('Find My candidate keeps one receive and a bounded synchronous tap', () {
    final findMy = _withoutComments(
      File('rustpush/src/findmy.rs').readAsStringSync(),
    );
    final diagnostics = _withoutComments(
      File('rustpush/src/findmy/diagnostics.rs').readAsStringSync(),
    );
    final client = _body(findMy, 'impl<P: AnisetteProvider> FindMyClient<P>');
    final handle = _body(client, 'pub async fn handle(');
    final dispatch = handle.indexOf('let do_app_ack');
    expect(dispatch, greaterThan(0));

    // Pin the actual straight-line prefix, including the original receiver,
    // topics and error propagation. The tap result is discarded before the
    // original destructure: no observer condition, await, ?, or early return.
    _sameCode(handle.substring(0, dispatch), r'''
      let wire_had_plaintext = findmy_242_wire_had_plaintext(&msg);
      let incoming = self.identity.receive_message(
        msg,
        &[
          "com.apple.private.alloy.fmf",
          "com.apple.private.alloy.fmd",
          "com.apple.private.alloy.findmy.itemsharing-crossaccount",
        ],
      ).await?;
      diagnostics::observe_ids242_single_pass(incoming.as_ref(), wire_had_plaintext);
      if let Some(IDSRecvMessage {
        message_unenc: Some(message), topic, token: Some(token),
        target: Some(target), sender: Some(sender), uuid: Some(uuid),
        ns_since_epoch: Some(ns_since_epoch), ..
      }) = incoming {
    ''');
    expect(
      RegExp(r'\.\s*receive_message\s*\(').allMatches(handle),
      hasLength(1),
    );
    expect(
      RegExp(r'\.\s*receive_message\s*\(').allMatches(findMy),
      hasLength(1),
    );
    expect(
      RegExp(r'\bobserve_ids242_single_pass\b').allMatches(handle),
      hasLength(1),
    );
    expect(RegExp(r'\bwire_had_plaintext\b').allMatches(handle), hasLength(2));
    expect(RegExp(r'\bincoming\b').allMatches(handle), hasLength(3));
    expect(handle.substring(dispatch), isNot(contains('observe_ids242')));
    expect(
      RegExp(
        r'\bpub(?:\([^)]*\))?\s+(?:async\s+)?fn\s+\w*observ\w*\s*\(',
      ).hasMatch(findMy),
      isFalse,
      reason: 'Find My must not expose another observation entry point',
    );
    expect(findMy, isNot(contains('observe_ids242_only')));
    expect(findMy, isNot(contains('classify_242_observation')));
    expect(findMy, isNot(contains('FindMy242ObserveOutcome')));

    _sameCode(_body(findMy, 'fn findmy_242_wire_had_plaintext('), r'''
      match msg {
        APSMessage::Notification { payload, .. } => match payload {
          Value::Dictionary(dict) => dict.contains_key("p"),
          _ => false,
        },
        _ => false,
      }
    ''');

    // Check executable gates, not comments mentioning a gate. Both gates and
    // bounded admission must precede record construction and the only log call.
    const tap = 'pub(super) fn observe_ids242_single_pass';
    final tapStart = diagnostics.indexOf(tap);
    expect(tapStart, greaterThan(0));
    _sameCode(
      diagnostics.substring(tapStart, diagnostics.indexOf('{', tapStart)),
      r'''pub(super) fn observe_ids242_single_pass(
          msg: Option<&IDSRecvMessage>, wire_had_plaintext: bool
        )''',
    );
    _sameCode(_body(diagnostics, '$tap('), r'''
      if option_env!("OPENBUBBLES_FINDMY_VERBOSE_DIAGNOSTICS") != Some("true") {
        return;
      }
      if !log::log_enabled!(target: "findmy_diagnostic", log::Level::Warn) {
        return;
      }
      let Some(msg) = msg else { return };
      let Some(topic) = admit_observe_ids242(msg.command, msg.topic) else {
        return;
      };
      if !admit_ids242_envelope(&IDS242_ENVELOPES) { return; }
      let record = Ids242Record::read(topic, msg, wire_had_plaintext);
      log::warn!(target: "findmy_diagnostic", "Find My IDS 242 conservative envelope {record:?}");
    ''');
    final compactDiagnostics = _compact(diagnostics);
    expect(compactDiagnostics, contains('constREQUEST_LIMIT:usize=12;'));
    expect(compactDiagnostics, contains('constIDS242_COMMAND:u8=242;'));
    expect(
      compactDiagnostics,
      contains('staticIDS242_ENVELOPES:AtomicUsize=AtomicUsize::new(0);'),
    );
    _sameCode(_body(diagnostics, 'fn admit_ids242_envelope('), r'''
      budget.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
        (used < REQUEST_LIMIT).then_some(used + 1)
      }).is_ok()
    ''');
    _sameCode(_body(diagnostics, 'fn admit_observe_ids242('), r'''
      if command != IDS242_COMMAND { return None; }
      ids242_topic(topic)
    ''');
    _sameCode(_body(diagnostics, 'fn ids242_topic('), r'''
      match topic {
        "com.apple.private.alloy.fmf" => Some(Ids242Topic::Fmf),
        "com.apple.private.alloy.fmd" => Some(Ids242Topic::Fmd),
        "com.apple.private.alloy.findmy.itemsharing-crossaccount" => Some(Ids242Topic::ItemSharing),
        _ => None,
      }
    ''');

    // The sole formatted record may hold only finite categories and booleans.
    // Pin its construction too: field types alone would not catch raw logging
    // inside read(), or replacing a length bucket with private body contents.
    for (final shape in <String, String>{
      'enum Ids242Topic': 'Fmf, Fmd, ItemSharing,',
      'struct Ids242Presence':
          'uuid: bool, sender: bool, target: bool, token: bool, time: bool,',
      'enum LenBucket': 'Empty, Tiny, Small, Medium, Large, XLarge, Over,',
      'enum Ids242Body': 'Skipped, Bytes(LenBucket),',
      'struct Ids242Record':
          'topic: Ids242Topic, command: u8, shaped: bool, presence: Ids242Presence, body: Ids242Body,',
    }.entries) {
      _sameCode(_body(diagnostics, shape.key), shape.value);
    }
    _sameCode(_body(diagnostics, 'impl Ids242Record'), r'''
      fn read(topic: Ids242Topic, msg: &IDSRecvMessage, wire_had_plaintext: bool) -> Self {
        let presence = Ids242Presence {
          uuid: msg.uuid.is_some(), sender: msg.sender.is_some(),
          target: msg.target.is_some(), token: msg.token.is_some(),
          time: msg.ns_since_epoch.is_some(),
        };
        let shaped = !wire_had_plaintext && !msg.verification_failed
          && msg.sender.is_some() && msg.message.is_some()
          && msg.encryption.is_some()
          && matches!(msg.message_unenc, Some(MessageBody::Bytes(_)));
        let body = if !shaped { Ids242Body::Skipped } else {
          match &msg.message_unenc {
            Some(MessageBody::Bytes(bytes)) => Ids242Body::Bytes(len_bucket(bytes.len())),
            _ => Ids242Body::Skipped,
          }
        };
        Self { topic, command: msg.command, shaped, presence, body, }
      }
    ''');
    _sameCode(_body(diagnostics, 'fn len_bucket('), r'''
      match len {
        0 => LenBucket::Empty, 1..=32 => LenBucket::Tiny,
        33..=64 => LenBucket::Small, 65..=256 => LenBucket::Medium,
        257..=1024 => LenBucket::Large, 1025..=65536 => LenBucket::XLarge,
        _ => LenBucket::Over,
      }
    ''');

    final observerStart = diagnostics.indexOf('const IDS242_COMMAND');
    final observerEnd = diagnostics.indexOf('#[cfg(test)]', observerStart);
    expect(observerStart, greaterThanOrEqualTo(0));
    expect(observerEnd, greaterThan(observerStart));
    final observer = diagnostics.substring(observerStart, observerEnd);
    expect(
      RegExp(r'log::(?:warn|info|debug|trace|error)!').allMatches(observer),
      hasLength(1),
    );
    expect(
      RegExp(
        r'\b(?:async|await|receive_message|cache_keys|refresh_now|send_message)\b',
      ).hasMatch(observer),
      isFalse,
    );
    expect(RegExp(r'\bpub\s+(?:async\s+)?fn\s+').hasMatch(observer), isFalse);
    // Derive(Debug) is safe for the pinned finite fields; a custom formatter
    // could bypass the field checks above and needs a fresh review.
    expect(
      RegExp(
        r'impl[^{};]*\bDebug\s+for\s+(?:Ids242\w+|LenBucket)\b',
      ).hasMatch(diagnostics),
      isFalse,
    );
  });
}

// Keep quoted strings intact while discarding comments so prose cannot satisfy
// the contract. The reviewed fragments use ordinary Rust string literals.
String _withoutComments(String source) => source.replaceAllMapped(
  RegExp(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/'),
  (match) => match[0]!.startsWith('"') ? match[0]! : ' ',
);

// Brace matching skips strings (including {record:?} in the logger) and follows
// nesting, so an injected control-flow block cannot shorten the inspected body.
String _body(String source, String anchor) {
  final start = source.indexOf(anchor);
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: 'Missing Rust anchor: $anchor',
  );
  expect(
    source.indexOf(anchor, start + anchor.length),
    -1,
    reason: 'Ambiguous Rust anchor: $anchor',
  );
  final open = source.indexOf('{', start + anchor.length);
  expect(open, greaterThan(start), reason: 'Missing body: $anchor');
  var depth = 0;
  for (final token in RegExp(
    r'"(?:\\.|[^"\\])*"|[{}]',
  ).allMatches(source, open)) {
    if (token[0] == '{') depth++;
    if (token[0] == '}' && --depth == 0) {
      return source.substring(open + 1, token.start);
    }
  }
  throw StateError('Unclosed Rust body: $anchor');
}

// Normalize whitespace only outside literals. A changed log message or topic
// remains significant even if it differs only by whitespace inside the string.
String _compact(String source) => source.replaceAllMapped(
  RegExp(r'"(?:\\.|[^"\\])*"|\s+'),
  (match) => match[0]!.startsWith('"') ? match[0]! : '',
);

void _sameCode(String actual, String expected) =>
    expect(_compact(actual), _compact(expected));
