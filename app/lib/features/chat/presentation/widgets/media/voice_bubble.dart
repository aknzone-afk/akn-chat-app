import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/widgets/states.dart';
import '../../../domain/message.dart';
import '../../../providers/media_providers.dart';
import 'media_status_overlay.dart';

/// A voice note, with a real waveform.
///
/// The bars are 40 genuine RMS levels computed by
/// `functions/handlers/transcodeVoiceNote.js` from a second 8 kHz decode of the
/// clip. A hash-derived decorative waveform is the usual shortcut, and it is a
/// small lie told to the user forty times a day; real peaks cost about ten
/// lines of JS and a few tens of milliseconds.
///
/// ⚠️ ON IPHONE THE `.ogg` DOES NOT PLAY AT ALL. iOS AVFoundation has no Ogg
/// demuxer, so `playableAudioUrl` prefers `audioUrl` — the server-side .m4a
/// transcode — and falls back to the original only for Android. If the
/// transcode has not finished, the honest thing is to say so rather than to
/// offer a play button that silently does nothing.
class VoiceBubble extends ConsumerWidget {
  const VoiceBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch only the slice that concerns THIS bubble, so a position tick
    // repaints one voice note and nothing else in the conversation.
    final playback = ref.watch(voicePlaybackForProvider(message.id));
    final brightness = Theme.of(context).brightness;
    final scheme = Theme.of(context).colorScheme;
    final metaColour = metaTextStyle(brightness).color;

    final phase = mediaPhaseOf(message);
    final transcoding =
        message.audioStatus == 'pending' || message.audioStatus == 'working';
    // Android can play the original Ogg happily, so a transcode still in flight
    // only blocks playback where the fallback genuinely does not work.
    final iosWaitingOnTranscode =
        transcoding &&
        Theme.of(context).platform == TargetPlatform.iOS &&
        message.audioUrl == null;

    final playable =
        phase == MediaPhase.ready &&
        message.playableAudioUrl != null &&
        !iosWaitingOnTranscode;

    final peaks = message.audioPeaks;
    final total = playback?.duration.inMilliseconds != null &&
            playback!.duration > Duration.zero
        ? playback.duration
        : Duration(milliseconds: message.audioDurationMs ?? 0);
    final progress = playback?.progress ?? 0;

    return SizedBox(
      width: 232,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _PlayButton(
            playing: playback?.playing ?? false,
            buffering: playback?.buffering ?? false,
            enabled: playable,
            colour: message.isOutgoing ? scheme.primary : AknColors.gold,
            onTap: () {
              if (!playable) {
                showAknSnack(
                  context,
                  iosWaitingOnTranscode
                      ? 'Voice message taiyaar ho raha hai — ek pal ruk kar bajaayein.'
                      : (mediaStatusLabel(message) ??
                            'Ye voice message abhi chal nahi paaya.'),
                  isError: phase == MediaPhase.dead,
                );
                return;
              }
              ref.read(voicePlayerProvider.notifier).toggle(message);
            },
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Waveform(
                  peaks: peaks,
                  progress: progress,
                  played: message.isOutgoing ? scheme.primary : AknColors.gold,
                  unplayed: (metaColour ?? Colors.grey).withValues(alpha: 0.45),
                  // `playable` means "this note COULD play", not "this note IS
                  // loaded in the shared player". Only the loaded one is
                  // scrubbable; the rest have nothing to scrub.
                  enabled: playable && playback != null,
                  onSeek: (fraction) {
                    if (playback == null || total <= Duration.zero) return;
                    ref
                        .read(voicePlayerProvider.notifier)
                        .seek(message.id, total * fraction);
                  },
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      _clock(
                        playback != null && playback.playing
                            ? playback.position
                            : total,
                      ),
                      style: TextStyle(fontSize: 11, color: metaColour),
                    ),
                    if (message.voice) ...[
                      const SizedBox(width: 5),
                      Icon(Icons.mic, size: 12, color: metaColour),
                    ],
                    const Spacer(),
                    if (playback != null)
                      _SpeedChip(
                        speed: playback.speed,
                        onTap: () =>
                            ref.read(voicePlayerProvider.notifier).cycleSpeed(),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    if (d <= Duration.zero) return '0:00';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.buffering,
    required this.enabled,
    required this.colour,
    required this.onTap,
  });

  final bool playing;
  final bool buffering;
  final bool enabled;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: enabled
            ? colour.withValues(alpha: 0.16)
            : Colors.grey.withValues(alpha: 0.16),
        shape: BoxShape.circle,
      ),
      child: buffering
          ? const Padding(
              padding: EdgeInsets.all(9),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 21,
              color: enabled ? colour : Colors.grey,
            ),
    ),
  );
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.speed, required this.onTap});

  final double speed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          speed == 1.0 ? '1x' : '${speed.toStringAsFixed(1)}x',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Forty bars, drag anywhere to seek.
class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.unplayed,
    required this.enabled,
    required this.onSeek,
  });

  final List<int>? peaks;
  final double progress;
  final Color played;
  final Color unplayed;
  final bool enabled;
  final void Function(double fraction) onSeek;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void seekAt(Offset local) {
        if (!enabled || constraints.maxWidth <= 0) return;
        onSeek((local.dx / constraints.maxWidth).clamp(0.0, 1.0));
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // onTapUp, NOT onTapDown. TapGestureRecognizer emits onTapDown from
        // didExceedDeadline() after kPressTimeout — 100 ms — even when the
        // gesture goes on to become a vertical list scroll. A thumb that lands
        // on a voice note and pauses for a beat before flicking the conversation
        // would otherwise scrub the playing note to wherever it happened to
        // land.
        onTapUp: (d) => seekAt(d.localPosition),
        onHorizontalDragUpdate: (d) => seekAt(d.localPosition),
        child: SizedBox(
          height: 26,
          width: double.infinity,
          child: CustomPaint(
            painter: _WaveformPainter(
              peaks: peaks,
              progress: progress,
              played: played,
              unplayed: unplayed,
            ),
          ),
        ),
      );
    },
  );
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.unplayed,
  });

  final List<int>? peaks;
  final double progress;
  final Color played;
  final Color unplayed;

  /// A flat placeholder while the transcode is still running, so the bubble is
  /// the same height before and after — nothing jumps when the peaks land.
  static const _fallback = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final values = peaks;
    final count = values?.length ?? 40;
    if (count == 0 || size.width <= 0) return;

    final slot = size.width / count;
    final barWidth = (slot * 0.55).clamp(1.4, 3.2);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final cutoff = progress * count;

    for (var i = 0; i < count; i++) {
      final level = (values == null ? _fallback : values[i]).clamp(0, 100);
      final h = (size.height * (0.14 + 0.86 * (level / 100))).clamp(
        2.0,
        size.height,
      );
      final x = slot * i + slot / 2;
      final top = (size.height - h) / 2;
      paint.color = i < cutoff ? played : unplayed;
      canvas.drawLine(Offset(x, top), Offset(x, top + h), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.played != played ||
      old.unplayed != unplayed ||
      !identical(old.peaks, peaks);
}
