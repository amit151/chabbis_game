import 'dart:math';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'game_engine.dart';

const String kDatabaseUrl = 'https://chabbis-26-default-rtdb.firebaseio.com';

/// Realtime Database returns a List instead of a Map for nodes whose keys are
/// sequential integers ('0','1','2'). This converts either shape to a Map.
Map<String, dynamic> _asStringMap(dynamic v) {
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), val));
  }
  if (v is List) {
    final out = <String, dynamic>{};
    for (var i = 0; i < v.length; i++) {
      if (v[i] != null) out['$i'] = v[i];
    }
    return out;
  }
  return <String, dynamic>{};
}

List<String> _asStringList(dynamic v) {
  if (v is List) {
    return v.where((e) => e != null).map((e) => e.toString()).toList();
  }
  if (v is Map) {
    return v.values.map((e) => e.toString()).toList();
  }
  return <String>[];
}

List<int> _asIntList(dynamic v) {
  if (v is List) {
    return v
        .where((e) => e != null)
        .map((e) => e is int ? e : int.tryParse(e.toString()))
        .whereType<int>()
        .toList();
  }
  if (v is Map) {
    return v.values
        .map((e) => e is int ? e : int.tryParse(e.toString()))
        .whereType<int>()
        .toList();
  }
  return <int>[];
}

/// Converts raw RTDB data into a predictable, fully typed structure.
Map<String, dynamic> _normalizeRoom(dynamic raw) {
  final room = _asStringMap(raw);

  final seatsRaw = _asStringMap(room['seats']);
  room['seats'] = seatsRaw.map((k, v) {
    final seat = _asStringMap(v);
    seat['hand'] = _asStringList(seat['hand']);
    seat['fullHand'] = _asStringList(seat['fullHand']);
    seat['isOnline'] = seat['isOnline'] as bool? ?? true;
    return MapEntry(k, seat);
  });

  final trick = _asStringMap(room['trickCards']);
  room['trickCards'] = trick.map((k, v) => MapEntry(k, v.toString()));

  final scores = _asStringMap(room['teamScores']);
  room['teamScores'] = {
    'team02': (scores['team02'] as num?)?.toInt() ?? 0,
    'team13': (scores['team13'] as num?)?.toInt() ?? 0,
  };

  final hands = _asStringMap(room['handsWon']);
  room['handsWon'] = {
    'team02': (hands['team02'] as num?)?.toInt() ?? 0,
    'team13': (hands['team13'] as num?)?.toInt() ?? 0,
  };

  room['pendingChaalCards'] = _asStringList(room['pendingChaalCards']);
  room['remainingDeck'] = _asStringList(room['remainingDeck']);
  room['khulliPassedSeats'] = _asIntList(room['khulliPassedSeats']);
  return room;
}

