import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// An on-disk cache for documents, audio and video.
///
/// Images do NOT go through here — `cached_network_image` has its own LRU and
/// its own decode-at-display-size machinery, and duplicating that would double
/// the storage a phone spends on photos.
///
/// KEYED BY STORAGE PATH, NEVER BY DOWNLOAD URL. Firebase download URLs carry a
/// rotatable `token` query parameter; a URL-keyed cache re-downloads the whole
/// object every time that token changes, which on a 14 MB video is a very
/// expensive way to look identical.
abstract final class MediaCache {
  /// Concurrent callers share one download. Without this, a chat with three
  /// visible voice notes fires three downloads for the same file the moment
  /// somebody taps play twice.
  static final Map<String, Future<File>> _inflight = {};

  /// Delete files untouched for this long on the next sweep.
  static const Duration maxAge = Duration(days: 30);

  /// …and then oldest-first until the directory is under this. Staff phones are
  /// low-storage; an unbounded cache is a support call.
  static const int maxBytes = 400 * 1024 * 1024;

  /// Downloads [storagePath] once, ever, and returns the local file.
  ///
  /// 11-Oct-2026: when the message carries a token download [url], fetch it by
  /// plain https first — on the owner's iPhone the Storage SDK's writeToFile
  /// failed every time on a perfect connection, while https links always load.
  static Future<File> file(String storagePath, {String? url}) {
    final existing = _inflight[storagePath];
    if (existing != null) return existing;

    final future = _download(storagePath, url);
    _inflight[storagePath] = future;
    // Whether it succeeded or threw, stop holding the entry — a failed download
    // must be retryable, and a successful one is on disk now.
    unawaited(future.whenComplete(() => _inflight.remove(storagePath)));
    return future;
  }

  static Future<File> _download(String storagePath, String? url) async {
    final target = await _targetFor(storagePath);
    if (await target.exists() && await target.length() > 0) return target;

    if (url != null && url.startsWith('https://')) {
      final part = File('${target.path}.part');
      try {
        await _httpToFile(url, part);
        return await part.rename(target.path);
      } catch (_) {
        await part.delete().catchError((_) => part);
        // fall through to the SDK
      }
    }
    return _sdkDownload(storagePath, target);
  }

  static Future<void> _httpToFile(String url, File out) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      final sink = out.openWrite();
      await res.pipe(sink);
      if (await out.length() == 0) throw const FileSystemException('empty download');
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> _sdkDownload(String storagePath, File target) async {

    // Download to '<target>.part' and RENAME on success. A process killed
    // mid-transfer must never be able to leave a truncated file that looks
    // perfectly valid to the next reader — which, for a PDF, means an app that
    // opens to an error page and a staff member who thinks the file is corrupt.
    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();

    final ref = FirebaseStorage.instance.ref(storagePath);
    try {
      await ref.writeToFile(part);
    } catch (e) {
      await part.delete().catchError((_) => part);
      // Last resort: ask Storage for a link and fetch that by https.
      try {
        await _httpToFile(await ref.getDownloadURL(), part);
      } catch (_) {
        await part.delete().catchError((_) => part);
        rethrow;
      }
    }
    return part.rename(target.path);
  }

  static Future<File> _targetFor(String storagePath) async {
    final dir = await _dir();
    final digest = md5.convert(storagePath.codeUnits).toString();
    final ext = p.extension(storagePath);
    return File(p.join(dir.path, '$digest$ext'));
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'media_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Called once at startup, unawaited. Never throws.
  static Future<void> sweep() async {
    try {
      final dir = await _dir();
      final entries = <({File file, DateTime at, int size})>[];
      final cutoff = DateTime.now().subtract(maxAge);

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete().catchError((_) => entity);
          continue;
        }
        // A '.part' left behind by a killed process is dead weight.
        if (entity.path.endsWith('.part')) {
          await entity.delete().catchError((_) => entity);
          continue;
        }
        entries.add((file: entity, at: stat.modified, size: stat.size));
      }

      var total = entries.fold<int>(0, (sum, e) => sum + e.size);
      if (total <= maxBytes) return;

      entries.sort((a, b) => a.at.compareTo(b.at)); // oldest first
      for (final entry in entries) {
        if (total <= maxBytes) break;
        await entry.file.delete().catchError((_) => entry.file);
        total -= entry.size;
      }
    } catch (e) {
      debugPrint('MediaCache.sweep skipped: $e');
    }
  }
}
