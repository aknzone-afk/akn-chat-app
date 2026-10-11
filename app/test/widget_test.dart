// Phase 3 unit tests.
//
// Deliberately narrow: the two things worth testing without a Firebase
// emulator are (a) that the outgoing draft matches firestore.rules exactly —
// the #1 cause of "why is nothing happening" — and (b) that the 24-hour window
// maths is right, because it gates the composer.

import 'package:akn_chat/features/chat/data/chat_actions.dart';
import 'package:akn_chat/features/chat/domain/message.dart';
import 'package:akn_chat/features/chats/domain/chat.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact allowlist from firestore.rules → `validOutboundDraft()`.
const _allowedDraftKeys = {
  'direction',
  'from',
  'type',
  'status',
  'statusRank',
  'senderStaffId',
  'phoneNumberId',
  'wamid',
  'claimedAt',
  'error',
  'text',
  'caption',
  'previewUrl',
  'replyToWamid',
  'mediaPath',
  'mediaMime',
  'mediaStatus',
  'fileName',
  'fileSize',
  'timestamp',
  'createdAt',
};

void main() {
  group('outgoing draft', () {
    final payload = ChatActions.draftPayload(
      uid: 'staff-uid-1',
      body: 'Rate DM me bhej raha hoon',
      at: DateTime(2026, 7, 26, 10, 30),
    );

    test('every key is on the firestore.rules allowlist', () {
      expect(payload.keys.toSet().difference(_allowedDraftKeys), isEmpty);
    });

    test('satisfies the four hard rule conditions', () {
      expect(payload['direction'], 'out');
      expect(payload['status'], 'sending');
      expect(payload['from'], anyOf('staff', 'owner-cmd'));
      expect(payload['senderStaffId'], 'staff-uid-1');
    });

    test('never invents a wamid, a claim or a tick', () {
      expect(payload.containsKey('wamid'), isFalse);
      expect(payload.containsKey('claimedAt'), isFalse);
      expect(payload['statusRank'], 0);
      expect(payload['mediaStatus'], 'none');
    });

    test('previewUrl is set only when the body contains a link', () {
      expect(payload['previewUrl'], isFalse);
      final withLink = ChatActions.draftPayload(
        uid: 'u',
        body: 'Catalogue: https://aknzone.example/cat',
        at: DateTime(2026, 7, 26),
      );
      expect(withLink['previewUrl'], isTrue);
    });
  });

  group('24-hour window', () {
    final now = DateTime(2026, 7, 26, 12, 0);

    test('open while the expiry is in the future', () {
      final window = ReplyWindow(now.add(const Duration(hours: 5)));
      expect(window.isOpen(now), isTrue);
      expect(window.label(now), contains('5h 0m'));
    });

    test('closed at and after the expiry', () {
      expect(ReplyWindow(now).isOpen(now), isFalse);
      expect(
        ReplyWindow(now.subtract(const Duration(minutes: 1))).isOpen(now),
        isFalse,
      );
      expect(ReplyWindow(now).label(now), contains('band'));
    });

    test('a chat that has never had an inbound message is closed', () {
      expect(const ReplyWindow(null).isOpen(now), isFalse);
      expect(const ReplyWindow(null).remaining(now), Duration.zero);
    });
  });

  group('ticks', () {
    Message outgoing({
      String? status,
      int? rank,
      DateTime? at,
      String? wamid,
      String? senderStaffId = 'me',
    }) => Message(
      id: 'm1',
      direction: 'out',
      type: MsgType.text,
      timestamp: at ?? DateTime(2026, 7, 26, 12, 0),
      status: status,
      statusRank: rank,
      wamid: wamid,
      senderStaffId: senderStaffId,
    );

    final now = DateTime(2026, 7, 26, 12, 0, 10);

    test('rank drives the tick', () {
      expect(outgoing(rank: 0).tickAt(now), Tick.sending);
      expect(outgoing(rank: 1).tickAt(now), Tick.sent);
      expect(outgoing(rank: 2).tickAt(now), Tick.delivered);
      expect(outgoing(rank: 3).tickAt(now), Tick.read);
      expect(outgoing(rank: 4).tickAt(now), Tick.played);
      expect(outgoing(rank: 99, status: 'failed').tickAt(now), Tick.failed);
    });

    test('an inbound message never has a tick', () {
      final inbound = Message(
        id: 'in1',
        direction: 'in',
        type: MsgType.text,
        timestamp: DateTime(2026, 7, 26, 12, 0),
      );
      expect(inbound.tickAt(now), Tick.none);
    });

    test('a stuck "sending" becomes retryable after 90 seconds', () {
      final stale = outgoing(
        rank: 0,
        at: now.subtract(const Duration(minutes: 3)),
      );
      expect(stale.tickAt(now), Tick.failed);
      expect(stale.isRetryableBy('me'), isTrue);
    });

    test('a local failure wins over the stored rank', () {
      final failed = outgoing(rank: 0).copyWith(localFailure: 'Internet nahi');
      expect(failed.tickAt(now), Tick.failed);
    });

    test('retry is only offered on a draft THIS phone wrote', () {
      // sendMessage.js refuses the claim when doc.senderStaffId !== staff.uid
      // and returns permission-denied, which reads at the call site as "your
      // account is not set up".
      final theirs = outgoing(rank: 0, senderStaffId: 'someone-else');
      expect(theirs.isRetryableBy('me'), isFalse);
    });

    test('retry is not offered once Meta has the message', () {
      // statuses.js writes status:'failed' onto messages that already carry a
      // wamid; sendMessage would answer "already-sent".
      final delivered = outgoing(
        rank: 99,
        status: 'failed',
        wamid: 'wamid.HBg',
      );
      expect(delivered.tickAt(now), Tick.failed);
      expect(delivered.isRetryableBy('me'), isFalse);
    });
  });

  group('unknown messages that still carry text', () {
    // normalize.js stores a system notice, a template button tap and an
    // interactive reply as type "unknown" while keeping the readable line in
    // `text`.
    Message unknown(String? text) => Message(
      id: 'u1',
      direction: 'in',
      type: MsgType.unknown,
      timestamp: DateTime(2026, 7, 26, 12, 0),
      text: text,
    );

    test('render as text rather than as a placeholder', () {
      expect(unknown('Customer ne apna number badal diya').rendersAsText, isTrue);
      expect(
        unknown('Customer ne apna number badal diya').shortPreview,
        'Customer ne apna number badal diya',
      );
    });

    test('an unknown with no text still falls back to the placeholder', () {
      expect(unknown(null).rendersAsText, isFalse);
      expect(unknown('   ').rendersAsText, isFalse);
      expect(unknown(null).shortPreview, contains('nahi dikha sakta'));
    });
  });

  group('media placeholders', () {
    Message of(String type, {bool voice = false, String? fileName}) => Message(
      id: 'x',
      direction: 'in',
      type: type,
      timestamp: DateTime(2026, 7, 26),
      voice: voice,
      fileName: fileName,
    );

    test('never renders as empty or broken', () {
      for (final type in [
        MsgType.image,
        MsgType.video,
        MsgType.document,
        MsgType.audio,
        MsgType.sticker,
        MsgType.location,
        MsgType.contacts,
        MsgType.unknown,
        'something-meta-invents-in-2027',
      ]) {
        expect(of(type).placeholder, isNotEmpty, reason: type);
      }
    });

    test('a voice note is labelled as one', () {
      expect(of(MsgType.audio, voice: true).placeholder, '🎤 Voice message');
      expect(of(MsgType.audio).placeholder, '🎵 Audio');
      expect(
        of(MsgType.document, fileName: 'rate-list.pdf').placeholder,
        '📄 rate-list.pdf',
      );
    });
  });
}
