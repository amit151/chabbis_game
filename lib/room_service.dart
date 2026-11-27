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

/// Converts raw RTDB data into a predictable, fully typed structure.
Map<String, dynamic> _normalizeRoom(dynamic raw) {
  final room = _asStringMap(raw);

  final seatsRaw = _asStringMap(room['seats']);
  room['seats'] = seatsRaw.map((k, v) {
    final seat = _asStringMap(v);
    seat['hand'] = _asStringList(seat['hand']);
    return MapEntry(k, seat);
  });

  final trick = _asStringMap(room['trickCards']);
  room['trickCards'] = trick.map((k, v) => MapEntry(k, v.toString()));

  room['teamScores'] = _asStringMap(room['teamScores']);
  room['handsWon'] = _asStringMap(room['handsWon']);
  room['pendingChaalCards'] = _asStringList(room['pendingChaalCards']);
  room['remainingDeck'] = _asStringList(room['remainingDeck']);
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
  Future<String> createRoom(String playerName) async {
    final code = _generateCode();
    await _db.child(code).set({
      'status': 'LOBBY',
      'shufflerSeat': 0,
      'turnSeat': 1,
      'bidderSeat': -1,
      'currentBid': 9,
      'consecutivePasses': 0,
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
        '0': {'name': playerName, 'hand': <String>[]},
      },
    });
    return code;
  }

  /// Joins an existing room at the first open seat (0..3).
  Future<int?> joinRoom(String rawCode, String playerName) async {
    final code = rawCode.trim().toUpperCase();
    final snap = await _db.child(code).get();
    if (!snap.exists || snap.value == null) return null;

    final data = _normalizeRoom(snap.value);
    final seats = data['seats'] as Map<String, dynamic>;

    for (int i = 0; i < 4; i++) {
      if (!seats.containsKey('$i')) {
        await _db.child('$code/seats/$i').set({
          'name': playerName,
          'hand': <String>[],
        });
        if (seats.length + 1 == 4) {
          await _db.child(code).update({
            'statusMessage': 'All 4 players joined! Shuffler can deal.',
          });
        }
        return i;
      }
    }
    return null;
  }

  Stream<Map<String, dynamic>?> watchRoom(String code) {
    return _db.child(code).onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;
      return _normalizeRoom(event.snapshot.value);
    });
  }

  /// Step 1: Shuffler deals 5 cards to each player; first anti-clockwise player starts bidding.
  Future<void> dealInitialFive(String code, int shufflerSeat) async {
    final deck = GameEngine.createShuffledDeck().map((c) => c.code).toList();
    final firstBidder = GameEngine.nextSeat(shufflerSeat);

    final updates = <String, dynamic>{
      'status': 'BIDDING',
      'shufflerSeat': shufflerSeat,
      'turnSeat': firstBidder,
      'bidderSeat': -1,
      'currentBid': 9,
      'consecutivePasses': 0,
      'turapSuit': '',
      'isTurapOpen': false,
      'isKhulliChabbis': false,
      'handsWon': {'team02': 0, 'team13': 0},
      'streakSeat': -1,
      'streakCount': 0,
      'pendingChaalCards': <String>[],
      'trickCards': <String, String>{},
      'leadSuit': '',
      'remainingDeck': deck.sublist(20),
      'statusMessage': '5 cards dealt! Seat ${firstBidder + 1} picks Turap & bids.',
    };

    for (int i = 0; i < 4; i++) {
      updates['seats/$i/hand'] = deck.sublist(i * 5, (i + 1) * 5);
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

  /// Pass during bidding; if 3 passes occur after a bid, deal remaining 4 + 4 cards.
  Future<void> passBid({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
  }) async {
    final bidderSeat = room['bidderSeat'] as int;
    final passes = (room['consecutivePasses'] as int) + 1;

    if (bidderSeat != -1 && passes >= 3) {
      await _dealRemainingCards(code, room, bidderSeat);
    } else {
      final next = GameEngine.nextSeat(seat);
      await _db.child(code).update({
        'consecutivePasses': passes,
        'turnSeat': next,
        'statusMessage': 'Seat ${seat + 1} passed. Seat ${next + 1} to bid.',
      });
    }
  }

  /// Deals remaining 32 cards in 2 waves of 4 cards (total 13 cards per player).
  Future<void> _dealRemainingCards(
    String code,
    Map<String, dynamic> room,
    int bidderSeat,
  ) async {
    final rem = List<String>.from(room['remainingDeck'] as List);
    final seats = room['seats'] as Map<String, dynamic>;
    final updates = <String, dynamic>{
      'status': 'KHULLI_WINDOW',
      'turnSeat': bidderSeat,
      'remainingDeck': <String>[],
      'statusMessage':
          'All 13 cards dealt (4 + 4)! Bidder may lead or anyone may call Khulli Chabbis.',
    };

    for (int i = 0; i < 4; i++) {
      final seatData = seats['$i'] as Map<String, dynamic>;
      final existing = List<String>.from(seatData['hand'] as List);
      final wave1 = rem.sublist(i * 4, (i + 1) * 4);
      final wave2 = rem.sublist(16 + i * 4, 16 + (i + 1) * 4);
      updates['seats/$i/hand'] = [...existing, ...wave1, ...wave2];
    }

    await _db.child(code).update(updates);
  }

  /// Declares Open 26 (Khulli Chabbis) after all 13 cards are distributed.
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
      'turnSeat': callerSeat,
      'statusMessage':
          'KHULLI CHABBIS called by Seat ${callerSeat + 1}! Turap is ${turapSuit.label}.',
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

    int newStreakSeat = trickWinner;
    int newStreakCount = (prevStreakSeat == trickWinner) ? prevStreakCount + 1 : 1;
    String chaalMsg =
        'Seat ${trickWinner + 1} won hand ($newStreakCount/2 consecutive).';

    if (newStreakCount == 2) {
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
    final isKhulli = room['isKhulliChabbis'] as bool? ?? false;

    final khulliDefeatedEarly = isKhulli &&
        (winnerTeam == defenderTeam) &&
        (prevStreakSeat == trickWinner) &&
        (prevStreakCount + 1 == 2);

    if (totalHandsPlayed >= 13 || khulliDefeatedEarly) {
      await _finishRound(
        code: code,
        room: room,
        seat: seat,
        updatedHand: hand,
        handsWon: handsWon,
        khulliDefeatedEarly: khulliDefeatedEarly,
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

  Future<void> _finishRound({
    required String code,
    required Map<String, dynamic> room,
    required int seat,
    required List<String> updatedHand,
    required Map<String, dynamic> handsWon,
    required bool khulliDefeatedEarly,
  }) async {
    final bidderSeat = room['bidderSeat'] as int;
    final bidderTeam = GameEngine.teamKeyForSeat(bidderSeat);
    final defenderTeam = bidderTeam == 'team02' ? 'team13' : 'team02';
    final bid = room['currentBid'] as int;
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

    final bidderWonRound = delta > 0;
    final currentShuffler = room['shufflerSeat'] as int;
    final nextShuffler =
        bidderWonRound ? currentShuffler : GameEngine.nextSeat(currentShuffler);

    final t02 = scores['team02'] as int;
    final t13 = scores['team13'] as int;
    final matchOver = t02 <= -104 || t13 <= -104;

    String endMsg;
    if (matchOver) {
      final loser = t02 <= -104 ? 'Team A (Seats 1 & 3)' : 'Team B (Seats 2 & 4)';
      endMsg = 'MATCH OVER! $loser reached -104 points and lost!';
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
