import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

// --- Data Models ---
class Sport {
  final String id;
  final String name;
  final String logoUrl;

  Sport({required this.id, required this.name, required this.logoUrl});

  factory Sport.fromJson(Map<String, dynamic> json) {
    return Sport(
      id: json['idSport'] as String,
      name: json['strSport'] as String,
      logoUrl: json['strSportIconGreen'] as String? ?? '',
    );
  }
}

class Match {
  final String id;
  final String title;
  final String streamUrl;
  final DateTime startTime;
  final Sport sport;
  final String teamALogo;
  final String teamBLogo;
  final String leagueName;
  final String leagueId;

  Match({
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.startTime,
    required this.sport,
    required this.teamALogo,
    required this.teamBLogo,
    required this.leagueName,
    required this.leagueId,
  });

  factory Match.fromJson(Map<String, dynamic> json) {
    return Match(
      id: json['id'] as String,
      title: json['title'] as String,
      streamUrl: json['streamUrl'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      sport: Sport.fromJson(json['sport'] as Map<String, dynamic>),
      teamALogo: json['teamA_logo'] as String,
      teamBLogo: json['teamB_logo'] as String,
      leagueName: json['leagueName'] as String,
      leagueId: json['leagueId'] as String,
    );
  }
}

class Team {
  final String id;
  final String name;
  final String logoUrl;

  Team({required this.id, required this.name, required this.logoUrl});

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      id: json['idTeam'] as String,
      name: json['strTeam'] as String,
      logoUrl: json['strTeamBadge'] as String? ?? '',
    );
  }
}

// --- API Service ---
class LiveSportsApi {
  // The free public API key for thesportsdb.com is '3'.
  // For production apps, it's recommended to get a key via their Patreon.
  static const String _apiKey = '3';
  static const String _baseUrl =
      'https://www.thesportsdb.com/api/v1/json/$_apiKey';

  // Cache for team details to avoid redundant API calls
  final Map<String, Team> _teamCache = {};

  // This simulates the "player api" that knows which events are streamable.
  // In a real app, this would be another API call or a more complex logic.
  final _streamableEvents = <String>{
    'Arsenal vs Man City',
    'Real Madrid vs Barcelona',
    'Lakers vs Celtics',
    'Pakistan vs India',
    'Australia vs England',
  };

  Future<List<Sport>> fetchSports() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/all_sports.php'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> sportsData = data['sports'] ?? [];

