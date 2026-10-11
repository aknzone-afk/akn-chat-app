import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/widgets/states.dart';

/// Owner, 11-Oct-2026: a link in a message opens when tapped; a mobile number
/// opens a sheet — Call, WhatsApp, SMS, Copy — like WhatsApp itself.
///
/// The caller owns [recognizers] and must dispose them.
List<InlineSpan> linkSpans(
  BuildContext context,
  String text,
  List<TapGestureRecognizer> recognizers,
) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _pattern.allMatches(text)) {
    var raw = m.group(0)!;
    // A sentence's full stop or a closing bracket is not part of the link.
    final trimmed = raw.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
    final end = m.start + trimmed.length;
    raw = trimmed;
    if (raw.isEmpty) continue;
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    final isPhone = m.group(1) == null;
    final tap = TapGestureRecognizer()
      ..onTap = () => isPhone ? _phoneSheet(context, raw) : _openUrl(context, raw);
    recognizers.add(tap);
    spans.add(TextSpan(
      text: raw,
      recognizer: tap,
      style: const TextStyle(color: Color(0xFF027EB5), decoration: TextDecoration.underline),
    ));
    last = end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

// group 1 = a web link (https://…, www.…, or a bare domain like bbsynthetics.in/d/N1),
// otherwise an Indian mobile number (optional +91 / 0, spaces or dashes allowed).
final _pattern = RegExp(
  r'((?:https?://|www\.)\S+|\b[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.(?:in|com|net|org|co|app|me|io|shop|store)\b(?:/\S*)?)'
  r'|(?<![\d])(?:\+?91[\s-]?|0)?[6-9]\d{4}[\s-]?\d{5}(?![\d])',
);

Future<void> _openUrl(BuildContext context, String raw) async {
  final url = raw.startsWith('http') ? raw : 'https://$raw';
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
      .catchError((_) => false);
  if (!ok && context.mounted) showAknSnack(context, 'Link khul nahi paayi.', isError: true);
}

String _ten(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.length >= 10 ? d.substring(d.length - 10) : d;
}

void _phoneSheet(BuildContext context, String raw) {
  final ten = _ten(raw);
  final shown = '+91 ${ten.substring(0, 5)} ${ten.substring(5)}';
  Future<void> go(String url) async {
    Navigator.of(context).pop();
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
        .catchError((_) => false);
  }

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(shown, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.call_rounded),
          title: Text('Call $shown'),
          onTap: () => go('tel:+91$ten'),
        ),
        ListTile(
          leading: const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
          title: const Text('WhatsApp pe kholein (chat / call)'),
          onTap: () => go('https://wa.me/91$ten'),
        ),
        ListTile(
          leading: const Icon(Icons.sms_rounded),
          title: const Text('SMS bhejein'),
          onTap: () => go('sms:+91$ten'),
        ),
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('Number copy karein'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: '+91$ten'));
            Navigator.of(ctx).pop();
            showAknSnack(context, 'Number copy ho gaya.');
          },
        ),
      ]),
    ),
  );
}
