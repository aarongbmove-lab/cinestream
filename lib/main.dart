// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart' as gsi;
// ignore: unused_import
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';
import 'web_player_stub.dart' if (dart.library.html) 'web_player.dart';
// ignore: unused_import
import 'web_button_stub.dart' if (dart.library.html) 'web_button.dart';

const String tmdbApiKey = '1334200a3782740ce2c83ced081d086e';
final Map<String, dynamic> _apiCache = {};
bool _isGoogleSignInInitialized = false;
bool _hasShownWebPopup = false;

Future<dynamic> fetchWithCache(String url) async {
  if (_apiCache.containsKey(url)) {
    return _apiCache[url];
  }
  final response = await http.get(Uri.parse(url));
  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    _apiCache[url] = data;
    return data;
  } else {
    throw Exception('Failed to load data: ${response.statusCode}');
  }
}

bool _isReleased(dynamic item) {
  if (item is! Map) return false;
  final mediaType = item['media_type'];
  final isMovie = mediaType == 'movie' || (mediaType == null && item.containsKey('title') && item.containsKey('release_date'));
  
  if (isMovie) {
    final releaseDateStr = item['release_date']?.toString();
    if (releaseDateStr == null || releaseDateStr.trim().isEmpty) return false;
    try {
      final releaseDate = DateTime.parse(releaseDateStr);
      if (releaseDate.isAfter(DateTime.now())) return false;
    } catch (_) {}
  }
  return true;
}

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      WindowsWebViewPlatform.registerWith();
    }
    runApp(const MyApp());
  } catch (e, stackTrace) {
    debugPrint('App initialization error: $e\n$stackTrace');
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F1014),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Failed to launch:\n\n$e', style: const TextStyle(color: Colors.red, fontSize: 16)),
          ),
        ),
      ),
    ));
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CineStream',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0F1014),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1CE783), // Hulu Green
          brightness: Brightness.dark,
          primary: const Color(0xFF1CE783),
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F1014),
            body: Center(child: CircularProgressIndicator(color: Color(0xFF1CE783))),
          );
        }
        if (snapshot.hasData) {
          return const TMDBHomePage(title: 'cinestream');
        }
        return const LoginPage();
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _authenticate(bool isSignUp) async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both email and password.'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      if (isSignUp) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
    } catch (e) {
      String errorMessage = e.toString();

      // The Firebase Desktop SDK maps "INVALID_LOGIN_CREDENTIALS" to a generic internal error.
      if (e is FirebaseAuthException && e.code == 'internal-error') {
        if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
          errorMessage = 'Invalid email or password. (If you created this account with Google/Microsoft, please use those buttons).';
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
        // --- NATIVE DESKTOP LOOPBACK WORKAROUND ---
        
        // You MUST create a "Desktop app" OAuth Client ID in Google Cloud Console
        const String clientId = '651005734001-e060vcsc7hslmcb4joemh194ms4vits1.apps.googleusercontent.com';
        const String clientSecret = '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';

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final redirectUri = 'http://localhost:${server.port}';

        final authUrl = 'https://accounts.google.com/o/oauth2/v2/auth'
            '?client_id=$clientId'
            '&response_type=code'
            '&redirect_uri=$redirectUri'
            '&scope=openid%20email%20profile';

        if (defaultTargetPlatform == TargetPlatform.windows) {
          await Process.run('cmd', ['/c', 'start', authUrl.replaceAll('&', '^&')]);
        } else {
          await Process.run('xdg-open', [authUrl]);
        }

        try {
          final request = await server.first.timeout(const Duration(minutes: 3));
          final code = request.uri.queryParameters['code'];

          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body style="background:#0F1014;color:#1CE783;text-align:center;margin-top:20%;font-family:sans-serif;"><h2>Login successful! You can close this window and return to CineStream.</h2><script>window.close();</script></body></html>');
          await request.response.close();

          if (code != null) {
            final tokenResponse = await http.post(
              Uri.parse('https://oauth2.googleapis.com/token'),
              body: {
                'client_id': clientId,
                'client_secret': clientSecret,
                'code': code,
                'redirect_uri': redirectUri,
                'grant_type': 'authorization_code',
              },
            );

            if (tokenResponse.statusCode == 200) {
              final tokenData = json.decode(tokenResponse.body);
              final credential = GoogleAuthProvider.credential(
                idToken: tokenData['id_token'],
                accessToken: tokenData['access_token'],
              );
              await FirebaseAuth.instance.signInWithCredential(credential);
            } else {
              throw Exception('Failed to exchange token: ${tokenResponse.body}');
            }
          } else {
            throw Exception('No authorization code received.');
          }
        } on TimeoutException {
          throw Exception('Sign-in timed out or was cancelled. Please try again.');
        } finally {
          await server.close(force: true);
        }
      } else if (kIsWeb) {
        final googleProvider = GoogleAuthProvider();
        await FirebaseAuth.instance.signInWithPopup(googleProvider);
      } else {
        // Android / iOS native Google Sign-In
        if (!_isGoogleSignInInitialized) {
          await gsi.GoogleSignIn.instance.initialize(
            serverClientId: '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
          );
          try {
            await gsi.GoogleSignIn.instance.initialize(
              serverClientId: '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
            );
          } catch (_) {}
          _isGoogleSignInInitialized = true;
        }

        // ignore: unnecessary_nullable_for_final_variable_declarations
        final gsi.GoogleSignInAccount? googleUser = await gsi.GoogleSignIn.instance.authenticate();

        if (googleUser == null) {
          // User cancelled the sign-in.
          return;
        }

        final gsi.GoogleSignInAuthentication googleAuth = googleUser.authentication; // Synchronous in v7+
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        await FirebaseAuth.instance.signInWithCredential(credential);
      }
    } catch (e) {
      if (e is FirebaseAuthException && e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        // Don't show an error if the user just cancelled the login flow.
        final isCancellation = e is FirebaseAuthException && (e.code == 'web-context-cancelled' || e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            String errorMessage = e.toString();
            if (e is FirebaseAuthException && e.code == 'internal-error') {
              errorMessage = 'Internal Error: Ensure your Desktop Client ID is added to the "Whitelisted client IDs" in Firebase Console under Google Sign-In.';
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
            );
          }
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithMicrosoft() async {
    setState(() => _isLoading = true);
    try {
      if (kIsWeb) {
        final microsoftProvider = OAuthProvider('microsoft.com');
        microsoftProvider.addScope('User.Read');
        final userCred = await FirebaseAuth.instance.signInWithPopup(microsoftProvider);
        final credential = userCred.credential;
        final token = credential is OAuthCredential ? credential.accessToken : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      } else {
        final microsoftProvider = OAuthProvider('microsoft.com');
        microsoftProvider.addScope('User.Read');
        final userCred = await FirebaseAuth.instance.signInWithProvider(microsoftProvider);
        final credential = userCred.credential;
        final token = credential is OAuthCredential ? credential.accessToken : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      }
    } catch (e) {
      if (e is FirebaseAuthException && e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        final isCancellation = e is FirebaseAuthException && (e.code == 'web-context-cancelled' || e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            String errorMessage = e.toString();
            if (e is FirebaseAuthException && e.code == 'internal-error') {
              errorMessage = 'Internal Error: Ensure Microsoft Sign-In is enabled in Firebase Console with your Client ID & Secret.';
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
            );
          }
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateMicrosoftPhoto(User user, String accessToken) async {
    // Skip if they already have a standard URL (e.g. from a linked Google account)
    if (user.photoURL != null && !user.photoURL!.startsWith('data:')) return;
    
    try {
      // Try to fetch a small 48x48 image to ensure the Base64 string safely fits inside Firebase's photoURL field
      final response = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/photos/48x48/\$value'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        final base64Data = base64Encode(response.bodyBytes);
        await user.updatePhotoURL('data:${response.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data');
      } else {
        // Fallback to default photo endpoint if the user's account doesn't support explicit resizing
        final fallback = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/photo/\$value'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (fallback.statusCode == 200) {
          final base64Data = base64Encode(fallback.bodyBytes);
          await user.updatePhotoURL('data:${fallback.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data');
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch Microsoft photo: $e');
    }
  }

  Future<void> _handleAccountLinking(AuthCredential? credential, String? email) async {
    if (credential == null || email == null || !mounted) return;

    final password = await _promptForPassword(email);
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _isLoading = true);
    try {
      // Sign in with email and password to verify user
      final userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Link the new (social) credential
      await userCredential.user?.linkWithCredential(credential);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Successfully linked account!'), backgroundColor: Colors.green),
        );
      }
    } on FirebaseAuthException catch (authError) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to link: ${authError.message}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _promptForPassword(String email) {
    final passwordController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F24),
          title: const Text('Link Account', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  'An account already exists with $email. Please enter your password to link it.',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1CE783))),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1CE783), foregroundColor: Colors.black),
              onPressed: () => Navigator.of(context).pop(passwordController.text.trim()),
              child: const Text('Link'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            const Text(
              'CineStream',
              style: TextStyle(
                color: Color(0xFF1CE783),
                fontWeight: FontWeight.w900,
                fontSize: 36,
                letterSpacing: -1.0,
              ),
            ),
            const SizedBox(height: 48),
            TextField(
              controller: _emailController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Email',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1CE783))),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Password',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1CE783))),
              ),
            ),
            const SizedBox(height: 32),
            if (_isLoading)
              const CircularProgressIndicator(color: Color(0xFF1CE783))
            else ...[
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1CE783),
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: () => _authenticate(false),
                child: const Text('Sign In', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _authenticate(true),
                child: const Text('Create Account', style: TextStyle(color: Color(0xFF1CE783))),
              ),
              const SizedBox(height: 24),
              const Row(
                children: [
                  Expanded(child: Divider(color: Colors.white24)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('OR', style: TextStyle(color: Colors.white54)),
                  ),
                  Expanded(child: Divider(color: Colors.white24)),
                ],
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                  side: const BorderSide(color: Colors.white54),
                ),
                onPressed: _signInWithGoogle,
                icon: Image.network(
                  'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                  height: 24,
                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.account_circle, size: 24),
                ),
                label: const Text('Sign in with Google', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              if (kIsWeb || (defaultTargetPlatform != TargetPlatform.windows && defaultTargetPlatform != TargetPlatform.linux)) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    side: const BorderSide(color: Colors.white54),
                  ),
                  onPressed: _signInWithMicrosoft,
                  icon: Image.network(
                    'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                    height: 24,
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.window, size: 24),
                  ),
                  label: const Text('Sign in with Microsoft', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ],
            ],
          ],
        ),
      ),
      ),
    );
  }
}

class SearchBody extends StatefulWidget {
  const SearchBody({super.key});

  @override
  State<SearchBody> createState() => _SearchBodyState();
}

