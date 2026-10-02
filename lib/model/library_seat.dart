import 'library_reservation.dart';

export 'library_reservation.dart'
    show LibraryCatalog, LibraryBuilding, LibraryBookingException;

/// Ordinary seats use server-issued time segments, not arbitrary time ranges.
abstract class LibrarySeatBookingClient {
  Future<LibraryCatalog> loadSeatCatalog({String? date});
  Future<List<LibrarySeatArea>> loadSeatAreas({
    required String buildingId,
    required String date,
  });
  Future<LibrarySeatAvailability> loadSeatAvailability({
    required LibrarySeatArea area,
  });
  Future<List<LibrarySeat>> loadSeats({
    required LibrarySeatArea area,
    required LibrarySeatSegment segment,
  });
  Future<String> submitSeat(LibrarySeatDraft draft);
  Future<List<LibrarySeatReservation>> loadSeatReservations({int page = 1});
  Future<String> cancelSeat(LibrarySeatReservation reservation);
  void dispose();
}

class LibrarySeatArea {
  final String id;
  final String name;
  final String buildingId;
  final String floorName;
  final String typeCategory;
  final bool canReserve;
  final String? unsupportedReason;

  const LibrarySeatArea({
    required this.id,
    required this.name,
    required this.buildingId,
    this.floorName = '',
    this.typeCategory = '1',
    this.canReserve = true,
    this.unsupportedReason,
  });
}

class LibrarySeatAvailability {
  final LibrarySeatArea area;
  final List<LibrarySeatDay> days;
  final String rules;
  final bool canReserve;
  final String? unsupportedReason;

  const LibrarySeatAvailability({
    required this.area,
    required this.days,
    this.rules = '',
    this.canReserve = true,
    this.unsupportedReason,
  });
}

class LibrarySeatDay {
  final String date;
  final List<LibrarySeatSegment> segments;

  const LibrarySeatDay({required this.date, required this.segments});
}

class LibrarySeatSegment {
  final String id;
  final String areaId;
  final String date;
  final String startTime;
  final String endTime;
  final bool canReserve;
  final String? unavailableReason;

  const LibrarySeatSegment({
    required this.id,
    required this.areaId,
    required this.date,
    required this.startTime,
    required this.endTime,
    this.canReserve = true,
    this.unavailableReason,
  });
}

class LibrarySeat {
  final String id;
  final String name;
  final String status;
  final bool canReserve;
  final List<String> labels;

  const LibrarySeat({
    required this.id,
    required this.name,
    this.status = '',
    this.canReserve = true,
    this.labels = const [],
  });
}

class LibrarySeatDraft {
  final LibrarySeatArea area;
  final LibrarySeatSegment segment;
  final LibrarySeat seat;

  const LibrarySeatDraft({
    required this.area,
    required this.segment,
    required this.seat,
  });
}

class LibrarySeatReservation {
  final String id;
  final String seatName;
  final String areaName;
  final String date;
  final String startTime;
  final String endTime;
  final String status;
  final bool canCancel;
  final String? cancellationReason;
  final String cancellationWarning;

  const LibrarySeatReservation({
    required this.id,
    required this.seatName,
    required this.areaName,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.canCancel = false,
    this.cancellationReason,
    this.cancellationWarning = '',
  });
}
