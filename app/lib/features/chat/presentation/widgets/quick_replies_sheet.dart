import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/states.dart';
import '../../../settings/providers/settings_providers.dart';

/// The ⚡ sheet. Tapping a reply INSERTS it at the cursor and closes; a
/// long-press copies it instead.
Future<String?> showQuickRepliesSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        final replies = ref.read(quickRepliesProvider);
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                children: [
                  Icon(Icons.bolt_outlined, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Quick replies',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: replies.isEmpty
                  ? const EmptyView(
                      icon: Icons.bolt_outlined,
                      title: 'Koi quick reply nahi',
                      subtitle:
                          'Owner settings/app.quickReplies me add kar sakte hain.',
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: replies.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final reply = replies[i];
                        return ListTile(
                          title: Text(reply),
                          trailing: const Icon(Icons.north_east, size: 16),
                          onTap: () => Navigator.of(sheetContext).pop(reply),
                          onLongPress: () async {
                            await Clipboard.setData(
                              ClipboardData(text: reply),
                            );
                            if (!context.mounted) return;
                            showAknSnack(context, 'Copy ho gaya');
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}