class _SearchBodyState extends State<SearchBody> {
  List<dynamic> _results = [];
  bool _isLoading = false;
  Timer? _debounce;

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (query.trim().isNotEmpty) {
        _performSearch(query.trim());
      } else {
        setState(() {
          _results = [];
          _isLoading = false;
        });
      }
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isLoading = true);
    try {
      final url = 'https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=${Uri.encodeComponent(query)}';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          // Filter out people (actors) from results since we only want to show media content
          _results = (data['results'] as List)
              .where((item) => item['media_type'] != 'person' && _isReleased(item))
              .toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          // Extra top padding prevents the text field from sliding under the transparent app bar
          padding: const EdgeInsets.fromLTRB(16.0, 100.0, 16.0, 16.0),
          child: TextField(
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search for movies, shows...',
              hintStyle: const TextStyle(color: Colors.white54),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              filled: true,
              fillColor: Colors.white12,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8.0),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783)))
              : _results.isEmpty
                  ? const Center(child: Text('No results found.', style: TextStyle(color: Colors.white54)))
                  : GridView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 2 / 3,
                        crossAxisSpacing: 12.0,
                        mainAxisSpacing: 12.0,
                      ),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final media = _results[index];
                        final posterPath = media['poster_path'];
                        final imageUrl = posterPath != null
                            ? 'https://image.tmdb.org/t/p/w500$posterPath'
                            : 'https://via.placeholder.com/500x750?text=No+Image';
                        final heroTag = 'search_${media['media_type']}_${media['id']}_$index';

                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => MediaDetailsPage(media: media, heroTag: heroTag)),
                            );
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8.0),
                            child: Hero(
                              tag: heroTag,
                              child: CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(color: Colors.black26),
                                errorWidget: (context, url, error) => Container(
                                  color: Colors.black26,
                                  child: const Icon(Icons.broken_image, color: Colors.white54),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class TMDBHomePage extends StatefulWidget {
  const TMDBHomePage({super.key, required this.title});
  final String title;

  @override
  State<TMDBHomePage> createState() => _TMDBHomePageState();
}

class _TMDBHomePageState extends State<TMDBHomePage> {
  List<dynamic> mediaList = [];
  bool isLoading = true;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    fetchTrending();
  }

  Future<void> fetchTrending() async {
    try {
      final url = 'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          final rawList = data['results'] as List? ?? [];
          mediaList = rawList.where((item) => _isReleased(item)).toList();
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _selectedIndex == 0
          ? (isLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783)))
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (mediaList.isNotEmpty) FeaturedMediaItem(mediaList: mediaList.take(5).toList()),
                      const SizedBox(height: 20),
                      HorizontalMediaList(categoryTitle: 'Trending Now', items: mediaList.skip(5).toList()),
                      const SizedBox(height: 16),
                      // Simulating another category visually by reversing the list
                      HorizontalMediaList(categoryTitle: 'Because You Watched', items: mediaList.reversed.toList()),
                      const SizedBox(height: 32),
                    ],
                  ),
                ))
          : _selectedIndex == 1
              ? const MediaCategoryBody(key: ValueKey('movie'), mediaType: 'movie')
              : _selectedIndex == 2
                  ? const MediaCategoryBody(key: ValueKey('tv'), mediaType: 'tv')
                  : _selectedIndex == 3
                  ? const SearchBody()
                  : const ProfileBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFF1CE783),
        unselectedItemColor: Colors.white54,
        backgroundColor: const Color(0xFF0F1014),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.movie), label: 'Movies'),
          BottomNavigationBarItem(icon: Icon(Icons.tv), label: 'TV Shows'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.bookmark), label: 'My Stuff'),
        ],
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
      ),
    );
  }
}

