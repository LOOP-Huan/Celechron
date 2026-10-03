/// The native library client keeps all account and reservation state in memory.
abstract class LibraryBookingClient {
  Future<LibraryCatalog> loadCatalog({String? date});
  Future<List<LibraryRoom>> loadRooms({
    required String buildingId,
    required String date,
  });
  Future<LibraryRoomAvailability> loadAvailability({
    required LibraryRoom room,
    required String date,
  });
  Future<LibraryParticipant> lookupParticipant({
    required String studentId,
    required LibraryRoom room,
    required String date,
    required int startMinute,
    required int endMinute,
  });
  Future<String> submit(LibraryBookingDraft draft);
  Future<List<LibraryReservation>> loadReservations({int page = 1});
  Future<String> cancel(LibraryReservation reservation);
  void dispose();
}

class LibraryBookingException implements Exception {
  final String message;
  final bool authenticationRequired;
  final bool outcomeUnknown;

  const LibraryBookingException(
    this.message, {
    this.authenticationRequired = false,
    this.outcomeUnknown = false,
  });

  @override
  String toString() => message;
}

class LibraryCatalog {
  final List<String> dates;
  final List<LibraryBuilding> buildings;

  const LibraryCatalog({required this.dates, required this.buildings});
}

class LibraryBuilding {
  final String id;
  final String name;

  const LibraryBuilding({required this.id, required this.name});
}

class LibraryRoom {
  final String id;
  final String name;
  final String buildingId;
  final String floorId;
  final String floorName;
  final String description;
  final bool canReserve;

  /// Missing directory flags do not establish a booking permission; details
  /// must be queried before enabling an actual submission.
  final bool availabilityKnown;
  final String? unavailableReason;
  final String typeCategory;
  final int earlierPeriods;

  const LibraryRoom({
    required this.id,
    required this.name,
    required this.buildingId,
    this.floorId = '',
    this.floorName = '',
    this.description = '',
    this.canReserve = true,
    this.availabilityKnown = true,
    this.unavailableReason,
    this.typeCategory = '2',
    this.earlierPeriods = 0,
  });
}

class LibraryTimeRange {
  final int startMinute;
  final int endMinute;

  const LibraryTimeRange({
    required this.startMinute,
    required this.endMinute,
  });

  bool overlaps(int start, int end) => start < endMinute && end > startMinute;
}

class LibraryTitleChoice {
  final String id;
  final String title;

  const LibraryTitleChoice({required this.id, required this.title});
}

class LibraryRoomAvailability {
  final LibraryRoom room;
  final String date;
  final int startMinute;
  final int endMinute;
  final int stepMinutes;
  final int minDurationMinutes;
  final int maxDurationMinutes;
  final int minParticipants;
  final int maxParticipants;
  final List<LibraryTimeRange> unavailable;
  final bool requiresAttachment;
  final bool titleRequired;
  final List<LibraryTitleChoice> titleChoices;
  final bool canReserve;
  final String mobile;
  final String rules;
  final String? unsupportedReason;
  final String? unavailableReason;
  final bool requireUntilClosing;
  final int? earliestStartMinute;

  const LibraryRoomAvailability({
    required this.room,
    required this.date,
    required this.startMinute,
    required this.endMinute,
    this.stepMinutes = 15,
    required this.minDurationMinutes,
    required this.maxDurationMinutes,
    this.minParticipants = 1,
    this.maxParticipants = 1,
    this.unavailable = const [],
    this.requiresAttachment = false,
    this.titleRequired = false,
    this.titleChoices = const [],
    this.canReserve = true,
    this.mobile = '',
    this.rules = '',
    this.unsupportedReason,
    this.unavailableReason,
    this.requireUntilClosing = false,
    this.earliestStartMinute,
  });

  bool isRangeAvailable(int start, int end) {
    final duration = end - start;
    return canReserve &&
        !requiresAttachment &&
        unsupportedReason == null &&
        start >= startMinute &&
        start >= (earliestStartMinute ?? startMinute) &&
        end <= endMinute &&
        stepMinutes > 0 &&
        start % stepMinutes == 0 &&
        end % stepMinutes == 0 &&
        duration > 0 &&
        duration >= minDurationMinutes &&
        duration <= maxDurationMinutes &&
        (!requireUntilClosing || end == endMinute) &&
        !unavailable.any((range) => range.overlaps(start, end));
  }
}

class LibraryParticipant {
  final String id;
  final String name;

  const LibraryParticipant({required this.id, required this.name});
}

class LibraryBookingDraft {
  final LibraryRoom room;
  final LibraryRoomAvailability availability;
  final int startMinute;
  final int endMinute;
  final String title;
  final String content;
  final String mobile;
  final List<LibraryParticipant> participants;
  final bool isPublic;
  final LibraryTitleChoice? titleChoice;

  const LibraryBookingDraft({
    required this.room,
    required this.availability,
    required this.startMinute,
    required this.endMinute,
    this.title = '',
    required this.content,
    required this.mobile,
    this.participants = const [],
    this.isPublic = true,
    this.titleChoice,
  });
}

class LibraryReservation {
  final String id;
  final String roomName;
  final String date;
  final String startTime;
  final String endTime;
  final String status;
  final bool canCancel;
  final String? cancellationReason;

  const LibraryReservation({
    required this.id,
    required this.roomName,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.canCancel = false,
    this.cancellationReason,
  });
}

String libraryTimeLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';
