import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'game_engine.dart';
import 'room_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const Chabbis26App());
}

class Chabbis26App extends StatelessWidget {
  const Chabbis26App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '26 (Chabbis)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B5E20),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LobbyScreen(),
    );
  }
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _roomService = RoomService();
  final String _playerId = 'p_${Random.secure().nextInt(1 << 31)}';
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your name first');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await _roomService.createRoom(name, playerId: _playerId);
      if (!mounted) return;
      setState(() => _loading = false);
      if (code.isEmpty) {
        setState(() => _error = 'Could not generate room code. Check Firebase connection.');
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GameTableScreen(
            roomCode: code,
            mySeat: 0,
            playerId: _playerId,
            playerName: name,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to create room: $e';
      });
    }
  }

  Future<void> _join() async {
    final name = _nameCtrl.text.trim();
    final code = _codeCtrl.text.trim().toUpperCase();
    if (name.isEmpty || code.length < 4) {
      setState(() => _error = 'Enter your name and valid room code');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final seat = await _roomService.joinRoom(
        code,
        name,
        playerId: _playerId,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      if (seat == null) {
        setState(() => _error = 'Room not found or already full (4/4)');
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GameTableScreen(
            roomCode: code,
            mySeat: seat,
            playerId: _playerId,
            playerName: name,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to join room: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D2818),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              color: const Color(0xFF143D24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '26 • CHABBIS',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '4-Player Partnership Card Game (-104 Eliminates)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Your Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _create,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.add_circle_outline),
                        label: Text(_loading ? 'Creating Room...' : 'Create Room (Get Code)'),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('— OR JOIN WITH CODE —'),
                    ),
                    TextField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: '6-Character Room Code',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _loading ? null : _join,
                        icon: const Icon(Icons.login),
                        label: const Text('Join Room'),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GameTableScreen extends StatefulWidget {
  final String roomCode;
  final int mySeat;
  final String? playerId;
  final String? playerName;

  const GameTableScreen({
    super.key,
    required this.roomCode,
    required this.mySeat,
    this.playerId,
    this.playerName,
  });

  @override
  State<GameTableScreen> createState() => _GameTableScreenState();
}

class _GameTableScreenState extends State<GameTableScreen> {
  final _roomService = RoomService();
  Suit _selectedTurap = Suit.spades;

  Widget _buildCardFace(
    PlayingCard card, {
    required double width,
    required double height,
    bool highlighted = false,
    bool dimmed = false,
  }) {
    final isRed = card.suit.isRed;
    final fg = isRed ? const Color(0xFFB91C1C) : const Color(0xFF111827);
    final isRoyal = card.rank == 11 || card.rank == 12 || card.rank == 13;
    final royalTitle = card.rank == 13
        ? '♔ KING'
        : card.rank == 12
            ? '♕ QUEEN'
            : '♙ JACK';

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBF0),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlighted ? Colors.amber : Colors.black26,
            width: highlighted ? 2.5 : 1,
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 5, offset: Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.rankLabel,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w800,
                      fontSize: width * 0.21,
                      height: 1.0,
                    ),
                  ),
                  Text(
                    card.suit.symbol,
                    style: TextStyle(
                      color: fg,
                      fontSize: width * 0.18,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            if (isRoyal)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: fg.withOpacity(0.09),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: fg.withOpacity(0.35)),
                ),
                child: Text(
                  royalTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: width * 0.135,
                  ),
                ),
              )
            else
              Text(
                card.suit.symbol,
                style: TextStyle(
                  color: fg,
                  fontSize: width * 0.34,
                  height: 1.0,
                ),
              ),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                '${card.rankLabel}${card.suit.symbol}',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: width * 0.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Leave Game Table?'),
            content: const Text(
              'If you leave accidentally, you can rejoin with the same room code.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Stay'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Leave'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: StreamBuilder?>(
        stream: _roomService.watchRoom(widget.roomCode),
        builder: (context, snapshot) {
          final room = snapshot.data;
          if (room == null) {
            return Scaffold(
              backgroundColor: const Color(0xFF0E331D),
              appBar: AppBar(
                backgroundColor: const Color(0xFF092213),
                title: Text('Room: ${widget.roomCode}'),
              ),
              body: const Center(child: CircularProgressIndicator()),
            );
          }

          final status = room['status'] as String;
          final shufflerSeat = room['shufflerSeat'] as int;
          final turnSeat = room['turnSeat'] as int;
          final bidderSeat = room['bidderSeat'] as int;
          final currentBid = room['currentBid'] as int;
          final isTurapOpen = room['isTurapOpen'] as bool? ?? false;
          final turapStr = room['turapSuit'] as String? ?? '';
          final turapSuit = turapStr.isEmpty
              ? null
              : Suit.values.firstWhere((s) => s.name == turapStr);

          final streakCount = room['streakCount'] as int? ?? 0;
          final pendingChaalCards =
              List<String>.from((room['pendingChaalCards'] ?? []) as List);

          final scores = Map<String, dynamic>.from(room['teamScores'] as Map);
          final handsWon = Map<String, dynamic>.from(room['handsWon'] as Map);
          final seats = Map<String, dynamic>.from((room['seats'] ?? {}) as Map);
          final myData =
              Map<String, dynamic>.from((seats['${widget.mySeat}'] ?? {}) as Map);
          final myHand = GameEngine.sortHand(
            List<String>.from((myData['hand'] ?? []) as List)
                .map(PlayingCard.fromCode)
                .toList(),
          );

          final trickRaw =
              Map<String, dynamic>.from((room['trickCards'] ?? {}) as Map);
          final leadSuitStr = room['leadSuit'] as String? ?? '';
          final leadSuit = leadSuitStr.isEmpty
              ? null
              : Suit.values.firstWhere((s) => s.name == leadSuitStr);

          // Collect visible cards remaining/active on table until 2 consecutive wins
          final visibleTableCards = <String>[
            ...myHand.map((c) => c.toString()),
            ...pendingChaalCards.map((code) => PlayingCard.fromCode(code).toString()),
            ...trickRaw.values.map((v) => PlayingCard.fromCode(v as String).toString()),
          ];

          final isMyTurn = turnSeat == widget.mySeat;
          final canSeeTurap =
              isTurapOpen || (bidderSeat == widget.mySeat && turapSuit != null);

          final rightSeat = GameEngine.nextSeat(widget.mySeat);
          final topSeat = GameEngine.nextSeat(rightSeat);
          final leftSeat = GameEngine.nextSeat(topSeat);

          return Scaffold(
            backgroundColor: const Color(0xFF0E331D),
            appBar: AppBar(
              backgroundColor: const Color(0xFF092213),
              title: Text('Room: ${widget.roomCode}'),
              actions: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      'A(1&3): ${scores['team02']} | B(2&4): ${scores['team13']}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black26,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.amber.withOpacity(0.5)),
                          ),
                          child: Text(
                            'Chaal Cards: ${pendingChaalCards.length}  •  Streak: $streakCount/2',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (streakCount < 2 && visibleTableCards.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Active/Remaining (${visibleTableCards.length}): ${visibleTableCards.join(' ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          room['statusMessage'] ?? '',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 12,
                          children: [
                            Text('Bid: ${bidderSeat == -1 ? '-' : '$currentBid (Seat ${bidderSeat + 1})'}'),
                            Text(
                              'Turap: ${canSeeTurap && turapSuit != null ? '${turapSuit.label} ${turapSuit.symbol}' : 'HIDDEN'}',
                              style: const TextStyle(color: Colors.amberAccent),
                            ),
                            Text('Hands A:${handsWon['team02']} B:${handsWon['team13']}'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _seatBadge(seats, topSeat, turnSeat, shufflerSeat, 'Partner'),
                  Expanded(
                    child: Row(
                      children: [
                        _seatBadge(seats, leftSeat, turnSeat, shufflerSeat, 'Opp'),
                        Expanded(
                          child: _centerTableArea(
                            code: widget.roomCode,
                            room: room,
                            status: status,
                            seatsCount: seats.length,
                            shufflerSeat: shufflerSeat,
                            isMyTurn: isMyTurn,
                            currentBid: currentBid,
                            trickRaw: trickRaw,
                            myHand: myHand,
                            leadSuit: leadSuit,
                            isTurapOpen: isTurapOpen,
                          ),
                        ),
                        _seatBadge(seats, rightSeat, turnSeat, shufflerSeat, 'Opp'),
                      ],
                    ),
                  ),
                  _seatBadge(seats, widget.mySeat, turnSeat, shufflerSeat, 'You'),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 112,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: myHand.length,
                      itemBuilder: (_, idx) {
                        final card = myHand[idx];
                        final playable =
                            (status == 'TRICK_PLAY' || status == 'KHULLI_WINDOW') &&
                                isMyTurn &&
                                GameEngine.canPlayCard(
                                  hand: myHand,
                                  card: card,
                                  leadSuit: leadSuit,
                                );

                        return GestureDetector(
                          onTap: playable
                              ? () => _roomService.playCard(
                                    code: widget.roomCode,
                                    room: room,
                                    seat: widget.mySeat,
                                    card: card,
                                  )
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _buildCardFace(
                              card,
                              width: 72,
                              height: 108,
                              highlighted: playable,
                              dimmed: !playable,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _seatBadge(
    Map<String, dynamic> seats,
    int seat,
    int turnSeat,
    int shufflerSeat,
    String role,
  ) {
    final info = seats['$seat'] as Map?;
    final name = info == null ? 'Open' : (info['name'] ?? 'P${seat + 1}');
    final active = seat == turnSeat;
    return Container(
      margin: const EdgeInsets.all(6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? Colors.amber.withOpacity(0.25) : Colors.black26,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? Colors.amber : Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'S${seat + 1}: $name ($role)',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          if (seat == shufflerSeat)
            const Text(
              'Shuffler',
              style: TextStyle(fontSize: 10, color: Colors.lightGreenAccent),
            ),
        ],
      ),
    );
  }

  Widget _centerTableArea({
    required String code,
    required Map<String, dynamic> room,
    required String status,
    required int seatsCount,
    required int shufflerSeat,
    required bool isMyTurn,
    required int currentBid,
    required Map<String, dynamic> trickRaw,
    required List<PlayingCard> myHand,
    required Suit? leadSuit,
    required bool isTurapOpen,
  }) {
    if ((status == 'LOBBY' || status == 'ROUND_END') && widget.mySeat == shufflerSeat) {
      return Center(
        child: FilledButton(
          onPressed: seatsCount == 4
              ? () => _roomService.dealInitialFive(code, shufflerSeat)
              : null,
          child: Text(seatsCount == 4 ? 'Shuffle & Deal (5-4-4)' : 'Waiting ($seatsCount/4)'),
        ),
      );
    }

    if (status == 'BIDDING' && isMyTurn) {
      final nextBid = currentBid < 10 ? 10 : currentBid + 1;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Select Hidden Turap & Bid:'),
          const SizedBox(height: 6),
          SegmentedButton<Suit>(
            segments: Suit.values
                .map((s) => ButtonSegment(value: s, label: Text(s.symbol)))
                .toList(),
            selected: {_selectedTurap},
            onSelectionChanged: (val) => setState(() => _selectedTurap = val.first),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (nextBid <= 13)
                FilledButton(
                  onPressed: () => _roomService.placeBid(
                    code: code,
                    room: room,
                    seat: widget.mySeat,
                    bidAmount: nextBid,
                    turapSuit: _selectedTurap,
                  ),
                  child: Text('Bid $nextBid'),
                ),
              if (currentBid >= 10)
                OutlinedButton(
                  onPressed: () => _roomService.passBid(
                    code: code,
                    room: room,
                    seat: widget.mySeat,
                  ),
                  child: const Text('Pass'),
                ),
            ],
          ),
        ],
      );
    }

    final canAskTurap = status == 'TRICK_PLAY' &&
        isMyTurn &&
        GameEngine.canRequestOrOpenTurap(
          hand: myHand,
          leadSuit: leadSuit,
          isTurapOpen: isTurapOpen,
        );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (status == 'KHULLI_WINDOW' && isMyTurn)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  onPressed: () => _roomService.callKhulliChabbis(
                    code: code,
                    callerSeat: widget.mySeat,
                    turapSuit: _selectedTurap,
                  ),
                  child: const Text('Call Khulli Chabbis (52 pts)'),
                ),
                OutlinedButton(
                  onPressed: () => _roomService.passKhulliChabbis(
                    code: code,
                    room: room,
                    seat: widget.mySeat,
                  ),
                  child: const Text('Pass'),
                ),
              ],
            ),
          ),
        if (canAskTurap)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.tonal(
              onPressed: () => _roomService.openTurap(code, room, widget.mySeat),
              child: const Text('Ask / Open Turap'),
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: trickRaw.entries.map((e) {
            final s = int.parse(e.key);
            final c = PlayingCard.fromCode(e.value as String);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCardFace(c, width: 78, height: 114, highlighted: true),
                const SizedBox(height: 3),
                Text(
                  'S${s + 1}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }
}