class ProfileBody extends StatelessWidget {
  const ProfileBody({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    
    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        // Decode the Base64 string we saved from Microsoft Graph
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!);
      }
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (profileImage != null)
            CircleAvatar(
              radius: 50,
              backgroundImage: profileImage,
            )
          else
            const CircleAvatar(
              radius: 50,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person, size: 50, color: Colors.white),
            ),
          const SizedBox(height: 16),
          Text(
            (user?.displayName != null && user!.displayName!.isNotEmpty) 
                ? user.displayName! 
                : 'My Stuff',
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          if (user?.email != null && user!.email!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              user.email!,
              style: const TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
          const SizedBox(height: 32),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white12, 
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () async {
              try {
                // Safely attempt to disconnect native Google session (Android/iOS only)
                try {
                  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
                    await gsi.GoogleSignIn.instance.signOut();
                  }
                } catch (_) {}
                
                await FirebaseAuth.instance.signOut();
              } catch (e) {
                debugPrint('Error signing out: $e');
              }
            },
            icon: const Icon(Icons.logout),
            label: const Text('Sign Out', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

class FeaturedMediaItem extends StatefulWidget {
  final List<dynamic> mediaList;

  const FeaturedMediaItem({super.key, required this.mediaList});

  @override
  State<FeaturedMediaItem> createState() => _FeaturedMediaItemState();
}

class _FeaturedMediaItemState extends State<FeaturedMediaItem> with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  Timer? _carouselTimer;
  String? _logoPath;
  bool _showContent = false;
  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    _fetchLogo();
    _startTimer();
  }

  @override
  void didUpdateWidget(FeaturedMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaList.isEmpty || widget.mediaList.isEmpty || oldWidget.mediaList[0]['id'] != widget.mediaList[0]['id']) {
      setState(() {
        _currentIndex = 0;
        _showContent = false;
      });
      _fetchLogo();
      _startTimer();
    }
  }

  void _startTimer() {
    _carouselTimer?.cancel();
    if (widget.mediaList.length > 1) {
      _preloadNext();
      _progressController.forward(from: 0.0);
      _carouselTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
        _nextItem();
      });
    }
  }

  void _nextItem() {
    if (!mounted) return;
    setState(() => _showContent = false);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.mediaList.length;
      });
      _progressController.forward(from: 0.0);
      _fetchLogo();
      _preloadNext();
    });
  }

  void _preloadNext() {
    if (widget.mediaList.length > 1 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final nextIndex = (_currentIndex + 1) % widget.mediaList.length;
        final nextMedia = widget.mediaList[nextIndex];
        final imageUrl = nextMedia['backdrop_path'] != null
            ? 'https://image.tmdb.org/t/p/original${nextMedia['backdrop_path']}'
            : (nextMedia['poster_path'] != null
                ? 'https://image.tmdb.org/t/p/original${nextMedia['poster_path']}'
                : 'https://via.placeholder.com/1280x720?text=No+Image');
        precacheImage(CachedNetworkImageProvider(imageUrl), context);
      });
    }
  }

  void _goToItem(int index) {
    if (!mounted || _currentIndex == index) return;
    _carouselTimer?.cancel();
    setState(() => _showContent = false);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _currentIndex = index;
      });
      _startTimer();
      _fetchLogo();
    });
  }

  Future<void> _fetchLogo() async {
    if (widget.mediaList.isEmpty) return;
    final media = widget.mediaList[_currentIndex];
    final mediaType = media['media_type'] ?? 'movie';
    final mediaId = media['id'];
    if (mediaId == null) {
      if (mounted) setState(() => _showContent = true);
      return;
    }

    final url = 'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=images';
    try {
      final data = await fetchWithCache(url);
      if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          if (logos.isNotEmpty) {
            final enLogo = logos.firstWhere((l) => l is Map && l['iso_639_1'] == 'en', orElse: () => logos.first);
            extractedLogo = enLogo['file_path'];
          }
        }
        setState(() => _logoPath = extractedLogo);
      }
    } catch (_) {}

    if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
          setState(() => _showContent = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaList.isEmpty) return const SizedBox(height: 450);
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final media = widget.mediaList[_currentIndex];
    final imageUrl = media['backdrop_path'] != null
        ? 'https://image.tmdb.org/t/p/original${media['backdrop_path']}'
        : (media['poster_path'] != null
            ? 'https://image.tmdb.org/t/p/original${media['poster_path']}'
            : 'https://via.placeholder.com/1280x720?text=No+Image');
    final title = media['title'] ?? media['name'] ?? 'Unknown';
    final overview = media['overview']?.toString() ?? '';
    final releaseDateRaw = media['release_date'] ?? media['first_air_date'];
    final releaseDate = releaseDateRaw?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : '';
    final voteAverageRaw = media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ?? ''
        : '';
    final heroTag = 'featured_${media['media_type']}_${media['id']}';

    final isTvShow = media['media_type'] == 'tv';
    double currentProgress = 0.0;
    int selectedSeason = 1;
    int selectedEpisode = 1;

    if (isTvShow) {
      // Mock Database Variables for tracking watched progress
      final Map<int, Map<int, double>> tvProgress = {
        1: {1: 1.0, 2: 1.0, 3: 1.0, 4: 1.0, 5: 1.0, 6: 1.0, 7: 1.0, 8: 1.0},
        2: {1: 1.0, 2: 0.45},
      };
      if (tvProgress.isNotEmpty) {
        int maxS = tvProgress.keys.reduce((a, b) => a > b ? a : b);
        if (tvProgress[maxS]!.isNotEmpty) {
          int maxE = tvProgress[maxS]!.keys.reduce((a, b) => a > b ? a : b);
          selectedSeason = maxS;
          selectedEpisode = maxE;
          currentProgress = tvProgress[maxS]![maxE]!;

          if (currentProgress >= 1.0) {
            selectedEpisode += 1;
            currentProgress = 0.0;
          }
        }
      }
    } else {
      currentProgress = 1.0; // Mock movie progress
    }

    String playButtonText = isTvShow 
        ? ((currentProgress > 0 && currentProgress < 1.0) ? (isMobile ? 'Resume' : 'Resume S$selectedSeason E$selectedEpisode') : (isMobile ? 'Play' : 'Play S$selectedSeason E$selectedEpisode'))
        : ((currentProgress > 0 && currentProgress < 1.0) ? 'Resume' : 'Play');

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => MediaDetailsPage(media: media, heroTag: heroTag)),
        );
      },
      onHorizontalDragEnd: (details) {
        if (widget.mediaList.length <= 1) return;
        if (details.primaryVelocity == null) return;

        if (details.primaryVelocity! < -100) {
          // Swiped Left -> Go to Next Item
          _goToItem((_currentIndex + 1) % widget.mediaList.length);
        } else if (details.primaryVelocity! > 100) {
          // Swiped Right -> Go to Previous Item
          _goToItem((_currentIndex - 1 + widget.mediaList.length) % widget.mediaList.length);
        }
      },
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 1000),
            child: Hero(
              key: ValueKey(heroTag),
              tag: heroTag,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                height: 450,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(height: 450, color: Colors.black26),
                errorWidget: (context, url, error) => Container(
                  height: 450,
                  color: Colors.black26,
                  child: const Icon(Icons.broken_image, size: 50, color: Colors.white54),
                ),
              ),
            ),
          ),
          Container(
            height: 450,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF0F1014),
                  Colors.transparent,
                  Color(0xFF0F1014)
                ],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                stops: [0.0, 0.4, 1.0],
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: AnimatedOpacity(
              opacity: _showContent ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 800),
              child: Container(
                padding: isMobile ? const EdgeInsets.all(16.0) : EdgeInsets.zero,
                decoration: isMobile ? BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 16,
                      spreadRadius: 4,
                    ),
                  ],
                ) : const BoxDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                if (_logoPath != null)
                  CachedNetworkImage(
                    imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                    width: 250,
                    height: 100,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                  )
                else
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.1,
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (releaseYear.isNotEmpty)
                      Text(
                        releaseYear,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                    if (voteAverage.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, color: Color(0xFF1CE783), size: 18),
                          const SizedBox(width: 4),
                          Text(
                            '$voteAverage / 10',
                            style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                  ],
                ),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                  ),
                ],
                if (!isTvShow && currentProgress >= 1.0) ...[
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Watched',
                        style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.check_circle, color: Color(0xFF1CE783), size: 16),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                        ),
                      onPressed: () async {
                          int resumeSeconds = 0;
                          if (currentProgress > 0 && currentProgress < 1.0) {
                          int rTime = isTvShow ? 45 : 120;
                          try {
                            final mediaId = media['id'];
                            final mediaType = isTvShow ? 'tv' : 'movie';
                            final url = 'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey';
                            final data = await fetchWithCache(url);
                            
                            if (isTvShow) {
                              final epUrl = 'https://api.themoviedb.org/3/tv/$mediaId/season/$selectedSeason/episode/$selectedEpisode?api_key=$tmdbApiKey';
                              try {
                                final epData = await fetchWithCache(epUrl);
                                if (epData['runtime'] != null) {
                                  rTime = epData['runtime'];
                                } else if (data['episode_run_time'] is List && data['episode_run_time'].isNotEmpty) {
                                  rTime = data['episode_run_time'][0];
                                }
                              } catch (_) {
                                if (data['episode_run_time'] is List && data['episode_run_time'].isNotEmpty) {
                                  rTime = data['episode_run_time'][0];
                                }
                              }
                            } else {
                              if (data['runtime'] != null) {
                                rTime = data['runtime'];
                              }
                            }
                          } catch (_) {}
                          resumeSeconds = (rTime * 60 * currentProgress).toInt();
                          }
                          final String progressParam = '&progress=$resumeSeconds';
                          final String placeholderLink = isTvShow 
                              ? 'https://player.videasy.net/tv/${media['id']}/$selectedSeason/$selectedEpisode?color=1ce783&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                              : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';
                          
                          if (!context.mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => VideoPlayerPage(videoUrl: placeholderLink)),
                          );
                        },
                        icon: const Icon(Icons.play_arrow, size: 24),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            playButtonText,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Colors.white54, width: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => MediaDetailsPage(media: media, heroTag: heroTag)),
                          );
                        },
                        icon: const Icon(Icons.list, size: 24),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Details',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                if (!isMobile) const Spacer(flex: 4),
                  ],
                ),
              ],
            ),
            ),
            ),
          ),
          if (widget.mediaList.length > 1)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.mediaList.length, (index) {
                  final isActive = index == _currentIndex;
                  return GestureDetector(
                    onTap: () => _goToItem(index),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                        color: Colors.transparent,
                        child: Container(
                          height: 4,
                          width: isActive ? 32 : 8,
                          decoration: BoxDecoration(
                            color: Colors.white38,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: isActive
                              ? AnimatedBuilder(
                                  animation: _progressController,
                                  builder: (context, child) {
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: _progressController.value,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1CE783),
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }
}

class HorizontalMediaList extends StatelessWidget {
  final String categoryTitle;
  final List<dynamic> items;

  const HorizontalMediaList({super.key, required this.categoryTitle, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            categoryTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final media = items[index];
              final posterPath = media['poster_path'];
              final imageUrl = posterPath != null
                  ? 'https://image.tmdb.org/t/p/w500$posterPath'
                  : 'https://via.placeholder.com/500x750?text=No+Image';
              final heroTag = '${categoryTitle}_${media['media_type']}_${media['id']}_$index';

              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => MediaDetailsPage(media: media, heroTag: heroTag)),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.0),
                    child: Hero(
                      tag: heroTag,
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        width: 135,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(width: 135, color: Colors.black26),
                        errorWidget: (context, url, error) => Container(
                          width: 135,
                          color: Colors.black26,
                          child: const Icon(Icons.broken_image, color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class MediaCategoryBody extends StatefulWidget {
  final String mediaType;
  const MediaCategoryBody({super.key, required this.mediaType});

  @override
  State<MediaCategoryBody> createState() => _MediaCategoryBodyState();
}

class _MediaCategoryBodyState extends State<MediaCategoryBody> with AutomaticKeepAliveClientMixin {
  List<dynamic> trendingList = [];
  List<dynamic> allGenres = [];
  int displayedGenresCount = 0;
  bool isLoading = true;
  bool isPaginating = false;
  final ScrollController _scrollController = ScrollController();
  final Set<int> seenMediaIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    fetchData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMoreGenres();
    }
  }

  void _loadMoreGenres() {
    if (isPaginating || displayedGenresCount >= allGenres.length) return;
    setState(() => isPaginating = true);
    
    // Load the next 5 genres in the background
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          displayedGenresCount = (displayedGenresCount + 5).clamp(0, allGenres.length);
          isPaginating = false;
        });
      }
    });
  }

  Future<void> fetchData() async {
    try {
      final trendingUrl = 'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey';
      final genreUrl = 'https://api.themoviedb.org/3/genre/${widget.mediaType}/list?api_key=$tmdbApiKey';

      final trendingData = await fetchWithCache(trendingUrl);
      final genreData = await fetchWithCache(genreUrl);

      if (mounted) {
        setState(() {
          final rawTrending = trendingData['results'] as List? ?? [];
          trendingList = rawTrending.where((item) => _isReleased(item)).toList();
          // Mark trending items as seen so they don't repeat in genre lists
          for (var item in trendingList) {
            item['media_type'] = widget.mediaType;
            if (item['id'] != null) seenMediaIds.add(item['id']);
          }
          allGenres = genreData['genres'] ?? [];
          displayedGenresCount = allGenres.length > 5 ? 5 : allGenres.length;
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783)));
    }
    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trendingList.isNotEmpty) FeaturedMediaItem(mediaList: trendingList.take(5).toList()),
          const SizedBox(height: 20),
          HorizontalMediaList(
            categoryTitle: 'Trending Now',
            items: trendingList.skip(5).toList(),
          ),
          const SizedBox(height: 16),
          ...allGenres.take(displayedGenresCount).toList().asMap().entries.map((entry) => GenreRow(
                title: entry.value['name'],
                genreId: entry.value['id'],
                mediaType: widget.mediaType,
                index: entry.key,
                seenMediaIds: seenMediaIds,
              )),
          if (isPaginating)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32.0),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1CE783))),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class GenreRow extends StatefulWidget {
  final String title;
  final int genreId;
  final String mediaType;
  final int index;
  final Set<int> seenMediaIds;

  const GenreRow({
    super.key, 
    required this.title, 
    required this.genreId, 
    required this.mediaType,
    required this.index,
    required this.seenMediaIds,
  });

  @override
  State<GenreRow> createState() => _GenreRowState();
}

