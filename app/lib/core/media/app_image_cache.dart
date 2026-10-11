import 'dart:async';
import 'dart:collection';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The ONE image cache for the whole app (owner, 4/5-Oct-2026: "every photo
/// must always be there, like WhatsApp").
///
/// The package default (`DefaultCacheManager`) keeps only 200 files for 30
/// days. Customers send hundreds of photos a day, so older photos were evicted
/// and re-downloaded every time a chat was opened. This keeps 5,000 files for a
/// year. Every `CachedNetworkImage` / `CachedNetworkImageProvider` and the
/// uploader's cache-seed must pass `cacheManager: appImageCache`.
final CacheManager appImageCache = CacheManager(
  Config(
    'aknImages',
    stalePeriod: const Duration(days: 365),
    maxNrOfCacheObjects: 5000,
  ),
);

/// Cache key for the small preview of a photo (server field `thumbUrl`).
String thumbKey(String mediaPath) => 'thumb:$mediaPath';

final Set<String> _queuedOrDone = <String>{};
final Queue<(String, String)> _queue = Queue<(String, String)>();
int _running = 0;
const int _maxParallel = 3;

/// Download previews in the background (3 at a time) so they are already on
/// disk before the user scrolls to them. Safe to call often: keys already
/// queued or cached are skipped.
void prefetchImages(Iterable<(String url, String key)> items) {
  for (final item in items) {
    if (_queuedOrDone.add(item.$2)) _queue.add(item);
  }
  _pump();
}

void _pump() {
  while (_running < _maxParallel && _queue.isNotEmpty) {
    final (url, key) = _queue.removeFirst();
    _running++;
    unawaited(() async {
      try {
        final cached = await appImageCache.getFileFromCache(key);
        if (cached == null) {
          await appImageCache.downloadFile(url, key: key);
        }
      } catch (_) {
        _queuedOrDone.remove(key); // let a later call retry it
      } finally {
        _running--;
        _pump();
      }
    }());
  }
}