class RoomService {
  final DatabaseReference _db = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: kDatabaseUrl,
  ).ref('rooms');

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Creates a new room and seats the host at Seat 0.
  Future<String> createRoom(
    String playerName, {
    String? playerId,
  }) async {
    final code = _generateCode();
    final hostId = (playerId != null && playerId.isNotEmpty)
        ? playerId
        : 'player_${Random.secure().nextInt(1 << 31)}';

    await _db.child(code).set({
      'status': 'LOBBY',
      'shufflerSeat': 0,
      'turnSeat': 1,
      'bidderSeat': -1,
      'currentBid': 9,
      'consecutivePasses': 0,
      'khulliPassedSeats': <int>[],
      'turapSuit': '',
      'isTurapOpen': false,
      'isKhulliChabbis': false,
      'teamScores': {'team02': 0, 'team13': 0},
      'handsWon': {'team02': 0, 'team13': 0},
      'streakSeat': -1,
      'streakCount': 0,
      'pendingChaalCards': <String>[],
      'trickCards': <String, String>{},
      'leadSuit': '',
      'statusMessage': 'Waiting for 4 players to join...',
      'seats': {
        '0': {
          'playerId': hostId,
          'name': playerName,
          'isOnline': true,
          'hand': <String>[],
          'fullHand': <String>[],
        },
      },
    });

    await _db.child('$code/seats/0/isOnline').onDisconnect().set(false);
    return code;
  }

  /// Joins an existing room or reclaims an existing seat if [playerId] matches.
  Future<int?> joinRoom(
    String rawCode,
    String playerName, {
    String? playerId,
  }) async {
    final code = rawCode.trim().toUpperCase();
    final snap = await _db.child(code).get();
    if (!snap.exists || snap.value == null) return null;

    final data = _normalizeRoom(snap.value);
    final seats = data['seats'] as Map<String, dynamic>;

    // 1. Reclaim existing seat after accidental back press or reconnect
    if (playerId != null && playerId.isNotEmpty) {
      for (int i = 0; i < 4; i++) {
        final seatMap = seats['$i'] as Map<String, dynamic>?;
        if (seatMap != null && seatMap['playerId'] == playerId) {
          await _db.child('$code/seats/$i').update({
            'name': playerName,
            'isOnline': true,
          });
          await _db.child('$code/seats/$i/isOnline').onDisconnect().set(false);
          return i;
        }
      }
    }

    // 2. Otherwise sit in the first unoccupied seat (0..3)
    for (int i = 0; i < 4; i++) {
      if (!seats.containsKey('$i')) {
        final assignedId = (playerId != null && playerId.isNotEmpty)
            ? playerId
            : 'seat_${i}_${Random.secure().nextInt(1 << 24)}';

        await _db.child('$code/seats/$i').set({
          'playerId': assignedId,
          'name': playerName,
          'isOnline': true,
          'hand': <String>[],
          'fullHand': <String>[],
        });
        await _db.child('$code/seats/$i/isOnline').onDisconnect().set(false);

        final updatedCount = seats.length + 1;
        if (updatedCount == 4) {
          await _db.child(code).update({
            'statusMessage': 'All 4 players joined! Shuffler can deal.',
          });
        }
        return i;
      }
    }

    return null;
  }

  Future<void> markSeatOffline(String code, int seat) async {
    await _db.child('$code/seats/$seat/isOnline').set(false);
  }

  Stream?> watchRoom(String code) {
    return _db.child(code).onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;
      return _normalizeRoom(event.snapshot.value);
    });
  }

  /// Step 1: Fisher-Yates shuffle + 5-4-4 deal (all 52 cards -> 13 each).
  Future<void> dealInitialFive(String code, int shufflerSeat) async {
    final shuffledCards = GameEngine.createShuffledDeck();
    final handsBySeat = GameEngine.deal544(shuffledCards, shufflerSeat);
    final firstBidder = GameEngine.nextSeat(shufflerSeat);

    final updates = <String, dynamic>{
      'status': 'BIDDING',
      'shufflerSeat': shufflerSeat,
      'turnSeat': firstBidder,
      'bidderSeat': -1,
      'currentBid': 9,
      'consecutivePasses': 0,
      'khulliPassedSeats': <int>[],
      'turapSuit': '',
      'isTurapOpen': false,
      'isKhulliChabbis': false,
      'handsWon': {'team02': 0, 'team13': 0},
      'streakSeat': -1,
      'streakCount': 0,
      'pendingChaalCards': <String>[],
      'trickCards': <String, String>{},
      'leadSuit': '',
      'remainingDeck': <String>[],
      'statusMessage':
          '52 cards dealt (5-4-4, 13 each)! Seat ${firstBidder + 1} picks Turap & bids.',
    };

    for (int i = 0; i < 4; i++) {
      final fullCodes = handsBySeat[i]!.map((c) => c.code).toList();
      updates['seats/$i/hand'] = fullCodes.sublist(0, 5);
      updates['seats/$i/fullHand'] = fullCodes;
    }
    await _db.child(code).update(updates);
  }

  /// Place or raise a bid (minimum 10, +1 increments) and set hidden Turap.
  Future<void> placeBid({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
    required int bidAmount,
    required Suit turapSuit,
  }) async {
    final next = GameEngine.nextSeat(seat);
    await _db.child(code).update({
      'bidderSeat': seat,
      'currentBid': bidAmount,
      'turapSuit': turapSuit.name,
      'consecutivePasses': 0,
      'turnSeat': next,
      'statusMessage': 'Seat ${seat + 1} bid $bidAmount with hidden Turap.',
    });
  }

  /// Pass during bidding; if 3 passes occur after a bid, reveal all 13 dealt cards.
  Future<void> passBid({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
  }) async {
    final bidderSeat = room['bidderSeat'] as int;
    final passes = (room['consecutivePasses'] as int) + 1;

    if (bidderSeat != -1 && passes >= 3) {
      await _revealFullHandsForKhulliWindow(code, room, bidderSeat);
    } else {
      final next = GameEngine.nextSeat(seat);
      await _db.child(code).update({
        'consecutivePasses': passes,
        'turnSeat': next,
        'statusMessage': 'Seat ${seat + 1} passed. Seat ${next + 1} to bid.',
      });
    }
  }

  Future<void> _revealFullHandsForKhulliWindow(
    String code,
    Map<String, dynamic> room,
    int bidderSeat,
  ) async {
    final seats = room['seats'] as Map<String, dynamic>;
    final updates = <String, dynamic>{
      'status': 'KHULLI_WINDOW',
      'turnSeat': bidderSeat,
      'khulliPassedSeats': <int>[],
      'remainingDeck': <String>[],
      'statusMessage':
          'All 13 cards ready! Call Khulli Chabbis, Pass, or lead to start.',
    };

    for (int i = 0; i < 4; i++) {
      final seatData = seats['$i'] as Map<String, dynamic>;
      final full = _asStringList(seatData['fullHand']);
      final current = _asStringList(seatData['hand']);
      updates['seats/$i/hand'] = full.isNotEmpty ? full : current;
    }

    await _db.child(code).update(updates);
  }

  /// Declares Open 26 (Khulli Chabbis).
  Future<void> callKhulliChabbis({
    required String code,
    required int callerSeat,
    required Suit turapSuit,
  }) async {
    await _db.child(code).update({
      'status': 'TRICK_PLAY',
      'bidderSeat': callerSeat,
      'currentBid': 26,
      'turapSuit': turapSuit.name,
      'isTurapOpen': true,
      'isKhulliChabbis': true,
      'khulliPassedSeats': <int>[],
      'turnSeat': callerSeat,
      'statusMessage':
          'KHULLI CHABBIS called by Seat ${callerSeat + 1}! Turap is ${turapSuit.label}.',
    });
  }

  /// Passes on calling Khulli Chabbis and advances turn to the next seat.
  Future<void> passKhulliChabbis({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
  }) async {
    final passed = Set<int>.from(_asIntList(room['khulliPassedSeats']))..add(seat);
    final nextSeat = GameEngine.nextSeat(seat);
    final bidderSeat = room['bidderSeat'] as int;

    await _db.child(code).update({
      'khulliPassedSeats': passed.toList(),
      'turnSeat': passed.length >= 4 && bidderSeat != -1 ? bidderSeat : nextSeat,
      'statusMessage':
          'Seat ${seat + 1} passed Khulli Chabbis. Seat ${nextSeat + 1}\'s turn.',
    });
  }

  /// Opens Turap when a player has no card of the led suit on their turn.
  Future<void> openTurap(String code, Map<String, dynamic> room, int seat) async {
    final suitName = room['turapSuit'] as String;
    await _db.child(code).update({
      'isTurapOpen': true,
      'statusMessage':
          'Seat ${seat + 1} opened Turap! Trump suit is ${suitName.toUpperCase()}.',
    });
  }

  /// Plays a card and resolves trick / consecutive-hand Chaal / round end.
  Future<void> playCard({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
    required PlayingCard card,
  }) async {
    final seats = room['seats'] as Map<String, dynamic>;
    final seatData = seats['$seat'] as Map<String, dynamic>;
    final hand = List<String>.from(seatData['hand'] as List);
    hand.remove(card.code);

    final trickRaw = Map<String, dynamic>.from(room['trickCards'] as Map);
    trickRaw['$seat'] = card.code;

    final leadSuitStr = (room['leadSuit'] as String? ?? '');
    final leadSuit = leadSuitStr.isEmpty
        ? card.suit
        : Suit.values.firstWhere((s) => s.name == leadSuitStr);

    if (trickRaw.length < 4) {
      final next = GameEngine.nextSeat(seat);
      await _db.child(code).update({
        'status': 'TRICK_PLAY',
        'seats/$seat/hand': hand,
        'trickCards': trickRaw,
        'leadSuit': leadSuit.name,
        'turnSeat': next,
        'statusMessage': 'Seat ${seat + 1} played $card. Seat ${next + 1} turn.',
      });
      return;
    }

    // 4 cards played -> resolve trick
    final trickCards = <int, PlayingCard>{};
    trickRaw.forEach((k, v) {
      trickCards[int.parse(k)] = PlayingCard.fromCode(v as String);
    });

    final turapSuit = Suit.values.firstWhere(
      (s) => s.name == (room['turapSuit'] as String),
    );
    final isTurapOpen = room['isTurapOpen'] as bool? ?? false;

    final trickWinner = GameEngine.evaluateTrickWinner(
      trickCards: trickCards,
      leadSuit: leadSuit,
      turapSuit: turapSuit,
      isTurapOpen: isTurapOpen,
    );

    final handsWon = Map<String, dynamic>.from(room['handsWon'] as Map);
    final winnerTeam = GameEngine.teamKeyForSeat(trickWinner);
    handsWon[winnerTeam] = (handsWon[winnerTeam] as int) + 1;

    final prevStreakSeat = room['streakSeat'] as int? ?? -1;
    final prevStreakCount = room['streakCount'] as int? ?? 0;
    final pendingChaal = List<String>.from(room['pendingChaalCards'] as List);
    pendingChaal.addAll(trickRaw.values.cast<String>());

    final int newStreakSeat = trickWinner;
    int newStreakCount = (prevStreakSeat == trickWinner) ? prevStreakCount + 1 : 1;
    String chaalMsg =
        'Seat ${trickWinner + 1} won hand ($newStreakCount/2 consecutive).';

    final chaalWonNow = newStreakCount == 2;
    if (chaalWonNow) {
      chaalMsg =
          'CHAAL WON! Seat ${trickWinner + 1} won 2 consecutive hands (${pendingChaal.length} cards claimed)!';
      pendingChaal.clear();
      newStreakCount = 0;
    }

    final totalHandsPlayed =
        (handsWon['team02'] as int) + (handsWon['team13'] as int);
    final bidderSeat = room['bidderSeat'] as int;
    final bidderTeam = GameEngine.teamKeyForSeat(bidderSeat);
    final defenderTeam = bidderTeam == 'team02' ? 'team13' : 'team02';
    final bid = room['currentBid'] as int? ?? 10;
    final isKhulli = room['isKhulliChabbis'] as bool? ?? false;
    final defenderHands = handsWon[defenderTeam] as int;

    final endedByOpponents = GameEngine.opponentsReachedEndThreshold(
      bid: bid,
      defenderHandsWon: defenderHands,
      isKhulliChabbis: isKhulli,
    );

    if (totalHandsPlayed >= 13 || endedByOpponents) {
      await _finishRound(
        code: code,
        room: room,
        seat: seat,
        updatedHand: hand,
        handsWon: handsWon,
        khulliDefeatedEarly: isKhulli && endedByOpponents,
        endedByOpponents: endedByOpponents,
      );
      return;
    }

    await _db.child(code).update({
      'status': 'TRICK_PLAY',
      'seats/$seat/hand': hand,
      'trickCards': <String, String>{},
      'leadSuit': '',
      'turnSeat': trickWinner,
      'handsWon': handsWon,
      'streakSeat': newStreakSeat,
      'streakCount': newStreakCount,
      'pendingChaalCards': pendingChaal,
      'statusMessage': chaalMsg,
    });
  }

  /// Locks the shuffler to a team while its score is negative (< 0).
  int _resolveNextShuffler({
    required int currentShuffler,
    required Map<String, dynamic> scores,
    required bool bidderWonRound,
  }) {
    final t02 = (scores['team02'] as int?) ?? 0;
    final t13 = (scores['team13'] as int?) ?? 0;

    if (t02 < 0 && t13 >= 0) {
      return (currentShuffler == 0 || currentShuffler == 2) ? currentShuffler : 0;
    }
    if (t13 < 0 && t02 >= 0) {
      return (currentShuffler == 1 || currentShuffler == 3) ? currentShuffler : 1;
    }

    return bidderWonRound ? currentShuffler : GameEngine.nextSeat(currentShuffler);
  }

  Future<void> _finishRound({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
    required List<String> updatedHand,
    required Map<String, dynamic> handsWon,
    required bool khulliDefeatedEarly,
    required bool endedByOpponents,
  }) async {
    final bidderSeat = room['bidderSeat'] as int;
    final bidderTeam = GameEngine.teamKeyForSeat(bidderSeat);
    final defenderTeam = bidderTeam == 'team02' ? 'team13' : 'team02';
    final bid = room['currentBid'] as int? ?? 10;
    final isKhulli = room['isKhulliChabbis'] as bool? ?? false;

    final bidderHands = handsWon[bidderTeam] as int;
    final defenderHands = handsWon[defenderTeam] as int;

    final delta = GameEngine.calculateRoundDeltaForBidder(
      bid: bid,
      bidderHandsWon: bidderHands,
      defenderHandsWon: defenderHands,
      isKhulliChabbis: isKhulli,
      khulliChabbisFailedEarly: khulliDefeatedEarly,
    );

    final scores = Map<String, dynamic>.from(room['teamScores'] as Map);
    scores[bidderTeam] = (scores[bidderTeam] as int) + delta;
    scores[defenderTeam] = (scores[defenderTeam] as int) - delta;

    final bidderWonRound = delta > 0 && !endedByOpponents;
    final currentShuffler = room['shufflerSeat'] as int;
    final nextShuffler = _resolveNextShuffler(
      currentShuffler: currentShuffler,
      scores: scores,
      bidderWonRound: bidderWonRound,
    );

    final t02 = scores['team02'] as int;
    final t13 = scores['team13'] as int;
    final matchOver = t02 <= -104 || t13 <= -104;

    String endMsg;
    if (matchOver) {
      final loser = t02 <= -104 ? 'Team A (Seats 1 & 3)' : 'Team B (Seats 2 & 4)';
      endMsg = 'MATCH OVER! $loser reached -104 points and lost!';
    } else if (endedByOpponents) {
      endMsg =
          'Round ended: Opponents won $defenderHands hands! Next shuffler: Seat ${nextShuffler + 1}.';
    } else {
      endMsg =
          'Round ended (${delta >= 0 ? '+$delta' : '$delta'} to bidder). Next shuffler: Seat ${nextShuffler + 1}.';
    }

    await _db.child(code).update({
      'status': matchOver ? 'MATCH_OVER' : 'ROUND_END',
      'seats/$seat/hand': updatedHand,
      'trickCards': <String, String>{},
      'leadSuit': '',
      'handsWon': handsWon,
      'teamScores': scores,
      'shufflerSeat': nextShuffler,
      'statusMessage': endMsg,
    });
  }
}
