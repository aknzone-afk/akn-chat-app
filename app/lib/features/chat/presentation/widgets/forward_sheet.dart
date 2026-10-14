import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/contacts/phone_contacts.dart';
import '../../../../core/firebase/firebase_providers.dart';
import '../../../../core/widgets/states.dart';
import '../../../chats/domain/chat.dart';
import '../../../chats/providers/chat_list_providers.dart';

/// Owner, 14-Oct-2026: "make an option to forward". Long-press → Forward →
/// tick up to 10 chats → the forwardMessage callable copies the text / file
/// into each chat and sends it the normal way (24-hour window rules apply).
final _forwardChatsProvider = StreamProvider.autoDispose<List<Chat>>((ref) {
  final db = ref.watch(firestoreProvider);
  return db
      .collection('chats')
      .orderBy('lastMessageAt', descending: true)
      .limit(400)
      .snapshots()
      .map((qs) => qs.docs.map(Chat.fromSnapshot).toList(growable: false));
});

Future<void> showForwardSheet(
  BuildContext context, {
  required String fromWaId,
  required String messageId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _ForwardSheet(fromWaId: fromWaId, messageId: messageId),
    ),
  );
}

class _ForwardSheet extends ConsumerStatefulWidget {
  const _ForwardSheet({required this.fromWaId, required this.messageId});
  final String fromWaId;
  final String messageId;

  @override
  ConsumerState<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends ConsumerState<_ForwardSheet> {
  final _picked = <String>{};
  String _q = '';
  bool _sending = false;

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final res = await ref
          .read(functionsProvider)
          .httpsCallable('forwardMessage',
              options: HttpsCallableOptions(timeout: const Duration(seconds: 280)))
          .call<Map<String, dynamic>>({
        'fromWaId': widget.fromWaId,
        'messageId': widget.messageId,
        'toWaIds': _picked.toList(),
      });
      final results = (res.data['results'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final ok = results.where((r) => r['ok'] == true).length;
      final bad = results.length - ok;
      nav.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(bad == 0
            ? 'Forward ho gaya ($ok chat)'
            : '$ok chat me gaya, $bad me nahi gaya (24 ghante ki window band ho sakti hai)'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showAknSnack(context, 'Forward nahi ho paaya. Dobara try karein.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(_forwardChatsProvider).value ?? const <Chat>[];
    final party = ref.watch(partyNamesProvider).value ?? const <String, String>{};
    final book = ref.watch(phoneContactNamesProvider).value ?? const <String, String>{};
    final q = _q.trim().toLowerCase();
    final shown = chats.where((c) {
      if (c.waId == widget.fromWaId) return false;
      if (q.isEmpty) return true;
      final t = chatTitle(c, party, book).toLowerCase();
      final digits = q.replaceAll(RegExp(r'\D'), '');
      return t.contains(q) || (digits.isNotEmpty && c.customerWaId.contains(digits));
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_picked.isEmpty ? 'Forward karein' : '${_picked.length} chosen'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Naam ya number se dhoondhein',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (_, i) {
              final c = shown[i];
              final on = _picked.contains(c.waId);
              return CheckboxListTile(
                value: on,
                title: Text(chatTitle(c, party, book), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('+${c.customerWaId}', style: const TextStyle(fontSize: 12)),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    if (_picked.length < 10) _picked.add(c.waId);
                  } else {
                    _picked.remove(c.waId);
                  }
                }),
              );
            },
          ),
        ),
      ]),
      floatingActionButton: _picked.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(_sending ? 'Bhej rahe hain…' : 'Bhejein'),
            ),
    );
  }
}
