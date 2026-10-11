import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../domain/message.dart';

/// What the voice bubbles watch.
@immutable
class VoicePlayback {
  const VoicePlayback({
    this.messageId,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.speed = 1.0,
    this.error,
  });

  /// null = nothing is playing.
  final String? messageId;

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;

  /// WhatsApp's own set: 1.0 / 1.5 / 2.0.
  final double speed;

  final String? error;

  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  VoicePlayback copyWith({
    String? messageId,
    bool clearMessageId = false,
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    double? speed,
    String? error,
    bool clearError = false,
  }) => VoicePlayback(
    messageId: clearMessageId ? null : (messageId ?? this.messageId),
    position: position ?? this.position,
    duration: duration ?? this.duration,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    speed: speed ?? this.speed,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  bool operator ==(Object other) =>
      other is VoicePlayback &&
      other.messageId == messageId &&
      other.position == position &&
      other.duration == duration &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.speed == speed &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    messageId,
    position,
    duration,
    playing,
    buffering,
    speed,
    error,
  );
}

/// ONE `AudioPlayer` for the whole app.
///
/// Two voice notes playing at once is simply wrong, and an iOS audio session
/// per bubble is expensive. Each bubble watches only the slice of this state
/// that concerns it, so a playing note repaints itself and nothing else.
class VoicePlayer extends Notifier<VoicePlayback> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  VoicePlayback build() {
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
      unawaited(_player?.dispose());
      _player = null;
    });
    return const VoicePlayback();
  }

  AudioPlayer _ensure() {
    final existing = _player;
    if (existing != null) return existing;

    final player = AudioPlayer();
    _player = player;

    _subs.add(
      player.positionStream.listen((p) {
        if (state.messageId == null) return;
        state = state.copyWith(position: p);
      }),
    );
    _subs.add(
      player.durationStream.listen((d) {
        if (d == null || state.messageId == null) return;
        state = state.copyWith(duration: d);
      }),
    );
    _subs.add(
      player.playerStateStream.listen((s) {
        if (state.messageId == null) return;
        if (s.processingState == ProcessingState.completed) {
          // WhatsApp rewinds to the start and stops. Do the same rather than
          // leaving the scrubber pinned at the far end.
          unawaited(player.pause());
          unawaited(player.seek(Duration.zero));
          state = state.copyWith(playing: false, position: Duration.zero);
          return;
        }
        state = state.copyWith(
          playing: s.playing,
          buffering:
              s.processingState == ProcessingState.loading ||
              s.processingState == ProcessingState.buffering,
        );
      }),
    );

    return player;
  }

  /// Play this note, or pause it if it is the one already playing.
  Future<void> toggle(Message message) async {
    final url = message.playableAudioUrl;
    if (url == null) return;

    final player = _ensure();

    if (state.messageId == message.id) {
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
      return;
    }

    // A different note. Reset visibly first so the old bubble's scrubber does
    // not sit at 40% while the new one loads.
    state = VoicePlayback(
      messageId: message.id,
      buffering: true,
      speed: state.speed,
      duration: message.audioDurationMs != null
          ? Duration(milliseconds: message.audioDurationMs!)
          : Duration.zero,
    );

    try {
      await player.stop();
      // LockCachingAudioSource streams AND writes to disk in one pass, so the
      // second listen is instant and works offline.
      //
      // just_audio marks it experimental. Taken deliberately: the alternative
      // is downloading the whole clip before the first sound comes out, which
      // on a warehouse 4G connection is a two-second stare at a spinner every
      // time. If it is ever removed, fall back to MediaCache.file() +
      // setFilePath() — same behaviour, worse first-play latency.
      final duration = await player.setAudioSource(
        // ignore: experimental_member_use
        LockCachingAudioSource(Uri.parse(url)),
      );
      await player.setSpeed(state.speed);
      if (duration != null) state = state.copyWith(duration: duration);
      await player.play();
    } catch (e) {
      // The overwhelmingly likely cause on an iPhone is that the Ogg/Opus
      // transcode has not finished (or failed) and we are being handed the
      // original .ogg, which AVFoundation cannot demux at all.
      state = state.copyWith(
        playing: false,
        buffering: false,
        error: 'Ye voice message abhi chal nahi paaya.',
      );
      debugPrint('voice playback failed: $e');
    }
  }

  /// Seek inside the note that is ACTUALLY loaded.
  ///
  /// [messageId] is not decorative. There is one shared `AudioPlayer`, so
  /// without this check a tap on ANY other voice note's waveform scrubbed
  /// whatever happened to be playing — using the TAPPED note's duration. A
  /// two-minute clip mid-playback would jump to ~4 seconds because somebody
  /// touched an eight-second one, and the note they touched never started.
  Future<void> seek(String messageId, Duration to) async {
    final player = _player;
    if (player == null || state.messageId != messageId) return;
    final clamped = to < Duration.zero
        ? Duration.zero
        : (state.duration > Duration.zero && to > state.duration
              ? state.duration
              : to);
    state = state.copyWith(position: clamped);
    await player.seek(clamped);
  }

  Future<void> cycleSpeed() async {
    final next = switch (state.speed) {
      1.0 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    state = state.copyWith(speed: next);
    await _player?.setSpeed(next);
  }

  /// Called when the chat screen closes. Nothing should keep playing behind a
  /// screen nobody is looking at.
  Future<void> stop() async {
    final player = _player;
    if (player == null) return;
    await player.stop();
    state = VoicePlayback(speed: state.speed);
  }
}

final voicePlayerProvider = NotifierProvider<VoicePlayer, VoicePlayback>(
  VoicePlayer.new,
);

/// The slice one bubble needs: the playback state if it is the one playing,
/// null otherwise. Watching this instead of the whole object is what stops a
/// position tick rebuilding every voice bubble in the conversation.
final voicePlaybackForProvider = Provider.autoDispose
    .family<VoicePlayback?, String>((ref, messageId) {
      final playback = ref.watch(voicePlayerProvider);
      return playback.messageId == messageId ? playback : null;
    });