        return sportsData
            .map((json) => Sport.fromJson(json))
            .toList();
      } else {
        throw Exception('Failed to load sports');
      }
    } catch (e) {
      debugPrint('Error fetching sports: $e');
      return [];
    }
  }

  Future<Team?> _fetchTeamDetails(String teamId) async {
    if (_teamCache.containsKey(teamId)) {
      return _teamCache[teamId]!;
    }
    try {
      final response =
          await http.get(Uri.parse('$_baseUrl/lookupteam.php?id=$teamId'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic>? teamsData = data['teams'];
        if (teamsData != null && teamsData.isNotEmpty) {
          final team = Team.fromJson(teamsData.first);
          _teamCache[teamId] = team;
          return team;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error fetching team $teamId: $e');
      return null;
    }
  }

  Future<List<Match>> _fetchAndParseEvents(String url) async {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('Failed to load events from $url');
      }
      final data = json.decode(response.body);
      final List<dynamic> eventsData = data['events'] ?? [];

      final List<Match> matches = [];

      for (var eventJson in eventsData) {
        final String eventName = eventJson['strEvent'] ?? '';
        if (!_streamableEvents.contains(eventName)) {
          continue;
        }

        final homeTeamId = eventJson['idHomeTeam'];
        final awayTeamId = eventJson['idAwayTeam'];

        if (homeTeamId == null || awayTeamId == null) continue;

        final homeTeam = await _fetchTeamDetails(homeTeamId);
        final awayTeam = await _fetchTeamDetails(awayTeamId);

        if (homeTeam == null || awayTeam == null) continue;

        DateTime startTime;
        try {
          final dateStr = eventJson['dateEvent'];
          final timeStr = eventJson['strTime'];
          startTime = DateTime.parse('$dateStr $timeStr');
        } catch (e) {
          startTime = DateTime.now().add(const Duration(hours: 1));
        }

        matches.add(
          Match(
            id: eventJson['idEvent'],
            title: eventName,
            streamUrl: '', // This would come from the stream provider API
            startTime: startTime,
            sport: Sport(
              id: eventJson['idSport'] ?? '',
              name: eventJson['strSport'] ?? '',
              logoUrl:
                  '', // Sport logo isn't in this endpoint, but we have it from fetchSports()
            ),
            teamALogo: homeTeam.logoUrl,
            teamBLogo: awayTeam.logoUrl,
            leagueName: eventJson['strLeague'] ?? 'Unknown League',
            leagueId: eventJson['idLeague'] ?? '',
          ),
        );
      }
      return matches;
  }

  Future<List<Match>> fetchMatches({String? sportName}) async {
    try {
      final date = DateTime.now();
      final formattedDate =
          "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

      String url = '$_baseUrl/eventsday.php?d=$formattedDate';
      if (sportName != null) {
        url += '&s=${Uri.encodeComponent(sportName)}';
      }

      final matches = await _fetchAndParseEvents(url);
      matches.sort((a, b) => a.startTime.compareTo(b.startTime));
      return matches;
    } catch (e) {
      debugPrint('Error fetching matches: $e');
      return [];
    }
  }

  Future<List<Match>> fetchUpcomingSchedule({int days = 7}) async {
    try {
      List<Match> allUpcomingMatches = [];
      final now = DateTime.now();

      final futures = <Future<List<Match>>>[];
      for (int i = 0; i < days; i++) {
        final date = now.add(Duration(days: i));
        final formattedDate =
            "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
        final url = '$_baseUrl/eventsday.php?d=$formattedDate';
        futures.add(_fetchAndParseEvents(url));
      }

      final results = await Future.wait(futures);

      for (final dayMatches in results) {
        allUpcomingMatches.addAll(dayMatches);
      }

      allUpcomingMatches.sort((a, b) => a.startTime.compareTo(b.startTime));
      return allUpcomingMatches;
    } catch (e) {
      debugPrint('Error fetching upcoming schedule: $e');
      return [];
    }
  }
}

// --- Main Page Widget ---
class LiveTVPage extends StatefulWidget {
  const LiveTVPage({super.key});

  @override
  State<LiveTVPage> createState() => _LiveTVPageState();
}

class _LiveTVPageState extends State<LiveTVPage> {
  final _api = LiveSportsApi();
  bool _isLoading = true;
  List<Sport> _sports = [];
  List<Match> _allMatches = [];
  String _selectedSportId = 'all';

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    try {
      // Use Future.wait to run in parallel
      final results = await Future.wait([
        _api.fetchSports(),
        _api.fetchMatches(), // Fetches all sports for today
      ]);

      if (mounted) {
        final sports = results[0] as List<Sport>;
        final matches = results[1] as List<Match>;

        setState(() {
          _sports = sports;
          _allMatches = matches;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load live sports: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildSportFilterChip(String id, String name, {String? logoUrl}) {
    final isSelected = _selectedSportId == id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: ChoiceChip(
        avatar: (logoUrl != null && logoUrl.isNotEmpty)
            ? CircleAvatar(
                backgroundColor: Colors.transparent,
                child: CachedNetworkImage(
                  imageUrl: logoUrl,
                  color: isSelected ? Colors.black : Colors.white,
                  errorWidget: (context, url, error) =>
                      const Icon(Icons.sports, size: 18),
                ),
              )
            : null,
        label: Text(name),
        selected: isSelected,
        onSelected: (selected) {
          if (selected) setState(() => _selectedSportId = id);
        },
        selectedColor: const Color(0xFF1CE783),
        labelStyle: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
              color: isSelected ? Colors.transparent : const Color(0x33FFFFFF)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783)));
    }

    final Map<String, List<Match>> matchesBySport = {};
    for (var match in _allMatches) {
      matchesBySport.putIfAbsent(match.sport.name, () => []).add(match);
    }
    final sortedSports = matchesBySport.keys.toList()..sort();

    final filteredMatches = _selectedSportId == 'all'
        ? _allMatches
        : _allMatches.where((m) => m.sport.id == _selectedSportId).toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top + 16),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                _buildSportFilterChip('all', 'All Sports'),
                ..._sports.map((s) => _buildSportFilterChip(s.id, s.name, logoUrl: s.logoUrl)),
              ],
            ),
          ),
        ),
        if (_selectedSportId == 'all')
          ...sortedSports.map((sportName) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: HorizontalMatchList(
                  categoryTitle: sportName,
                  items: matchesBySport[sportName]!,
                ),
              ),
            );
          })
        else
          SliverPadding(
            padding: const EdgeInsets.all(16.0),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => MatchListItem(match: filteredMatches[index]),
                childCount: filteredMatches.length,
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)), // Padding for bottom nav bar
      ],
    );
  }
}

// --- Match Display Widgets ---

class HorizontalMatchList extends StatelessWidget {
  final String categoryTitle;
  final List<Match> items;

  const HorizontalMatchList({super.key, required this.categoryTitle, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            categoryTitle,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            itemCount: items.length,
            itemBuilder: (context, index) => MatchCard(match: items[index]),
          ),
        ),
      ],
    );
  }
}

class MatchCard extends StatelessWidget {
  final Match match;
  const MatchCard({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { /* Navigate to player */ },
      child: Container(
        width: 250,
        margin: const EdgeInsets.symmetric(horizontal: 4.0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1F24),
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(match.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), textAlign: TextAlign.center, maxLines: 2),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _TeamLogo(url: match.teamALogo),
                const Text('vs', style: TextStyle(color: Colors.white54, fontSize: 18)),
                _TeamLogo(url: match.teamBLogo),
              ],
            ),
            const Spacer(),
            Text('Starts at: ${TimeOfDay.fromDateTime(match.startTime).format(context)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class MatchListItem extends StatelessWidget {
  final Match match;
  const MatchListItem({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { /* Navigate to player */ },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12.0),
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1F24),
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            _TeamLogo(url: match.teamALogo, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(match.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('Starts at: ${TimeOfDay.fromDateTime(match.startTime).format(context)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _TeamLogo(url: match.teamBLogo, size: 40),
            const SizedBox(width: 16),
            const Icon(Icons.play_circle_outline, color: Color(0xFF1CE783), size: 32),
          ],
        ),
      ),
    );
  }
}

class _TeamLogo extends StatelessWidget {
  final String url;
  final double size;
  const _TeamLogo({required this.url, this.size = 50});

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      placeholder: (context, url) => Container(width: size, height: size, decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle)),
      errorWidget: (context, url, error) => Container(width: size, height: size, decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle), child: const Icon(Icons.shield, color: Colors.white24)),
    );
  }
}