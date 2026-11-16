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
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  runApp(const NMHKaraokeApp());
}

class NMHKaraokeApp extends StatelessWidget {
  const NMHKaraokeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NMH Karaoke',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF0A0D14), primaryColor: const Color(0xFFFFB300)),
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
      for (final s in songs) { batch.insert('songs', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace); }
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
          ? await db.query('songs', where: 'isDisco = 0', orderBy: 'code ASC', limit: limit, offset: offset)
          : await db.query('songs', where: 'isDisco = 0 AND code LIKE ?', whereArgs: ['${query.trim()}%'], orderBy: 'code ASC', limit: limit, offset: offset);
    } else if (category == 'ARTIST') {
      maps = await db.query('songs', where: 'isDisco = 0 AND (artist LIKE ? OR coArtist LIKE ?)', whereArgs: [q, q], limit: limit, offset: offset);
    } else if (category == 'ALBUM') {
      maps = await db.query('songs', where: 'isDisco = 0 AND album LIKE ?', whereArgs: [q], limit: limit, offset: offset);
    } else {
      maps = query.trim().isEmpty
          ? await db.query('songs', where: 'isDisco = 0', limit: limit, offset: offset)
          : await db.query('songs', where: 'isDisco = 0 AND (title LIKE ? OR code LIKE ?)', whereArgs: [q, q], limit: limit, offset: offset);
    }
    return maps.map((m) => Song.fromMap(m)).toList();
  }

  static Future<List<String>> getDistinctValues(String col, String filter, {int offset = 0, int limit = 200}) async {
    final db = await database;
    final whereClause = filter.trim().isEmpty ? 'isDisco = 0 AND $col != ""' : 'isDisco = 0 AND $col LIKE ?';
    final whereArgs = filter.trim().isEmpty ? null : ['%${filter.trim()}%'];
    final res = await db.query('songs', distinct: true, columns: [col], where: whereClause, whereArgs: whereArgs, orderBy: '$col ASC', limit: limit, offset: offset);
    return res.map((e) => e[col].toString()).where((s) => s.isNotEmpty).toList();
  }
}
List<Map<String, dynamic>> _parseCsvFromPath(String filePath, bool isDisco) {
  final lines = File(filePath).readAsLinesSync();
  final List<Map<String, dynamic>> list = [];
  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(',');
    String cell(int idx) => idx < parts.length ? parts[idx].replaceAll('"', '').trim() : '';
    if (cell(0).isNotEmpty && cell(1).isNotEmpty) {
      list.add({'code': cell(0), 'title': cell(1), 'artist': cell(2), 'coArtist': cell(3), 'album': cell(4), 'isDisco': isDisco ? 1 : 0});
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
  Song? _currentSong;
  bool _isTvConnected = false, _isPlaying = false, _isSyncing = false, _isLoadingMore = false, _hasMore = true;
  String _voiceMode = 'Stereo', _activeView = 'HOME';
  String? _selectedSubGroup;
  int _totalSongs = 0;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Song> _searchResults = [];
  List<String> _groupResults = [];

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayChanged') setState(() => _isTvConnected = call.arguments == true);
      if (call.method == 'onSongCompleted') _playNextSong();
    });
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300 && !_isLoadingMore && _hasMore) _loadMoreData();
    });
    _checkTvDisplay();
    _initStorageAndDb();
  }

  Future<void> _loadMoreData() async {
    setState(() => _isLoadingMore = true);
    final q = _searchController.text;
    if ((_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null) {
      final more = await DatabaseHelper.getDistinctValues(_activeView == 'ARTIST' ? 'artist' : 'album', q, offset: _groupResults.length);
      setState(() { _groupResults.addAll(more); _hasMore = more.length == 200; _isLoadingMore = false; });
    } else {
      final more = await DatabaseHelper.searchSongs(query: _selectedSubGroup ?? q, category: _activeView, offset: _searchResults.length);
      setState(() { _searchResults.addAll(more); _hasMore = more.length == 200; _isLoadingMore = false; });
    }
  }

  Future<void> _checkTvDisplay() async {
    try { final bool c = await platform.invokeMethod('checkDisplay'); setState(() => _isTvConnected = c); } catch (_) {}
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
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      final roots = await _discoverStorageRoots();
      final List<Song> loaded = [];
      for (final r in roots) {
        final q2Csv = p.join(r.path, 'q2.csv');
        if (await File(q2Csv).exists()) {
          final raw = _parseCsvFromPath(q2Csv, false);
          loaded.addAll(raw.map((m) => Song.fromMap(m)));
        }
        final dcCsv = p.join(r.path, 'disco.csv');
        if (await File(dcCsv).exists()) {
          final raw = _parseCsvFromPath(dcCsv, true);
          loaded.addAll(raw.map((m) => Song.fromMap(m)));
        }
      }
      if (loaded.isNotEmpty) {
        await DatabaseHelper.clearAndInsertSongs(loaded);
        final count = await DatabaseHelper.getSongCount();
        setState(() => _totalSongs = count);
        _showSnack('သီချင်းပေါင်း $count ပုဒ် ဖတ်သွင်းပြီးပါပြီ။');
      } else {
        _showSnack('q2.csv / disco.csv မတွေ့ပါ။');
      }
    } catch (e) {
      _showSnack('CSV Error: $e');
    } finally {
      setState(() => _isSyncing = false);
    }
  }
     final Map<String, String> _videoIndex = {};

  Future<void> _indexAllVideos() async {
    if (_videoIndex.isNotEmpty) return;
    final roots = await _discoverStorageRoots();
    final mntDir = Directory('/mnt/media_rw');
    if (await mntDir.exists()) {
      try {
        await for (final e in mntDir.list()) {
          if (e is Directory) roots.add(e);
        }
      } catch (_) {}
    }
    const exts = {'.mp4', '.mkv', '.dat', '.mpg', '.avi'};
    for (final r in roots) {
      if (r.path == '/storage/emulated/0') continue;
      try {
        await for (final entity in r.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase();
            if (exts.contains(ext)) {
              final base = p.basenameWithoutExtension(entity.path).toLowerCase();
              _videoIndex[base] = entity.path;
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<String?> _findVideoPath(String code) async {
    await _indexAllVideos();
    final c = code.trim().toLowerCase();
    return _videoIndex[c] ?? _videoIndex['a$c'] ?? _videoIndex['d$c'] ?? _videoIndex['m$c'];
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
    setState(() { _currentSong = song; _isPlaying = true; });
    await platform.invokeMethod('playVideo', {'path': path});
  }

  Future<void> _playNextSong() async {
    if (_queue.isEmpty) { setState(() { _currentSong = null; _isPlaying = false; }); await platform.invokeMethod('stop'); return; }
    final next = _queue.removeAt(0);
    setState(() {});
    await _startPlayingSong(next);
  }

  Future<void> _cycleVoiceMode() async {
    const modes = ['Stereo', 'Left', 'Right', 'Track 2'];
    const nativeCodes = ['STEREO', 'LEFT', 'RIGHT', 'TRACK2'];
    final nextIdx = (modes.indexOf(_voiceMode) + 1) % modes.length;
    await platform.invokeMethod('setVoiceMode', {'mode': nativeCodes[nextIdx]});
    setState(() => _voiceMode = modes[nextIdx]);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _openCategory(String cat) async {
    _searchController.clear();
    setState(() { _activeView = cat; _selectedSubGroup = null; _searchResults = []; _groupResults = []; _hasMore = true; });
    if (cat == 'ARTIST' || cat == 'ALBUM') {
      final l = await DatabaseHelper.getDistinctValues(cat == 'ARTIST' ? 'artist' : 'album', '');
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else {
      final l = await DatabaseHelper.searchSongs(query: '', category: cat);
      setState(() { _searchResults = l; _hasMore = l.length == 200; });
    }
  }

  void _onSearchChanged(String val) async {
    setState(() => _hasMore = true);
    if ((_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null) {
      final l = await DatabaseHelper.getDistinctValues(_activeView == 'ARTIST' ? 'artist' : 'album', val);
      setState(() { _groupResults = l; _hasMore = l.length == 200; });
    } else {
      final l = await DatabaseHelper.searchSongs(query: val, category: _activeView);
      setState(() { _searchResults = l; _hasMore = l.length == 200; });
    }
  }
    @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      body: SafeArea(
        child: Column(children: [
          _buildTopHeader(),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [SizedBox(width: MediaQuery.of(context).size.width * 0.33, child: _buildLeftQueueBox()), const SizedBox(width: 14), Expanded(child: _buildRightDashboard())]))),
          _buildBottomControlBar(),
        ]),
      ),
    );
  }

  Widget _buildTopHeader() {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Container(width: MediaQuery.of(context).size.width * 0.33, decoration: BoxDecoration(color: const Color(0xFF080C16), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.withOpacity(0.5))), child: ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.asset('assets/logo.jpg', fit: BoxFit.fill, errorBuilder: (_, __, ___) => const Center(child: Text('Capt.နေမျိုးထွန်း', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 18)))))),
        const SizedBox(width: 14),
        Expanded(child: Container(height: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: BoxDecoration(color: const Color(0xFF141821), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white12)), alignment: Alignment.centerLeft, child: Text(_currentSong != null ? 'ဖွင့်နေသည်: [${_currentSong!.code}] ${_currentSong!.title} (${_currentSong!.artist})' : 'အသင့်ဖြစ်ပါပြီ (စုစုပေါင်း: $_totalSongs ပုဒ် • ${_isTvConnected ? "TV Connected" : "Standalone Mode"})', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)))),
        const SizedBox(width: 10),
        InkWell(onTap: _isSyncing ? null : _syncExcelData, child: Container(height: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14), decoration: BoxDecoration(color: const Color(0xFFB71C1C), borderRadius: BorderRadius.circular(10)), child: Row(children: [Icon(_isSyncing ? Icons.hourglass_top : Icons.sync, color: Colors.white, size: 18), const SizedBox(width: 6), Text(_isSyncing ? 'Syncing...' : 'Sync Excel', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))]))),
      ]),
    );
  }

  Widget _buildLeftQueueBox() {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF0E121A), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF00BFA5), width: 1.5)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: const BoxDecoration(color: Color(0xFF00897B), borderRadius: BorderRadius.vertical(top: Radius.circular(10))), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('ရွေးထားသောသီချင်းများ (${_queue.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)), if (_queue.isNotEmpty) InkWell(onTap: () => setState(() => _queue.clear()), child: const Icon(Icons.playlist_remove, color: Colors.white, size: 20))])),
        Expanded(child: _queue.isEmpty ? const Center(child: Text('ရွေးထားသော သီချင်း မရှိသေးပါ', style: TextStyle(color: Colors.white38, fontSize: 14))) : ListView.separated(itemCount: _queue.length, separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10), itemBuilder: (context, index) { final s = _queue[index]; return ListTile(dense: true, leading: Text('${index + 1}.', style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)), title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)), subtitle: Text('${s.code} • ${s.artist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white54)), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.arrow_upward, size: 17, color: Colors.tealAccent), onPressed: index == 0 ? null : () => setState(() { final it = _queue.removeAt(index); _queue.insert(index - 1, it); })), IconButton(icon: const Icon(Icons.arrow_downward, size: 17, color: Colors.tealAccent), onPressed: index == _queue.length - 1 ? null : () => setState(() { final it = _queue.removeAt(index); _queue.insert(index + 1, it); })), IconButton(icon: const Icon(Icons.delete_outline, size: 17, color: Colors.redAccent), onPressed: () => setState(() => _queue.removeAt(index)))])); })),
      ]),
    );
  }
    Widget _buildRightDashboard() {
    if (_activeView == 'HOME') {
      return Column(children: [
        Expanded(flex: 4, child: Row(children: [Expanded(flex: 3, child: _remoteBigCard('မြန်မာသီချင်းများ', 'မြန်မာကာရာအိုကေ', Icons.mic_external_on, const [Color(0xFF00897B), Color(0xFF004D40)], Colors.tealAccent, () => _openCategory('MYANMAR'))), const SizedBox(width: 12), Expanded(flex: 2, child: _remoteBigCard('Disco Song', '', Icons.nightlife, const [Color(0xFF4527A0), Color(0xFF1A237E)], Colors.amber, () => _openCategory('DISCO')))])),
        SizedBox(height: 22, child: CustomPaint(size: const Size(double.infinity, 22), painter: _ConnectorLinePainter())),
        Expanded(flex: 5, child: Row(children: [Expanded(child: _remoteSubCard('အဆိုတော်\nနာမည်နှင့်ရှာမည်', Icons.record_voice_over, const [Color(0xFFD81B60), Color(0xFF880E4F)], () => _openCategory('ARTIST'))), const SizedBox(width: 10), Expanded(child: _remoteSubCard('တေးစီးရီး\nနာမည်နှင့်ရှာမည်', Icons.album, const [Color(0xFFEF6C00), Color(0xFFE65100)], () => _openCategory('ALBUM'))), const SizedBox(width: 10), Expanded(child: _remoteSubCard('သီချင်းနာမည်\nနှင့်ရှာမည်', Icons.music_note, const [Color(0xFF1565C0), Color(0xFF0D47A1)], () => _openCategory('TITLE'))), const SizedBox(width: 10), Expanded(child: _remoteSubCard('သီချင်းနံပါတ်\nနှင့်ရှာမည်', Icons.dialpad, const [Color(0xFF00796B), Color(0xFF004D40)], () => _openCategory('CODE')))])),
      ]);
    }
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF121620), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00897B), foregroundColor: Colors.white), onPressed: () => setState(() { if (_selectedSubGroup != null) _selectedSubGroup = null; else _activeView = 'HOME'; }), icon: const Icon(Icons.arrow_back, size: 18), label: Text(_selectedSubGroup != null ? 'နောက်သို့' : 'HOME')), const SizedBox(width: 10), Expanded(child: TextField(controller: _searchController, onChanged: _onSearchChanged, keyboardType: _activeView == 'CODE' ? TextInputType.number : TextInputType.text, decoration: InputDecoration(hintText: 'ရှာရန် ရိုက်ထည့်ပါ...', filled: true, fillColor: Colors.white10, prefixIcon: const Icon(Icons.search), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none))))])),
        Expanded(child: (_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null ? GridView.builder(controller: _scrollController, padding: const EdgeInsets.all(10), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 2.8, crossAxisSpacing: 8, mainAxisSpacing: 8), itemCount: _groupResults.length, itemBuilder: (context, index) { final name = _groupResults[index]; return InkWell(onTap: () async { final songs = await DatabaseHelper.searchSongs(query: name, category: _activeView); setState(() { _selectedSubGroup = name; _searchResults = songs; _hasMore = songs.length == 200; }); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10), decoration: BoxDecoration(color: const Color(0xFF1C2230), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.tealAccent.withOpacity(0.3))), alignment: Alignment.centerLeft, child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)))); }) : ListView.separated(controller: _scrollController, itemCount: _searchResults.length, separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10), itemBuilder: (context, index) { final s = _searchResults[index]; return ListTile(dense: true, leading: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.amber.withOpacity(0.15), borderRadius: BorderRadius.circular(6)), child: Text(s.code, style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))), title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), subtitle: Text('${s.artist} • ${s.album}', style: const TextStyle(color: Colors.white54, fontSize: 11)), trailing: Row(mainAxisSize: MainAxisSize.min, children: [ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00897B), foregroundColor: Colors.white), onPressed: () => _addToQueue(s), child: const Text('တန်းစီမည်', style: TextStyle(fontSize: 12))), const SizedBox(width: 6), OutlinedButton(onPressed: () => _addToQueue(s, playNow: true), child: const Text('ဖွင့်မည်', style: TextStyle(fontSize: 12)))])); })),
      ]),
    );
  }

  Widget _remoteBigCard(String title, String subtitle, IconData icon, List<Color> colors, Color borderColor, VoidCallback onTap) {
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor, width: 1.5)), child: Stack(children: [Positioned(right: 12, bottom: -10, child: Icon(icon, size: 88, color: Colors.white.withOpacity(0.12))), Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [if (subtitle.isEmpty) Icon(icon, color: Colors.amber, size: 28), Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)), if (subtitle.isNotEmpty) Text(subtitle, style: const TextStyle(fontSize: 15, color: Colors.white70))]))])));
  }

  Widget _remoteSubCard(String title, IconData icon, List<Color> colors, VoidCallback onTap) {
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white24)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircleAvatar(radius: 18, backgroundColor: Colors.white, child: Icon(icon, color: colors.first, size: 20)), const SizedBox(height: 10), Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white))])));
  }

  Widget _buildBottomControlBar() {
    return Container(
      height: 58,
      color: const Color(0xFF141821),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _bottomBtn(Icons.play_arrow, 'Play/Pause', Colors.pinkAccent, () async { final p = await platform.invokeMethod('pauseResume'); setState(() => _isPlaying = p == true); }),
        _bottomBtn(Icons.stop, 'Stop', Colors.redAccent, () async { await platform.invokeMethod('stop'); setState(() { _isPlaying = false; _currentSong = null; }); }),
        _bottomBtn(Icons.repeat, 'Repeat', Colors.purpleAccent, () => platform.invokeMethod('replay')),
        _bottomBtn(Icons.fast_rewind, '<<<<', Colors.lightBlueAccent, () {}),
        _bottomBtn(Icons.fast_forward, '>>>>', Colors.lightBlueAccent, () {}),
        _bottomBtn(Icons.replay, 'Re-Start', Colors.brown, () => platform.invokeMethod('replay')),
        _bottomBtn(Icons.skip_next, 'Next', Colors.pink, _playNextSong),
        _bottomBtn(Icons.home, 'HOME', Colors.greenAccent, () => setState(() { _activeView = 'HOME'; _selectedSubGroup = null; })),
        _bottomBtn(Icons.record_voice_over, _voiceMode, Colors.redAccent, _cycleVoiceMode),
        _bottomBtn(Icons.volume_down, 'Vol-', Colors.cyan, () {}),
        _bottomBtn(Icons.volume_up, 'Vol+', Colors.cyan, () {}),
        _bottomBtn(Icons.volume_off, 'Mute', Colors.grey, () {}),
      ]),
    );
  }

  Widget _bottomBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(onTap: onTap, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Container(padding: const EdgeInsets.all(5), decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(6)), child: Icon(icon, color: color, size: 18)), const SizedBox(height: 2), Text(label, style: const TextStyle(fontSize: 10, color: Colors.white70))]));
  }
}

class _ConnectorLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white54..strokeWidth = 1.5..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(size.width * 0.28, 0), Offset(size.width * 0.28, size.height * 0.5), paint);
    final cols = [0.125, 0.375, 0.625, 0.875];
    canvas.drawLine(Offset(size.width * cols.first, size.height * 0.5), Offset(size.width * cols.last, size.height * 0.5), paint);
    for (final c in cols) { canvas.drawLine(Offset(size.width * c, size.height * 0.5), Offset(size.width * c, size.height), paint); }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
