import 'package:celechron/design/round_rectangle_card.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter/cupertino.dart';

import 'library_reservation_page.dart';

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
        onPressed: () => Navigator.of(context, rootNavigator: true).push(
          CupertinoPageRoute<void>(
            builder: (_) => LibraryReservationPage(scholar: scholar),
          ),
        ),
        child: Row(
          children: [
            const Icon(CupertinoIcons.book, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '研讨间预约',
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .textStyle
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '查看空闲时段与我的预约',
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
