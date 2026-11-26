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
  bool _loading = false;
  String? _error;

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
    final code = await _roomService.createRoom(name);
    if (!mounted) return;
    setState(() => _loading = false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameTableScreen(roomCode: code, mySeat: 0),
      ),
    );
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
    final seat = await _roomService.joinRoom(code, name);
    if (!mounted) return;
    setState(() => _loading = false);
    if (seat == null) {
      setState(() => _error = 'Room not found or already full (4/4)');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameTableScreen(roomCode: code, mySeat: seat),
      ),
    );
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
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Create Room (Get Code)'),
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
                      Text(_error!, style: const TextStyle(color: Colors.redAccent)),
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

  const GameTableScreen({
    super.key,
    required this.roomCode,
    required this.mySeat,
  });

  @override
  State<GameTableScreen> createState() => _GameTableScreenState();
}

class _GameTableScreenState extends State<GameTableScreen> {
  final _roomService = RoomService();
  Suit _selectedTurap = Suit.spades;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: _roomService.watchRoom(widget.roomCode),
      builder: (context, snapshot) {
        final room = snapshot.data;
        if (room == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
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

        final scores = Map<String, dynamic>.from(room['teamScores']);
        final handsWon = Map<String, dynamic>.from(room['handsWon']);
        final seats = Map<String, dynamic>.from(room['seats'] ?? {});
        final myData = Map<String, dynamic>.from(seats['${widget.mySeat}'] ?? {});
        final myHand = GameEngine.sortHand(
          List<String>.from(myData['hand'] ?? [])
              .map(PlayingCard.fromCode)
              .toList(),
        );

        final trickRaw = Map<String, dynamic>.from(room['trickCards'] ?? {});
        final leadSuitStr = room['leadSuit'] as String? ?? '';
        final leadSuit = leadSuitStr.isEmpty
            ? null
            : Suit.values.firstWhere((s) => s.name == leadSuitStr);

        final isMyTurn = turnSeat == widget.mySeat;
        final canSeeTurap =
            isTurapOpen || (bidderSeat == widget.mySeat && turapSuit != null);

        // Diamond seating relative to current user (bottom = me, right = +1 anti-clockwise, top = partner, left = +3)
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
                // Top Info Bar
                Container(
                  width: double.infinity,
                  color: Colors.black26,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
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

                // Top Player (Teammate)
                _seatBadge(seats, topSeat, turnSeat, shufflerSeat, 'Partner'),

                // Middle Diamond Row: Left Player | Center Trick | Right Player
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

                // Bottom Player (You) + Hand
                _seatBadge(seats, widget.mySeat, turnSeat, shufflerSeat, 'You'),
                const SizedBox(height: 6),
                SizedBox(
                  height: 105,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: myHand.length,
                    itemBuilder: (_, idx) {
                      final card = myHand[idx];
                      final playable = (status == 'TRICK_PLAY' || status == 'KHULLI_WINDOW') &&
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
                        child: Container(
                          width: 66,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: playable ? Colors.white : Colors.white70,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: playable ? Colors.amber : Colors.grey,
                              width: playable ? 2.5 : 1,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              card.toString(),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: card.suit.isRed ? Colors.red[800] : Colors.black87,
                              ),
                            ),
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
    );
  }

  Widget _seatBadge(
    Map<String, dynamic> seats,
    int seat,
    int turnSeat,
    int shufflerSeat,
    String role,
  ) {
    final info = seats['$seat'];
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
            const Text('Shuffler', style: TextStyle(fontSize: 10, color: Colors.lightGreenAccent)),
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
          child: Text(seatsCount == 4 ? 'Shuffle & Deal 5 Cards' : 'Waiting ($seatsCount/4)'),
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
        if (status == 'KHULLI_WINDOW')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              onPressed: () => _roomService.callKhulliChabbis(
                code: code,
                callerSeat: widget.mySeat,
                turapSuit: _selectedTurap,
              ),
              child: const Text('Call Khulli Chabbis (52 pts)'),
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
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: trickRaw.entries.map((e) {
            final s = int.parse(e.key);
            final c = PlayingCard.fromCode(e.value as String);
            return Chip(
              label: Text('S${s + 1}: $c'),
              backgroundColor: Colors.black45,
            );
          }).toList(),
        ),
      ],
    );
  }
}
