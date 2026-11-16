import 'dart:io';
import 'dart:isolate';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const NMHKaraokeApp());
}

class NMHKaraokeApp extends StatelessWidget {
  const NMHKaraokeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NMH Karaoke',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        primaryColor: const Color(0xFFFFB300),
      ),
      home: const KaraokeHomeScreen(),
    );
  }
}

class Song {
  final String code, title, artist, coArtist, album;
  final bool isDisco;
  Song({required this.code, required this.title, required this.artist, required this.coArtist, required this.album, this.isDisco = false});
  Map<String, dynamic> toMap() => {'code': code, 'title': title, 'artist': artist, 'coArtist': coArtist, 'album': album, 'isDisco': isDisco ? 1 : 0};
  factory Song.fromMap(Map<String, dynamic> m) => Song(code: m['code'] ?? '', title: m['title'] ?? '', artist: m['artist'] ?? '', coArtist: m['coArtist'] ?? '', album: m['album'] ?? '', isDisco: (m['isDisco'] ?? 0) == 1);
}

class DatabaseHelper {
  static Database? _db;
  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await openDatabase(p.join(await getDatabasesPath(), 'nmh_karaoke.db'), version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE songs(code TEXT PRIMARY KEY, title TEXT, artist TEXT, coArtist TEXT, album TEXT, isDisco INTEGER)');
      await db.execute('CREATE INDEX idx_title ON songs(title)');
      await db.execute('CREATE INDEX idx_artist ON songs(artist)');
      await db.execute('CREATE INDEX idx_album ON songs(album)');
    });
    return _db!;
  }

  static Future<void> clearAndInsertSongs(List<Song> songs) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('songs');
      final batch = txn.batch();
      for (final s in songs) {
        batch.insert('songs', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<int> getSongCount() async => Sqflite.firstIntValue(await (await database).rawQuery('SELECT COUNT(*) FROM songs')) ?? 0;

  static Future<List<Song>> searchSongs({String query = '', String category = 'TITLE', int offset = 0, int limit = 200}) async {
    final db = await database;
    final q = '%${query.trim()}%';
    List<Map<String, dynamic>> maps;
    if (category == 'DISCO') {
      maps = query.trim().isEmpty
          ? await db.query('songs', where: 'isDisco = 1', limit: limit, offset: offset)
          : await db.query('songs', where: 'isDisco = 1 AND (title LIKE ? OR artist LIKE ? OR code LIKE ?)', whereArgs: [q, q, q], limit: limit, offset: offset);
    } else if (category == 'CODE') {
      maps = query.trim().isEmpty
          ? await db.query('songs', orderBy: 'code ASC', limit: limit, offset: offset)
          : await db.query('songs', where: 'code LIKE ?', whereArgs: ['${query.trim()}%'], orderBy: 'code ASC', limit: limit, offset: offset);
    } else if (category == 'ARTIST') {
      maps = await db.query('songs', where: 'artist LIKE ? OR coArtist LIKE ?', whereArgs: [q, q], limit: limit, offset: offset);
    } else if (category == 'ALBUM') {
      maps = await db.query('songs', where: 'album LIKE ?', whereArgs: [q], limit: limit, offset: offset);
    } else {
      maps = query.trim().isEmpty
          ? await db.query('songs', limit: limit, offset: offset)
          : await db.query('songs', where: 'title LIKE ? OR code LIKE ?', whereArgs: [q, q], limit: limit, offset: offset);
    }
    return maps.map((m) => Song.fromMap(m)).toList();
  }

  static Future<List<String>> getDistinctValues(String col, String filter, {int offset = 0, int limit = 200}) async {
    final db = await database;
    final res = await db.query('songs', distinct: true, columns: [col], where: filter.trim().isEmpty ? '$col != ""' : '$col LIKE ?', whereArgs: filter.trim().isEmpty ? null : ['%${filter.trim()}%'], orderBy: '$col ASC', limit: limit, offset: offset);
    return res.map((e) => e[col].toString()).where((s) => s.isNotEmpty).toList();
  }
}

List<Map<String, dynamic>> _parseExcelIsolate(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'];
  final bool isDisco = args['isDisco'];
  final excel = xls.Excel.decodeBytes(bytes);
  final List<Map<String, dynamic>> list = [];
  for (final t in excel.tables.keys) {
    final sheet = excel.tables[t];
    if (sheet == null) continue;
    for (int i = 1; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      String cell(int idx) => (idx < row.length && row[idx]?.value != null) ? row[idx]!.value.toString().trim() : '';
      if (cell(0).isNotEmpty && cell(1).isNotEmpty) {
        list.add({'code': cell(0), 'title': cell(1), 'artist': cell(2), 'coArtist': cell(3), 'album': cell(4), 'isDisco': isDisco ? 1 : 0});
      }
    }
  }
  return list;
}

class KaraokeHomeScreen extends StatefulWidget {
  const KaraokeHomeScreen({super.key});
  @override
  State<KaraokeHomeScreen> createState() => _KaraokeHomeScreenState();
}

class _KaraokeHomeScreenState extends State<KaraokeHomeScreen> {
  static const platform = MethodChannel('com.nmh.karaoke/player');
  final List<Song> _queue = [];
  final List<Song> _history = [];
  Song? _currentSong;
  bool _isTvConnected = false, _isPlaying = false, _isSyncing = false;
  String _voiceMode = 'STEREO', _activeView = 'HOME';
  String? _selectedSubGroup;
  int _totalSongs = 0;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Song> _searchResults = [];
  List<String> _groupResults = [];
  bool _isLoadingMore = false, _hasMore = true;

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayChanged') setState(() => _isTvConnected = call.arguments == true);
      if (call.method == 'onSongCompleted') _playNextSong();
    });
    _scrollController.addListener(_onScroll);
    _checkTvDisplay();
    _initStorageAndDb();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300 && !_isLoadingMore && _hasMore) {
      _loadMoreData();
    }
  }

  Future<void> _loadMoreData() async {
    setState(() => _isLoadingMore = true);
    final q = _searchController.text;
    if ((_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null) {
      final col = _activeView == 'ARTIST' ? 'artist' : 'album';
      final more = await DatabaseHelper.getDistinctValues(col, q, offset: _groupResults.length);
      setState(() {
        _groupResults.addAll(more);
        _hasMore = more.length == 200;
        _isLoadingMore = false;
      });
    } else {
      final queryStr = _selectedSubGroup ?? q;
      final more = await DatabaseHelper.searchSongs(query: queryStr, category: _activeView, offset: _searchResults.length);
      setState(() {
        _searchResults.addAll(more);
        _hasMore = more.length == 200;
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _checkTvDisplay() async {
    try {
      final bool c = await platform.invokeMethod('checkDisplay');
      setState(() => _isTvConnected = c);
    } catch (_) {}
  }

  Future<void> _initStorageAndDb() async {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
    final count = await DatabaseHelper.getSongCount();
    setState(() => _totalSongs = count);
    if (count == 0) await _syncExcelData();
  }

  Future<List<Directory>> _discoverStorageRoots() async {
    final List<Directory> roots = [];
    for (final path in ['/storage/emulated/0', '/storage/emulated/0/NMH_Karaoke', '/storage/sdcard1', '/storage/sdcard1/NMH_Karaoke']) {
      final d = Directory(path);
      if (await d.exists()) roots.add(d);
    }
    try {
      final s = Directory('/storage');
      if (await s.exists()) {
        await for (final e in s.list()) {
          if (e is Directory && !e.path.contains('emulated') && !e.path.contains('self')) {
            roots.add(e);
            final sub = Directory('${e.path}/NMH_Karaoke');
            if (await sub.exists()) roots.add(sub);
          }
        }
      }
    } catch (_) {}
    return roots;
  }

  Future<void> _syncExcelData() async {
    setState(() => _isSyncing = true);
    try {
      final roots = await _discoverStorageRoots();
      final List<Song> loaded = [];
      for (final r in roots) {
        final q2 = File(p.join(r.path, 'q2.xlsx'));
        if (await q2.exists()) {
          final bytes = await q2.readAsBytes();
          final raw = await Isolate.run(() => _parseExcelIsolate({'bytes': bytes, 'isDisco': false}));
          loaded.addAll(raw.map((m) => Song.fromMap(m)));
        }
        final dc = File(p.join(r.path, 'disco.xlsx'));
        if (await dc.exists()) {
          final bytes = await dc.readAsBytes();
          final raw = await Isolate.run(() => _parseExcelIsolate({'bytes': bytes, 'isDisco': true}));
          loaded.addAll(raw.map((m) => Song.fromMap(m)));
        }
      }
      if (loaded.isNotEmpty) {
        await DatabaseHelper.clearAndInsertSongs(loaded);
        final count = await DatabaseHelper.getSongCount();
        setState(() => _totalSongs = count);
        _showSnack('သီချင်းပေါင်း $count ပုဒ် ဖတ်သွင်းပြီးပါပြီ။');
      } else {
        _showSnack('q2.xlsx / disco.xlsx မတွေ့ပါ။');
      }
    } catch (e) {
      _showSnack('Excel Error: $e');
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  Future<String?> _findVideoPath(String code) async {
    final roots = await _discoverStorageRoots();
    for (final r in roots) {
      for (final f in ['Myanmar_songs', 'Myanmar_New_Songs', 'DiscoVideo', '']) {
        final dir = f.isEmpty ? r.path : p.join(r.path, f);
        for (final ext in ['.mp4', '.mkv', '.dat', '.mpg', '.avi', '.MP4', '.MKV', '.DAT', '.MPG']) {
          final file = File(p.join(dir, '$code$ext'));
          if (await file.exists()) return file.path;
        }
      }
    }
    return null;
  }

  Future<void> _addToQueue(Song song, {bool playNow = false}) async {
    if (playNow) { await _startPlayingSong(song); return; }
    setState(() => _queue.add(song));
    _showSnack('ရွေးချယ်ပြီး: ${song.title}');
    if (_currentSong == null) _playNextSong();
  }

  Future<void> _startPlayingSong(Song song) async {
    final path = await _findVideoPath(song.code);
    if (path == null) { _showSnack('ဗီဒီယိုဖိုင် (${song.code}) မတွေ့ပါ။'); return; }
    setState(() {
      _currentSong = song;
      _isPlaying = true;
      _history.removeWhere((s) => s.code == song.code);
      _history.insert(0, song);
    });
    await platform.invokeMethod('playVideo', {'path': path});
  }

  Future<void> _playNextSong() async {
    if (_queue.isEmpty) {
      setState(() { _currentSong = null; _isPlaying = false; });
      await platform.invokeMethod('stop');
      return;
    }
    final next = _queue.removeAt(0);
    setState(() {});
    await _startPlayingSong(next);
  }

  Future<void> _cycleVoiceMode() async {
    const modes = ['STEREO', 'LEFT', 'RIGHT', 'TRACK2'];
    final nextMode = modes[(modes.indexOf(_voiceMode) + 1) % modes.length];
    await platform.invokeMethod('setVoiceMode', {'mode': nextMode});
    setState(() => _voiceMode = nextMode);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _openCategory(String cat) async {
    _searchController.clear();
    setState(() { _activeView = cat; _selectedSubGroup = null; _searchResults = []; _groupResults = []; _hasMore = true; });
    if (cat == 'HISTORY') {
      setState(() { _searchResults = List.from(_history); _hasMore = false; });
    } else if (cat == 'ARTIST') {
      final l = await DatabaseHelper.getDistinctValues('artist', '');
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else if (cat == 'ALBUM') {
      final l = await DatabaseHelper.getDistinctValues('album', '');
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else {
      final l = await DatabaseHelper.searchSongs(query: '', category: cat);
      setState(() { _searchResults = l; _hasMore = l.length == 200; });
    }
  }

  void _onSearchChanged(String val) async {
    setState(() => _hasMore = true);
    if (_activeView == 'HISTORY') {
      setState(() => _searchResults = _history.where((s) => s.title.toLowerCase().contains(val.toLowerCase()) || s.code.contains(val)).toList());
    } else if (_activeView == 'ARTIST' && _selectedSubGroup == null) {
      final l = await DatabaseHelper.getDistinctValues('artist', val);
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else if (_activeView == 'ALBUM' && _selectedSubGroup == null) {
      final l = await DatabaseHelper.getDistinctValues('album', val);
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else {
      final l = await DatabaseHelper.searchSongs(query: val, category: _activeView);
      setState(() { _searchResults = l; _hasMore = l.length == 200; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF0A0F1D), Color(0xFF141E30)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: MediaQuery.of(context).size.width * 0.34, child: _buildQueuePanel()),
                    const VerticalDivider(width: 1, color: Colors.amber),
                    Expanded(child: _buildRightPanel()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildTopBar() {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(color: Color(0xFF0D1322), border: Border(bottom: BorderSide(color: Colors.amber, width: 1.5))),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/logo.jpg', height: 48, width: 48, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.music_video, color: Colors.amber, size: 42)),
          ),
          const SizedBox(width: 10),
          const Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('NMH KARAOKE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Colors.amber)),
            Text('Capt.နေမျိုးထွန်း', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white70)),
          ]),
          const SizedBox(width: 16),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.tv, size: 15, color: _isTvConnected ? Colors.greenAccent : Colors.orangeAccent),
                const SizedBox(width: 5),
                Text(_isTvConnected ? 'TV Connected' : 'Tablet Mode', style: TextStyle(fontSize: 11, color: _isTvConnected ? Colors.greenAccent : Colors.orangeAccent)),
                const SizedBox(width: 12),
                Text('စုစုပေါင်း: $_totalSongs ပုဒ်', style: const TextStyle(fontSize: 11, color: Colors.white60)),
              ]),
              Text(_currentSong != null ? 'ဖွင့်နေသည်: [${_currentSong!.code}] ${_currentSong!.title}' : 'သီချင်းရွေးချယ်ရန် အသင့်ဖြစ်ပါပြီ', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.amberAccent)),
            ]),
          ),
          _topBtn(Icons.record_voice_over, 'Voice: $_voiceMode', Colors.cyanAccent, _cycleVoiceMode),
          _topBtn(_isPlaying ? Icons.pause : Icons.play_arrow, _isPlaying ? 'Pause' : 'Play', Colors.greenAccent, () async {
            final p = await platform.invokeMethod('pauseResume');
            setState(() => _isPlaying = p == true);
          }),
          _topBtn(Icons.replay, 'Replay', Colors.amber, () => platform.invokeMethod('replay')),
          _topBtn(Icons.skip_next, 'Next', Colors.orangeAccent, _playNextSong),
          _topBtn(_isSyncing ? Icons.hourglass_top : Icons.sync, 'Sync Excel', Colors.purpleAccent, _isSyncing ? () {} : _syncExcelData),
        ],
      ),
    );
  }

  Widget _topBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.6))),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: color, size: 20), Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold))]),
        ),
      ),
    );
  }

  Widget _buildQueuePanel() {
    return Container(
      color: const Color(0xFF0E1424),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF1A2236),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('ရွေးထားသောသီချင်းများ (${_queue.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.amber)),
              if (_queue.isNotEmpty) InkWell(onTap: () => setState(() => _queue.clear()), child: const Text('အကုန်ဖျက်', style: TextStyle(color: Colors.redAccent, fontSize: 12))),
            ]),
          ),
          Expanded(
            child: _queue.isEmpty
                ? const Center(child: Text('ရွေးချယ်ထားသော သီချင်းမရှိသေးပါ', style: TextStyle(color: Colors.white38)))
                : ListView.separated(
                    itemCount: _queue.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, index) {
                      final s = _queue[index];
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(radius: 13, backgroundColor: Colors.amber.withOpacity(0.2), child: Text('${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.amber))),
                        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: Text('${s.code} • ${s.artist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.cyanAccent), onPressed: index == 0 ? null : () => setState(() { final it = _queue.removeAt(index); _queue.insert(index - 1, it); })),
                          IconButton(icon: const Icon(Icons.arrow_downward, size: 18, color: Colors.cyanAccent), onPressed: index == _queue.length - 1 ? null : () => setState(() { final it = _queue.removeAt(index); _queue.insert(index + 1, it); })),
                          IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent), onPressed: () => setState(() => _queue.removeAt(index))),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
  Widget _buildRightPanel() {
    if (_activeView == 'HOME') {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 3, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.35,
          children: [
            _card('အဆိုတော်', 'ARTIST', Icons.mic_external_on, [const Color(0xFF6A11CB), const Color(0xFF2575FC)]),
            _card('တေးစီးရီး', 'ALBUM', Icons.album, [const Color(0xFF11998E), const Color(0xFF38EF7D)]),
            _card('သီချင်းနာမည်', 'TITLE', Icons.music_note, [const Color(0xFFFF512F), const Color(0xFFDD2476)]),
            _card('သီချင်းနံပါတ်', 'CODE', Icons.dialpad, [const Color(0xFFF7971E), const Color(0xFFFFD200)]),
            _card('DISCO သီချင်းများ', 'DISCO', Icons.nightlife, [const Color(0xFF8E2DE2), const Color(0xFF4A00E0)]),
            _card('ဖွင့်ခဲ့ပြီးသောသီချင်း', 'HISTORY', Icons.history, [const Color(0xFF2C3E50), const Color(0xFF4CA1AF)]),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xFF161B22),
          child: Row(children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
              onPressed: () => setState(() { if (_selectedSubGroup != null) _selectedSubGroup = null; else _activeView = 'HOME'; }),
              icon: const Icon(Icons.arrow_back),
              label: Text(_selectedSubGroup != null ? 'နောက်သို့' : 'ပင်မစာမျက်နှာ'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                keyboardType: _activeView == 'CODE' ? TextInputType.number : TextInputType.text,
                decoration: InputDecoration(hintText: 'ရှာရန် ရိုက်ထည့်ပါ...', filled: true, fillColor: Colors.white10, prefixIcon: const Icon(Icons.search), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)),
              ),
            ),
          ]),
        ),
        Expanded(
          child: (_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null
              ? GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 2.8, crossAxisSpacing: 10, mainAxisSpacing: 10),
                  itemCount: _groupResults.length,
                  itemBuilder: (context, index) {
                    final name = _groupResults[index];
                    return InkWell(
                      onTap: () async {
                        final songs = await DatabaseHelper.searchSongs(query: name, category: _activeView);
                        setState(() { _selectedSubGroup = name; _searchResults = songs; _hasMore = songs.length == 200; });
                      },
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: const Color(0xFF1F2733), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.withOpacity(0.3))), alignment: Alignment.centerLeft, child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                    );
                  },
                )
              : ListView.separated(
                  controller: _scrollController,
                  itemCount: _searchResults.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                  itemBuilder: (context, index) {
                    final s = _searchResults[index];
                    return ListTile(
                      leading: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.amber.withOpacity(0.15), borderRadius: BorderRadius.circular(6)), child: Text(s.code, style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))),
                      title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${s.artist} • ${s.album}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black), onPressed: () => _addToQueue(s), child: const Text('တန်းစီမည်')),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: () => _addToQueue(s, playNow: true), child: const Text('ချက်ချင်းဖွင့်')),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _card(String title, String cat, IconData icon, List<Color> colors) {
    return InkWell(
      onTap: () => _openCategory(cat),
      child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.amber.withOpacity(0.5))),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 46, color: Colors.white), const SizedBox(height: 10), Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))]),
      ),
    );
  }
}



