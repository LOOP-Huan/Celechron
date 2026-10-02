import 'package:celechron/design/round_rectangle_card.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter/cupertino.dart';

import 'library_reservation_page.dart';
import 'library_seat_page.dart';

class LibraryReservationCard extends StatelessWidget {
  const LibraryReservationCard({super.key, required this.scholar});

  final Scholar scholar;

  @override
  Widget build(BuildContext context) {
    return RoundRectangleCard(
      animate: false,
      padding: EdgeInsets.zero,
      child: CupertinoButton(
        key: const ValueKey('library-reservation-card'),
        padding: const EdgeInsets.all(16),
        onPressed: () async {
          final selection = await showCupertinoModalPopup<int>(
            context: context,
            builder: (context) => CupertinoActionSheet(
              title: const Text('图书馆预约'),
              actions: [
                CupertinoActionSheetAction(
                  key: const ValueKey('library-seat-entry'),
                  onPressed: () => Navigator.of(context).pop(0),
                  child: const Text('座位预约'),
                ),
                CupertinoActionSheetAction(
                  key: const ValueKey('library-room-entry'),
                  onPressed: () => Navigator.of(context).pop(1),
                  child: const Text('研讨间预约'),
                ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ),
          );
          if (!context.mounted || selection == null) return;
          Navigator.of(context, rootNavigator: true).push(
            CupertinoPageRoute<void>(
              builder: (_) => selection == 0
                  ? LibrarySeatPage(scholar: scholar)
                  : LibraryReservationPage(scholar: scholar),
            ),
          );
        },
        child: Row(
          children: [
            const Icon(CupertinoIcons.book, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '图书馆预约',
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .textStyle
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '座位与研讨间',
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_forward, size: 18),
          ],
        ),
      ),
    );
  }
}
