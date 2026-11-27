import 'dart:math';

enum Suit { spades, hearts, diamonds, clubs }

extension SuitExt on Suit {
  String get symbol {
    switch (this) {
      case Suit.spades:
        return '♠';
      case Suit.hearts:
        return '♥';
      case Suit.diamonds:
        return '♦';
      case Suit.clubs:
        return '♣';
    }
  }

  String get label => name.toUpperCase();

  bool get isRed => this == Suit.hearts || this == Suit.diamonds;
}

class PlayingCard {
  final Suit suit;
  final int rank; // 2..14 (11=J, 12=Q, 13=K, 14=A)

  const PlayingCard({required this.suit, required this.rank});

  String get rankLabel {
    switch (rank) {
      case 14:
        return 'A';
      case 13:
        return 'K';
      case 12:
        return 'Q';
      case 11:
        return 'J';
      default:
        return rank.toString();
    }
  }

  String get code => '${suit.name[0].toUpperCase()}$rank';

  factory PlayingCard.fromCode(String code) {
    final suitChar = code[0];
    final rank = int.parse(code.substring(1));
    final suit = Suit.values.firstWhere(
      (s) => s.name[0].toUpperCase() == suitChar,
    );
    return PlayingCard(suit: suit, rank: rank);
  }

  @override
  String toString() => '$rankLabel${suit.symbol}';

  @override
  bool operator ==(Object other) =>
      other is PlayingCard && other.suit == suit && other.rank == rank;

  @override
  int get hashCode => Object.hash(suit, rank);
}

class GameEngine {
  /// Anti-clockwise next seat: 0 -> 1 -> 2 -> 3 -> 0
  static int nextSeat(int seat) => (seat + 1) % 4;

  /// Opposite seat is teammate: (0 & 2) = team02, (1 & 3) = team13
  static int teammateSeat(int seat) => (seat + 2) % 4;

  static String teamKeyForSeat(int seat) =>
      (seat % 2 == 0) ? 'team02' : 'team13';

  /// Fisher-Yates in-place shuffle on a standard 52-card deck.
  static List<PlayingCard> createShuffledDeck([Random? rng]) {
    final random = rng ?? Random.secure();
    final deck = <PlayingCard>[];
    for (final suit in Suit.values) {
      for (int r = 2; r <= 14; r++) {
        deck.add(PlayingCard(suit: suit, rank: r));
      }
    }

    for (int i = deck.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final temp = deck[i];
      deck[i] = deck[j];
      deck[j] = temp;
    }
    return deck;
  }

  /// Distributes all 52 cards (13 per player) across 4 seats in 3 rounds:
  /// 5 cards each, then 4 cards each, then 4 cards each starting after [shufflerSeat].
  static Map<int, List<PlayingCard>> deal544(
    List<PlayingCard> shuffledDeck,
    int shufflerSeat,
  ) {
    assert(shuffledDeck.length == 52, 'Expected 52 cards, got ${shuffledDeck.length}');
    final hands = <int, List<PlayingCard>>{0: [], 1: [], 2: [], 3: []};
    int cursor = 0;
    final startSeat = nextSeat(shufflerSeat);

    for (final batchSize in const [5, 4, 4]) {
      for (int step = 0; step < 4; step++) {
        final seat = (startSeat + step) % 4;
        hands[seat]!.addAll(shuffledDeck.sublist(cursor, cursor + batchSize));
        cursor += batchSize;
      }
    }
    return hands;
  }

  /// Sort hand by suit then descending rank
  static List<PlayingCard> sortHand(List<PlayingCard> cards) {
    final copy = List<PlayingCard>.from(cards);
    copy.sort((a, b) {
      final s = a.suit.index.compareTo(b.suit.index);
      if (s != 0) return s;
      return b.rank.compareTo(a.rank);
    });
    return copy;
  }

