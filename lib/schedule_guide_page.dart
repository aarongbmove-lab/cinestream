import 'package:flutter/material.dart';
import 'package:cinestream/live_tv_page.dart'; // Re-use models and API service
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';

class ScheduleGuidePage extends StatefulWidget {
  const ScheduleGuidePage({super.key});

  @override
  State<ScheduleGuidePage> createState() => _ScheduleGuidePageState();
}

class _ScheduleGuidePageState extends State<ScheduleGuidePage> {
  final _api = LiveSportsApi();
  bool _isLoading = true;
  List<Sport> _sports = [];
  String _selectedSportName = 'All';

  // Data structure for the view: Sport Name -> League Name -> Date String -> Matches
  Map<String, Map<String, Map<String, List<Match>>>> _groupedSchedule = {};

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    try {
      // Fetch sports for the filter bar and all matches for the next week
      final results = await Future.wait([
        _api.fetchSports(),
        _api.fetchUpcomingSchedule(days: 7),
      ]);

      if (mounted) {
        final sports = results[0] as List<Sport>;
        final matches = results[1] as List<Match>;

        // Group the schedule data
        final groupedData = <String, Map<String, Map<String, List<Match>>>>{};
        for (final match in matches) {
          final sportName = match.sport.name;
          final leagueName = match.leagueName;
          final dateString = DateFormat.yMMMEd().format(match.startTime);

          groupedData.putIfAbsent(sportName, () => {});
          groupedData[sportName]!.putIfAbsent(leagueName, () => {});
          groupedData[sportName]![leagueName]!
              .putIfAbsent(dateString, () => [])
              .add(match);
        }

        setState(() {
          _sports = sports;
          _groupedSchedule = groupedData;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to load schedule: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildSportFilterChip(String name, {String? logoUrl}) {
    final isSelected = _selectedSportName == name;
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
          if (selected) setState(() => _selectedSportName = name);
        },
        selectedColor: const Color(0xFF1CE783),
        labelStyle: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
              color:
                  isSelected ? Colors.transparent : const Color(0x33FFFFFF)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1CE783)));
    }

    final sportsToShow = _selectedSportName == 'All'
        ? (_groupedSchedule.keys.toList()..sort())
        : [_selectedSportName];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
              height: kToolbarHeight + MediaQuery.of(context).padding.top + 16),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                _buildSportFilterChip('All'),
                ..._sports.map(
                    (s) => _buildSportFilterChip(s.name, logoUrl: s.logoUrl)),
              ],
            ),
          ),
        ),
        ...sportsToShow.map((sportName) {
          final leagues = _groupedSchedule[sportName]?.keys.toList();
          leagues?.sort();
          if (leagues == null || leagues.isEmpty) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          return SliverList.list(
            children: [
              if (_selectedSportName == 'All')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                  child: Text(
                    sportName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ...leagues.map((leagueName) {
                final dates =
                    _groupedSchedule[sportName]![leagueName]!.keys.toList();
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        leagueName,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ...dates.map((dateString) {
                        final matchesOnDate =
                            _groupedSchedule[sportName]![leagueName]![dateString]!;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8.0),
                              child: Text(
                                dateString,
                                style: const TextStyle(
                                    color: Color(0xFF1CE783),
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            ...matchesOnDate
                                .map((match) => MatchScheduleItem(match: match)),
                          ],
                        );
                      }),
                    ],
                  ),
                );
              }),
            ],
          );
        }),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

class MatchScheduleItem extends StatelessWidget {
  final Match match;
  const MatchScheduleItem({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1F24),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              TimeOfDay.fromDateTime(match.startTime).format(context),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          _TeamLogo(url: match.teamALogo, size: 32),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              match.title,
              style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          _TeamLogo(url: match.teamBLogo, size: 32),
        ],
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
      placeholder: (context, url) => Container(
          width: size,
          height: size,
          decoration:
              const BoxDecoration(color: Colors.white10, shape: BoxShape.circle)),
      errorWidget: (context, url, error) => Container(
          width: size,
          height: size,
          decoration:
              const BoxDecoration(color: Colors.white10, shape: BoxShape.circle),
          child: const Icon(Icons.shield, color: Colors.white24)),
    );
  }
}
