class KaraokeHomeScreen extends StatefulWidget {
  const KaraokeHomeScreen({super.key});

  @override
  State<KaraokeHomeScreen> createState() => _KaraokeHomeScreenState();
}

class _KaraokeHomeScreenState extends State<KaraokeHomeScreen> {
  static const platform = MethodChannel('com.nmh.karaoke/player');

  final List<Song> _queue = [];
  Song? _currentSong;
  bool _isTvConnected = false;
  bool _isPlaying = false;
  bool _isSyncing = false;
  String _voiceMode = 'STEREO';
  int _totalSongs = 0;

  String _activeView = 'HOME';
  String? _selectedSubGroup;
  final TextEditingController _searchController = TextEditingController();
  List<Song> _searchResults = [];
  List<String> _groupResults = [];

  final List<String> _baseFolders = [
    '/storage/emulated/0',
    '/storage/emulated/0/NMH_Karaoke',
    '/storage/sdcard1',
    '/storage/sdcard1/NMH_Karaoke',
  ];

  @override
  void initState() {
    super.initState();
    _setupMethodChannel();
    _initStorageAndDb();
  }

  void _setupMethodChannel() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayChanged') {
        setState(() => _isTvConnected = call.arguments == true);
      } else if (call.method == 'onSongCompleted') {
        _playNextSong();
      }
    });
    _checkTvDisplay();
  }

  Future<void> _checkTvDisplay() async {
    try {
      final bool connected = await platform.invokeMethod('checkDisplay');
      setState(() => _isTvConnected = connected);
    } catch (_) {}
  }

  Future<void> _initStorageAndDb() async {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
    final count = await DatabaseHelper.getSongCount();
    setState(() => _totalSongs = count);
    if (count == 0) {
      await _syncExcelData();
    }
  }

  Future<List<Directory>> _discoverStorageRoots() async {
    final List<Directory> roots = [];
    for (final path in _baseFolders) {
      final dir = Directory(path);
      if (await dir.exists()) roots.add(dir);
    }
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list()) {
          if (entity is Directory && !entity.path.contains('emulated') && !entity.path.contains('self')) {
            roots.add(entity);
            final sub = Directory('${entity.path}/NMH_Karaoke');
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
      final List<Song> loadedSongs = [];

      for (final root in roots) {
        final q2File = File(p.join(root.path, 'q2.xlsx'));
        if (await q2File.exists()) {
          loadedSongs.addAll(await _parseExcelFile(q2File, isDisco: false));
        }
        final discoFile = File(p.join(root.path, 'disco.xlsx'));
        if (await discoFile.exists()) {
          loadedSongs.addAll(await _parseExcelFile(discoFile, isDisco: true));
        }
      }

      if (loadedSongs.isNotEmpty) {
        await DatabaseHelper.clearAndInsertSongs(loadedSongs);
        final count = await DatabaseHelper.getSongCount();
        setState(() => _totalSongs = count);
        _showSnack('သီချင်းပေါင်း $count ပုဒ် ဖတ်သွင်းပြီးပါပြီ။');
      } else {
        _showSnack('q2.xlsx သို့မဟုတ် disco.xlsx ဖိုင် မတွေ့ပါ (Internal Storage / SD Card ထဲတွင် ထည့်ပါ)။');
      }
    } catch (e) {
      _showSnack('Excel ဖတ်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်: $e');
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  Future<List<Song>> _parseExcelFile(File file, {required bool isDisco}) async {
    final bytes = await file.readAsBytes();
    final excel = xls.Excel.decodeBytes(bytes);
    final List<Song> songs = [];

    for (final table in excel.tables.keys) {
      final sheet = excel.tables[table];
      if (sheet == null) continue;

      for (int i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.isEmpty) continue;

        String cellStr(int idx) {
          if (idx >= row.length || row[idx] == null || row[idx]?.value == null) return '';
          return row[idx]!.value.toString().trim();
        }

        final code = cellStr(0);
        final title = cellStr(1);
        final artist = cellStr(2);
        final coArtist = cellStr(3);
        final album = cellStr(4);

        if (code.isNotEmpty && title.isNotEmpty) {
          songs.add(Song(
            code: code,
            title: title,
            artist: artist,
            coArtist: coArtist,
            album: album,
            isDisco: isDisco,
          ));
        }
      }
    }
    return songs;
  }

  Future<String?> _findVideoPath(String code) async {
    final roots = await _discoverStorageRoots();
    const subFolders = ['Myanmar_songs', 'Myanmar_New_Songs', 'DiscoVideo', ''];
    const extensions = ['.mp4', '.mkv', '.dat', '.mpg', '.avi', '.MP4', '.MKV', '.DAT', '.MPG'];

    for (final root in roots) {
      for (final folder in subFolders) {
        final dirPath = folder.isEmpty ? root.path : p.join(root.path, folder);
        for (final ext in extensions) {
          final file = File(p.join(dirPath, '$code$ext'));
          if (await file.exists()) {
            return file.path;
          }
        }
      }
    }
    return null;
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
  bool _isTvConnected = false;
  bool _isPlaying = false;
  bool _isSyncing = false;
  String _voiceMode = 'STEREO';
  int _totalSongs = 0;

  String _activeView = 'HOME';
  String? _selectedSubGroup;
  final TextEditingController _searchController = TextEditingController();
  List<Song> _searchResults = [];
  List<String> _groupResults = [];

  final List<String> _baseFolders = [
    '/storage/emulated/0',
    '/storage/emulated/0/NMH_Karaoke',
    '/storage/sdcard1',
    '/storage/sdcard1/NMH_Karaoke',
  ];

  @override
  void initState() {
    super.initState();
    _setupMethodChannel();
    _initStorageAndDb();
  }

  void _setupMethodChannel() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayChanged') {
        setState(() => _isTvConnected = call.arguments == true);
      } else if (call.method == 'onSongCompleted') {
        _playNextSong();
      }
    });
    _checkTvDisplay();
  }

  Future<void> _checkTvDisplay() async {
    try {
      final bool connected = await platform.invokeMethod('checkDisplay');
      setState(() => _isTvConnected = connected);
    } catch (_) {}
  }

  Future<void> _initStorageAndDb() async {
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
    final count = await DatabaseHelper.getSongCount();
    setState(() => _totalSongs = count);
    if (count == 0) {
      await _syncExcelData();
    }
  }

  Future<List<Directory>> _discoverStorageRoots() async {
    final List<Directory> roots = [];
    for (final path in _baseFolders) {
      final dir = Directory(path);
      if (await dir.exists()) roots.add(dir);
    }
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list()) {
          if (entity is Directory && !entity.path.contains('emulated') && !entity.path.contains('self')) {
            roots.add(entity);
            final sub = Directory('${entity.path}/NMH_Karaoke');
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
      final List<Song> loadedSongs = [];

      for (final root in roots) {
        final q2File = File(p.join(root.path, 'q2.xlsx'));
        if (await q2File.exists()) {
          loadedSongs.addAll(await _parseExcelFile(q2File, isDisco: false));
        }
        final discoFile = File(p.join(root.path, 'disco.xlsx'));
        if (await discoFile.exists()) {
          loadedSongs.addAll(await _parseExcelFile(discoFile, isDisco: true));
        }
      }

      if (loadedSongs.isNotEmpty) {
        await DatabaseHelper.clearAndInsertSongs(loadedSongs);
        final count = await DatabaseHelper.getSongCount();
        setState(() => _totalSongs = count);
        _showSnack('သီချင်းပေါင်း $count ပုဒ် ဖတ်သွင်းပြီးပါပြီ။');
      } else {
        _showSnack('q2.xlsx သို့မဟုတ် disco.xlsx ဖိုင် မတွေ့ပါ (Internal Storage / SD Card ထဲတွင် ထည့်ပါ)။');
      }
    } catch (e) {
      _showSnack('Excel ဖတ်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်: $e');
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  Future<List<Song>> _parseExcelFile(File file, {required bool isDisco}) async {
    final bytes = await file.readAsBytes();
    final excel = xls.Excel.decodeBytes(bytes);
    final List<Song> songs = [];

    for (final table in excel.tables.keys) {
      final sheet = excel.tables[table];
      if (sheet == null) continue;

      for (int i = 1; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.isEmpty) continue;

        String cellStr(int idx) {
          if (idx >= row.length || row[idx] == null || row[idx]?.value == null) return '';
          return row[idx]!.value.toString().trim();
        }

        final code = cellStr(0);
        final title = cellStr(1);
        final artist = cellStr(2);
        final coArtist = cellStr(3);
        final album = cellStr(4);

        if (code.isNotEmpty && title.isNotEmpty) {
          songs.add(Song(
            code: code,
            title: title,
            artist: artist,
            coArtist: coArtist,
            album: album,
            isDisco: isDisco,
          ));
        }
      }
    }
    return songs;
  }

  Future<String?> _findVideoPath(String code) async {
    final roots = await _discoverStorageRoots();
    const subFolders = ['Myanmar_songs', 'Myanmar_New_Songs', 'DiscoVideo', ''];
    const extensions = ['.mp4', '.mkv', '.dat', '.mpg', '.avi', '.MP4', '.MKV', '.DAT', '.MPG'];

    for (final root in roots) {
      for (final folder in subFolders) {
        final dirPath = folder.isEmpty ? root.path : p.join(root.path, folder);
        for (final ext in extensions) {
          final file = File(p.join(dirPath, '$code$ext'));
          if (await file.exists()) {
            return file.path;
          }
        }
      }
    }
    return null;
  }

    Future<void> _addToQueue(Song song, {bool playNow = false}) async {
    if (playNow) {
      await _startPlayingSong(song);
      return;
    }
    setState(() {
      _queue.add(song);
    });
    _showSnack('ရွေးချယ်ပြီး: ${song.title} (${song.code})');
    if (_currentSong == null) {
      _playNextSong();
    }
  }

  Future<void> _startPlayingSong(Song song) async {
    final videoPath = await _findVideoPath(song.code);
    if (videoPath == null) {
      _showSnack('ဗီဒီယိုဖိုင် (${song.code}) ကို Myanmar_songs / Myanmar_New_Songs / DiscoVideo ဖိုဒါထဲတွင် မတွေ့ပါ။');
      return;
    }

    setState(() {
      _currentSong = song;
      _isPlaying = true;
    });

    try {
      await platform.invokeMethod('playVideo', {'path': videoPath});
    } catch (e) {
      _showSnack('ဗီဒီယိုဖွင့်ရာတွင် အမှားဖြစ်ပါသည်: $e');
    }
  }

  Future<void> _playNextSong() async {
    if (_queue.isEmpty) {
      setState(() {
        _currentSong = null;
        _isPlaying = false;
      });
      await platform.invokeMethod('stop');
      return;
    }
    final next = _queue.removeAt(0);
    setState(() {});
    await _startPlayingSong(next);
  }

  Future<void> _cycleVoiceMode() async {
    const modes = ['STEREO', 'LEFT', 'RIGHT', 'TRACK2'];
    final nextIndex = (modes.indexOf(_voiceMode) + 1) % modes.length;
    final nextMode = modes[nextIndex];
    try {
      await platform.invokeMethod('setVoiceMode', {'mode': nextMode});
      setState(() => _voiceMode = nextMode);
    } catch (_) {}
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _openCategory(String category) async {
    _searchController.clear();
    setState(() {
      _activeView = category;
      _selectedSubGroup = null;
      _searchResults = [];
      _groupResults = [];
    });

    if (category == 'ARTIST') {
      final list = await DatabaseHelper.getDistinctValues('artist', '');
      setState(() => _groupResults = list);
    } else if (category == 'ALBUM') {
      final list = await DatabaseHelper.getDistinctValues('album', '');
      setState(() => _groupResults = list);
    } else {
      final list = await DatabaseHelper.searchSongs(query: '', category: category);
      setState(() => _searchResults = list);
    }
  }

  void _onSearchChanged(String val) async {
    if (_activeView == 'ARTIST' && _selectedSubGroup == null) {
      final list = await DatabaseHelper.getDistinctValues('artist', val);
      setState(() => _groupResults = list);
    } else if (_activeView == 'ALBUM' && _selectedSubGroup == null) {
      final list = await DatabaseHelper.getDistinctValues('album', val);
      setState(() => _groupResults = list);
    } else {
      final list = await DatabaseHelper.searchSongs(query: val, category: _activeView);
      setState(() => _searchResults = list);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: MediaQuery.of(context).size.width * 0.34, child: _buildQueuePanel()),
                  const VerticalDivider(width: 1, color: Colors.white24),
                  Expanded(child: _buildRightPanel()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFF6F00), Color(0xFFFFB300)]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('NMH KARAOKE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.black)),
                Text('Capt.နေမျိုးထွန်း', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.black87)),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tv, size: 16, color: _isTvConnected ? Colors.greenAccent : Colors.redAccent),
                    const SizedBox(width: 6),
                    Text(
                      _isTvConnected ? 'TV Dual Screen: ချိတ်ဆက်ထားသည်' : 'TV Dual Screen: မချိတ်ဆက်ရသေးပါ',
                      style: TextStyle(fontSize: 12, color: _isTvConnected ? Colors.greenAccent : Colors.orangeAccent),
                    ),
                    const SizedBox(width: 12),
                    Text('စုစုပေါင်း: $_totalSongs ပုဒ်', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _currentSong != null
                      ? 'ဖွင့်နေသည်: [${_currentSong!.code}] ${_currentSong!.title} - ${_currentSong!.artist}'
                      : 'သီချင်းရွေးချယ်ရန် အသင့်ဖြစ်ပါပြီ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                ),
              ],
            ),
          ),
          _topControlBtn(
            icon: Icons.record_voice_over,
            label: 'Voice: $_voiceMode',
            color: Colors.cyanAccent,
            onTap: _cycleVoiceMode,
          ),
          _topControlBtn(
            icon: _isPlaying ? Icons.pause : Icons.play_arrow,
            label: _isPlaying ? 'Pause' : 'Play',
            color: Colors.greenAccent,
            onTap: () async {
              final playing = await platform.invokeMethod('pauseResume');
              setState(() => _isPlaying = playing == true);
            },
          ),
          _topControlBtn(
            icon: Icons.replay,
            label: 'Replay',
            color: Colors.amber,
            onTap: () => platform.invokeMethod('replay'),
          ),
          _topControlBtn(
            icon: Icons.skip_next,
            label: 'Next',
            color: Colors.orangeAccent,
            onTap: _playNextSong,
          ),
          _topControlBtn(
            icon: _isSyncing ? Icons.hourglass_top : Icons.sync,
            label: 'Sync Excel',
            color: Colors.purpleAccent,
            onTap: _isSyncing ? () {} : _syncExcelData,
          ),
        ],
      ),
    );
  }

  Widget _topControlBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

    Widget _buildQueuePanel() {
    return Container(
      color: const Color(0xFF11161D),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF1C232E),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('ရွေးထားသောသီချင်းများ (${_queue.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.amber)),
                if (_queue.isNotEmpty)
                  InkWell(
                    onTap: () => setState(() => _queue.clear()),
                    child: const Text('အကုန်ဖျက်', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _queue.isEmpty
                ? const Center(child: Text('ရွေးချယ်ထားသော သီချင်းမရှိသေးပါ', style: TextStyle(color: Colors.white38)))
                : ListView.separated(
                    itemCount: _queue.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, index) {
                      final song = _queue[index];
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        leading: CircleAvatar(
                          radius: 13,
                          backgroundColor: Colors.amber.withOpacity(0.2),
                          child: Text('${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.amber)),
                        ),
                        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: Text('${song.code} • ${song.artist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.cyanAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 30),
                              onPressed: index == 0
                                  ? null
                                  : () {
                                      setState(() {
                                        final item = _queue.removeAt(index);
                                        _queue.insert(index - 1, item);
                                      });
                                    },
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward, size: 18, color: Colors.cyanAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 30),
                              onPressed: index == _queue.length - 1
                                  ? null
                                  : () {
                                      setState(() {
                                        final item = _queue.removeAt(index);
                                        _queue.insert(index + 1, item);
                                      });
                                    },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 30),
                              onPressed: () => setState(() => _queue.removeAt(index)),
                            ),
                          ],
                        ),
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
          crossAxisCount: 3,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 1.35,
          children: [
            _themedCard('အဆိုတော်', 'ARTIST', Icons.mic_external_on, [const Color(0xFF6A11CB), const Color(0xFF2575FC)]),
            _themedCard('တေးစီးရီး', 'ALBUM', Icons.album, [const Color(0xFF11998E), const Color(0xFF38EF7D)]),
            _themedCard('သီချင်းနာမည်', 'TITLE', Icons.music_note, [const Color(0xFFFF512F), const Color(0xFFDD2476)]),
            _themedCard('သီချင်းနံပါတ်', 'CODE', Icons.dialpad, [const Color(0xFFF7971E), const Color(0xFFFFD200)]),
            _themedCard('DISCO သီချင်းများ', 'DISCO', Icons.nightlife, [const Color(0xFF8E2DE2), const Color(0xFF4A00E0)]),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xFF161B22),
          child: Row(
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                onPressed: () {
                  if (_selectedSubGroup != null) {
                    setState(() => _selectedSubGroup = null);
                  } else {
                    setState(() => _activeView = 'HOME');
                  }
                },
                icon: const Icon(Icons.arrow_back),
                label: Text(_selectedSubGroup != null ? 'နောက်သို့' : 'ပင်မစာမျက်နှာ'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  keyboardType: _activeView == 'CODE' ? TextInputType.number : TextInputType.text,
                  decoration: InputDecoration(
                    hintText: _selectedSubGroup != null
                        ? '$_selectedSubGroup ၏ သီချင်းများ'
                        : '${_getCategoryTitle(_activeView)} ရှာရန် ရိုက်ထည့်ပါ...',
                    filled: true,
                    fillColor: Colors.white10,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: (_activeView == 'ARTIST' || _activeView == 'ALBUM') && _selectedSubGroup == null
              ? _buildGroupGrid()
              : _buildSongList(),
        ),
      ],
    );
  }

  String _getCategoryTitle(String cat) {
    switch (cat) {
      case 'ARTIST':
        return 'အဆိုတော်';
      case 'ALBUM':
        return 'တေးစီးရီး';
      case 'CODE':
        return 'သီချင်းနံပါတ်';
      case 'DISCO':
        return 'Disco';
      default:
        return 'သီချင်းနာမည်';
    }
  }

  Widget _themedCard(String title, String category, IconData icon, List<Color> colors) {
    return InkWell(
      onTap: () => _openCategory(category),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: colors.first.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 46, color: Colors.white),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupGrid() {
    if (_groupResults.isEmpty) {
      return const Center(child: Text('စာရင်းမတွေ့ပါ', style: TextStyle(color: Colors.white54)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2.8,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _groupResults.length,
      itemBuilder: (context, index) {
        final name = _groupResults[index];
        return InkWell(
          onTap: () async {
            final songs = await DatabaseHelper.searchSongs(query: name, category: _activeView);
            setState(() {
              _selectedSubGroup = name;
              _searchResults = songs;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2733),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            alignment: Alignment.centerLeft,
                        child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ),
        );
      },
    );
  }

  Widget _buildSongList() {
    if (_searchResults.isEmpty) {
      return const Center(child: Text('သီချင်းမတွေ့ပါ', style: TextStyle(color: Colors.white54)));
    }
    return ListView.separated(
      itemCount: _searchResults.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
      itemBuilder: (context, index) {
        final song = _searchResults[index];
        return ListTile(
          leading: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(song.code, style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          title: Text(song.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          subtitle: Text(
            '${song.artist}${song.coArtist.isNotEmpty ? " & ${song.coArtist}" : ""} • ${song.album}',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                onPressed: () => _addToQueue(song),
                child: const Text('တန်းစီမည်', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.cyanAccent),
                onPressed: () => _addToQueue(song, playNow: true),
                child: const Text('ချက်ချင်းဖွင့်'),
              ),
            ],
          ),
        );
      },
    );
  }
}
  