  /// Checks if a card is legal to play given current hand and led suit.
  static bool canPlayCard({
    required List<PlayingCard> hand,
    required PlayingCard card,
    required Suit? leadSuit,
  }) {
    if (leadSuit == null) return true;
    final hasLeadSuit = hand.any((c) => c.suit == leadSuit);
    if (!hasLeadSuit) return true;
    return card.suit == leadSuit;
  }

  /// Checks if current player on their turn can ask/open Turap.
  static bool canRequestOrOpenTurap({
    required List<PlayingCard> hand,
    required Suit? leadSuit,
    required bool isTurapOpen,
  }) {
    if (isTurapOpen || leadSuit == null) return false;
    return !hand.any((c) => c.suit == leadSuit);
  }

  /// Evaluates the winning seat of a 4-card trick.
  /// Turap only has power if [isTurapOpen] is true.
  static int evaluateTrickWinner({
    required Map<int, PlayingCard> trickCards,
    required Suit leadSuit,
    required Suit turapSuit,
    required bool isTurapOpen,
  }) {
    int? winningSeat;
    PlayingCard? bestCard;

    for (final entry in trickCards.entries) {
      final seat = entry.key;
      final card = entry.value;

      final isValidTrump = isTurapOpen && card.suit == turapSuit;
      final isLead = card.suit == leadSuit;

      // Off-suit non-trump cards have zero value
      if (!isValidTrump && !isLead) continue;

      if (bestCard == null) {
        bestCard = card;
        winningSeat = seat;
        continue;
      }

      final bestIsTrump = isTurapOpen && bestCard.suit == turapSuit;

      if (isValidTrump && !bestIsTrump) {
        bestCard = card;
        winningSeat = seat;
      } else if (isValidTrump && bestIsTrump) {
        if (card.rank > bestCard.rank) {
          bestCard = card;
          winningSeat = seat;
        }
      } else if (!bestIsTrump && isLead) {
        if (card.rank > bestCard.rank) {
          bestCard = card;
          winningSeat = seat;
        }
      }
    }

    return winningSeat ?? trickCards.keys.first;
  }

  /// Defenders' required hands to defeat the bidder based on bid amount:
  /// - Bid <= 10 -> defenders need 4 hands
  /// - Bid 11 -> defenders need 3 hands
  /// - Bid >= 12 -> defenders need 2 hands
  static int defenderHandsNeededToDefeat(int bid) {
    if (bid <= 10) return 4;
    if (bid == 11) return 3;
    return 2;
  }

  /// Number of hands won by the opposing (defender) team that ends the round/game:
  /// - Khulli Chabbis -> 2 hands
  /// - Bid <= 10 -> 4 hands
  /// - Bid == 11 -> 3 hands
  /// - Bid >= 12 -> 2 hands
  static int opponentHandsThreshold({
    required int bid,
    required bool isKhulliChabbis,
  }) {
    if (isKhulliChabbis) return 2;
    if (bid <= 10) return 4;
    if (bid == 11) return 3;
    return 2;
  }

  static bool opponentsReachedEndThreshold({
    required int bid,
    required int defenderHandsWon,
    required bool isKhulliChabbis,
  }) {
    return defenderHandsWon >=
        opponentHandsThreshold(bid: bid, isKhulliChabbis: isKhulliChabbis);
  }

  /// Zero-sum round delta calculation for bidding team:
  /// Returns positive points for bidding team if won, negative if lost.
  static int calculateRoundDeltaForBidder({
    required int bid,
    required int bidderHandsWon,
    required int defenderHandsWon,
    required bool isKhulliChabbis,
    required bool khulliChabbisFailedEarly,
  }) {
    final neededToDefeat = opponentHandsThreshold(
      bid: bid,
      isKhulliChabbis: isKhulliChabbis,
    );

    if (isKhulliChabbis) {
      if (khulliChabbisFailedEarly || defenderHandsWon >= neededToDefeat) {
        return -52;
      }
      return 52;
    }

    // Mega Round Win (Chabbis): winning all 13 hands
    if (bidderHandsWon == 13) {
      return 26;
    }

    if (defenderHandsWon >= neededToDefeat) {
      return -2 * bid;
    }
    return bid;
  }
}
