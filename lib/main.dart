import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const DonationLocatorApp());
}

// Backward-compatible wrapper for tests expecting MyApp
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const DonationLocatorApp();
}

class DonationLocatorApp extends StatelessWidget {
  const DonationLocatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Donation Center Locator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DonationLocatorHome(),
    );
  }
}

class DonationLocatorHome extends StatefulWidget {
  const DonationLocatorHome({super.key});

  @override
  State<DonationLocatorHome> createState() => _DonationLocatorHomeState();
}

class _DonationLocatorHomeState extends State<DonationLocatorHome> {
  static const String bookmarksPrefsKey = 'bookmarked_centers_v1';
  static const String serviceBaseUrl = 'https://v0-state-and-city-service.vercel.app';

  String? selectedState;
  String? selectedCity;

  List<String> availableStates = [];
  List<String> availableCities = [];
  List<DonationCenter> locations = [];
  List<DonationCenter> bookmarks = [];

  bool isLoadingStates = false;
  bool isLoadingCities = false;
  bool isLoadingLocations = false;

  Map<String, dynamic> _donationData = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await Future.wait([
      _loadBookmarksFromStorage(),
      _loadLocalDonationData(),
    ]);
    await _loadStates();
  }

  Future<void> _loadLocalDonationData() async {
    try {
      final jsonString = await rootBundle.loadString('assets/donation_data.json');
      final parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic>) {
        _donationData = parsed;
      }
    } catch (_) {
      // If asset missing or invalid, keep empty and rely on network/fallbacks
      _donationData = {};
    }
  }

  Future<void> _loadStates() async {
    setState(() => isLoadingStates = true);
    try {
      if (_donationData.isNotEmpty) {
        final states = _donationData.keys.map((e) => e.toString()).toList()..sort();
        setState(() => availableStates = states);
        return;
      }
      final states = await _fetchStatesFromService();
      setState(() => availableStates = states.isNotEmpty ? states : _usStates);
    } catch (_) {
      setState(() => availableStates = _usStates);
    } finally {
      setState(() => isLoadingStates = false);
    }
  }

  Future<void> _onStateChanged(String? state) async {
    if (state == null) return;
    setState(() {
      selectedState = state;
      selectedCity = null;
      availableCities = [];
      locations = [];
    });
    await _loadCitiesForState(state);
  }

  Future<void> _loadCitiesForState(String state) async {
    setState(() => isLoadingCities = true);
    try {
      if (_donationData.containsKey(state)) {
        final stateData = _donationData[state];
        if (stateData is Map && stateData['cities'] is Map) {
          final citiesMap = stateData['cities'] as Map;
          final cities = citiesMap.keys.map((e) => e.toString()).toList()
            ..sort();
          setState(() => availableCities = cities.take(10).toList());
          return;
        }
      }
      final cities = await _fetchTopCitiesFromService(state);
      setState(() => availableCities = cities.isNotEmpty
          ? cities
          : (_top10CitiesByState[state] ?? _generatePlaceholderCities(state)));
    } catch (_) {
      setState(() => availableCities =
          _top10CitiesByState[state] ?? _generatePlaceholderCities(state));
    } finally {
      setState(() => isLoadingCities = false);
    }
  }

  Future<void> _onCityChanged(String? city) async {
    if (city == null || selectedState == null) return;
    setState(() {
      selectedCity = city;
      locations = [];
    });
    await _loadLocationsForCity(selectedState!, city);
  }

  Future<void> _loadLocationsForCity(String state, String city) async {
    setState(() => isLoadingLocations = true);
    try {
      // Prefer local JSON if available
      if (_donationData.containsKey(state)) {
        final stateData = _donationData[state];
        if (stateData is Map && stateData['cities'] is Map) {
          final citiesMap = stateData['cities'] as Map;
          if (citiesMap[city] is List) {
            final list = (citiesMap[city] as List).cast<dynamic>();
            final centers = list.take(10).map((e) {
              final map = (e as Map).map((k, v) => MapEntry(k.toString(), v));
              // fill id if not provided
              map.putIfAbsent('id', () => '${state}_${city}_${list.indexOf(e) + 1}');
              return DonationCenter.fromMap(map);
            }).toList();
            setState(() => locations = centers);
            return;
          }
        }
      }

      // Fallback to network
      final centers = await _fetchDonationCentersFromService(state, city);
      setState(() => locations = centers.isNotEmpty
          ? centers
          : _generatePlaceholderCenters(state, city));
    } catch (_) {
      setState(() => locations = _generatePlaceholderCenters(state, city));
    } finally {
      setState(() => isLoadingLocations = false);
    }
  }

  Future<void> _toggleBookmark(DonationCenter center) async {
    final existingIndex = bookmarks.indexWhere((c) => c.id == center.id);
    setState(() {
      if (existingIndex >= 0) {
        bookmarks.removeAt(existingIndex);
      } else {
        bookmarks.add(center);
      }
    });
    await _saveBookmarksToStorage();
  }

  bool _isBookmarked(DonationCenter center) {
    return bookmarks.any((c) => c.id == center.id);
  }

  String _normalizePhone(String input) {
    final trimmed = input.trim();
    final hasLeadingPlus = trimmed.startsWith('+');
    final digitsOnly = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.isEmpty) return '';
    return hasLeadingPlus ? '+$digitsOnly' : digitsOnly;
  }

  Future<void> _callPhone(String phone) async {
    final normalized = _normalizePhone(phone);
    if (normalized.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: normalized);
    final can = await canLaunchUrl(uri);
    if (can) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open phone dialer')),
      );
    }
  }

  void _copyCenter(DonationCenter center) {
    final buffer = StringBuffer()
      ..writeln(center.name)
      ..writeln(center.address);
    if (center.phone.isNotEmpty) buffer.writeln('Phone: ${center.phone}');
    if (center.email.isNotEmpty) buffer.writeln('Email: ${center.email}');
    if (center.website.isNotEmpty) buffer.writeln('Website: ${center.website}');
    Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location copied')),
    );
  }

  Future<void> _loadBookmarksFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(bookmarksPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      final loaded = list
          .map((e) => DonationCenter.fromMap(e as Map<String, dynamic>))
          .toList();
      setState(() => bookmarks = loaded);
    } catch (_) {
      // Ignore malformed data
    }
  }

  Future<void> _saveBookmarksToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(bookmarks.map((c) => c.toMap()).toList());
    await prefs.setString(bookmarksPrefsKey, encoded);
  }

  // Networking (best-effort; falls back to local data if service not available)
  Future<List<String>> _fetchStatesFromService() async {
    try {
      final uri = Uri.parse('$serviceBaseUrl/states');
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is List) {
          return data.map((e) => e.toString()).cast<String>().toList();
        }
        if (data is Map && data['states'] is List) {
          return (data['states'] as List).map((e) => e.toString()).toList();
        }
      }
    } catch (_) {
      // ignore
    }
    return [];
  }

  Future<List<String>> _fetchTopCitiesFromService(String state) async {
    try {
      final encodedState = Uri.encodeComponent(state);
      final uri = Uri.parse('$serviceBaseUrl/states/$encodedState/cities/top?limit=10');
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is List) {
          return data.map((e) => e.toString()).cast<String>().toList();
        }
        if (data is Map && data['cities'] is List) {
          return (data['cities'] as List).map((e) => e.toString()).toList();
        }
      }
    } catch (_) {
      // ignore
    }
    return [];
  }

  Future<List<DonationCenter>> _fetchDonationCentersFromService(
    String state,
    String city,
  ) async {
    try {
      final encodedState = Uri.encodeComponent(state);
      final encodedCity = Uri.encodeComponent(city);
      final uri = Uri.parse(
          '$serviceBaseUrl/states/$encodedState/cities/$encodedCity/donation-centers?limit=10');
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is List) {
          return data
              .map((e) => DonationCenter.fromMap(
                    (e as Map).map((k, v) => MapEntry(k.toString(), v)),
                  ))
              .toList();
        }
        if (data is Map && data['centers'] is List) {
          return (data['centers'] as List)
              .map((e) => DonationCenter.fromMap(
                    (e as Map).map((k, v) => MapEntry(k.toString(), v)),
                  ))
              .toList();
        }
      }
    } catch (_) {
      // ignore
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Donation Center Locator'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildStateDropdown(),
              const SizedBox(height: 8),
              if (selectedState != null) _buildCityDropdown(),
              const SizedBox(height: 8),
              Expanded(
                child: _buildLocationsList(),
              ),
              const SizedBox(height: 8),
              _buildBookmarksSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStateDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select State',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
          child: isLoadingStates
              ? const SizedBox(
                  height: 40,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Choose a state'),
                    value: selectedState,
                    items: availableStates
                        .map((s) => DropdownMenuItem<String>(
                              value: s,
                              child: Text(s),
                            ))
                        .toList(),
                    onChanged: (val) => _onStateChanged(val),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCityDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select City',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
          child: isLoadingCities
              ? const SizedBox(
                  height: 40,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Choose a city'),
                    value: selectedCity,
                    items: availableCities
                        .map((c) => DropdownMenuItem<String>(
                              value: c,
                              child: Text(c),
                            ))
                        .toList(),
                    onChanged: (val) => _onCityChanged(val),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildLocationsList() {
    if (selectedState == null) {
      return const Center(
        child: Text('Please select a state to view top cities.'),
      );
    }

    if (selectedCity == null) {
      return const Center(
        child: Text('Please select a city to view donation centers.'),
      );
    }

    if (isLoadingLocations) {
      return const Center(child: CircularProgressIndicator());
    }

    if (locations.isEmpty) {
      return const Center(
        child: Text('No donation centers found.'),
      );
    }

    return ListView.builder(
      itemCount: locations.length,
      itemBuilder: (context, index) {
        final center = locations[index];
        final isSaved = _isBookmarked(center);
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        center.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copyCenter(center),
                          tooltip: 'Copy',
                        ),
                        IconButton(
                          icon: Icon(
                            isSaved ? Icons.bookmark : Icons.bookmark_border,
                            color: isSaved ? Colors.amber[800] : null,
                          ),
                          onPressed: () => _toggleBookmark(center),
                          tooltip: isSaved ? 'Remove bookmark' : 'Add bookmark',
                        ),
                      ],
                    )
                  ],
                ),
                const SizedBox(height: 4),
                Text(center.address),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _InfoChip(
                      icon: Icons.phone,
                      label: center.phone,
                      onTap: center.phone.isNotEmpty
                          ? () => _callPhone(center.phone)
                          : null,
                    ),
                    _InfoChip(icon: Icons.email, label: center.email),
                    _InfoChip(icon: Icons.language, label: center.website),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBookmarksSection() {
    return InkWell(
      onTap: _showBookmarksSheet,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.yellow[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.yellow[700]!.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bookmarks, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Selected List',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                if (bookmarks.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.yellow[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${bookmarks.length}'),
                  ),
                const Spacer(),
                if (bookmarks.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      setState(() => bookmarks.clear());
                      await _saveBookmarksToStorage();
                    },
                    child: const Text('Clear all'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (bookmarks.isEmpty)
              const Text('No bookmarks yet.'),
            if (bookmarks.isNotEmpty)
              Row(
                children: const [
                  Icon(Icons.swipe_up, size: 16),
                  SizedBox(width: 6),
                  Text('Tap to view and scroll the selected list'),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBookmarksSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.25,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.yellow[100],
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                border: Border.all(color: Colors.yellow[700]!.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.yellow[700],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.bookmarks, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Selected List',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                        ),
                        const SizedBox(width: 8),
                        if (bookmarks.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.yellow[200],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${bookmarks.length}'),
                          ),
                        const Spacer(),
                        if (bookmarks.isNotEmpty)
                          TextButton(
                            onPressed: () async {
                              setState(() => bookmarks.clear());
                              await _saveBookmarksToStorage();
                            },
                            child: const Text('Clear all'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: bookmarks.isEmpty
                        ? const Center(child: Text('No bookmarks yet.'))
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: bookmarks.length,
                            itemBuilder: (context, index) {
                              final center = bookmarks[index];
                              return Card(
                                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                child: Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              center.name,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                icon: const Icon(Icons.copy),
                                                onPressed: () => _copyCenter(center),
                                                tooltip: 'Copy',
                                              ),
                                              IconButton(
                                                icon: const Icon(Icons.delete_outline),
                                                onPressed: () => _toggleBookmark(center),
                                                tooltip: 'Remove',
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(center.address),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 12,
                                        runSpacing: 4,
                                        children: [
                                          _InfoChip(
                                            icon: Icons.phone,
                                            label: center.phone,
                                            onTap: center.phone.isNotEmpty
                                                ? () => _callPhone(center.phone)
                                                : null,
                                          ),
                                          _InfoChip(icon: Icons.language, label: center.website),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Local fallback data and generators
  List<String> _generatePlaceholderCities(String state) {
    return List.generate(10, (i) => 'City ${i + 1}');
  }

  List<DonationCenter> _generatePlaceholderCenters(String state, String city) {
    return List<DonationCenter>.generate(10, (index) {
      final idx = index + 1;
      return DonationCenter(
        id: '${state}_${city}_$idx',
        name: 'Donation Center $idx - $city',
        address: '123${idx.toString().padLeft(2, '0')} Main St, $city, $state',
        phone: '555-010${(idx % 10)}',
        email: 'contact$idx@donate.org',
        website: 'https://example.org/center$idx',
      );
    });
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _InfoChip({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.grey[700]),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: onTap != null ? Colors.blue[800] : Colors.grey[800],
            decoration: onTap != null ? TextDecoration.underline : TextDecoration.none,
          ),
        ),
      ],
    );

    if (onTap != null && label.isNotEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}

class DonationCenter {
  final String id;
  final String name;
  final String address;
  final String phone;
  final String email;
  final String website;

  DonationCenter({
    required this.id,
    required this.name,
    required this.address,
    required this.phone,
    required this.email,
    required this.website,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'address': address,
      'phone': phone,
      'email': email,
      'website': website,
    };
  }

  factory DonationCenter.fromMap(Map<String, dynamic> map) {
    // If no explicit id is provided from API, derive a stable id from fields
    final providedId = map['id']?.toString();
    final derivedId = '${map['name'] ?? ''}|${map['address'] ?? ''}|${map['phone'] ?? ''}';
    return DonationCenter(
      id: providedId?.isNotEmpty == true ? providedId! : derivedId,
      name: (map['name'] ?? '').toString(),
      address: (map['address'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      website: (map['website'] ?? '').toString(),
    );
  }
}

// Static list of US states. Used for initial population and as a fallback.
const List<String> _usStates = [
  'Alabama',
  'Alaska',
  'Arizona',
  'Arkansas',
  'California',
  'Colorado',
  'Connecticut',
  'Delaware',
  'Florida',
  'Georgia',
  'Hawaii',
  'Idaho',
  'Illinois',
  'Indiana',
  'Iowa',
  'Kansas',
  'Kentucky',
  'Louisiana',
  'Maine',
  'Maryland',
  'Massachusetts',
  'Michigan',
  'Minnesota',
  'Mississippi',
  'Missouri',
  'Montana',
  'Nebraska',
  'Nevada',
  'New Hampshire',
  'New Jersey',
  'New Mexico',
  'New York',
  'North Carolina',
  'North Dakota',
  'Ohio',
  'Oklahoma',
  'Oregon',
  'Pennsylvania',
  'Rhode Island',
  'South Carolina',
  'South Dakota',
  'Tennessee',
  'Texas',
  'Utah',
  'Vermont',
  'Virginia',
  'Washington',
  'West Virginia',
  'Wisconsin',
  'Wyoming',
];

// Optional curated top cities for some states. Falls back to generated list if missing.
const Map<String, List<String>> _top10CitiesByState = {
  'California': [
    'Los Angeles',
    'San Diego',
    'San Jose',
    'San Francisco',
    'Fresno',
    'Sacramento',
    'Long Beach',
    'Oakland',
    'Bakersfield',
    'Anaheim',
  ],
  'Texas': [
    'Houston',
    'San Antonio',
    'Dallas',
    'Austin',
    'Fort Worth',
    'El Paso',
    'Arlington',
    'Corpus Christi',
    'Plano',
    'Laredo',
  ],
  'Florida': [
    'Jacksonville',
    'Miami',
    'Tampa',
    'Orlando',
    'St. Petersburg',
    'Hialeah',
    'Tallahassee',
    'Port St. Lucie',
    'Cape Coral',
    'Fort Lauderdale',
  ],
  'New York': [
    'New York',
    'Buffalo',
    'Rochester',
    'Yonkers',
    'Syracuse',
    'Albany',
    'New Rochelle',
    'Mount Vernon',
    'Schenectady',
    'Utica',
  ],
  'Illinois': [
    'Chicago',
    'Aurora',
    'Naperville',
    'Joliet',
    'Rockford',
    'Springfield',
    'Elgin',
    'Peoria',
    'Waukegan',
    'Cicero',
  ],
};
