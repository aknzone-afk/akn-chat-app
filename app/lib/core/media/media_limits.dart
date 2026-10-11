/// What WhatsApp will actually accept, and what we tell staff when it will not.
///
/// These numbers appear in THREE places and must stay in step:
///   • here,
///   • `storage.rules` → the `outbound/` create clause,
///   • `functions/handlers/sendMessage.js` → `MAX_OUTBOUND_BYTES` / `TYPE_LIMITS`.
///
/// Checking here first is not belt-and-braces for its own sake: it is the only
/// one of the three that can say something useful to a human. A rules rejection
/// surfaces as a bare `PERMISSION_DENIED`, and Meta's own refusal (131053)
/// arrives after the file has already been uploaded twice.
library;

abstract final class MetaLimits {
  static const int image = 5 * 1024 * 1024;
  static const int video = 16 * 1024 * 1024;
  static const int audio = 16 * 1024 * 1024;

  /// OUR cap, not Meta's 100 MB. `sendMessage.js` buffers the whole file in
  /// memory and then copies it again into a Blob, so a 100 MB PDF is ~250 MB of
  /// live heap. Anything larger needs a streaming multipart upload.
  static const int document = 32 * 1024 * 1024;

  static const int caption = 1024;

  /// Meta accepts only these two as an image. Note what is NOT here: HEIC,
  /// which is what an iPhone shoots by default. Everything is transcoded to
  /// JPEG before upload — see `compress.dart`.
  static const Set<String> imageMimes = {'image/jpeg', 'image/png'};

  static const Set<String> videoMimes = {'video/mp4', 'video/3gpp'};

  static const Set<String> audioMimes = {
    'audio/aac',
    'audio/amr',
    'audio/mpeg',
    'audio/mp4',
    'audio/ogg',
  };

  static const Set<String> documentMimes = {
    'application/pdf',
    'text/plain',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };

  /// The extensions the document picker offers. Same nine types as above.
  static const List<String> documentExtensions = [
    'pdf',
    'txt',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
  ];

  static int limitFor(String type) => switch (type) {
    'image' => image,
    'video' => video,
    'audio' => audio,
    _ => document,
  };
}

/// Meta sends `audio/ogg; codecs=opus`, so always cut at the ';' before
/// comparing. Mirrors `functions/lib/ids.js::baseMime` exactly.
String baseMime(String? mime) {
  if (mime == null) return '';
  final cut = mime.indexOf(';');
  return (cut < 0 ? mime : mime.substring(0, cut)).trim().toLowerCase();
}

/// Best-effort MIME from a file name. Only used for files the DOCUMENT picker
/// hands us, where the platform often gives no MIME at all.
String? mimeForExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return null;
  return switch (fileName.substring(dot + 1).toLowerCase()) {
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'mp4' => 'video/mp4',
    '3gp' => 'video/3gpp',
    // Recognised so the rejection can be HONEST, not so it can be sent: Meta
    // does not accept video/quicktime, and every video an iPhone hands back
    // through the picker is `IMG_xxxx.MOV`. Without this entry the MIME resolved
    // to '' and staff were told "MP4 video bhejein" — an instruction an iPhone
    // cannot follow. See MediaMessages.videoFormat.
    'mov' => 'video/quicktime',
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'aac' => 'audio/aac',
    'amr' => 'audio/amr',
    'ogg' || 'opus' => 'audio/ogg',
    _ => null,
  };
}

/// The extension the Storage object should carry, derived from the MIME we are
/// actually going to declare — never from the source file name, which on iOS is
/// routinely `.HEIC` for bytes we have already turned into JPEG.
String extForMime(String mime) => switch (baseMime(mime)) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'video/mp4' => 'mp4',
  'video/3gpp' => '3gp',
  'audio/mp4' => 'm4a',
  'audio/mpeg' => 'mp3',
  'audio/aac' => 'aac',
  'audio/amr' => 'amr',
  'audio/ogg' => 'ogg',
  'application/pdf' => 'pdf',
  'text/plain' => 'txt',
  'application/msword' => 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
    'docx',
  'application/vnd.ms-excel' => 'xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
  'application/vnd.ms-powerpoint' => 'ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
    'pptx',
  _ => 'bin',
};

// ---------------------------------------------------------------------------
// The exact words staff read when something will not send.
//
// Every one of these goes through showAknSnack(..., isError: true). Never a
// silent failure, never an English stack trace.
// ---------------------------------------------------------------------------

abstract final class MediaMessages {
  static String videoTooBig(int bytes) =>
      'Ye video ${_mb(bytes)} ka hai, aur WhatsApp 16 MB se bada video nahi '
      'leta. Chhota clip bhejein ya trim karke bhejein.';

  static String documentTooBig(int bytes) =>
      'Ye file ${_mb(bytes)} ki hai. Itni badi file abhi nahi bhej sakte — '
      'chhoti file ya PDF ka compressed version bhejein.';

  static const imageTooBig =
      'Ye photo bahut badi hai. Phone ke camera se dobara kheench kar bhejein.';

  static const unsupportedDocument =
      'Is type ki file WhatsApp par nahi bheji ja sakti. PDF, Word, Excel, '
      'PowerPoint ya text file bhejein.';

  static const unsupportedImage =
      'Ye image format WhatsApp support nahi karta. Screenshot leke ya JPG me '
      'convert karke bhejein.';

  static const compressionFailed =
      'Photo taiyaar nahi ho paayi. Dobara koshish karein.';

  static const uploadOffline =
      'Internet nahi mil raha. File abhi tak nahi gayi — network aane par '
      'dobara bhejein.';

  static const uploadRejected =
      'Ye file bheji nahi ja saki. Doosri file try karein.';

  /// The picker's temp file is gone — the app restarted, or the OS purged its
  /// cache — so there is nothing left on this phone to upload. Retrying cannot
  /// possibly work, and saying "network aane par dobara bhejein" would send a
  /// staff member round the same dead loop for ever.
  static const reattachNeeded =
      'Ye file phone se hat gayi. Gallery se dobara select karke bhejein.';

  /// Meta accepts only mp4 and 3gpp. An iPhone only ever produces .MOV
  /// (QuickTime), so "MP4 bhejein" is an instruction that phone cannot follow —
  /// say what CAN be done instead.
  static String videoFormat({required bool isApple}) => isApple
      ? 'iPhone ki video WhatsApp par nahi jaati. Photo bhejein, ya Android '
            'phone se video bhejein.'
      : 'Ye video format WhatsApp par nahi jaata. MP4 video bhejein.';

  static const metaRejected =
      'WhatsApp ne ye file reject kar di. Doosri file ya doosra format try karein.';

  static const chatNotReady =
      'Ye chat abhi poori load nahi hui. Ek pal ruk kar dobara try karein.';

  static const noAppToOpen =
      'Is file ko kholne wala koi app phone me nahi hai.';

  static const fileNotFound = 'File nahi mili. Dobara download ho rahi hai.';

  static const openFailed = 'File khul nahi paayi.';

  static const downloadFailed =
      'Internet slow hai — file download nahi hui. Dobara tap karein.';

  static String _mb(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }
}