class _GenreRowState extends State<GenreRow> {
  List<dynamic> items = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchGenreItems();
  }

  Future<void> fetchGenreItems() async {
    // Stagger API calls based on index to enforce deduplication priority
    // and strictly manage rate-limits to a safe trickle.
    await Future.delayed(Duration(milliseconds: (widget.index % 5) * 200));

    try {
      final url = 'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}';
      final data = await fetchWithCache(url);
      if (mounted) {
        List<dynamic> deduplicatedItems = [];
        for (var item in (data['results'] as List? ?? [])) {
          if (!_isReleased(item)) continue;
          final int? id = item['id'];
          if (id != null && !widget.seenMediaIds.contains(id)) {
            item['media_type'] = widget.mediaType;
            deduplicatedItems.add(item);
            widget.seenMediaIds.add(id);
          }
        }
        setState(() {
          items = deduplicatedItems;
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(color: Color(0xFF1CE783))),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: HorizontalMediaList(categoryTitle: widget.title, items: items),
    );
  }
}

class MediaDetailsPage extends StatefulWidget {
  final dynamic media;
  final String heroTag;

  const MediaDetailsPage({super.key, required this.media, required this.heroTag});

  @override
  State<MediaDetailsPage> createState() => _MediaDetailsPageState();
}

class _MediaDetailsPageState extends State<MediaDetailsPage> {
  bool isLoadingDetails = true;
  Map<dynamic, dynamic>? detailedMedia;
  String? _trailerKey;
  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  int? _visualSelectedEpisode;
  Color? _dominantColor;
  bool _isColorExtracted = false;
  bool _showContent = false;
  String? _logoPath;
  final Map<int, List<dynamic>> _seasonEpisodesData = {};
  bool _isCamRelease = false;
  
  // Mock Database Variables for tracking watched progress
  double _movieProgress = 0.0;
  Map<int, Map<int, double>> _tvProgress = {};

  // Using the API key from your existing fetch method
  final String apiKey = '1334200a3782740ce2c83ced081d086e';

  @override
  void initState() {
    super.initState();
    fetchDetails();
  }

  void _checkIfReady() {
    if (!isLoadingDetails && _isColorExtracted && !_showContent) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          setState(() {
            _showContent = true;
          });
        }
      });
    }
  }

  Future<void> fetchDetails() async {
    final mediaType = widget.media['media_type']?.toString() ?? 'movie';
    final mediaId = widget.media['id'];
    if (mediaId == null) {
      if (mounted) {
        setState(() { 
          isLoadingDetails = false;
          _isColorExtracted = true;
        });
        _checkIfReady();
      }
      return;
    }

    final url = Uri.parse(
        'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$apiKey&append_to_response=credits,reviews,videos,release_dates,images');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Simulate pulling watched progress from a database
        if (mediaType == 'tv') {
          _tvProgress = {
            1: {1: 1.0, 2: 1.0, 3: 1.0, 4: 1.0, 5: 1.0, 6: 1.0, 7: 1.0, 8: 1.0}, // Matches Home Banner
            2: {1: 1.0, 2: 0.45}, // Season 2: Ep 1 watched, Ep 2 is 45% complete. (Button will show "Resume S2 E2")
          };
        } else {
          _movieProgress = 1.0; // Movie is 100% watched
        }

        bool isCam = false;
        // Parse the US release dates to determine if the latest current release is strictly Theatrical (Types 2 or 3)
        if (mediaType == 'movie' && data['release_dates'] != null && data['release_dates']['results'] is List) {
          final results = data['release_dates']['results'] as List;
          for (var r in results) {
            if (r is Map && r['iso_3166_1'] == 'US') {
              if (r['release_dates'] is List) {
                final dates = r['release_dates'] as List;
                final now = DateTime.now();
                List<Map<String, dynamic>> pastReleases = [];

                for (var d in dates) {
                  if (d is Map && d['release_date'] != null) {
                    final date = DateTime.tryParse(d['release_date']);
                    // Only consider release dates that have already occurred
                    if (date != null && date.isBefore(now)) {
                      pastReleases.add({
                        'date': date,
                        'type': d['type'] as int? ?? 0,
                      });
                    }
                  }
                }

                if (pastReleases.isNotEmpty) {
                  // Sort chronologically by date
                  pastReleases.sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
                  final latestType = pastReleases.last['type'] as int;

                  if (latestType == 2 || latestType == 3) {
                    if (pastReleases.length == 1) {
                      isCam = true;
                    } else {
                      final previousType = pastReleases[pastReleases.length - 2]['type'] as int;
                      // Type 1 is Premiere. Types 2 and 3 are Limited/Theatrical.
                      if (previousType == 1 || previousType == 2 || previousType == 3) {
                        isCam = true;
                      }
                    }
                  }
                }
              }
              break;
            }
          }
        }

        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          if (logos.isNotEmpty) {
            final enLogo = logos.firstWhere((l) => l is Map && l['iso_639_1'] == 'en', orElse: () => logos.first);
            extractedLogo = enLogo['file_path'];
          }
        }

        if (mounted) {
          setState(() {
            detailedMedia = data;
            isLoadingDetails = false;
            _isCamRelease = isCam;
            _logoPath = extractedLogo;

            // Auto-select the most recent or next episode for TV Shows
            if (mediaType == 'tv' && _tvProgress.isNotEmpty) {
              int maxS = _tvProgress.keys.reduce((a, b) => a > b ? a : b);
              if (_tvProgress[maxS]!.isNotEmpty) {
                int maxE = _tvProgress[maxS]!.keys.reduce((a, b) => a > b ? a : b);
                _selectedSeason = maxS;
                _selectedEpisode = maxE;

                if (_tvProgress[maxS]![maxE]! >= 1.0) {
                  int epCount = _getEpisodeCountForSeason(maxS);
                  if (maxE < epCount) {
                    _selectedEpisode = maxE + 1;
                  } else {
                    final availableSeasons = (data['seasons'] as List?)?.whereType<Map>().map((s) => (s['season_number'] ?? 0) as int).where((n) => n > 0).toList() ?? [];
                    if (availableSeasons.contains(maxS + 1)) {
                      _selectedSeason = maxS + 1;
                      _selectedEpisode = 1;
                    }
                  }
                }
              }
            }
          });
          
          _checkIfReady();

          if (mediaType == 'tv') {
            fetchSeasonDetails(_selectedSeason);
          }
          
          final videosData = data['videos'] is Map ? data['videos'] as Map : null;
          final videosList = videosData != null && videosData['results'] is List ? videosData['results'] as List : [];
          for (var v in videosList) {
            if (v is Map && v['type'] == 'Trailer' && v['site'] == 'YouTube') {
              _trailerKey = v['key'];
              break;
            }
          }

          final posterPath = data['poster_path']?.toString();
          if (posterPath != null) {
            _extractDominantColor('https://image.tmdb.org/t/p/w300$posterPath');
          } else {
            if (mounted) {
              setState(() => _isColorExtracted = true);
              _checkIfReady();
            }
          }
        }
      } else {
        if (mounted) {
          setState(() { isLoadingDetails = false; _isColorExtracted = true; });
          _checkIfReady();
        }
      }
    } catch (e) {
      debugPrint('Error fetching details: $e');
      if (mounted) {
        setState(() { isLoadingDetails = false; _isColorExtracted = true; });
        _checkIfReady();
      }
    }
  }

  Future<void> _extractDominantColor(String imageUrl) async {
    try {
      final colorScheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(imageUrl),
        brightness: Brightness.dark,
      );

      if (mounted) {
        setState(() {
          _dominantColor = colorScheme.primary;
          _isColorExtracted = true;
        });
        _checkIfReady();
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
      if (mounted) {
        setState(() => _isColorExtracted = true);
        _checkIfReady();
      }
    }
  }

  Future<void> fetchSeasonDetails(int seasonNumber) async {
    if (_seasonEpisodesData.containsKey(seasonNumber)) return;
    final mediaId = widget.media['id'];
    final url = 'https://api.themoviedb.org/3/tv/$mediaId/season/$seasonNumber?api_key=$apiKey';
    try {
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          _seasonEpisodesData[seasonNumber] = data['episodes'] ?? [];
        });
      }
    } catch (e) {
      debugPrint('Error fetching season details: $e');
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final DateTime d = DateTime.parse(dateStr);
      const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
      return '${months[d.month - 1]} ${d.day}, ${d.year}';
    } catch (e) {
      return dateStr;
    }
  }

  String _formatCurrency(num? amount) {
    if (amount == null || amount <= 0) return '';
    String s = amount.toStringAsFixed(0);
    String result = '';
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) result += ',';
      result += s[i];
    }
    return '\$$result';
  }

  int _getEpisodeCountForSeason(int season) {
    if (_seasonEpisodesData.containsKey(season)) {
      final epList = _seasonEpisodesData[season]!;
      int airedCount = 0;
      for (var epData in epList) {
        if (epData is! Map) continue;
        final airDateStr = epData['air_date']?.toString();
        if (airDateStr != null && airDateStr.trim().isNotEmpty) {
          try {
            final airDate = DateTime.parse(airDateStr);
            if (!airDate.isAfter(DateTime.now())) airedCount++;
          } catch (_) {
            airedCount++;
          }
        } else {
          final overview = epData['overview']?.toString();
          if (overview != null && overview.trim().isNotEmpty) airedCount++;
        }
      }
      if (airedCount > 0) return airedCount;
    }

    if (detailedMedia == null || detailedMedia!['seasons'] is! List) return 1;
    final seasonsList = detailedMedia!['seasons'] as List;
    final currentSeasonMap = seasonsList.whereType<Map>().firstWhere((s) => s['season_number'] == season, orElse: () => <dynamic, dynamic>{});
    return (currentSeasonMap.isNotEmpty && currentSeasonMap['episode_count'] != null) ? (currentSeasonMap['episode_count'] as int) : 1;
  }

  double _getEpisodeProgress(int season, int episode) {
    return _tvProgress[season]?[episode] ?? 0.0;
  }

  double _getSeasonProgress(int season, int totalEpisodes) {
    if (!_tvProgress.containsKey(season) || totalEpisodes == 0) return 0.0;
    double totalProgress = 0.0;
    for (int i = 1; i <= totalEpisodes; i++) {
      totalProgress += _getEpisodeProgress(season, i);
    }
    return totalProgress / totalEpisodes;
  }

  Widget _buildProgressIndicator(double progress) {
    if (progress >= 1.0) {
      return const Icon(Icons.check_circle, color: Color(0xFF1CE783), size: 16);
    } else if (progress > 0.0) {
      return SizedBox(
        width: 24,
        height: 4,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1CE783)),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildDetailRow(String label, String value) {
    if (value.isEmpty || value == 'N/A') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    // Basic details from passed search/trending context
    final title = widget.media['title']?.toString() ?? widget.media['name']?.toString() ?? 'Unknown';
    final overview = widget.media['overview']?.toString() ?? 'No overview available.';
    final backdropPath = widget.media['backdrop_path']?.toString();
    final posterPath = widget.media['poster_path']?.toString();
    final releaseDateRaw = widget.media['release_date'] ?? widget.media['first_air_date'];
    final releaseDate = releaseDateRaw?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4 ? releaseDate.substring(0, 4) : 'N/A';
    final voteAverageRaw = widget.media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ?? 'N/A'
        : 'N/A';

    final bool isTvShow = widget.media['media_type'] == 'tv';
    // Deep details from detailed fetch
    final details = detailedMedia ?? {};
    final numSeasons = details['number_of_seasons'];
    final numEpisodes = details['number_of_episodes'];
    final seasonsStr = numSeasons != null ? '$numSeasons Season${numSeasons != 1 ? 's' : ''}' : '';
    final episodesStr = numEpisodes != null ? '$numEpisodes Episode${numEpisodes != 1 ? 's' : ''}' : '';

    List<int> availableSeasons = [1];
    int currentSeasonEpisodeCount = 1;
    if (isTvShow && details['seasons'] is List) {
      final seasonsList = details['seasons'] as List;
      availableSeasons = seasonsList.whereType<Map>().map((s) => (s['season_number'] ?? 0) as int).where((n) => n > 0).toList();
      if (availableSeasons.isEmpty) availableSeasons = [1];

      currentSeasonEpisodeCount = _getEpisodeCountForSeason(_selectedSeason);
      if (currentSeasonEpisodeCount < 1) currentSeasonEpisodeCount = 1;
    }

    if (!availableSeasons.contains(_selectedSeason) && availableSeasons.isNotEmpty) {
      _selectedSeason = availableSeasons.first;
    }
    
    List<int> availableEpisodes = List.generate(currentSeasonEpisodeCount, (i) => i + 1);
    if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
      final epList = _seasonEpisodesData[_selectedSeason]!.whereType<Map>().toList();
      availableEpisodes = epList.map<int>((e) => int.tryParse(e['episode_number']?.toString() ?? '') ?? 0).where((n) => n > 0).toList();
      
      // Filter out episodes that haven't aired yet (future dates or missing dates)
      availableEpisodes.removeWhere((epNum) {
        final epData = epList.firstWhere((e) => (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) == epNum, orElse: () => <dynamic, dynamic>{});
        if (epData.isNotEmpty) {
          final airDateStr = epData['air_date']?.toString();
          if (airDateStr != null && airDateStr.isNotEmpty) {
            try {
              final airDate = DateTime.parse(airDateStr);
              if (airDate.isAfter(DateTime.now())) return true;
            } catch (_) {}
          } else {
            // TMDB returns null for air_date if the episode hasn't been scheduled yet.
            // If it also lacks an overview, it is definitely a dummy placeholder.
            final overview = epData['overview']?.toString();
            if (overview == null || overview.trim().isEmpty) {
              return true;
            }
          }
        }
        return false;
      });
    }

    if (!availableEpisodes.contains(_selectedEpisode) && availableEpisodes.isNotEmpty) {
      _selectedEpisode = availableEpisodes.first;
    }

    final credits = details['credits'] is Map ? details['credits'] as Map : null;
    final castList = credits != null && credits['cast'] is List ? credits['cast'] as List : [];
    final crewList = credits != null && credits['crew'] is List ? credits['crew'] as List : [];
    
    final directors = crewList.whereType<Map>().where((c) => c['job'] == 'Director').map((c) => c['name']).join(', ');
    final screenplay = crewList.whereType<Map>().where((c) => c['job'] == 'Screenplay' || c['job'] == 'Writer' || c['job'] == 'Teleplay').map((c) => c['name']).join(', ');
    final authors = crewList.whereType<Map>().where((c) => c['job'] == 'Novel' || c['job'] == 'Author' || c['job'] == 'Story' || c['job'] == 'Book').map((c) => c['name']).join(', ');
    
    final genresList = details['genres'] is List ? details['genres'] as List : [];
    final genres = genresList.whereType<Map>().map((g) => g['name']).join(', ');
    
    final epRunTimeList = details['episode_run_time'] is List ? details['episode_run_time'] as List : null;
    final epRunTimeNum = details['episode_run_time'] is num ? details['episode_run_time'] as num : null;
    final runtimeRaw = details['runtime'] ?? (epRunTimeList != null && epRunTimeList.isNotEmpty ? epRunTimeList.first : epRunTimeNum);
    int? runtimeInt = runtimeRaw is num ? runtimeRaw.toInt() : null;

    String runtimeStr = '';
    if (runtimeInt != null && runtimeInt > 0) {
      final int hrs = runtimeInt ~/ 60;
      final int mins = runtimeInt % 60;
      runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
    }

    double currentProgress = isTvShow ? _getEpisodeProgress(_selectedSeason, _selectedEpisode) : _movieProgress;
    String mediaResumeStr = '';
    int mainResumeSeconds = 0;
    if (currentProgress > 0) {
      if (currentProgress >= 1.0) {
        mediaResumeStr = 'Watched';
      } else {
        int rTime = runtimeInt ?? (isTvShow ? 45 : 120); // Fallbacks
        
        if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
          final epList = _seasonEpisodesData[_selectedSeason]!.whereType<Map>().toList();
          final epData = epList.firstWhere((e) => (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) == _selectedEpisode, orElse: () => <dynamic, dynamic>{});
          if (epData.isNotEmpty && epData['runtime'] != null) {
            rTime = epData['runtime'];
          }
        }
        final int resumeMinutes = (rTime * currentProgress).toInt();
        mainResumeSeconds = (rTime * 60 * currentProgress).toInt();
        final int rHr = resumeMinutes ~/ 60;
        final int rMin = resumeMinutes % 60;
        mediaResumeStr = 'Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m';
      }
    }

    bool isFullyWatched = false;
    if (isTvShow) {
      if (_tvProgress.isNotEmpty) {
        int maxS = _tvProgress.keys.reduce((a, b) => a > b ? a : b);
        if (_tvProgress[maxS]!.isNotEmpty) {
          int maxE = _tvProgress[maxS]!.keys.reduce((a, b) => a > b ? a : b);
          if (_tvProgress[maxS]![maxE]! >= 1.0) {
             int epCount = _getEpisodeCountForSeason(maxS);
             if (maxE >= epCount && !availableSeasons.contains(maxS + 1)) {
               isFullyWatched = true;
             }
          }
        }
      }
    } else {
      isFullyWatched = _movieProgress >= 1.0;
    }
    
    final status = details['status']?.toString() ?? '';
    final language = details['original_language']?.toString().toUpperCase() ?? '';
    
    final budgetRaw = details['budget'];
    final budget = _formatCurrency(budgetRaw is num ? budgetRaw : null);
    final revenueRaw = details['revenue'];
    final revenue = _formatCurrency(revenueRaw is num ? revenueRaw : null);
    
    final networksList = details['networks'] is List ? details['networks'] as List : [];
    final networks = networksList.whereType<Map>().map((n) => n['name']).join(', ');
    final type = details['type']?.toString() ?? '';
    final firstAirDate = _formatDate(details['first_air_date']?.toString());
    final lastAirDate = _formatDate(details['last_air_date']?.toString());
    final inProductionRaw = details['in_production'];
    final inProduction = inProductionRaw != null ? (inProductionRaw ? 'Yes' : 'No') : '';
    
    final reviewsData = details['reviews'] is Map ? details['reviews'] as Map : null;
    final reviews = (reviewsData != null && reviewsData['results'] is List ? reviewsData['results'] as List : []).take(10).toList();

    final backgroundImageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/original$backdropPath'
        : (posterPath != null
            ? 'https://image.tmdb.org/t/p/original$posterPath'
            : 'https://via.placeholder.com/1280x720?text=No+Image');

    final String colorHex = _dominantColor != null 
        ? (_dominantColor!.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0') 
        : '1ce783';

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 0.3,
            child: CachedNetworkImage(
              imageUrl: backgroundImageUrl,
              fit: BoxFit.cover,
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Color(0xFF0F1014)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.2, 1.0],
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _showContent ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 800),
            child: SafeArea(
              child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(isMobile ? 20.0 : 40.0, 100.0, isMobile ? 20.0 : 40.0, 40.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: isMobile ? const EdgeInsets.all(16.0) : EdgeInsets.zero,
                    decoration: isMobile ? BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 16,
                          spreadRadius: 4,
                        ),
                      ],
                    ) : const BoxDecoration(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      if (_logoPath != null)
                        CachedNetworkImage(
                          imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                          width: 250,
                          height: 100,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                        )
                      else
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineLarge
                              ?.copyWith(fontWeight: FontWeight.bold, color: Colors.white, height: 1.1, fontSize: isMobile ? 28 : null),
                        ),
                      const SizedBox(height: 16),
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  releaseYear,
                                  style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: isMobile ? 14 : 16,
                                      fontWeight: FontWeight.bold),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.star, color: Color(0xFF1CE783), size: 18),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$voteAverage / 10',
                                      style: TextStyle(color: Colors.white70, fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                if (runtimeStr.isNotEmpty && !isTvShow)
                                  Text(
                                    runtimeStr,
                                    style: TextStyle(color: Colors.white70, fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                  ),
                                if (isTvShow && seasonsStr.isNotEmpty)
                                  Text(
                                    seasonsStr,
                                    style: TextStyle(color: Colors.white70, fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                  ),
                                if (isTvShow && episodesStr.isNotEmpty)
                                  Text(
                                    episodesStr,
                                    style: TextStyle(color: Colors.white70, fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                  ),
                              ],
                            ),
                            if (genres.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                genres,
                                style: TextStyle(color: Colors.white54, fontSize: isMobile ? 12 : 14),
                              ),
                            ],
                            if (isFullyWatched) ...[
                              const SizedBox(height: 12),
                              const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('Watched', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
                                  SizedBox(width: 8),
                                  Icon(Icons.check_circle, color: Color(0xFF1CE783), size: 16),
                                ],
                              ),
                            ],
                            const SizedBox(height: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      SizedBox(
                                        height: 50,
                                        width: isMobile ? double.infinity : null,
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: (!isTvShow && _isCamRelease) ? Colors.red : (_dominantColor ?? Colors.white),
                                            foregroundColor: (!isTvShow && _isCamRelease) ? Colors.white : ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5 ? Colors.white : Colors.black),
                                            padding: const EdgeInsets.symmetric(horizontal: 16),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(4.0),
                                            ),
                                          ),
                                          onPressed: () {
                                            final String progressParam = '&progress=$mainResumeSeconds';
                                            final String placeholderLink = isTvShow 
                                            ? 'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$_selectedEpisode?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                                            : 'https://player.videasy.net/movie/${widget.media['id']}?color=$colorHex&autoPlay=true&overlay=true$progressParam';
                                            
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => VideoPlayerPage(videoUrl: placeholderLink),
                                              ),
                                            );
                                          },
                                          icon: const Icon(Icons.play_arrow, size: 24),
                                          label: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              isTvShow 
                                                  ? ((currentProgress > 0 && currentProgress < 1.0) ? 'Resume S$_selectedSeason E$_selectedEpisode' : 'Play S$_selectedSeason E$_selectedEpisode')
                                                  : ((currentProgress > 0 && currentProgress < 1.0) ? (_isCamRelease ? 'Resume (Cam)' : 'Resume') : (_isCamRelease ? 'Play (Cam)' : 'Play')),
                                              style: TextStyle(fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_trailerKey != null)
                                        SizedBox(
                                          height: 50,
                                          width: isMobile ? double.infinity : null,
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.black,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 16),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(4.0),
                                                side: const BorderSide(color: Colors.white24),
                                              ),
                                            ),
                                            onPressed: () {
                                              showDialog(
                                                context: context,
                                                builder: (context) => TrailerPlayerDialog(trailerKey: _trailerKey!),
                                              );
                                            },
                                            icon: const Icon(Icons.movie_creation_outlined, size: 24),
                                            label: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                'Trailer',
                                                style: TextStyle(fontSize: isMobile ? 14 : 16, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (currentProgress > 0 && currentProgress < 1.0)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12.0),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            mediaResumeStr,
                                            style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: 100,
                                            height: 4,
                                            child: LinearProgressIndicator(
                                              value: currentProgress,
                                              backgroundColor: Colors.white24,
                                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1CE783)),
                                              borderRadius: BorderRadius.circular(2),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                    ],
                  ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    overview,
                    style: TextStyle(
                        color: Colors.white70, fontSize: isMobile ? 14 : 16, height: 1.5),
                  ),
                  const SizedBox(height: 40),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                            Text(
                              'CAST',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            castList.isEmpty
                                ? const Text('Cast information is unavailable.', style: TextStyle(color: Colors.white70))
                                : SizedBox(
                          height: 150,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: castList.length,
                            itemBuilder: (context, index) {
                              final actor = castList[index];
                              if (actor == null || actor is! Map) return const SizedBox.shrink();

                              final profilePath = actor['profile_path']?.toString();
                              final actorImageUrl = profilePath != null
                                  ? 'https://image.tmdb.org/t/p/w200$profilePath'
                                  : 'https://via.placeholder.com/200x300?text=No+Image';
                              final actorName = actor['name']?.toString() ?? 'Unknown';

                              return Container(
                                width: 90,
                                margin: const EdgeInsets.only(right: 12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    ClipOval(
                                      child: CachedNetworkImage(
                                        imageUrl: actorImageUrl,
                                        width: 70,
                                        height: 70,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => Container(width: 70, height: 70, color: Colors.white24),
                                        errorWidget: (context, url, error) => Container(
                                          width: 70,
                                          height: 70,
                                          color: Colors.white24,
                                          child: const Icon(Icons.person, color: Colors.white54),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      actorName,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                            
                            if (isTvShow) ...[
                              const SizedBox(height: 40),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(20.0),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    dropdownColor: const Color(0xFF1E1F24),
                                    icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 18),
                                    value: _selectedSeason,
                                    items: availableSeasons.map((int s) {
                                      double progress = _getSeasonProgress(s, _getEpisodeCountForSeason(s));
                                      Widget? statusIcon;
                                      if (progress >= 1.0) {
                                        statusIcon = const Icon(Icons.check_circle, color: Color(0xFF1CE783), size: 16);
                                      } else if (progress > 0.0) {
                                        statusIcon = const Icon(Icons.brightness_medium, color: Color(0xFF1CE783), size: 16);
                                      }
                                      return DropdownMenuItem<int>(
                                        value: s,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text('Season $s', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                                            if (statusIcon != null) ...[
                                              const SizedBox(width: 8),
                                              statusIcon,
                                            ],
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                    onChanged: (val) {
                                      if (val != null && val != _selectedSeason) {
                                        setState(() {
                                          _selectedSeason = val;
                                          _selectedEpisode = 1;
                                          _visualSelectedEpisode = null;
                                        });
                                        fetchSeasonDetails(val);
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              ListView.builder(
                                padding: EdgeInsets.zero,
                                physics: const NeverScrollableScrollPhysics(),
                                shrinkWrap: true,
                                itemCount: availableEpisodes.length,
                                itemBuilder: (context, index) {
                                  final int val = availableEpisodes[index];
                                  final double progress = _getEpisodeProgress(_selectedSeason, val);
                                  final bool isSelected = val == _visualSelectedEpisode;

                                  String titleText = 'Ep. $val';
                                  int? epRuntime;
                                  String? epOverview;
                                  String? epAirDate;
                                  String? epStillPath;

                                  if (_seasonEpisodesData.containsKey(_selectedSeason)) {
                                    final epList = _seasonEpisodesData[_selectedSeason]!.whereType<Map>().toList();
                                    final epData = epList.firstWhere((e) => (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) == val, orElse: () => <dynamic, dynamic>{});
                                    if (epData.isNotEmpty) {
                                      final name = epData['name']?.toString() ?? '';
                                      if (name.isNotEmpty) titleText = 'Ep. $val - $name';
                                      epRuntime = epData['runtime'];
                                      epOverview = epData['overview']?.toString();
                                      epAirDate = epData['air_date']?.toString();
                                      epStillPath = epData['still_path']?.toString();
                                    }
                                  }

                                  List<Widget> subtitleChildren = [];
                                  if (epRuntime != null && epRuntime > 0) {
                                    final int hrs = epRuntime ~/ 60;
                                    final int mins = epRuntime % 60;
                                    final String durationStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
                                    subtitleChildren.add(Text(durationStr, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)));
                                  }
                                  if (epOverview != null && epOverview.isNotEmpty) {
                                    if (subtitleChildren.isNotEmpty) subtitleChildren.add(const SizedBox(height: 4));
                                    subtitleChildren.add(Text(epOverview, style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 3, overflow: TextOverflow.ellipsis));
                                  }
                                  if (epAirDate != null && epAirDate.isNotEmpty) {
                                    if (subtitleChildren.isNotEmpty) subtitleChildren.add(const SizedBox(height: 4));
                                    subtitleChildren.add(Text('Aired: ${_formatDate(epAirDate)}', style: const TextStyle(color: Colors.white38, fontSize: 11, fontStyle: FontStyle.italic)));
                                  }
                                  
                                  int epResumeSeconds = 0;
                                  if (progress > 0 && progress < 1.0) {
                                    if (subtitleChildren.isNotEmpty) subtitleChildren.add(const SizedBox(height: 6));
                                    final int resumeMins = ((epRuntime ?? 45) * progress).toInt();
                                    epResumeSeconds = ((epRuntime ?? 45) * 60 * progress).toInt();
                                    final int rHr = resumeMins ~/ 60;
                                    final int rMin = resumeMins % 60;
                                    subtitleChildren.add(Text('Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m', style: const TextStyle(color: Color(0xFF1CE783), fontSize: 12, fontWeight: FontWeight.w600)));
                                  }

                                  Widget? subtitleWidget = subtitleChildren.isNotEmpty
                                      ? Padding(padding: const EdgeInsets.only(top: 4.0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: subtitleChildren))
                                      : null;

                                  bool isInteractionActive = false;

                                  return StatefulBuilder(
                                    builder: (context, setItemState) {
                                      return MouseRegion(
                                        onEnter: (_) => setItemState(() => isInteractionActive = true),
                                        onExit: (_) => setItemState(() => isInteractionActive = false),
                                        child: Container(
                                          margin: const EdgeInsets.only(bottom: 12.0),
                                          clipBehavior: Clip.hardEdge,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(8.0),
                                            color: isSelected ? Colors.white.withOpacity(0.05) : const Color(0xFF1E1F24),
                                            border: isSelected ? Border.all(color: const Color(0xFF1CE783).withOpacity(0.5)) : Border.all(color: Colors.white12),
                                          ),
                                          child: InkWell(
                                            onTap: () => setState(() {
                                              _visualSelectedEpisode = val;
                                              _selectedEpisode = val;
                                            }),
                                            onHighlightChanged: (highlighted) {
                                              setItemState(() => isInteractionActive = highlighted);
                                            },
                                            child: Padding(
                                              padding: const EdgeInsets.all(8.0),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                GestureDetector(
                                                  onTap: () {
                                                    setState(() {
                                                      _visualSelectedEpisode = val;
                                                      _selectedEpisode = val;
                                                    });
                                                    final String progressParam = '&progress=$epResumeSeconds';
                                          final String placeholderLink = 'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$val?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam';
                                                    Navigator.push(
                                                      context,
                                                MaterialPageRoute(builder: (context) => VideoPlayerPage(videoUrl: placeholderLink)),
                                                    );
                                                  },
                                                  child: SizedBox(
                                                    width: 150,
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(8.0),
                                                      child: Stack(
                                                        alignment: Alignment.center,
                                                        children: [
                                                          epStillPath != null
                                                              ? AspectRatio(aspectRatio: 16 / 9, child: CachedNetworkImage(imageUrl: 'https://image.tmdb.org/t/p/w500$epStillPath', fit: BoxFit.cover))
                                                              : AspectRatio(aspectRatio: 16 / 9, child: Container(color: Colors.white12, child: const Icon(Icons.tv, color: Colors.white54, size: 24))),
                                                          if (isInteractionActive) ...[
                                                            Positioned.fill(child: Container(color: Colors.black45)),
                                                            const Icon(Icons.play_circle_fill, color: Colors.white, size: 36),
                                                          ],
                                                        ],
                                                      ), // closes Stack
                                                    ), // closes ClipRRect
                                                  ), // closes SizedBox
                                                ), // closes GestureDetector
                                                  Expanded(
                                                    child: Padding(
                                                      padding: const EdgeInsets.only(left: 16.0, right: 8.0),
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          Row(
                                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                            children: [
                                                              Expanded(child: Text(titleText, style: TextStyle(color: isSelected ? const Color(0xFF1CE783) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))),
                                                              const SizedBox(width: 8),
                                                              _buildProgressIndicator(progress),
                                                            ],
                                                          ),
                                                          // ignore: use_null_aware_elements
                                                          if (subtitleWidget != null) subtitleWidget,
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 40),
                            Text(
                              'DETAILS',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            if (isTvShow) ...[
                              _buildDetailRow('Network', networks),
                              _buildDetailRow('Type', type),
                              _buildDetailRow('Status', status),
                              _buildDetailRow('First Aired', firstAirDate),
                              _buildDetailRow('Last Aired', lastAirDate),
                              _buildDetailRow('In Production', inProduction),
                            ] else ...[
                              _buildDetailRow('Status', status),
                              _buildDetailRow('Budget', budget),
                              _buildDetailRow('Revenue', revenue),
                            ],
                            _buildDetailRow('Director', directors),
                            _buildDetailRow('Screenplay', screenplay),
                            _buildDetailRow('Based on', authors),
                            _buildDetailRow('Language', language),

                            if (reviews.isNotEmpty) ...[
                              const SizedBox(height: 40),
                              Text(
                                'TOP REVIEWS',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                    ),
                              ),
                              const SizedBox(height: 16),
                              ListView.builder(
                                padding: EdgeInsets.zero,
                                physics: const NeverScrollableScrollPhysics(),
                                shrinkWrap: true,
                                itemCount: reviews.length,
                                itemBuilder: (context, index) {
                                  final review = reviews[index];
                                  if (review is! Map) return const SizedBox.shrink();
                                  
                                  final author = review['author']?.toString() ?? 'Unknown';
                                  final content = review['content']?.toString() ?? '';
                                  final authorDetails = review['author_details'] is Map ? review['author_details'] as Map : null;
                                  final rating = authorDetails != null ? authorDetails['rating']?.toString() : null;

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 16.0),
                                    padding: const EdgeInsets.all(16.0),
                                    decoration: BoxDecoration(
                                      color: const Color(0x0DFFFFFF), // 5% opacity white
                                      borderRadius: BorderRadius.circular(8.0),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              author,
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                            ),
                                            const Spacer(),
                                            if (rating != null) ...[
                                              const Icon(Icons.star, color: Color(0xFF1CE783), size: 16),
                                              const SizedBox(width: 4),
                                              Text(rating, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                                            ]
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          content,
                                          style: const TextStyle(color: Colors.white70, height: 1.4),
                                          maxLines: 5,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ]
                          ],
                        ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
          ),
          if (!_showContent)
            const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783))),
        ],
      ),
    );
  }
}

class TrailerPlayerDialog extends StatefulWidget {
  final String trailerKey;
  const TrailerPlayerDialog({super.key, required this.trailerKey});

  @override
  State<TrailerPlayerDialog> createState() => _TrailerPlayerDialogState();
}

class _TrailerPlayerDialogState extends State<TrailerPlayerDialog> {
  YoutubePlayerController? _ytController;
  WebViewController? _webController;
  bool _isLoading = true;
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();
    final useWebView = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    
    if (useWebView) {
      _webController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
        ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webController!.platform as dynamic).setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      _webController!
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (mounted) setState(() => _isLoading = false);
              // Inject JS to forcefully click the play button, bypassing WebView autoplay restrictions
              _webController!.runJavaScript('''
                setTimeout(function() {
                try {
                  var doc = document.querySelector('iframe') ? document.querySelector('iframe').contentWindow.document : document;
                  var playBtn = doc.querySelector('.ytp-large-play-button');
                  if (playBtn) playBtn.click();
                  var video = doc.querySelector('video');
                  if (video && video.paused) video.play();
                } catch(e) {}
                }, 800);
              ''');
            },
            onWebResourceError: (error) {
              debugPrint('Webview Resource Error: ${error.description}');
              // Only fallback if the main video page completely fails to load
              if (error.isForMainFrame == true) {
                _fallbackToExternal();
              }
            },
            onHttpError: (error) {
              debugPrint('Webview HTTP Error: ${error.response?.statusCode}');
            },
          ),
        )
      ..loadHtmlString('''
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            body { margin: 0; padding: 0; background-color: black; overflow: hidden; }
            iframe { width: 100vw; height: 100vh; border: none; }
          </style>
        </head>
        <body>
          <iframe 
            src="https://corsproxy.io/?${Uri.encodeComponent('https://www.youtube.com/embed/${widget.trailerKey}?autoplay=1&playsinline=1&origin=http://localhost')}" 
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" 
            allowfullscreen>
          </iframe>
        </body>
        </html>
      ''', baseUrl: 'http://localhost/');
    } else {
      _ytController = YoutubePlayerController.fromVideoId(
        videoId: widget.trailerKey,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
          showVideoAnnotations: false,
        ),
      );
      _isLoading = false;
    }
  }

  Future<void> _fallbackToExternal() async {
    if (!mounted || _hasFailed) return;
    _hasFailed = true;
    setState(() => _isLoading = false);
    final url = Uri.parse('https://www.youtube.com/watch?v=${widget.trailerKey}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ytController?.close();
    if (_webController != null) {
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useWebView = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Dialog(
      backgroundColor: isMobile ? Colors.black.withOpacity(0.95) : Colors.transparent,
      insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Container(
        width: isMobile ? double.infinity : null,
        height: isMobile ? double.infinity : null,
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SafeArea(
              bottom: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (useWebView && !isMobile)
                    TextButton.icon(
                      onPressed: () async {
                        final url = Uri.parse('https://www.youtube.com/watch?v=${widget.trailerKey}');
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      },
                      icon: const Icon(Icons.open_in_browser, color: Colors.white),
                      label: const Text('Watch Externally', style: TextStyle(color: Colors.white)),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 30),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (isMobile) const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(isMobile ? 0 : 12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: useWebView
                    ? Stack(
                        children: [
                          WebViewWidget(controller: _webController!),
                          if (_isLoading)
                            const Center(child: CircularProgressIndicator(color: Color(0xFF1CE783))),
                        ],
                      )
                    : (_ytController != null ? YoutubePlayer(controller: _ytController!) : const SizedBox.shrink()),
              ),
            ),
            if (isMobile) const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  final String? videoUrl;
  const VideoPlayerPage({super.key, this.videoUrl});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  WebViewController? _webViewController;
  Timer? _webPopupTimer;
  // ignore: unused_field
  bool _isControlsVisible = true;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _resetControlsTimer();

    final isNativeWebView = !kIsWeb && (
      defaultTargetPlatform == TargetPlatform.windows || 
      defaultTargetPlatform == TargetPlatform.android || 
      defaultTargetPlatform == TargetPlatform.iOS
    );
    
    if (kIsWeb) {
      registerWebIframe(widget.videoUrl ?? 'about:blank');
      
      // Show a helpful tip on the Web since we cannot natively automate the server switch here
      if (!_hasShownWebPopup) {
        _webPopupTimer = Timer(const Duration(seconds: 10), () {
          if (mounted) {
            _hasShownWebPopup = true;
            final size = MediaQuery.sizeOf(context);
            // Pushes the SnackBar to the top right by creating large bottom and left margins
            final bottomMargin = size.height > 120 ? size.height - 120 : 20.0;
            // Restricts the width to ~350px on desktop, but falls back to full width on mobile
            final leftMargin = size.width > 400 ? size.width - 380 : 24.0;

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                duration: const Duration(seconds: 5),
                behavior: SnackBarBehavior.floating,
                margin: EdgeInsets.only(bottom: bottomMargin, left: leftMargin, right: 24),
                dismissDirection: DismissDirection.horizontal,
                padding: EdgeInsets.zero, // Remove default padding to use our own
                content: ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1F24).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(12.0),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: const Text(
                        'Having issues loading the video?\nTry switching to the Sage server!',
                        style: TextStyle(color: Color(0xFF1CE783), fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        });
      }
    } else if (isNativeWebView) {
      final embedUrl = widget.videoUrl ?? 'about:blank';

      String progressSuffix = '';
      String resumeText = '';
      final match = RegExp(r'&progress=([0-9]+)').firstMatch(embedUrl);
      if (match != null) {
        final pStr = match.group(1) ?? '0';
        final p = int.tryParse(pStr) ?? 0;
        if (p > 0) {
          final int hrs = p ~/ 3600;
          final int mins = (p % 3600) ~/ 60;
          resumeText = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
        }
        progressSuffix = '&t=$pStr&progress=$pStr';
      }

      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('FlutterControls', onMessageReceived: (message) {
          if (message.message == 'hover') {
            _resetControlsTimer();
          } else if (message.message == 'pop') {
            _stopAndPop();
          }
        })
        ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
        ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36');

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webViewController!.platform as dynamic).setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      _webViewController!
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (String url) {
              _resetControlsTimer();
              final isAndroid = defaultTargetPlatform == TargetPlatform.android;
              // Inject JS to neutralize the invisible ad overlays natively.
              // We return a dummy window object to prevent ad scripts from throwing fatal exceptions.
              _webViewController!.runJavaScript('''
                window.open = function() { 
                  return { 
                    closed: false, 
                    close: function() {}, 
                    focus: function() {}, 
                    blur: function() {},
                    postMessage: function() {},
                    location: { href: '' }
                  }; 
                };
                document.addEventListener('click', function(e) {
                  var a = e.target.closest('a');
                  if (a && a.getAttribute('target') === '_blank') {
                    e.preventDefault();
                  }
                }, true);

                // Inject a Native-looking Back Button directly into the DOM to bypass OS Window overlap
                var backBtn = document.createElement('div');
                backBtn.style.position = 'fixed';
                backBtn.style.top = 'calc(env(safe-area-inset-top, 0px) + 4px)';
                backBtn.style.left = 'calc(env(safe-area-inset-left, 0px) + 4px)';
                backBtn.style.width = '48px';
                backBtn.style.height = '48px';
                backBtn.style.borderRadius = '50%';
                backBtn.style.backgroundColor = 'rgba(0, 0, 0, 0.4)';
                backBtn.style.backdropFilter = 'blur(4px)';
                backBtn.style.WebkitBackdropFilter = 'blur(4px)';
                backBtn.style.display = 'flex';
                backBtn.style.alignItems = 'center';
                backBtn.style.justifyContent = 'center';
                backBtn.style.cursor = 'pointer';
                backBtn.style.zIndex = '2147483647';
                backBtn.style.transition = 'opacity 0.3s ease';
                backBtn.style.filter = 'drop-shadow(0px 2px 6px rgba(0,0,0,0.8))';
                backBtn.style.pointerEvents = 'auto';
                backBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>';
                
                function triggerPop(e) {
                  e.preventDefault();
                  e.stopPropagation();
                  if (typeof FlutterControls !== 'undefined') {
                    FlutterControls.postMessage('pop');
                  } else if (window.FlutterControls) {
                    window.FlutterControls.postMessage('pop');
                  }
                }
                backBtn.addEventListener('click', triggerPop, true);
                backBtn.addEventListener('touchstart', triggerPop, true);
                document.body.appendChild(backBtn);
                
                var hideTimeout;
                function resetHideTimer() {
                  if (typeof FlutterControls !== 'undefined') FlutterControls.postMessage('hover');
                  else if (window.FlutterControls) window.FlutterControls.postMessage('hover');
                  if (backBtn) backBtn.style.opacity = '1';
                  clearTimeout(hideTimeout);
                  hideTimeout = setTimeout(function() {
                    if (backBtn) backBtn.style.opacity = '0';
                  }, 3000);
                }
                
                document.addEventListener('mousemove', resetHideTimer, true);
                document.addEventListener('touchstart', resetHideTimer, true);
                resetHideTimer();

                // Wait 1 second, then click the center of the screen
                setTimeout(function() {
                  var x = window.innerWidth / 2;
                  var y = window.innerHeight / 2;
                  var ev = new MouseEvent('click', {
                    view: window, bubbles: true, cancelable: true, clientX: x, clientY: y
                  });
                  var el = document.elementFromPoint(x, y) || document.body;
                  if (el) el.dispatchEvent(ev);

                  // Wait 10 seconds after initial click to check if video playback started successfully
                  setTimeout(function() {
                    var isPlaying = false;
                    var videos = document.querySelectorAll('video');
                    for (var i = 0; i < videos.length; i++) {
                      if (videos[i].currentTime > 0 && !videos[i].paused && !videos[i].ended && videos[i].readyState > 2) {
                        isPlaying = true;
                        break;
                      }
                    }
                    
                    if (!isPlaying) {
                      // Show an injected dialog natively within the webview
                      var dialog = document.createElement('div');
                      dialog.style.position = 'fixed';
                      dialog.style.top = '20px';
                      dialog.style.right = '20px';
                      dialog.style.backgroundColor = '#1E1F24';
                      dialog.style.color = '#fff';
                      dialog.style.padding = '16px 24px';
                      dialog.style.borderRadius = '8px';
                      dialog.style.border = '1px solid rgba(28, 231, 131, 0.5)';
                      dialog.style.boxShadow = '0 4px 12px rgba(0,0,0,0.5)';
                      dialog.style.zIndex = '2147483647';
                      dialog.style.display = 'flex';
                      dialog.style.alignItems = 'center';
                      dialog.style.fontFamily = 'sans-serif';
                      dialog.style.fontSize = '14px';
                      dialog.style.fontWeight = 'bold';
                      dialog.style.pointerEvents = 'auto';
                      
                      if ($isAndroid) {
                        dialog.innerHTML = 'Having issues loading? Try to switch to Sage server instead.';
                        document.body.appendChild(dialog);
                        setTimeout(function() {
                          if (dialog.parentNode) dialog.parentNode.removeChild(dialog);
                        }, 5000);
                      } else {
                        dialog.innerHTML = 'Having issues loading? <button id="switchServerBtn" style="margin-left: 16px; background: #1CE783; color: black; border: none; padding: 8px 16px; border-radius: 4px; font-weight: bold; cursor: pointer;">Switch Server</button> <button id="closeDialogBtn" style="margin-left: 8px; background: transparent; color: white; border: 1px solid rgba(255,255,255,0.3); padding: 8px 16px; border-radius: 4px; cursor: pointer;">Dismiss</button>';
                        document.body.appendChild(dialog);
                        
                        var closeHandler = function(e) {
                          if (e) { e.preventDefault(); e.stopPropagation(); }
                          if (dialog.parentNode) dialog.parentNode.removeChild(dialog);
                        };
                        var closeBtn = document.getElementById('closeDialogBtn');
                        if (closeBtn) {
                          closeBtn.onclick = closeHandler;
                          closeBtn.ontouchstart = closeHandler;
                        }

                        var switchHandled = false;
                        var switchHandler = function(e) {
                          if (e) { e.preventDefault(); e.stopPropagation(); }
                          if (switchHandled) return;
                          switchHandled = true;
                          dialog.innerHTML = '<div style="width:18px;height:18px;border:3px solid #1CE783;border-top:3px solid transparent;border-radius:50%;animation:spin 1s linear infinite;margin-right:12px;"></div> Switching to valid server... <style>@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }</style>';

                      // Actively poll for the Sage server to click it immediately when it renders
                      var sageClicked = false;
                      var automationState = 0; // 0: Click Settings, 1: Click Servers Tab, 2: Wait for Sage
                      var stateStartTime = Date.now();
                      var checkInterval = setInterval(function() {
                        if (sageClicked) return;
                        
                        var now = Date.now();
                        var timeInState = now - stateStartTime;
                        
                        // Give UI animations 500ms to settle before interacting
                        if (timeInState < 500) return;

                        if (automationState === 0) {
                          var clickedSettings = false;
                          try {
                            var exactSelector = 'html body.vc-init div#__next div#videasy-player-wrapper.fixed.inset-0 div.fixed.inset-0.videasy div.flex.w-full.h-full div.videasy-container.relative.top-0.left-0.w-full.h-full.flex.justify-center.items-center.flex-1 div.absolute.bottom-0.left-0.w-full.flex.flex-col.items-stretch.z-10.px-4.md\\\\:px-8.pb-3.pt-6.duration-300.bg-gradient-to-t.from-black\\\\/80.via-black\\\\/40.to-transparent div.relative.flex.items-center.justify-between.mt-2.md\\\\:mt-3 div.flex.items-center.justify-center.space-x-2.md\\\\:space-x-3.ml-auto button.tabbable.p-2.rounded-full.hover\\\\:bg-white\\\\/20.transition-transform.duration-100.flex.items-center.gap-3.active\\\\:scale-110.active\\\\:bg-white\\\\/30.active\\\\:text-white span.text-2xl.flex.items-center.justify-center.w-\\\\[1em\\\\].h-\\\\[1em\\\\] svg';
                            var settingsSvg = document.querySelector(exactSelector);
                            if (!settingsSvg) {
                              settingsSvg = document.querySelector('div#videasy-player-wrapper div.absolute.bottom-0 div.ml-auto button.tabbable svg');
                            }
                            if (settingsSvg) {
                              var settingsBtn = settingsSvg.closest('button');
                              if (settingsBtn && settingsBtn.offsetWidth > 0) {
                                settingsBtn.click();
                                settingsBtn.dispatchEvent(new MouseEvent('mousedown', { view: window, bubbles: true, cancelable: true }));
                                settingsBtn.dispatchEvent(new MouseEvent('mouseup', { view: window, bubbles: true, cancelable: true }));
                                clickedSettings = true;
                              }
                            }
                          } catch(e) {}
                          
                          if (clickedSettings) {
                            automationState = 1;
                            stateStartTime = now;
                          } else if (timeInState > 3000) {
                            stateStartTime = now; // Retry Settings
                          }
                        } 
                        else if (automationState === 1) {
                          var clickedTab = false;
                          var serversTabBtn = document.querySelector('button[id\\\$="-trigger-Servers"]');
                          
                          if (serversTabBtn && serversTabBtn.offsetWidth > 0) {
                            serversTabBtn.click();
                            serversTabBtn.dispatchEvent(new MouseEvent('mousedown', { view: window, bubbles: true, cancelable: true }));
                            serversTabBtn.dispatchEvent(new MouseEvent('mouseup', { view: window, bubbles: true, cancelable: true }));
                            clickedTab = true;
                          } else {
                            var menuElements = document.querySelectorAll('button, div, span, li, a');
                            for (var i = 0; i < menuElements.length; i++) {
                              var txt = (menuElements[i].textContent || '').trim().toLowerCase();
                              if (txt === 'servers' || txt === 'server') {
                                if (menuElements[i].offsetWidth > 0) {
                                  menuElements[i].click();
                                  menuElements[i].dispatchEvent(new MouseEvent('mousedown', { view: window, bubbles: true, cancelable: true }));
                                  menuElements[i].dispatchEvent(new MouseEvent('mouseup', { view: window, bubbles: true, cancelable: true }));
                                  clickedTab = true;
                                  break;
                                }
                              }
                            }
                          }
                          
                          if (clickedTab) {
                            automationState = 2;
                            stateStartTime = now;
                          } else if (timeInState > 3000) {
                            automationState = 0; // Menu probably closed, restart sequence
                            stateStartTime = now;
                          }
                        } 
                        else if (automationState === 2) {
                          var clickedSage = false;
                          var btn = null;
                          try {
                            var serversContent = document.querySelector('div[id\\\$="-content-Servers"]');
                            if (serversContent) {
                              var buttons = serversContent.querySelectorAll('button');
                              for (var i = 0; i < buttons.length; i++) {
                                if (buttons[i].textContent && buttons[i].textContent.trim().toLowerCase() === 'sage') {
                                  btn = buttons[i];
                                  break;
                                }
                              }
                            }
                            
                            if (!btn) {
                              var xpath = '/html/body/div/div[2]/div/div/div/div[5]/div/div[2]/div/div/div[3]/div/button[4]';
                              var result = document.evaluate(xpath, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                              btn = result.singleNodeValue;
                            }
                          } catch(e) {}
                          
                          if (!btn) {
                            var elements = document.querySelectorAll('button, div, span, li, a');
                            for (var i = 0; i < elements.length; i++) {
                              if (elements[i].textContent && elements[i].textContent.trim().toLowerCase() === 'sage') {
                                btn = elements[i];
                                break;
                              }
                            }
                          }

                          if (btn && btn.offsetWidth > 0 && btn.offsetHeight > 0) {
                            btn.click();
                            btn.dispatchEvent(new MouseEvent('mousedown', { view: window, bubbles: true, cancelable: true }));
                            btn.dispatchEvent(new MouseEvent('mouseup', { view: window, bubbles: true, cancelable: true }));
                            clickedSage = true;
                          }
                          
                          if (clickedSage) {
                            sageClicked = true;
                            clearInterval(checkInterval);
                            
                            setTimeout(function() {
                              var cx = window.innerWidth / 2;
                              var cy = window.innerHeight / 2;
                              var cev = new MouseEvent('click', { view: window, bubbles: true, cancelable: true, clientX: cx, clientY: cy });
                              var cel = document.elementFromPoint(cx, cy) || document.body;
                              if (cel) cel.dispatchEvent(cev);

                              if (dialog.parentNode) dialog.parentNode.removeChild(dialog);
                              
                              var resText = '$resumeText';
                              if (resText) {
                                var resDialog = document.createElement('div');
                                resDialog.style.position = 'fixed';
                                resDialog.style.top = '20px';
                                resDialog.style.right = '20px';
                                resDialog.style.backgroundColor = '#1E1F24';
                                resDialog.style.color = '#fff';
                                resDialog.style.padding = '16px 24px';
                                resDialog.style.borderRadius = '8px';
                                resDialog.style.border = '1px solid rgba(28, 231, 131, 0.5)';
                                resDialog.style.boxShadow = '0 4px 12px rgba(0,0,0,0.5)';
                                resDialog.style.zIndex = '2147483647';
                                resDialog.style.fontFamily = 'sans-serif';
                                resDialog.style.fontSize = '14px';
                                resDialog.style.transition = 'opacity 0.5s ease';
                                resDialog.innerHTML = 'To resume, seek to <strong style="color:#1CE783;">' + resText + '</strong>';
                                document.body.appendChild(resDialog);
                                
                                setTimeout(function() {
                                  if (resDialog) resDialog.style.opacity = '0';
                                  setTimeout(function() {
                                    if (resDialog && resDialog.parentNode) resDialog.parentNode.removeChild(resDialog);
                                  }, 500);
                                }, 8000);
                              }
                              
                              var suffix = '$progressSuffix';
                              if (suffix) {
                                setTimeout(function() {
                                  var frames = document.querySelectorAll('iframe');
                                  for (var i = 0; i < frames.length; i++) {
                                    var src = frames[i].src;
                                    if (src && src.startsWith('http') && !src.includes('progress=')) {
                                      frames[i].src = src + suffix;
                                    }
                                  }
                                }, 1000);
                              }
                            }, 1000);
                          } else if (timeInState > 4000) {
                            automationState = 0; // Restart sequence
                            stateStartTime = now;
                          }
                        }
                      }, 500);

                      // Stop polling after 25 seconds to prevent memory leaks
                      setTimeout(function() { 
                        clearInterval(checkInterval); 
                        if (dialog.parentNode) dialog.parentNode.removeChild(dialog);
                      }, 25000);
                      };
                      
                      var switchBtn = document.getElementById('switchServerBtn');
                      if (switchBtn) {
                        switchBtn.onclick = switchHandler;
                        switchBtn.ontouchstart = switchHandler;
                      }
                      }
                    }
                  }, 10000);
                }, 1000);
              ''');
            },
          ),
        )
        ..loadRequest(Uri.parse(embedUrl));
    }
  }

  void _resetControlsTimer() {
    if (!mounted) return;
    setState(() {
      _isControlsVisible = true;
    });
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isControlsVisible = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _webPopupTimer?.cancel();
    _controlsTimer?.cancel();
    super.dispose();
  }

  Future<void> _stopAndPop() async {
    if (_webViewController != null) {
      // Load a blank page instantly to cut off playing audio before popping
      _webViewController!.loadRequest(Uri.parse('about:blank'));
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNativeWebView = !kIsWeb && (
      defaultTargetPlatform == TargetPlatform.windows || 
      defaultTargetPlatform == TargetPlatform.android || 
      defaultTargetPlatform == TargetPlatform.iOS
    );

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _stopAndPop();
      },
      child: MouseRegion(
        onHover: (_) => _resetControlsTimer(),
        child: GestureDetector(
          onTap: _resetControlsTimer,
          behavior: HitTestBehavior.translucent,
          child: Scaffold(
            backgroundColor: Colors.black,
            extendBodyBehindAppBar: isNativeWebView,
            appBar: isNativeWebView ? null : AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _stopAndPop,
              ),
            ),
            body: kIsWeb
                ? buildWebIframe(widget.videoUrl ?? 'about:blank')
                : isNativeWebView
                ? WebViewWidget(controller: _webViewController!)
                : const Center(
                    child: Text(
                      'Webview only supported on Windows, Android, and iOS in this configuration.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
