// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:video_player/video_player.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages, unnecessary_import
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart' as gsi;
// ignore: unused_import
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import 'firebase_options.dart';
import 'live_tv_page.dart';
import 'schedule_guide_page.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'web_player_stub.dart' if (dart.library.html) 'web_player.dart';
// ignore: unused_import
import 'web_button_stub.dart' if (dart.library.html) 'web_button.dart';
import 'download_manager.dart';

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

bool _isReleased(dynamic item, {bool strictFilter = false}) {
  if (item is! Map) return false;

  // Filter out explicit adult content globally
  if (item['adult'] == true || item['adult'] == 'true') {
    return false;
  }

  if (strictFilter) {
    // Hide documentaries (Genre ID 99) from general browsing/home pages
    if (item['genre_ids'] is List && (item['genre_ids'] as List).contains(99)) {
      return false;
    }

    final originalLanguage = item['original_language']?.toString();
    if (originalLanguage != null && originalLanguage != 'en') {
      final originCountry = item['origin_country'];
      bool isUS = false;
      if (originCountry is List) {
        isUS = originCountry.contains('US');
      } else if (originCountry is String) {
        isUS = originCountry == 'US';
      }
      if (!isUS) {
        final voteCount = (item['vote_count'] as num?)?.toInt() ?? 0;
        final popularity = (item['popularity'] as num?)?.toDouble() ?? 0.0;
        if (voteCount < 200 && popularity < 50.0) {
          return false;
        }
      }
    }
  }

  final voteAverageRaw = item['vote_average'];
  if (voteAverageRaw != null) {
    final voteAverage = double.tryParse(voteAverageRaw.toString()) ?? 0.0;
    if (voteAverage == 0.0) return false;
  }

  final mediaType = item['media_type'];
  final isMovie =
      mediaType == 'movie' ||
      (mediaType == null &&
          item.containsKey('title') &&
          item.containsKey('release_date'));

  if (isMovie) {
    // Filter out short films (< 20 mins) if runtime data is present
    final runtimeRaw = item['runtime'];
    if (runtimeRaw != null) {
      final runtime = double.tryParse(runtimeRaw.toString()) ?? 0.0;
      if (runtime > 0 && runtime < 20) return false;
    }

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

    // Override the default ffmpeg-kit log callback with an empty one.
    // This prevents a FileSystemException crash on iOS when the app tries to write
    // logs to a non-existent path.
    FFmpegKitConfig.enableLogCallback((log) {});

    // Set preferred orientation to portrait on app startup for mobile.
    // This ensures the app doesn't start in landscape if it was closed
    // while a video was playing.
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }

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
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Text(
                'Failed to launch:\n\n$e',
                style: const TextStyle(color: Colors.red, fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
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
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF1CE783)),
            ),
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
        const SnackBar(
          content: Text('Please enter both email and password.'),
          backgroundColor: Colors.red,
        ),
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
        if (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux)) {
          errorMessage =
              'Invalid email or password. (If you created this account with Google/Microsoft, please use those buttons).';
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
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux)) {
        // --- NATIVE DESKTOP LOOPBACK WORKAROUND ---

        // You MUST create a "Desktop app" OAuth Client ID in Google Cloud Console
        const String clientId =
            '651005734001-e060vcsc7hslmcb4joemh194ms4vits1.apps.googleusercontent.com';
        const String clientSecret = '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';

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final redirectUri = 'http://localhost:${server.port}';

        final authUrl =
            'https://accounts.google.com/o/oauth2/v2/auth'
            '?client_id=$clientId'
            '&response_type=code'
            '&redirect_uri=$redirectUri'
            '&scope=openid%20email%20profile';

        if (defaultTargetPlatform == TargetPlatform.windows) {
          await Process.run('cmd', [
            '/c',
            'start',
            authUrl.replaceAll('&', '^&'),
          ]);
        } else {
          await Process.run('xdg-open', [authUrl]);
        }

        try {
          final request = await server.first.timeout(
            const Duration(minutes: 3),
          );
          final code = request.uri.queryParameters['code'];

          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><body style="background:#0F1014;color:#1CE783;text-align:center;margin-top:20%;font-family:sans-serif;"><h2>Login successful! You can close this window and return to CineStream.</h2><script>window.close();</script></body></html>',
            );
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
              throw Exception(
                'Failed to exchange token: ${tokenResponse.body}',
              );
            }
          } else {
            throw Exception('No authorization code received.');
          }
        } on TimeoutException {
          throw Exception(
            'Sign-in timed out or was cancelled. Please try again.',
          );
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
            serverClientId:
                '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
          );
          try {
            await gsi.GoogleSignIn.instance.initialize(
              serverClientId:
                  '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
            );
          } catch (_) {}
          _isGoogleSignInInitialized = true;
        }

        // ignore: unnecessary_nullable_for_final_variable_declarations
        final gsi.GoogleSignInAccount? googleUser = await gsi
            .GoogleSignIn
            .instance
            .authenticate();

        if (googleUser == null) {
          // User cancelled the sign-in.
          return;
        }

        final gsi.GoogleSignInAuthentication googleAuth =
            googleUser.authentication; // Synchronous in v7+
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        await FirebaseAuth.instance.signInWithCredential(credential);
      }
    } catch (e) {
      if (e is FirebaseAuthException &&
          e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        // Don't show an error if the user just cancelled the login flow.
        final isCancellation =
            e is FirebaseAuthException &&
            (e.code == 'web-context-cancelled' ||
                e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            String errorMessage = e.toString();
            if (e is FirebaseAuthException && e.code == 'internal-error') {
              errorMessage =
                  'Internal Error: Ensure your Desktop Client ID is added to the "Whitelisted client IDs" in Firebase Console under Google Sign-In.';
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(errorMessage),
                backgroundColor: Colors.red,
              ),
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
        final userCred = await FirebaseAuth.instance.signInWithPopup(
          microsoftProvider,
        );
        final credential = userCred.credential;
        final token = credential is OAuthCredential
            ? credential.accessToken
            : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      } else {
        final microsoftProvider = OAuthProvider('microsoft.com');
        microsoftProvider.addScope('User.Read');
        final userCred = await FirebaseAuth.instance.signInWithProvider(
          microsoftProvider,
        );
        final credential = userCred.credential;
        final token = credential is OAuthCredential
            ? credential.accessToken
            : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      }
    } catch (e) {
      if (e is FirebaseAuthException &&
          e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        final isCancellation =
            e is FirebaseAuthException &&
            (e.code == 'web-context-cancelled' ||
                e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            String errorMessage = e.toString();
            if (e is FirebaseAuthException && e.code == 'internal-error') {
              errorMessage =
                  'Internal Error: Ensure Microsoft Sign-In is enabled in Firebase Console with your Client ID & Secret.';
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(errorMessage),
                backgroundColor: Colors.red,
              ),
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
        await user.updatePhotoURL(
          'data:${response.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data',
        );
      } else {
        // Fallback to default photo endpoint if the user's account doesn't support explicit resizing
        final fallback = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/photo/\$value'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (fallback.statusCode == 200) {
          final base64Data = base64Encode(fallback.bodyBytes);
          await user.updatePhotoURL(
            'data:${fallback.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data',
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch Microsoft photo: $e');
    }
  }

  Future<void> _handleAccountLinking(
    AuthCredential? credential,
    String? email,
  ) async {
    if (credential == null || email == null || !mounted) return;

    final password = await _promptForPassword(email);
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _isLoading = true);
    try {
      // Sign in with email and password to verify user
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);

      // Link the new (social) credential
      await userCredential.user?.linkWithCredential(credential);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Successfully linked account!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on FirebaseAuthException catch (authError) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to link: ${authError.message}'),
            backgroundColor: Colors.red,
          ),
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
          title: const Text(
            'Link Account',
            style: TextStyle(color: Colors.white),
          ),
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
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1CE783)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1CE783),
                foregroundColor: Colors.black,
              ),
              onPressed: () =>
                  Navigator.of(context).pop(passwordController.text.trim()),
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
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1CE783)),
                  ),
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
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1CE783)),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              if (_isLoading)
                const CircularProgressIndicator(color: Color(0xFF1CE783))
              else ...[
                defaultTargetPlatform == TargetPlatform.iOS
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            height: 50,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: const Color(0xFF1CE783),
                              ),
                              onPressed: () => _authenticate(false),
                              child: const Text(
                                'Sign In',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1CE783),
                          foregroundColor: Colors.black,
                          minimumSize: const Size.fromHeight(50),
                        ),
                        onPressed: () => _authenticate(false),
                        child: const Text(
                          'Sign In',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => _authenticate(true),
                  child: const Text(
                    'Create Account',
                    style: TextStyle(color: Color(0xFF1CE783)),
                  ),
                ),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(child: Divider(color: Colors.white24)),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'OR',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.white24)),
                  ],
                ),
                const SizedBox(height: 24),
                defaultTargetPlatform == TargetPlatform.iOS
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            height: 50,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.15),
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide.none,
                              ),
                              onPressed: _signInWithGoogle,
                              icon: Image.network(
                                'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                                height: 24,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.account_circle, size: 24),
                              ),
                              label: const Text(
                                'Sign in with Google',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(50),
                          side: const BorderSide(color: Colors.white54),
                        ),
                        onPressed: _signInWithGoogle,
                        icon: Image.network(
                          'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                          height: 24,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(Icons.account_circle, size: 24),
                        ),
                        label: const Text(
                          'Sign in with Google',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                if (kIsWeb ||
                    (defaultTargetPlatform != TargetPlatform.windows &&
                        defaultTargetPlatform != TargetPlatform.linux)) ...[
                  const SizedBox(height: 16),
                  defaultTargetPlatform == TargetPlatform.iOS
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                            child: Container(
                              height: 50,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.05),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.15),
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: BorderSide.none,
                                ),
                                onPressed: _signInWithMicrosoft,
                                icon: Image.network(
                                  'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                                  height: 24,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(Icons.window, size: 24),
                                ),
                                label: const Text(
                                  'Sign in with Microsoft',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(color: Colors.white54),
                          ),
                          onPressed: _signInWithMicrosoft,
                          icon: Image.network(
                            'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                            height: 24,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.window, size: 24),
                          ),
                          label: const Text(
                            'Sign in with Microsoft',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
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

class SearchBody extends StatelessWidget {
  final List<dynamic> results;
  final List<dynamic> recentSearches;
  final bool isLoading;
  final Function(dynamic) onResultTapped;
  final String searchQuery;

  const SearchBody({
    super.key,
    required this.results,
    required this.recentSearches,
    required this.isLoading,
    required this.onResultTapped,
    required this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add padding for the transparent app bar at the top
        SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top),
        if (searchQuery.isEmpty && recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: HorizontalMediaList(
              categoryTitle: 'Recent',
              items: recentSearches,
            ),
          ),
        Expanded(
          child: isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF1CE783)),
                )
              : results.isEmpty
              ? Center(
                  child: Text(
                    searchQuery.isEmpty
                        ? 'Search for movies and TV shows.'
                        : 'No results found.',
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160.0,
                    childAspectRatio: 2 / 3,
                    crossAxisSpacing: 12.0,
                    mainAxisSpacing: 12.0,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final media = results[index];
                    final posterPath = media['poster_path'];
                    final imageUrl = posterPath != null
                        ? 'https://image.tmdb.org/t/p/w500$posterPath'
                        : 'https://via.placeholder.com/500x750?text=No+Image';
                    final heroTag =
                        'search_${media['media_type']}_${media['id']}_$index';
                    return GestureDetector(
                      onTap: () {
                        onResultTapped(media);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => MediaDetailsPage(
                              media: media,
                              heroTag: heroTag,
                            ),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: Hero(
                          tag: heroTag,
                          child: CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            placeholder: (context, url) =>
                                Container(color: Colors.black26),
                            errorWidget: (context, url, error) => Container(
                              color: Colors.black26,
                              child: const Icon(
                                Icons.broken_image,
                                color: Colors.white54,
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

class LocalVideoPlayerPage extends StatefulWidget {
  final File videoFile;
  const LocalVideoPlayerPage({super.key, required this.videoFile});

  @override
  State<LocalVideoPlayerPage> createState() => _LocalVideoPlayerPageState();
}

class _LocalVideoPlayerPageState extends State<LocalVideoPlayerPage> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _isControlsVisible = true;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controller = VideoPlayerController.file(widget.videoFile)
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _isInitialized = true);
          _controller.play();
          _resetControlsTimer();
        }
      });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (mounted) {
      setState(() => _isControlsVisible = true);
      _controlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isControlsVisible = false);
      });
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controlsTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _isInitialized
            ? GestureDetector(
                onTap: _resetControlsTimer,
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: <Widget>[
                      VideoPlayer(_controller),
                      AnimatedOpacity(
                        opacity: _isControlsVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: Container(
                          color: Colors.black26,
                          child: Stack(
                            children: [
                              Center(
                                child: IconButton(
                                  iconSize: 64,
                                  color: Colors.white,
                                  icon: Icon(
                                    _controller.value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _controller.value.isPlaying
                                          ? _controller.pause()
                                          : _controller.play();
                                    });
                                    _resetControlsTimer();
                                  },
                                ),
                              ),
                              Positioned(
                                top: 20,
                                left: 20,
                                child: SafeArea(
                                  child: IconButton(
                                    icon: const Icon(Icons.arrow_back,
                                        color: Colors.white),
                                    onPressed: () => Navigator.of(context).pop(),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: VideoProgressIndicator(
                                  _controller,
                                  allowScrubbing: true,
                                  padding: const EdgeInsets.all(10),
                                  colors: const VideoProgressColors(
                                    playedColor: Color(0xFF1CE783),
                                    bufferedColor: Colors.white54,
                                    backgroundColor: Colors.white24,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : const CircularProgressIndicator(color: Color(0xFF1CE783)),
      ),
    );
  }
}

class DownloadedItemWidget extends StatefulWidget {
  final AssetEntity asset;
  const DownloadedItemWidget({super.key, required this.asset});

  @override
  State<DownloadedItemWidget> createState() => _DownloadedItemWidgetState();
}

class _DownloadedItemWidgetState extends State<DownloadedItemWidget> {
  Uint8List? _thumbnailData;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final data = await widget.asset.thumbnailDataWithSize(
      const ThumbnailSize(200, 300),
    );
    if (mounted) {
      setState(() {
        _thumbnailData = data;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String title = 'Unknown';
    final filename = widget.asset.title ?? '';
    if (filename.contains('+')) {
      title = filename.split('+').sublist(1).join(' ').replaceAll('_', ' ');
      if (title.toLowerCase().endsWith('.mp4')) {
        title = title.substring(0, title.length - 4);
      }
    }

    return GestureDetector(
      onTap: () async {
        final file = await widget.asset.file;
        if (file != null && context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => LocalVideoPlayerPage(videoFile: file),
            ),
          );
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: GridTile(
          footer: GridTileBar(
            backgroundColor: Colors.black54,
            title: Text(
              title,
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
            ),
          ),
          child: Container(
            color: Colors.black26,
            child: _thumbnailData != null
                ? Image.memory(_thumbnailData!, fit: BoxFit.cover)
                : const SizedBox(),
          ),
        ),
      ),
    );
  }
}

class MyStuffSheet extends StatefulWidget {
  const MyStuffSheet({super.key});

  @override
  State<MyStuffSheet> createState() => _MyStuffSheetState();
}

class _MyStuffSheetState extends State<MyStuffSheet> {
  List<AssetEntity> _downloads = [];
  bool _isLoadingDownloads = true;

  @override
  void initState() {
    super.initState();
    _fetchDownloads();
  }

  Future<void> _fetchDownloads() async {
    try {
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (ps.isAuth || ps.hasAccess) {
        final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
          type: RequestType.video,
        );
        AssetPathEntity? cineStreamAlbum;
        for (final path in paths) {
          if (path.name == 'CineStream') {
            cineStreamAlbum = path;
            break;
          }
        }

        if (cineStreamAlbum != null) {
          final List<AssetEntity> assets =
              await cineStreamAlbum.getAssetListPaged(
            page: 0,
            size: 50,
          );
          if (mounted) {
            setState(() {
              _downloads = assets;
              _isLoadingDownloads = false;
            });
          }
        } else {
          if (mounted) setState(() => _isLoadingDownloads = false);
        }
      } else {
        if (mounted) {
          setState(() => _isLoadingDownloads = false);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingDownloads = false);
      debugPrint("Error fetching downloads: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final screenHeight = MediaQuery.of(context).size.height;
    // Calculate max size to stop just below the AppBar, leaving it visible.
    final maxChildSize =
        (screenHeight - topPadding - kToolbarHeight - 10) / screenHeight;

    return DraggableScrollableSheet(
      initialChildSize: maxChildSize, // Start nearly full screen
      minChildSize: 0.5,
      maxChildSize: maxChildSize,
      builder: (BuildContext context, ScrollController scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E1F24),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 10, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'My Stuff',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      onPressed: () {
                        // Close the sheet first
                        Navigator.of(context).pop();
                        // Then navigate to settings
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const SettingsPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      if (_isLoadingDownloads)
                        const Center(
                            child: Padding(
                          padding: EdgeInsets.all(32.0),
                          child: CircularProgressIndicator(
                              color: Color(0xFF1CE783)),
                        ))
                      else if (_downloads.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32.0),
                            child: Text(
                              'Your downloaded movies and shows will appear here.',
                              style:
                                  TextStyle(color: Colors.white54, fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16.0),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160.0,
                            childAspectRatio: 2 / 3,
                            crossAxisSpacing: 12.0,
                            mainAxisSpacing: 12.0,
                          ),
                          itemCount: _downloads.length,
                          itemBuilder: (context, index) {
                            final asset = _downloads[index];
                            return DownloadedItemWidget(asset: asset);
                          },
                        ),
                    ]),
              ),
            ],
          ),
        );
      },
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
  String _liveTvMode = 'live';
  int _selectedIndex = 0;
  bool _isMuted = true;
  bool _isSearchActive = false;

  // --- State lifted from SearchBody ---
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  final List<dynamic> _recentSearches = [];
  bool _isLoadingSearch = false;
  Timer? _searchDebounce;
  double _maxKeyboardHeight = 0.0;


  @override
  void initState() {
    super.initState();
    fetchTrending();
    _loadRecentSearches();
    // Listen for global download messages
    DownloadManager().messages.listen((message) {
      if (mounted && message.isNotEmpty) {
        final parts = message.split(':');
        final type = parts.first;
        final content = parts.sublist(1).join(':');
        Color backgroundColor;
        switch (type) {
          case 'SUCCESS':
            backgroundColor = Colors.green;
            break;
          case 'ERROR':
            backgroundColor = Colors.red;
            break;
          default:
            backgroundColor = Colors.blue;
            break;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(content), backgroundColor: backgroundColor),
        );
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // --- Methods lifted from SearchBody ---
  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('recentSearches');
    if (saved != null && mounted) {
      setState(() {
        _recentSearches.clear();
        _recentSearches.addAll(saved.map((e) => json.decode(e)));
      });
    }
  }

  Future<void> _saveRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final serialized = _recentSearches.map((e) => json.encode(e)).toList();
    await prefs.setStringList('recentSearches', serialized);
  }

  void _onSearchChanged(String query) {
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (query.trim().isNotEmpty) {
        _performSearch(query.trim());
      } else {
        setState(() {
          _searchResults = [];
          _isLoadingSearch = false;
        });
      }
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isLoadingSearch = true);
    try {
      final url =
          'https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=${Uri.encodeComponent(query)}';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          _searchResults = (data['results'] as List)
              .where(
                (item) => item['media_type'] != 'person' && _isReleased(item),
              )
              .toList();
          _isLoadingSearch = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingSearch = false);
    }
  }

  Future<void> fetchTrending() async {
    try {
      final url =
          'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          final rawList = data['results'] as List? ?? [];
          mediaList = rawList
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  void _handleResultTapped(dynamic media) {
    setState(() {
      _recentSearches.removeWhere((item) => item['id'] == media['id']);
      _recentSearches.insert(0, media);
      if (_recentSearches.length > 20) {
        _recentSearches.removeLast();
      }
    });
    _saveRecentSearches();
  }

  // --- UI Builder Methods for Animated Bottom Bar ---

  Widget _buildNavBarContainer({required Widget child, bool isCircle = false}) {
    final borderRadius = isCircle ? 28.0 : 40.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40.0, sigmaY: 40.0),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.15),
                Colors.white.withOpacity(0.03),
                Colors.white.withOpacity(0.03),
                Colors.white.withOpacity(0.1),
              ],
              stops: const [0.0, 0.2, 0.8, 1.0],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 1.0,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSearchIcon() {
    return IconButton(
      key: const ValueKey('search_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: const Icon(Icons.search, color: Colors.white, size: 28),
          ),
        ),
      ),
      onPressed: () {
        setState(() {
          _selectedIndex = 3;
          _isSearchActive = true;
        });
      },
    );
  }

  Widget _buildSearchBar() {
    return _buildNavBarContainer(
      child: Center(
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, child) {
            return TextField(
              key: const ValueKey('search_field'),
              controller: _searchController,
              autofocus: false,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: 'Search movies, shows...',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: Container(
                  width: 48,
                  alignment: Alignment.center,
                  child: const Icon(Icons.search, color: Colors.white54),
                ),
                suffixIcon: value.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white54),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : const SizedBox(width: 48),
                border: InputBorder.none,
              ),
              onChanged: _onSearchChanged,
            );
          },
        ),
      ),
    );
  }

  Widget _buildCloseKeyboardIcon() {
    return IconButton(
      key: const ValueKey('close_keyboard_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: const Icon(Icons.close, color: Colors.white, size: 28),
          ),
        ),
      ),
      onPressed: () => FocusScope.of(context).unfocus(),
    );
  }

  Widget _buildLiveTvModeSwitcher() {
    final itemValues = ['live', 'schedule'];
    final selectedIndex = itemValues.indexOf(_liveTvMode);
    const double itemWidth = 80.0;
    const double switcherWidth = itemWidth * 2;
    const double switcherHeight = 56.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(40.0),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40.0, sigmaY: 40.0),
        child: Container(
          width: switcherWidth,
          height: switcherHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.15),
                Colors.white.withOpacity(0.03),
                Colors.white.withOpacity(0.03),
                Colors.white.withOpacity(0.1),
              ],
              stops: const [0.0, 0.2, 0.8, 1.0],
            ),
            borderRadius: BorderRadius.circular(40.0),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 1.0,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Sliding glass indicator
              AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                left: (selectedIndex * itemWidth),
                top: 0,
                width: itemWidth,
                height: switcherHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(switcherHeight / 2),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius:
                            BorderRadius.circular(switcherHeight / 2),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Icons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLiveTvSwitcherItem(Icons.live_tv, 'live', selectedIndex == 0),
                  _buildLiveTvSwitcherItem(
                      Icons.calendar_today, 'schedule', selectedIndex == 1),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveTvSwitcherItem(IconData icon, String value, bool isSelected) {
    const double itemWidth = 80.0;
    return GestureDetector(
      onTap: () => setState(() => _liveTvMode = value),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: itemWidth,
        height: 56.0,
        child: Center(
          child: AnimatedScale(
            scale: isSelected ? 1.1 : 1.0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            child: Icon(
              icon,
              color: isSelected ? Colors.white : Colors.white70,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    // ignore: unused_local_variable
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardHeight == 0) {
      // Reset max height when keyboard is closed to handle orientation/keyboard changes
      _maxKeyboardHeight = 0.0;
    } else if (keyboardHeight > _maxKeyboardHeight) {
      _maxKeyboardHeight = keyboardHeight;
    }
    final keyboardAnimationProgress =
        (_maxKeyboardHeight > 0 ? (keyboardHeight / _maxKeyboardHeight) : 0.0)
            .clamp(0.0, 1.0);
    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!);
      }
    }

    String appBarTitle = '';
    switch (_selectedIndex) {
      case 0:
        appBarTitle = 'CineStream';
        break;
      case 1:
        appBarTitle = 'Movies';
        break;
      case 2:
        appBarTitle = 'TV Shows';
        break;
      case 3:
        appBarTitle =
            'Search'; // This will now be triggered by the new app bar button
        break;
      case 4:
        appBarTitle = 'Live TV';
        break;
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: _selectedIndex == 4
            ? _buildLiveTvModeSwitcher()
            : ClipRRect(
                borderRadius: BorderRadius.circular(28.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16.0, vertical: 8.0),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(28.0),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Text(
                      appBarTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
        actionsPadding: const EdgeInsets.only(right: 16.0),
        actions: [
          if (_selectedIndex <= 2)
            IconButton(
              iconSize: 52,
              padding: EdgeInsets.zero,
              icon: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Icon(
                      _isMuted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
              onPressed: () {
                setState(() {
                  _isMuted = !_isMuted;
                });
              },
            ),
          if (_selectedIndex <= 2) const SizedBox(width: 12.0),
          IconButton(
            iconSize: 52,
            padding: EdgeInsets.zero,
            icon: Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: ClipOval(
                child: profileImage == null
                    ? Container(
                        color: Colors.white24,
                        child: const Icon(
                          Icons.person,
                          size: 28,
                          color: Colors.white,
                        ),
                      )
                    : Image(image: profileImage, fit: BoxFit.cover),
              ),
            ),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => const MyStuffSheet(),
              );
            },
          ),
        ],
      ),
      body: RepaintBoundary(
        child: _selectedIndex == 0
            ? (isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Color(0xFF1CE783)),
                    )
                  : SingleChildScrollView(
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (mediaList.isNotEmpty)
                            FeaturedMediaItem(
                              mediaList: mediaList.take(5).toList(),
                              isMuted: _isMuted,
                            ),
                          const SizedBox(height: 20),
                          HorizontalMediaList(
                            categoryTitle: 'Trending Now',
                            items: mediaList.skip(5).toList(),
                          ),
                          const SizedBox(height: 16),
                          // Simulating another category visually by reversing the list
                          HorizontalMediaList(
                            categoryTitle: 'Because You Watched',
                            items: mediaList.reversed.toList(),
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ))
            : _selectedIndex == 1
            ? MediaCategoryBody(
                key: const ValueKey('movie'),
                mediaType: 'movie',
                isMuted: _isMuted,
              )
            : _selectedIndex == 2
            ? MediaCategoryBody(
                key: const ValueKey('tv'),
                mediaType: 'tv',
                isMuted: _isMuted,
              )
            : _selectedIndex == 3
            ? SearchBody(
                results: _searchResults,
                recentSearches: _recentSearches,
                isLoading: _isLoadingSearch,
                onResultTapped: _handleResultTapped,
                searchQuery: _searchController.text,
              )
            : _selectedIndex == 4
            ? (_liveTvMode == 'live'
                ? const LiveTVPage()
                : const ScheduleGuidePage())
            : const SizedBox.shrink(),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: defaultTargetPlatform == TargetPlatform.iOS
            ? LayoutBuilder(builder: (context, constraints) {
                final safeAreaHorizontalPadding =
                    MediaQuery.of(context).padding.left +
                        MediaQuery.of(context).padding.right;
                final containerMargin = 16.0 * 2;
                final availableWidth =
                    constraints.maxWidth - safeAreaHorizontalPadding - containerMargin;

                final searchIconWidth = 56.0;
                final spacing = 12.0;
                final homeIconWidth = 56.0;
                final closeButtonWidth = 56.0;

                final expandedNavBarWidth = availableWidth - searchIconWidth - spacing;
                final collapsedNavBarWidth = homeIconWidth;

                final searchBarLeft = collapsedNavBarWidth + spacing;

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16.0)
                      .copyWith(bottom: 16.0),
                  height: 56,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Main Nav Bar
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        left: 0,
                        width: _isSearchActive
                            ? collapsedNavBarWidth
                            : expandedNavBarWidth,
                        height: 56,
                        child: Transform.scale(
                          scale: 1.0 - keyboardAnimationProgress,
                          alignment: Alignment.centerLeft,
                          child: _buildNavBarContainer(
                            isCircle: _isSearchActive,
                            child: SlidingGlassBottomNavBar(
                              showIndicator: !_isSearchActive,
                              selectedIndex: _isSearchActive ? 0 : _selectedIndex,
                              onTap: (index) {
                                if (index == 0 && _isSearchActive) {
                                  setState(() {
                                    _isSearchActive = false;
                                    _selectedIndex = 0;
                                    _searchController.clear();
                                    _onSearchChanged('');
                                  });
                                } else {
                                  setState(() {
                                    _isSearchActive = false;
                                    _selectedIndex = index;
                                  });
                                }
                              },
                              isSearchActive: _isSearchActive,
                              expandedWidth: expandedNavBarWidth - 2.0,
                              collapsedWidth: collapsedNavBarWidth - 2.0,
                              itemValues: const [0, 1, 2, 4],
                              items: const [
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.home), label: 'Home'),
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.movie), label: 'Movies'),
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.tv), label: 'TV Shows'),
                                BottomNavigationBarItem(icon: Icon(Icons.sports_basketball),
                                    label: 'Sports'),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Search component
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            begin: 0.0, end: _isSearchActive ? 1.0 : 0.0),
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        builder: (context, searchAnimationValue, child) {
                          // Animate the search bar sliding in/out when search is activated/deactivated
                          final searchBarLeftOnSearch = lerpDouble(
                              expandedNavBarWidth + spacing,
                              searchBarLeft,
                              searchAnimationValue);

                          // Further animate the position based on the keyboard's visibility
                          final searchBarLeftCurrent = lerpDouble(
                              searchBarLeftOnSearch,
                              0,
                              keyboardAnimationProgress);
                          final searchBarRightCurrent = lerpDouble(0.0,
                              closeButtonWidth + spacing, keyboardAnimationProgress);

                          return Positioned(
                            left: searchBarLeftCurrent,
                            right: searchBarRightCurrent,
                            height: 56,
                            child: child!,
                          );
                        },
                        child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _isSearchActive
                                ? _buildSearchBar()
                                : _buildSearchIcon()),
                      ),
                      // Close Keyboard Button
                      Positioned(
                        right: 0,
                        width: closeButtonWidth,
                        height: 56,
                        child: Transform.scale(
                          scale: keyboardAnimationProgress,
                          alignment: Alignment.centerRight,
                          child: _buildCloseKeyboardIcon(),
                        ),
                      ),
                    ],
                  ),
                );
              })
            : Container(
                color: const Color(0xFF0F1014),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 60,
                    child: LayoutBuilder(builder: (context, constraints) {
                      return SlidingGlassBottomNavBar(
                        selectedIndex: _selectedIndex,
                        onTap: (index) => setState(() => _selectedIndex = index),
                        expandedWidth: constraints.maxWidth,
                        collapsedWidth: constraints.maxWidth,
                        items: const [
                          BottomNavigationBarItem(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          BottomNavigationBarItem(
                            icon: Icon(Icons.movie),
                            label: 'Movies',
                          ),
                           BottomNavigationBarItem(
                            icon: Icon(Icons.tv),
                            label: 'TV Shows',
                          ),
                           BottomNavigationBarItem(
                            icon: Icon(Icons.sports_basketball),
                            label: 'Sports',
                          ),
                        ],
                        itemValues: const [0, 1, 2, 4],
                      );
                    }),
                  ),
                ),
              ),
      ),
    );
  }
}

class SlidingGlassBottomNavBar extends StatelessWidget {
  final int selectedIndex;
  final Function(int) onTap;
  final List<int>? itemValues;
  final List<BottomNavigationBarItem> items;
  final bool showIndicator;
  final bool isSearchActive;
  final double expandedWidth;
  final double collapsedWidth;

  const SlidingGlassBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onTap,
    this.itemValues,
    required this.items,
    this.showIndicator = true,
    this.isSearchActive = false,
    required this.expandedWidth,
    required this.collapsedWidth,
  });

  @override
  Widget build(BuildContext context) {
    final values =
        itemValues ?? List<int>.generate(items.length, (index) => index);
    final activeItemIndex = values.indexOf(selectedIndex);
    const indicatorHeight = 56.0; // Use fixed height of the parent container

    final expandedItemWidth =
        items.isNotEmpty ? expandedWidth / items.length : 0.0;
    final indicatorTargetWidth =
        isSearchActive ? collapsedWidth : expandedItemWidth;
    final indicatorTargetLeft =
        activeItemIndex != -1 ? activeItemIndex * expandedItemWidth : 0.0;

    return Stack(
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.hardEdge,
      children: [
        // Sliding glass indicator
        if (activeItemIndex != -1)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            left: indicatorTargetLeft,
            top: 0,
            width: indicatorTargetWidth,
            height: indicatorHeight,
            child: AnimatedOpacity(
              opacity: showIndicator ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(indicatorHeight / 2),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius:
                          BorderRadius.circular(indicatorHeight / 2),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // Icons
        Row(
          children: items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            final isSelected = values[index] == selectedIndex;
            final isHomeButton = index == 0;

            final homeItemTargetWidth =
                isSearchActive ? collapsedWidth : expandedItemWidth;
            final otherItemTargetWidth =
                isSearchActive ? 0.0 : expandedItemWidth;
            final targetWidth =
                isHomeButton ? homeItemTargetWidth : otherItemTargetWidth;

            Widget iconWidget = GestureDetector(
              onTap: () => onTap(values[index]),
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: AnimatedScale(
                  scale: isSelected && showIndicator ? 1.2 : 1.0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    (item.icon as Icon).icon,
                    color: isSelected && showIndicator
                        ? Colors.white
                        : Colors.white70,
                  ),
                ),
              ),
            );

            return AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              width: targetWidth,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: AnimatedOpacity(
                opacity: (isHomeButton || !isSearchActive) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                child: iconWidget,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!);
      }
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (profileImage != null)
              CircleAvatar(radius: 50, backgroundImage: profileImage)
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
                  : 'Account',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              onPressed: () async {
                try {
                  try {
                    if (!kIsWeb &&
                        (defaultTargetPlatform == TargetPlatform.android ||
                            defaultTargetPlatform == TargetPlatform.iOS)) {
                      await gsi.GoogleSignIn.instance.signOut();
                    }
                  } catch (_) {}

                  await FirebaseAuth.instance.signOut();
                  if (context.mounted) {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  }
                } catch (e) {
                  debugPrint('Error signing out: $e');
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white12,
                foregroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              onPressed: () async {
                final bool? confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      backgroundColor: const Color(0xFF1E1F24),
                      title: const Text(
                        'Clear Search History',
                        style: TextStyle(color: Colors.white),
                      ),
                      content: const Text(
                        'Are you sure you want to clear your recent searches? This cannot be undone.',
                        style: TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Clear'),
                        ),
                      ],
                    );
                  },
                );

                if (confirm == true) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('recentSearches');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Search history cleared.'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.delete_sweep),
              label: const Text(
                'Clear Search History',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FeaturedMediaItem extends StatefulWidget {
  final List<dynamic> mediaList;
  final bool isMuted;

  const FeaturedMediaItem({
    super.key,
    required this.mediaList,
    this.isMuted = true,
  });

  @override
  State<FeaturedMediaItem> createState() => _FeaturedMediaItemState();
}

class _FeaturedMediaItemState extends State<FeaturedMediaItem>
    with TickerProviderStateMixin {
  late AnimationController _progressController;
  int _currentIndex = 0;
  String? _logoPath;
  bool _showContent = false;
  String _contentRating = '';
  String _displayYear = '';

  WebViewController? _webController;
  YoutubePlayerController? _ytController;
  bool _isVideoPlaying = false;
  String? _trailerKey;
  Timer? _trailerDelayTimer;
  Timer? _fadeDelayTimer;
  Timer? _audioFadeTimer;
  Timer? _audioFadeInterval;
  Timer? _transitionTimer;
  Color? _dominantColor;
  bool _isCamRelease = false;
  bool get _useWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(vsync: this);
    _progressController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _goToItem((_currentIndex + 1) % widget.mediaList.length);
      }
    });
    _fetchLogo();
  }

  @override
  void didUpdateWidget(FeaturedMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isMuted != widget.isMuted) {
      if (_useWebView && _webController != null) {
        _webController!.runJavaScript(
          'if (typeof setMute === "function") setMute(${widget.isMuted});',
        );
      } else if (!_useWebView && _ytController != null) {
        if (widget.isMuted) {
          _ytController!.mute();
        } else {
          _ytController!.unMute();
          _ytController!.setVolume(100);
        }
      }
    }
    if (oldWidget.mediaList.isEmpty ||
        widget.mediaList.isEmpty ||
        oldWidget.mediaList[0]['id'] != widget.mediaList[0]['id']) {
      _stopTrailerVideo();
      _progressController.reset();
      _transitionTimer?.cancel();
      setState(() {
        _currentIndex = 0;
        _showContent = false;
        _displayYear = '';
        _isVideoPlaying = false;
        _isCamRelease = false;
      });
      _fetchLogo();
    }
  }

  void _goToItem(int index) {
    if (!mounted || _currentIndex == index) return;
    _stopTrailerVideo(keepVideoVisible: true);
    _progressController.stop();
    _progressController.reset();
    _transitionTimer?.cancel();
    setState(() {
      _showContent = false;
    });
    _transitionTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _currentIndex = index;
        _displayYear = '';
        _isVideoPlaying = false;
        _dominantColor = null;
        _isCamRelease = false;
      });
      _fetchLogo();
    });
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
        });
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
    }
  }

  Future<void> _fetchLogo() async {
    if (widget.mediaList.isEmpty) return;
    final media = widget.mediaList[_currentIndex];

    if (media['poster_path'] != null) {
      _extractDominantColor(
        'https://image.tmdb.org/t/p/w300${media['poster_path']}',
      );
    } else {
      if (mounted) setState(() => _dominantColor = null);
    }

    final mediaType = media['media_type'] ?? 'movie';
    final mediaId = media['id'];
    if (mediaId == null) {
      if (mounted) setState(() => _showContent = true);
      return;
    }

    final url =
        'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=images,content_ratings,release_dates,videos&include_image_language=en,null';
    try {
      final data = await fetchWithCache(url);
      if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          final validLogos = logos
              .where(
                (l) =>
                    l is Map &&
                    !(l['file_path']?.toString().toLowerCase().endsWith(
                          '.svg',
                        ) ??
                        false),
              )
              .toList();
          if (validLogos.isNotEmpty) {
            validLogos.sort((a, b) {
              final double voteA =
                  double.tryParse(a['vote_average']?.toString() ?? '0') ?? 0.0;
              final double voteB =
                  double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0;
              return voteB.compareTo(voteA);
            });
            final enLogo = validLogos.firstWhere(
              (l) => l['iso_639_1'] == 'en',
              orElse: () => validLogos.first,
            );
            extractedLogo = enLogo['file_path'];
          }
        }

        String? extractedTrailer;
        if (data['videos'] != null && data['videos']['results'] is List) {
          for (var v in data['videos']['results']) {
            if (v is Map && v['type'] == 'Trailer' && v['site'] == 'YouTube') {
              extractedTrailer = v['key'];
              break;
            }
          }
        }

        String cert = '';
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          final results = data['release_dates']['results'] as List;
          for (var r in results) {
            if (r is Map &&
                r['iso_3166_1'] == 'US' &&
                r['release_dates'] is List) {
              for (var d in r['release_dates']) {
                if (d is Map &&
                    d['certification'] != null &&
                    d['certification'].toString().isNotEmpty) {
                  cert = d['certification'].toString();
                  break;
                }
              }
              break;
            }
          }
        } else if (mediaType == 'tv' &&
            data['content_ratings'] != null &&
            data['content_ratings']['results'] is List) {
          final results = data['content_ratings']['results'] as List;
          for (var r in results) {
            if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
              cert = r['rating'].toString();
              break;
            }
          }
        }

        String fetchedYear = '';
        if (mediaType == 'tv') {
          final firstAir = data['first_air_date']?.toString();
          final lastAir = data['last_air_date']?.toString();
          final status = data['status']?.toString() ?? '';
          final numSeasons = data['number_of_seasons'];

          String startYear = '';
          if (firstAir != null && firstAir.length >= 4) {
            startYear = firstAir.substring(0, 4);
          } else {
            final fallback = media['first_air_date']?.toString();
            if (fallback != null && fallback.length >= 4) {
              startYear = fallback.substring(0, 4);
            }
          }

          String endYear = '';
          if (lastAir != null && lastAir.length >= 4) {
            endYear = lastAir.substring(0, 4);
          }

          String seasonStr = '';
          if (numSeasons != null && numSeasons > 0) {
            seasonStr = ' • $numSeasons Season${numSeasons == 1 ? '' : 's'}';
          }

          if (startYear.isNotEmpty) {
            if (status == 'Ended' || status == 'Canceled') {
              if (endYear.isNotEmpty && endYear != startYear) {
                fetchedYear = '$startYear - $endYear$seasonStr';
              } else {
                fetchedYear = '$startYear$seasonStr';
              }
            } else {
              fetchedYear = '$startYear - Present$seasonStr';
            }
          } else if (seasonStr.isNotEmpty) {
            fetchedYear = seasonStr.substring(3);
          }
        } else {
          final releaseDateRaw = data['release_date'] ?? media['release_date'];
          if (releaseDateRaw != null && releaseDateRaw.toString().length >= 4) {
            fetchedYear = releaseDateRaw.toString().substring(0, 4);
          }
          final runtime = data['runtime'];
          if (runtime != null && runtime > 0) {
            final int hrs = runtime ~/ 60;
            final int mins = runtime % 60;
            final runtimeStr = hrs > 0 ? ' • ${hrs}h ${mins}m' : ' • ${mins}m';
            fetchedYear = '$fetchedYear$runtimeStr';
          }
        }

        bool isCam = false;
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          bool isOlderThanOneYear = false;
          if (data['release_date'] != null &&
              data['release_date'].toString().isNotEmpty) {
            try {
              final mainRelease = DateTime.parse(
                data['release_date'].toString(),
              );
              if (DateTime.now().difference(mainRelease).inDays > 365) {
                isOlderThanOneYear = true;
              }
            } catch (_) {}
          }

          if (!isOlderThanOneYear) {
            final results = data['release_dates']['results'] as List;
            for (var r in results) {
              if (r is Map &&
                  r['iso_3166_1'] == 'US' &&
                  r['release_dates'] is List) {
                final dates = r['release_dates'] as List;
                final now = DateTime.now();
                List<Map<String, dynamic>> pastReleases = [];

                for (var d in dates) {
                  if (d is Map && d['release_date'] != null) {
                    final date = DateTime.tryParse(d['release_date']);
                    if (date != null && date.isBefore(now)) {
                      pastReleases.add({
                        'date': date,
                        'type': d['type'] as int? ?? 0,
                      });
                    }
                  }
                }

                if (pastReleases.isNotEmpty) {
                  pastReleases.sort(
                    (a, b) => (a['date'] as DateTime).compareTo(
                      b['date'] as DateTime,
                    ),
                  );
                  final latestType = pastReleases.last['type'] as int;
                  if (latestType == 2 || latestType == 3) {
                    isCam =
                        pastReleases.length == 1 ||
                        [1, 2, 3].contains(
                          pastReleases[pastReleases.length - 2]['type'] as int,
                        );
                  }
                }
                break;
              }
            }
          }
        }

        setState(() {
          _logoPath = extractedLogo;
          _contentRating = cert;
          _displayYear = fetchedYear;
          _trailerKey = extractedTrailer; // Only update _trailerKey here
          // Removed: _isVideoPlaying = false; // This flag should be controlled by the video player's state
          _isCamRelease = isCam;
        });

        if (_trailerKey != null) {
          _trailerDelayTimer?.cancel();
          _trailerDelayTimer = Timer(const Duration(seconds: 2), () {
            if (mounted &&
                media['id'] == widget.mediaList[_currentIndex]['id']) {
              _loadTrailerVideo(_trailerKey!);
            }
          });
        } else {
          _stopTrailerVideo();
          if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
            _progressController.duration = const Duration(seconds: 10);
            _progressController.forward(from: 0.0);
          }
        }
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

  void _onVideoStarted(double duration) {
    if (!mounted) return;
    if (!_isVideoPlaying) {
      _fadeDelayTimer?.cancel();
      _fadeDelayTimer = Timer(const Duration(seconds: 0), () {
        if (mounted) setState(() => _isVideoPlaying = true);
      });

      double playSeconds = duration > 30.0 ? 30.0 : duration;
      if (playSeconds <= 0) playSeconds = 30.0;

      _progressController.duration = Duration(
        milliseconds: (playSeconds * 1000).toInt(),
      );
      _progressController.forward(from: 0.0);

      if (playSeconds > 2.0) {
        _audioFadeTimer?.cancel();
        _audioFadeTimer = Timer(
          Duration(milliseconds: ((playSeconds - 2.0) * 1000).toInt()),
          () {
            _startAudioFade();
          },
        );
      }
    }
  }

  void _startAudioFade() {
    if (widget.isMuted || !mounted) return;
    int currentVol = 100;
    _audioFadeInterval?.cancel();
    _audioFadeInterval = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (widget.isMuted || !mounted) {
        timer.cancel();
        return;
      }
      currentVol -= 5;
      if (currentVol <= 0) {
        currentVol = 0;
        timer.cancel();
      }
      if (_useWebView && _webController != null) {
        _webController!.runJavaScript(
          'if (typeof player !== "undefined" && typeof player.setVolume === "function") { player.setVolume($currentVol); }',
        );
      } else if (!_useWebView && _ytController != null) {
        _ytController!.setVolume(currentVol);
      }
    });
  }

  void _initWebController() {
    late final PlatformWebViewControllerCreationParams params;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      params = WindowsWebViewControllerCreationParams();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _webController = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'FlutterVideo',
        onMessageReceived: (message) {
          if (message.message.startsWith('playing') && mounted) {
            final parts = message.message.split(':');
            double duration = 0.0;
            if (parts.length > 1) {
              duration = double.tryParse(parts[1]) ?? 0.0;
            }
            _onVideoStarted(duration);
          }
        },
      );

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        (_webController!.platform as dynamic)
            .setMediaPlaybackRequiresUserGesture(false);
      } catch (_) {}
    }
  }

  void _loadTrailerVideo(String key) {
    if (_useWebView) {
      if (_webController == null) {
        _initWebController();
        final html =
            '''
          <!DOCTYPE html>
          <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>body { margin: 0; background: black; overflow: hidden; pointer-events: none; } iframe { border: none; width: 100vw; height: 100vh; pointer-events: none; }</style>
          </head>
          <body>
            <div id="player"></div>
            <script>
              var tag = document.createElement('script');
              tag.src = "https://www.youtube.com/iframe_api";
              var firstScriptTag = document.getElementsByTagName('script')[0];
              firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
              
              var player;
              function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                  height: '100%',
                  width: '100%',
                  videoId: '$key',
                  playerVars: {
                    'autoplay': 1,
                    'controls': 0,
                    'disablekb': 1,
                    'fs': 0,
                    'modestbranding': 1,
                    'playsinline': 1,
                    'mute': ${widget.isMuted ? 1 : 0},
                    'playlist': '$key',
                    'loop': 1
                  },
                  events: {
                    'onReady': function(event) {
                      event.target.playVideo();
                    },
                    'onStateChange': function(event) {
                      if (event.data == YT.PlayerState.PLAYING) {
                        var duration = player.getDuration();
                        var msg = 'playing:' + duration;
                        if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage(msg);
                        else if (window.FlutterVideo) window.FlutterVideo.postMessage(msg);
                      }
                    }
                  }
                });
              }
              function setMute(mute) {
                if (player && typeof player.mute === 'function') {
                  if (mute) player.mute();
                  else { player.unMute(); player.setVolume(100); }
                }
              }
            </script>
          </body>
          </html>
        ''';
        _webController!.loadHtmlString(html, baseUrl: 'http://localhost:5000');
        if (mounted) {
          setState(() {});
        }
      } else {
        _webController!.runJavaScript(
          'if (typeof player !== "undefined" && typeof player.loadVideoById === "function") { player.setVolume(100); player.loadVideoById("$key"); player.playVideo(); }',
        );
      }
    } else {
      if (_ytController == null) {
        _ytController = YoutubePlayerController.fromVideoId(
          videoId: key,
          autoPlay: true,
          params: YoutubePlayerParams(
            showControls: false,
            mute: widget.isMuted,
            showFullscreenButton: false,
            pointerEvents: PointerEvents.none,
            loop: true,
          ),
        );
        _ytController!.listen((event) {
          if (event.playerState == PlayerState.playing && !_isVideoPlaying) {
            double duration = event.metaData.duration.inMilliseconds / 1000.0;
            _onVideoStarted(duration);
          }
        });
        if (mounted) {
          setState(() {});
        }
      } else {
        _ytController!.setVolume(100);
        _ytController!.loadVideoById(videoId: key);
        _ytController!.playVideo();
      }
    }
  }

  void _stopTrailerVideo({
    bool isDisposing = false,
    bool keepVideoVisible = false,
  }) {
    _trailerDelayTimer?.cancel();
    _fadeDelayTimer?.cancel();
    _audioFadeTimer?.cancel();
    _audioFadeInterval?.cancel();
    if (mounted && !isDisposing) {
      _progressController.stop();
    }
    if (_useWebView && _webController != null) {
      _webController!.runJavaScript(
        'if (typeof player !== "undefined" && typeof player.pauseVideo === "function") { player.pauseVideo(); }',
      );
    }
    if (!_useWebView && _ytController != null) {
      _ytController!.pauseVideo();
    }
    if (mounted && _isVideoPlaying && !isDisposing && !keepVideoVisible) {
      setState(() => _isVideoPlaying = false);
    }
  }

  @override
  void dispose() {
    _trailerDelayTimer?.cancel();
    _transitionTimer?.cancel();
    _progressController.dispose();
    _stopTrailerVideo(isDisposing: true);
    _ytController?.close();
    if (_webController != null) {
      // Loading a blank page is a good way to release web resources.
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaList.isEmpty) return const SizedBox(height: 660);
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
    final releaseYear = releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : '';
    final displayYearText = _displayYear.isNotEmpty
        ? _displayYear
        : releaseYear;
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

          if (currentProgress >= 0.5) {
            selectedEpisode += 1;
            currentProgress = 0.0;
          }
        }
      }
    } else {
      currentProgress = 1.0; // Mock movie progress
    }

    String playButtonText = isTvShow
        ? ((currentProgress > 0 && currentProgress < 1.0)
              ? (isMobile
                    ? 'Resume'
                    : 'Resume S$selectedSeason E$selectedEpisode')
              : (isMobile ? 'Play' : 'Play S$selectedSeason E$selectedEpisode'))
        : ((currentProgress > 0 && currentProgress < 1.0)
              ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
              : (_isCamRelease ? 'Play (Cam)' : 'Play'));

    final Color? btnBaseColor = (!isTvShow && _isCamRelease)
        ? Colors.red
        : _dominantColor;

    return GestureDetector(
      onTap: () {
        _stopTrailerVideo();
        // Explicitly nullify controllers to force re-initialization when returning
        _webController = null;
        _ytController?.close();
        _ytController = null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MediaDetailsPage(media: media, heroTag: heroTag),
          ),
        ).then((_) {
          if (mounted) {
            setState(() {
              _isVideoPlaying = false;
              _showContent = false;
            });
            _progressController.reset();
            _fetchLogo();
          }
        });
      },
      onHorizontalDragEnd: (details) {
        if (widget.mediaList.length <= 1) return;
        if (details.primaryVelocity == null) return;

        if (details.primaryVelocity! < -100) {
          // Swiped Left -> Go to Next Item
          _goToItem((_currentIndex + 1) % widget.mediaList.length);
        } else if (details.primaryVelocity! > 100) {
          // Swiped Right -> Go to Previous Item
          _goToItem(
            (_currentIndex - 1 + widget.mediaList.length) %
                widget.mediaList.length,
          );
        }
      },
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Column(
            children: [
              SizedBox(
                height: 440,
                width: double.infinity,
                child: Stack(
                  children: [
                    if (_trailerKey != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: Transform.scale(
                              scale: 1.35,
                              child: SizedBox(
                                width: 1280,
                                height: 720,
                                child: _useWebView && _webController != null
                                    ? WebViewWidget(controller: _webController!)
                                    : (!_useWebView && _ytController != null
                                          ? YoutubePlayer(
                                              controller: _ytController!,
                                            )
                                          : const SizedBox.shrink()),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: _isVideoPlaying
                            ? const SizedBox.expand(
                                key: ValueKey('empty_video_bg'),
                              )
                            : Hero(
                                key: ValueKey(heroTag),
                                tag: heroTag,
                                child: CachedNetworkImage(
                                  imageUrl: imageUrl,
                                  height: 440,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    height: 440,
                                    color: Colors.black26,
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        height: 440,
                                        color: Colors.black26,
                                        child: const Icon(
                                          Icons.broken_image,
                                          size: 50,
                                          color: Colors.white54,
                                        ),
                                      ),
                                ),
                              ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 220,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF0F1014), Colors.transparent],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 220,
                width: double.infinity,
                color: const Color(0xFF0F1014),
              ),
            ],
          ),
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: AnimatedOpacity(
              opacity: _showContent ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
              child: Container(
                padding: isMobile
                    ? const EdgeInsets.all(16.0)
                    : EdgeInsets.zero,
                decoration: const BoxDecoration(),
                child: Column(
                  crossAxisAlignment: isMobile
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    if (_logoPath != null)
                      CachedNetworkImage(
                        imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                        width: 250,
                        height: 100,
                        fit: BoxFit.contain,
                        alignment: isMobile
                            ? Alignment.center
                            : Alignment.centerLeft,
                      )
                    else
                      Text(
                        title,
                        textAlign: isMobile
                            ? TextAlign.center
                            : TextAlign.start,
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
                      alignment: isMobile
                          ? WrapAlignment.center
                          : WrapAlignment.start,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_contentRating.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white54),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _contentRating,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: isMobile ? 12 : 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        if (displayYearText.isNotEmpty)
                          Text(
                            displayYearText,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: isMobile ? 14 : 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (voteAverage.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star,
                                color: const Color(0xFF1CE783),
                                size: isMobile ? 16 : 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$voteAverage / 10',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: isMobile ? 14 : 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (overview.isNotEmpty) ...[
                      SizedBox(height: isMobile ? 8 : 12),
                      Text(
                        overview,
                        maxLines: 3,
                        textAlign: isMobile
                            ? TextAlign.center
                            : TextAlign.start,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: isMobile ? 12 : 14,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (!isTvShow && currentProgress >= 1.0) ...[
                      SizedBox(height: isMobile ? 8 : 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Watched',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: isMobile ? 11 : 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(
                            Icons.check_circle,
                            color: const Color(0xFF1CE783),
                            size: isMobile ? 14 : 16,
                          ),
                        ],
                      ),
                    ],
                    SizedBox(height: isMobile ? 16 : 20),
                    Row(
                      mainAxisAlignment: isMobile
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: defaultTargetPlatform == TargetPlatform.iOS
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                      sigmaX: 20,
                                      sigmaY: 20,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: btnBaseColor != null
                                            ? btnBaseColor.withOpacity(0.15)
                                            : Colors.white.withOpacity(0.15),
                                        border: Border.all(
                                          color: btnBaseColor != null
                                              ? btnBaseColor.withOpacity(0.3)
                                              : Colors.white.withOpacity(0.3),
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.transparent,
                                          shadowColor: Colors.transparent,
                                          foregroundColor:
                                              btnBaseColor ?? Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                        ),
                                        onPressed: () async {
                                          _stopTrailerVideo();
                                          int resumeSeconds = 0;
                                          if (currentProgress > 0 &&
                                              currentProgress < 1.0) {
                                            int rTime = isTvShow ? 45 : 120;
                                            try {
                                              final mediaId = media['id'];
                                              final mediaType = isTvShow
                                                  ? 'tv'
                                                  : 'movie';
                                              final url =
                                                  'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey';
                                              final data = await fetchWithCache(
                                                url,
                                              );

                                              if (isTvShow) {
                                                final epUrl =
                                                    'https://api.themoviedb.org/3/tv/$mediaId/season/$selectedSeason/episode/$selectedEpisode?api_key=$tmdbApiKey';
                                                try {
                                                  final epData =
                                                      await fetchWithCache(
                                                        epUrl,
                                                      );
                                                  if (epData['runtime'] !=
                                                      null) {
                                                    rTime = epData['runtime'];
                                                  } else if (data['episode_run_time']
                                                          is List &&
                                                      data['episode_run_time']
                                                          .isNotEmpty) {
                                                    rTime =
                                                        data['episode_run_time'][0];
                                                  }
                                                } catch (_) {
                                                  if (data['episode_run_time']
                                                          is List &&
                                                      data['episode_run_time']
                                                          .isNotEmpty) {
                                                    rTime =
                                                        data['episode_run_time'][0];
                                                  }
                                                }
                                              } else {
                                                if (data['runtime'] != null) {
                                                  rTime = data['runtime'];
                                                }
                                              }
                                            } catch (_) {}
                                            resumeSeconds =
                                                (rTime * 60 * currentProgress)
                                                    .toInt();
                                          }
                                          final String progressParam =
                                              '&progress=$resumeSeconds';
                                          final String placeholderLink =
                                              isTvShow
                                              ? 'https://player.videasy.net/tv/${media['id']}/$selectedSeason/$selectedEpisode?color=1ce783&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                                              : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';

                                          if (!context.mounted) return;
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  VideoPlayerPage(
                                                    videoUrl: placeholderLink,
                                                  ),
                                            ),
                                          ).then((_) {
                                            if (mounted) {
                                              setState(() {
                                                _isVideoPlaying = false;
                                                _showContent = false;
                                              });
                                              _progressController.reset();
                                              _fetchLogo();
                                            }
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.play_arrow,
                                          size: 24,
                                        ),
                                        label: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            playButtonText,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                : ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        btnBaseColor ?? Colors.white,
                                    foregroundColor:
                                        (!isTvShow && _isCamRelease) || btnBaseColor == null
                                        ? Colors.white
                                        : (btnBaseColor.computeLuminance() <
                                                  0.5
                                              ? Colors.white
                                              : Colors.black),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4.0)),
                                  ),
                                  onPressed: () async {
                                    _stopTrailerVideo();
                                    int resumeSeconds = 0;
                                    if (currentProgress > 0 &&
                                        currentProgress < 1.0) {
                                      int rTime = isTvShow ? 45 : 120;
                                      try {
                                        final mediaId = media['id'];
                                        final mediaType = isTvShow
                                            ? 'tv'
                                            : 'movie';
                                        final url =
                                            'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey';
                                        final data = await fetchWithCache(url);

                                        if (isTvShow) {
                                          final epUrl =
                                              'https://api.themoviedb.org/3/tv/$mediaId/season/$selectedSeason/episode/$selectedEpisode?api_key=$tmdbApiKey';
                                          try {
                                            final epData = await fetchWithCache(
                                              epUrl,
                                            );
                                            if (epData['runtime'] != null) {
                                              rTime = epData['runtime'];
                                            } else if (data['episode_run_time']
                                                    is List &&
                                                data['episode_run_time']
                                                    .isNotEmpty) {
                                              rTime =
                                                  data['episode_run_time'][0];
                                            }
                                          } catch (_) {
                                            if (data['episode_run_time']
                                                    is List &&
                                                data['episode_run_time']
                                                    .isNotEmpty) {
                                              rTime =
                                                  data['episode_run_time'][0];
                                            }
                                          }
                                        } else {
                                          if (data['runtime'] != null) {
                                            rTime = data['runtime'];
                                          }
                                        }
                                      } catch (_) {}
                                      resumeSeconds =
                                          (rTime * 60 * currentProgress)
                                              .toInt();
                                    }
                                    final String progressParam =
                                        '&progress=$resumeSeconds';
                                    final String placeholderLink = isTvShow
                                        ? 'https://player.videasy.net/tv/${media['id']}/$selectedSeason/$selectedEpisode?color=1ce783&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                                        : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';

                                    if (!context.mounted) return;
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => VideoPlayerPage(
                                          videoUrl: placeholderLink,
                                        ),
                                      ),
                                    ).then((_) {
                                      if (mounted) {
                                        setState(() {
                                          _isVideoPlaying = false;
                                          _showContent = false;
                                        });
                                        _progressController.reset();
                                        _fetchLogo();
                                      }
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.play_arrow, size: 24),
                                      const SizedBox(width: 8),
                                      Text(playButtonText,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ), 
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: defaultTargetPlatform == TargetPlatform.iOS
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                      sigmaX: 20,
                                      sigmaY: 20,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.05),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.15),
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          side: BorderSide.none,
                                        ),
                                        onPressed: () {
                                          _stopTrailerVideo();
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  MediaDetailsPage(
                                                    media: media,
                                                    heroTag: heroTag,
                                                  ),
                                            ),
                                          ).then((_) {
                                            if (mounted) {
                                              setState(() {
                                                _isVideoPlaying = false;
                                                _showContent = false;
                                              });
                                              _progressController.reset();
                                              _fetchLogo();
                                            }
                                          });
                                        },
                                        icon: const Icon(Icons.list, size: 24),
                                        label: const FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'Details',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    side: const BorderSide(
                                      color: Colors.white54,
                                      width: 2,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4.0),
                                    ),
                                  ),
                                  onPressed: () {
                                    _stopTrailerVideo();
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => MediaDetailsPage(
                                          media: media,
                                          heroTag: heroTag,
                                        ),
                                      ),
                                    ).then((_) {
                                      if (mounted) {
                                        setState(() {
                                          _isVideoPlaying = false;
                                          _showContent = false;
                                        });
                                        _progressController.reset();
                                        _fetchLogo();
                                      }
                                    });
                                  },
                                  icon: const Icon(Icons.list, size: 24),
                                  label: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      'Details',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 10,
                        ),
                        color: Colors.transparent,
                        child: Container(
                          height: 4,
                          width: isActive ? 32 : 8,
                          clipBehavior: Clip.hardEdge,
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
                                          color: const Color(0xFF1CE783),
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

class HoverableMediaItem extends StatefulWidget {
  final dynamic media;
  final String heroTag;
  final String imageUrl;

  const HoverableMediaItem({
    super.key,
    required this.media,
    required this.heroTag,
    required this.imageUrl,
  });

  @override
  State<HoverableMediaItem> createState() => _HoverableMediaItemState();
}

class _HoverableMediaItemState extends State<HoverableMediaItem> {
  bool _isHovered = false;
  String _displayYear = '';
  String _contentRating = '';
  bool _detailsFetched = false;

  @override
  void initState() {
    super.initState();
    _calculateInitialYear();
  }

  void _calculateInitialYear() {
    final media = widget.media;
    final releaseDateRaw = media['release_date'] ?? media['first_air_date'];
    if (releaseDateRaw != null && releaseDateRaw.toString().length >= 4) {
      _displayYear = releaseDateRaw.toString().substring(0, 4);
    }
  }

  Future<void> _fetchMoreDetails() async {
    if (_detailsFetched) return;
    _detailsFetched = true;

    final media = widget.media;
    final mediaType =
        media['media_type'] ??
        (media.containsKey('first_air_date') ? 'tv' : 'movie');
    final mediaId = media['id'];

    if (mediaId != null) {
      try {
        final url =
            'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=content_ratings,release_dates';
        final data = await fetchWithCache(url);
        if (mounted) {
          String cert = '';
          if (mediaType == 'movie' &&
              data['release_dates'] != null &&
              data['release_dates']['results'] is List) {
            final results = data['release_dates']['results'] as List;
            for (var r in results) {
              if (r is Map &&
                  r['iso_3166_1'] == 'US' &&
                  r['release_dates'] is List) {
                for (var d in r['release_dates']) {
                  if (d is Map &&
                      d['certification'] != null &&
                      d['certification'].toString().isNotEmpty) {
                    cert = d['certification'].toString();
                    break;
                  }
                }
                break;
              }
            }
          } else if (mediaType == 'tv' &&
              data['content_ratings'] != null &&
              data['content_ratings']['results'] is List) {
            final results = data['content_ratings']['results'] as List;
            for (var r in results) {
              if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
                cert = r['rating'].toString();
                break;
              }
            }
          }

          if (mediaType == 'tv') {
            final firstAir = data['first_air_date']?.toString();
            final lastAir = data['last_air_date']?.toString();
            final status = data['status']?.toString() ?? '';
            final numSeasons = data['number_of_seasons'];

            String startYear = '';
            if (firstAir != null && firstAir.length >= 4) {
              startYear = firstAir.substring(0, 4);
            } else {
              startYear = _displayYear;
            }

            String endYear = '';
            if (lastAir != null && lastAir.length >= 4) {
              endYear = lastAir.substring(0, 4);
            }

            String seasonStr = '';
            if (numSeasons != null && numSeasons > 0) {
              seasonStr = ' • $numSeasons Season${numSeasons == 1 ? '' : 's'}';
            }

            if (startYear.isNotEmpty) {
              if (status == 'Ended' || status == 'Canceled') {
                if (endYear.isNotEmpty && endYear != startYear) {
                  setState(() {
                    _displayYear = '$startYear - $endYear$seasonStr';
                  });
                } else {
                  setState(() {
                    _displayYear = '$startYear$seasonStr';
                  });
                }
              } else {
                setState(() {
                  _displayYear = '$startYear - $endYear$seasonStr';
                });
              }
            } else if (seasonStr.isNotEmpty) {
              setState(() {
                _displayYear = seasonStr.substring(3);
              });
            }
          } else {
            final runtime = data['runtime'];
            if (runtime != null && runtime > 0) {
              final int hrs = runtime ~/ 60;
              final int mins = runtime % 60;
              final runtimeStr = hrs > 0
                  ? ' • ${hrs}h ${mins}m'
                  : ' • ${mins}m';
              setState(() {
                _displayYear = '$_displayYear$runtimeStr';
              });
            }
          }

          if (cert.isNotEmpty) {
            setState(() {
              _contentRating = cert;
            });
          }
        }
      } catch (_) {}
    }
  }

  void _onHover(bool isHovered) {
    setState(() => _isHovered = isHovered);
    if (isHovered) {
      _fetchMoreDetails();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final title = media['title'] ?? media['name'] ?? 'Unknown';
    final voteAverageRaw = media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ??
              '0.0'
        : '0.0';
    final overview = media['overview']?.toString() ?? 'No overview available.';
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    final mediaType =
        media['media_type'] ??
        (media.containsKey('first_air_date') ? 'tv' : 'movie');
    final isTvShow = mediaType == 'tv';
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
        }
      }
    } else {
      currentProgress = 1.0; // Mock movie progress
    }

    bool isFullyWatched = !isTvShow && currentProgress >= 1.0;

    return MouseRegion(
      onEnter: isMobile ? null : (_) => _onHover(true),
      onExit: isMobile ? null : (_) => _onHover(false),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  MediaDetailsPage(media: media, heroTag: widget.heroTag),
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4.0),
          decoration: BoxDecoration(
            color: _isHovered ? const Color(0xFF1E1F24) : Colors.transparent,
            borderRadius: BorderRadius.circular(8.0),
            border: Border.all(
              color: _isHovered ? Colors.white24 : Colors.transparent,
              width: 1,
            ),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Hero(
                  tag: widget.heroTag,
                  child: CachedNetworkImage(
                    imageUrl: widget.imageUrl,
                    width: 135,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(width: 135, color: Colors.black26),
                    errorWidget: (context, url, error) => Container(
                      width: 135,
                      color: Colors.black26,
                      child: const Icon(
                        Icons.broken_image,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  width: _isHovered ? 200 : 0,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 200,
                      maxWidth: 200,
                      child: AnimatedOpacity(
                        opacity: _isHovered ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeIn,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              if (_contentRating.isNotEmpty ||
                                  _displayYear.isNotEmpty)
                                Row(
                                  children: [
                                    if (_contentRating.isNotEmpty) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.white54,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          _contentRating,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    if (_displayYear.isNotEmpty)
                                      Expanded(
                                        child: Text(
                                          _displayYear,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.fade,
                                        ),
                                      ),
                                  ],
                                ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.star,
                                    color: Color(0xFF1CE783),
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '$voteAverage / 10',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.fade,
                                    ),
                                  ),
                                ],
                              ),
                              if (isFullyWatched) ...[
                                const SizedBox(height: 6),
                                const Row(
                                  children: [
                                    Text(
                                      'Watched',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(
                                      Icons.check_circle,
                                      color: Color(0xFF1CE783),
                                      size: 12,
                                    ),
                                  ],
                                ),
                              ] else if (currentProgress > 0 &&
                                  currentProgress < 1.0) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      isTvShow
                                          ? 'Resume S$selectedSeason E$selectedEpisode'
                                          : 'Resume',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: currentProgress,
                                        backgroundColor: Colors.white24,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                              Color(0xFF1CE783),
                                            ),
                                        minHeight: 4,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 8),
                              Expanded(
                                child: Text(
                                  overview,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                    height: 1.3,
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.fade,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HorizontalMediaList extends StatefulWidget {
  final String categoryTitle;
  final List<dynamic> items;
  final bool showTitle;
  final EdgeInsetsGeometry? listPadding;

  const HorizontalMediaList({
    super.key,
    required this.categoryTitle,
    required this.items,
    this.showTitle = true,
    this.listPadding,
  });

  @override
  State<HorizontalMediaList> createState() => _HorizontalMediaListState();
}

class _HorizontalMediaListState extends State<HorizontalMediaList> {
  final ScrollController _scrollController = ScrollController();
  bool _isHovering = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollButtons());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollButtons);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final canScrollLeft = position.pixels > 0;
    final canScrollRight = position.pixels < position.maxScrollExtent;

    if (_canScrollLeft != canScrollLeft || _canScrollRight != canScrollRight) {
      setState(() {
        _canScrollLeft = canScrollLeft;
        _canScrollRight = canScrollRight;
      });
    }
  }

  void _scroll(double amount) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + amount).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showTitle)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Text(
              widget.categoryTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        MouseRegion(
          onEnter: isMobile ? null : (_) => setState(() => _isHovering = true),
          onExit: isMobile ? null : (_) => setState(() => _isHovering = false),
          child: SizedBox(
            height: 200,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding:
                      widget.listPadding ??
                      const EdgeInsets.only(left: 12.0, right: 212.0),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final media = widget.items[index];
                    final posterPath = media['poster_path'];
                    final imageUrl = posterPath != null
                        ? 'https://image.tmdb.org/t/p/w500$posterPath'
                        : 'https://via.placeholder.com/500x750?text=No+Image';
                    final heroTag =
                        '${widget.categoryTitle}_${media['media_type']}_${media['id']}_$index';

                    return HoverableMediaItem(
                      media: media,
                      heroTag: heroTag,
                      imageUrl: imageUrl,
                    );
                  },
                ),
                if (!isMobile)
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollLeft),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollLeft) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _canScrollLeft
                                ? () => _scroll(-800)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!isMobile)
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollRight),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollRight) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _canScrollRight
                                ? () => _scroll(800)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MediaCategoryBody extends StatefulWidget {
  final String mediaType;
  final bool isMuted;
  const MediaCategoryBody({
    super.key,
    required this.mediaType,
    required this.isMuted,
  });

  @override
  State<MediaCategoryBody> createState() => _MediaCategoryBodyState();
}

class _MediaCategoryBodyState extends State<MediaCategoryBody>
    with AutomaticKeepAliveClientMixin {
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
          displayedGenresCount = (displayedGenresCount + 5).clamp(
            0,
            allGenres.length,
          );
          isPaginating = false;
        });
      }
    });
  }

  Future<void> fetchData() async {
    try {
      final trendingUrl =
          'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey';
      final genreUrl =
          'https://api.themoviedb.org/3/genre/${widget.mediaType}/list?api_key=$tmdbApiKey';

      final trendingData = await fetchWithCache(trendingUrl);
      final genreData = await fetchWithCache(genreUrl);

      if (mounted) {
        setState(() {
          final rawTrending = trendingData['results'] as List? ?? [];
          trendingList = rawTrending
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
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
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1CE783)),
      );
    }
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trendingList.isNotEmpty)
            FeaturedMediaItem(
              mediaList: trendingList.take(5).toList(),
              isMuted: widget.isMuted,
            ),
          const SizedBox(height: 20),
          HorizontalMediaList(
            categoryTitle: 'Trending Now',
            items: trendingList.skip(5).toList(),
          ),
          const SizedBox(height: 16),
          ...allGenres
              .take(displayedGenresCount)
              .toList()
              .asMap()
              .entries
              .map(
                (entry) => GenreRow(
                  title: entry.value['name'],
                  genreId: entry.value['id'],
                  mediaType: widget.mediaType,
                  index: entry.key,
                  seenMediaIds: seenMediaIds,
                ),
              ),
          if (isPaginating)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32.0),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF1CE783)),
              ),
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
      String url =
          'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}';
      if (widget.mediaType == 'movie') {
        url += '&with_runtime.gte=20';
      }

      final data = await fetchWithCache(url);
      if (mounted) {
        List<dynamic> deduplicatedItems = [];
        for (var item in (data['results'] as List? ?? [])) {
          if (!_isReleased(item, strictFilter: true)) continue;
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
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF1CE783)),
        ),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: HorizontalMediaList(categoryTitle: widget.title, items: items),
    );
  }
}

class DownloadProgressPainter extends CustomPainter {
  final DownloadStatus status;
  final double progress;
  final Animation<double> rotationAnimation;

  DownloadProgressPainter({
    required this.status,
    required this.progress,
    required this.rotationAnimation,
  }) : super(repaint: rotationAnimation);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final Rect rect = Rect.fromLTWH(0, 0, size.width, size.height);

    if (status == DownloadStatus.requesting) {
      paint.color = const Color(0xFF1CE783);
      final startAngle = rotationAnimation.value * 2 * pi;
      const sweepAngle = pi * 1.5; // 270 degrees
      canvas.drawArc(rect.deflate(1.5), startAngle, sweepAngle, false, paint);
    } else if (status == DownloadStatus.downloading || status == DownloadStatus.finalizing) {
      paint.color = Colors.white.withOpacity(0.2);
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);

      paint.color = const Color(0xFF1CE783);
      final sweepAngle = 2 * pi * progress;
      canvas.drawArc(rect.deflate(1.5), -pi / 2, sweepAngle, false, paint);
    } else if (status == DownloadStatus.done) {
      paint.color = const Color(0xFF1CE783);
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);
    } else if (status == DownloadStatus.failed) {
      paint.color = Colors.redAccent;
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DownloadProgressPainter oldDelegate) => true;
}



class MediaDetailsPage extends StatefulWidget {
  final dynamic media;
  final String heroTag;

  const MediaDetailsPage({
    super.key,
    required this.media,
    required this.heroTag,
  });

  @override
  State<MediaDetailsPage> createState() => _MediaDetailsPageState();
}

class _MediaDetailsPageState extends State<MediaDetailsPage>
    with TickerProviderStateMixin {
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
  String _contentRating = '';
  bool _isCamRelease = false;
  bool _isDownloadActive = false; // State for download button expansion
  String? _selectedResolution;
  final Map<int, List<dynamic>> _seasonEpisodesData = {};
  double _movieProgress = 0.0;
  Map<int, Map<int, double>> _tvProgress = {};

  DownloadTask? _task;
  late AnimationController _spinnerController;

  @override
  void initState() {
    super.initState();
    _spinnerController =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
    _updateTask();
    fetchDetails();
  }

  @override
  void dispose() {
    _task?.removeListener(_onDownloadUpdate);
    _spinnerController.dispose();
    super.dispose();
  }

  void _updateTask() {
    final mediaId = widget.media['id']?.toString();
    if (mediaId == null) return;
    final newTask = DownloadManager().getTask(mediaId);
    if (newTask != _task) {
      _task?.removeListener(_onDownloadUpdate);
      _task = newTask;
      _task?.addListener(_onDownloadUpdate);
    }
  }

  void _onDownloadUpdate() {
    if (mounted) {
      setState(() {});
    }
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
      'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=credits,reviews,videos,release_dates,images,content_ratings,recommendations&include_image_language=en,null',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Simulate pulling watched progress from a database
        if (mediaType == 'tv') {
          _tvProgress = {
            1: {
              1: 1.0,
              2: 1.0,
              3: 1.0,
              4: 1.0,
              5: 1.0,
              6: 1.0,
              7: 1.0,
              8: 1.0,
            }, // Matches Home Banner
            2: {
              1: 1.0,
              2: 0.45,
            }, // Season 2: Ep 1 watched, Ep 2 is 45% complete. (Button will show "Resume S2 E2")
          };
        } else {
          _movieProgress = 1.0; // Movie is 100% watched
        }

        String cert = '';
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          final results = data['release_dates']['results'] as List;
          for (var r in results) {
            if (r is Map &&
                r['iso_3166_1'] == 'US' &&
                r['release_dates'] is List) {
              for (var d in r['release_dates']) {
                if (d is Map &&
                    d['certification'] != null &&
                    d['certification'].toString().isNotEmpty) {
                  cert = d['certification'].toString();
                  break;
                }
              }
              break;
            }
          }
        } else if (mediaType == 'tv' &&
            data['content_ratings'] != null &&
            data['content_ratings']['results'] is List) {
          final results = data['content_ratings']['results'] as List;
          for (var r in results) {
            if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
              cert = r['rating'].toString();
              break;
            }
          }
        }

        bool isCam = false;
        // Parse the US release dates to determine if the latest current release is strictly Theatrical (Types 2 or 3)
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          bool isOlderThanOneYear = false;
          if (data['release_date'] != null &&
              data['release_date'].toString().isNotEmpty) {
            try {
              final mainRelease = DateTime.parse(
                data['release_date'].toString(),
              );
              if (DateTime.now().difference(mainRelease).inDays > 365) {
                isOlderThanOneYear = true;
              }
            } catch (_) {}
          }

          if (!isOlderThanOneYear) {
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
                    pastReleases.sort(
                      (a, b) => (a['date'] as DateTime).compareTo(
                        b['date'] as DateTime,
                      ),
                    );
                    final latestType = pastReleases.last['type'] as int;

                    if (latestType == 2 || latestType == 3) {
                      if (pastReleases.length == 1) {
                        isCam = true;
                      } else {
                        final previousType =
                            pastReleases[pastReleases.length - 2]['type']
                                as int;
                        // Type 1 is Premiere. Types 2 and 3 are Limited/Theatrical.
                        if (previousType == 1 ||
                            previousType == 2 ||
                            previousType == 3) {
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
        }

        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          final validLogos = logos
              .where(
                (l) =>
                    l is Map &&
                    !(l['file_path']?.toString().toLowerCase().endsWith(
                          '.svg',
                        ) ??
                        false),
              )
              .toList();
          if (validLogos.isNotEmpty) {
            validLogos.sort((a, b) {
              final double voteA =
                  double.tryParse(a['vote_average']?.toString() ?? '0') ?? 0.0;
              final double voteB =
                  double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0;
              return voteB.compareTo(voteA);
            });
            final enLogo = validLogos.firstWhere(
              (l) => l['iso_639_1'] == 'en',
              orElse: () => validLogos.first,
            );
            extractedLogo = enLogo['file_path'];
          }
        }

        if (mounted) {
          setState(() {
            detailedMedia = data;
            isLoadingDetails = false;
            _isCamRelease = isCam;
            _logoPath = extractedLogo;
            _contentRating = cert;

            // Auto-select the most recent or next episode for TV Shows
            if (mediaType == 'tv' && _tvProgress.isNotEmpty) {
              int maxS = _tvProgress.keys.reduce((a, b) => a > b ? a : b);
              if (_tvProgress[maxS]!.isNotEmpty) {
                int maxE = _tvProgress[maxS]!.keys.reduce(
                  (a, b) => a > b ? a : b,
                );
                _selectedSeason = maxS;
                _selectedEpisode = maxE;

                if (_tvProgress[maxS]![maxE]! >= 1.0) {
                  int epCount = _getEpisodeCountForSeason(maxS);
                  if (maxE < epCount) {
                    _selectedEpisode = maxE + 1;
                  } else {
                    final availableSeasons =
                        (data['seasons'] as List?)
                            ?.whereType<Map>()
                            .map((s) => (s['season_number'] ?? 0) as int)
                            .where((n) => n > 0)
                            .toList() ??
                        [];
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

          final videosData = data['videos'] is Map
              ? data['videos'] as Map
              : null;
          final videosList = videosData != null && videosData['results'] is List
              ? videosData['results'] as List
              : [];
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
          setState(() {
            isLoadingDetails = false;
            _isColorExtracted = true;
          });
          _checkIfReady();
        }
      }
    } catch (e) {
      debugPrint('Error fetching details: $e');
      if (mounted) {
        setState(() {
          isLoadingDetails = false;
          _isColorExtracted = true;
        });
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
    final url = 'https://api.themoviedb.org/3/tv/$mediaId/season/$seasonNumber?api_key=$tmdbApiKey';
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
      const months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
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
    final currentSeasonMap = seasonsList.whereType<Map>().firstWhere(
      (s) => s['season_number'] == season,
      orElse: () => <dynamic, dynamic>{},
    );
    return (currentSeasonMap.isNotEmpty &&
            currentSeasonMap['episode_count'] != null)
        ? (currentSeasonMap['episode_count'] as int)
        : 1;
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
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton(int mainResumeSeconds) {
    final isTvShow = widget.media['media_type'] == 'tv';
    double currentProgress = isTvShow
        ? _getEpisodeProgress(_selectedSeason, _selectedEpisode)
        : _movieProgress;
    
    final String colorHex = _dominantColor != null
        ? (_dominantColor!.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')
        : '1ce783';

    return defaultTargetPlatform == TargetPlatform.iOS
        ? ClipRRect(
            borderRadius: BorderRadius.circular(
              16,
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 20,
                sigmaY: 20,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: _dominantColor != null
                      ? _dominantColor!.withOpacity(0.15)
                      : Colors.white.withOpacity(0.15),
                  border: Border.all(
                    color: _dominantColor != null
                        ? _dominantColor!.withOpacity(0.3)
                        : Colors.white.withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: _dominantColor ?? Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
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
                        builder: (context) => VideoPlayerPage(
                          videoUrl: placeholderLink,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(
                    Icons.play_arrow,
                    size: 24,
                  ),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      isTvShow
                          ? ((currentProgress > 0 && currentProgress < 1.0)
                              ? 'Resume S$_selectedSeason E$_selectedEpisode'
                              : 'Play S$_selectedSeason E$_selectedEpisode')
                          : ((currentProgress > 0 && currentProgress < 1.0)
                              ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
                              : (_isCamRelease ? 'Play (Cam)' : 'Play')),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        : ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: (!isTvShow && _isCamRelease)
                  ? Colors.red
                  : (_dominantColor ?? Colors.white),
              foregroundColor: (!isTvShow && _isCamRelease)
                  ? Colors.white
                  : ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5
                      ? Colors.white
                      : Colors.black),
              padding: const EdgeInsets.symmetric(
                vertical: 12,
              ),
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
                  builder: (context) => VideoPlayerPage(
                    videoUrl: placeholderLink,
                  ),
                ),
              );
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.play_arrow, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    isTvShow
                        ? ((currentProgress > 0 && currentProgress < 1.0)
                            ? 'Resume S$_selectedSeason E$_selectedEpisode'
                            : 'Play S$_selectedSeason E$_selectedEpisode')
                        : ((currentProgress > 0 && currentProgress < 1.0)
                            ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
                            : (_isCamRelease ? 'Play (Cam)' : 'Play')),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    softWrap: false,
                  ),
                ],
              ),
            ),
          );
  }

  Widget _buildResolutionButton(String resolution, String label) {
    final isSelected = _selectedResolution == resolution;
    return InkWell(
      onTap: () {
        // Set state to give visual feedback of selection
        setState(() => _selectedResolution = resolution);
        final releaseDateRaw =
            widget.media['release_date'] ?? widget.media['first_air_date'];
        final releaseYear = (releaseDateRaw?.toString() ?? '').length >= 4
            ? releaseDateRaw.toString().substring(0, 4)
            : '';
        // Initiate the download via the manager
        DownloadManager().startDownload(
          mediaId: widget.media['id'].toString(),
          title: widget.media['title']?.toString() ??
              widget.media['name']?.toString() ??
              'Unknown',
          year: releaseYear,
          resolution: resolution,
        );
        // After starting, update the task listener and collapse the UI.
        setState(() {
          _isDownloadActive = false;
          _updateTask();
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white38,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadCollapsed() {
    final status = _task?.status ?? DownloadStatus.none;
    final progress = _task?.progress ?? 0.0;

    Widget iconChild;
    switch (status) {
      case DownloadStatus.requesting:
        iconChild = const SizedBox.shrink(); // Spinner is painted outside
        break;
      case DownloadStatus.downloading:
        iconChild = Text(
          '${(progress * 100).floor()}%',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
        );
        break;
      case DownloadStatus.finalizing:
        iconChild = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${(progress * 100).floor()}%',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
            const Text('',
                style: TextStyle(
                    color: Colors.white70, fontSize: 6, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          ],
        );
        break;
      case DownloadStatus.done:
        iconChild = const Icon(Icons.check, color: Color(0xFF1CE783), size: 28);
        break;
      case DownloadStatus.failed:
        iconChild = const Icon(Icons.close, color: Colors.redAccent, size: 28);
        break;
      case DownloadStatus.none:
      // ignore: unreachable_switch_default
      default:
        iconChild = const Icon(Icons.download, size: 24);
        break;
    }

    return SizedBox(
      key: const ValueKey('download_collapsed'),
      width: 56,
      height: 56,
      child: CustomPaint(
        painter: DownloadProgressPainter(
          status: status,
          progress: progress,
          rotationAnimation: _spinnerController,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            shape: BoxShape.circle,
          ),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                side: BorderSide.none,
                shape: const CircleBorder()),            
            onPressed: () {
              if (status == DownloadStatus.none || status == DownloadStatus.failed) {
                setState(() => _isDownloadActive = true);
              } else if (status == DownloadStatus.downloading) {
                DownloadManager().cancelDownload(widget.media['id'].toString());
              }
            },
            child: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: Align(key: ValueKey(status), alignment: Alignment.center, child: iconChild)),
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadExpanded() {
    return Container(
      key: const ValueKey('download_expanded'),
      height: 56,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: Colors.white.withOpacity(0.15),
        ),
      ),
      child: OverflowBox(
        maxWidth: double.infinity,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4.0),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() {
                    _isDownloadActive = false;
                    _selectedResolution = null;
                  }),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.close, color: Colors.white70),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildResolutionButton('480p', 'SD'),
                  const SizedBox(width: 8),
                  _buildResolutionButton('720p', 'HD'),
                  const SizedBox(width: 8),
                  _buildResolutionButton('1080p', 'FHD'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrailerButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(
          color: Colors.white.withOpacity(0.15),
        ),
        shape: BoxShape.circle,
      ),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          side: BorderSide.none,
          shape: const CircleBorder(),
        ),
        onPressed: () {
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.android)) {
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (
                  context,
                  animation,
                  secondaryAnimation,
                ) =>
                    FullscreenTrailerPage(
                  trailerKey: _trailerKey!,
                ),
                transitionsBuilder: (
                  context,
                  animation,
                  secondaryAnimation,
                  child,
                ) {
                  return FadeTransition(
                    opacity: animation,
                    child: child,
                  );
                },
              ),
            );
          } else {
            showDialog(
              context: context,
              builder: (context) => TrailerPlayerDialog(
                trailerKey: _trailerKey!,
              ),
            );
          }
        },
        child: const Icon(Icons.movie_creation_outlined, size: 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    // Basic details from passed search/trending context
    final title =
        widget.media['title']?.toString() ??
        widget.media['name']?.toString() ??
        'Unknown';
    final overview =
        widget.media['overview']?.toString() ?? 'No overview available.';
    final backdropPath = widget.media['backdrop_path']?.toString();
    final posterPath = widget.media['poster_path']?.toString();
    final releaseDateRaw =
        widget.media['release_date'] ?? widget.media['first_air_date'];
    final releaseDate = releaseDateRaw?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : 'N/A';
    final voteAverageRaw = widget.media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ??
              'N/A'
        : 'N/A';

    final bool isTvShow = widget.media['media_type'] == 'tv';
    // Deep details from detailed fetch
    final details = detailedMedia ?? {};
    final numSeasons = details['number_of_seasons'];
    final numEpisodes = details['number_of_episodes'];
    final seasonsStr = numSeasons != null
        ? '$numSeasons Season${numSeasons != 1 ? 's' : ''}'
        : '';
    final episodesStr = numEpisodes != null
        ? '$numEpisodes Episode${numEpisodes != 1 ? 's' : ''}'
        : '';

    List<int> availableSeasons = [1];
    int currentSeasonEpisodeCount = 1;
    if (isTvShow && details['seasons'] is List) {
      final seasonsList = details['seasons'] as List;
      availableSeasons = seasonsList
          .whereType<Map>()
          .map((s) => (s['season_number'] ?? 0) as int)
          .where((n) => n > 0)
          .toList();
      if (availableSeasons.isEmpty) availableSeasons = [1];

      currentSeasonEpisodeCount = _getEpisodeCountForSeason(_selectedSeason);
      if (currentSeasonEpisodeCount < 1) currentSeasonEpisodeCount = 1;
    }

    if (!availableSeasons.contains(_selectedSeason) &&
        availableSeasons.isNotEmpty) {
      _selectedSeason = availableSeasons.first;
    }

    List<int> availableEpisodes = List.generate(
      currentSeasonEpisodeCount,
      (i) => i + 1,
    );
    if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
      final epList = _seasonEpisodesData[_selectedSeason]!
          .whereType<Map>()
          .toList();
      availableEpisodes = epList
          .map<int>(
            (e) => int.tryParse(e['episode_number']?.toString() ?? '') ?? 0,
          )
          .where((n) => n > 0)
          .toList();

      // Filter out episodes that haven't aired yet (future dates or missing dates)
      availableEpisodes.removeWhere((epNum) {
        final epData = epList.firstWhere(
          (e) =>
              (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) ==
              epNum,
          orElse: () => <dynamic, dynamic>{},
        );
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

    if (!availableEpisodes.contains(_selectedEpisode) &&
        availableEpisodes.isNotEmpty) {
      _selectedEpisode = availableEpisodes.first;
    }

    final credits = details['credits'] is Map
        ? details['credits'] as Map
        : null;
    final castList = credits != null && credits['cast'] is List
        ? credits['cast'] as List
        : [];
    final crewList = credits != null && credits['crew'] is List
        ? credits['crew'] as List
        : [];

    final directors = crewList
        .whereType<Map>()
        .where((c) => c['job'] == 'Director')
        .map((c) => c['name'])
        .join(', ');
    final screenplay = crewList
        .whereType<Map>()
        .where(
          (c) =>
              c['job'] == 'Screenplay' ||
              c['job'] == 'Writer' ||
              c['job'] == 'Teleplay',
        )
        .map((c) => c['name'])
        .join(', ');
    final authors = crewList
        .whereType<Map>()
        .where(
          (c) =>
              c['job'] == 'Novel' ||
              c['job'] == 'Author' ||
              c['job'] == 'Story' ||
              c['job'] == 'Book',
        )
        .map((c) => c['name'])
        .join(', ');

    final genresList = details['genres'] is List
        ? details['genres'] as List
        : [];
    final genres = genresList.whereType<Map>().map((g) => g['name']).join(', ');

    final epRunTimeList = details['episode_run_time'] is List
        ? details['episode_run_time'] as List
        : null;
    final epRunTimeNum = details['episode_run_time'] is num
        ? details['episode_run_time'] as num
        : null;
    final runtimeRaw =
        details['runtime'] ??
        (epRunTimeList != null && epRunTimeList.isNotEmpty
            ? epRunTimeList.first
            : epRunTimeNum);
    int? runtimeInt = runtimeRaw is num ? runtimeRaw.toInt() : null;

    String runtimeStr = '';
    if (runtimeInt != null && runtimeInt > 0) {
      final int hrs = runtimeInt ~/ 60;
      final int mins = runtimeInt % 60;
      runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
    }

    double currentProgress = isTvShow
        ? _getEpisodeProgress(_selectedSeason, _selectedEpisode)
        : _movieProgress;
    String mediaResumeStr = '';
    int mainResumeSeconds = 0;
    if (currentProgress > 0) {
      if (currentProgress >= 1.0) {
        mediaResumeStr = 'Watched';
      } else {
        int rTime = runtimeInt ?? (isTvShow ? 45 : 120); // Fallbacks

        if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
          final epList = _seasonEpisodesData[_selectedSeason]!
              .whereType<Map>()
              .toList();
          final epData = epList.firstWhere(
            (e) =>
                (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) ==
                _selectedEpisode,
            orElse: () => <dynamic, dynamic>{},
          );
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
    final language =
        details['original_language']?.toString().toUpperCase() ?? '';

    final budgetRaw = details['budget'];
    final budget = _formatCurrency(budgetRaw is num ? budgetRaw : null);
    final revenueRaw = details['revenue'];
    final revenue = _formatCurrency(revenueRaw is num ? revenueRaw : null);

    final networksList = details['networks'] is List
        ? details['networks'] as List
        : [];
    final networks = networksList
        .whereType<Map>()
        .map((n) => n['name'])
        .join(', ');
    final type = details['type']?.toString() ?? '';
    final firstAirDate = _formatDate(details['first_air_date']?.toString());
    final lastAirDate = _formatDate(details['last_air_date']?.toString());
    final inProductionRaw = details['in_production'];
    final inProduction = inProductionRaw != null
        ? (inProductionRaw ? 'Yes' : 'No')
        : '';

    final reviewsData =
        details['reviews'] is Map ? details['reviews'] as Map : null;
    final reviews = (reviewsData != null && reviewsData['results'] is List
            ? reviewsData['results'] as List
            : [])
        .take(10)
        .toList();

    final recommendationsData = details['recommendations'] is Map
        ? details['recommendations'] as Map
        : null;
    final recommendationsListRaw =
        recommendationsData != null && recommendationsData['results'] is List
        ? recommendationsData['results'] as List
        : [];
    final recommendationsList = recommendationsListRaw
        .map((item) {
          if (item is Map && !item.containsKey('media_type')) {
            item['media_type'] = isTvShow ? 'tv' : 'movie';
          }
          return item;
        })
        .where((item) => _isReleased(item, strictFilter: true))
        .take(15)
        .toList();

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
                opacity: 0.2,
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
                    padding: EdgeInsets.fromLTRB(
                      isMobile ? 20.0 : 40.0,
                      100.0,
                      isMobile ? 20.0 : 40.0,
                      40.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: isMobile
                              ? const EdgeInsets.all(16.0)
                              : EdgeInsets.zero,
                          decoration: const BoxDecoration(),
                          child: Column(
                            crossAxisAlignment: isMobile
                                ? CrossAxisAlignment.center
                                : CrossAxisAlignment.start,
                            children: [
                              if (_logoPath != null)
                                CachedNetworkImage(
                                  imageUrl:
                                      'https://image.tmdb.org/t/p/w500$_logoPath',
                                  width: 250,
                                  height: 100,
                                  fit: BoxFit.contain,
                                  alignment: isMobile
                                      ? Alignment.center
                                      : Alignment.centerLeft,
                                )
                              else
                                Text(
                                  title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        height: 1.1,
                                        fontSize: isMobile ? 28 : 34,
                                      ),
                                ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                alignment: isMobile
                                    ? WrapAlignment.center
                                    : WrapAlignment.start,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (_contentRating.isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        border:
                                            Border.all(color: Colors.white54),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _contentRating,
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: isMobile ? 12 : 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  Text(
                                    releaseYear,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: isMobile ? 14 : 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.star,
                                        color: Color(0xFF1CE783),
                                        size: 18,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '$voteAverage / 10',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: isMobile ? 14 : 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (runtimeStr.isNotEmpty && !isTvShow)
                                    Text(
                                      runtimeStr,
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: isMobile ? 14 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  if (isTvShow && seasonsStr.isNotEmpty)
                                    Text(
                                      seasonsStr,
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: isMobile ? 14 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  if (isTvShow && episodesStr.isNotEmpty)
                                    Text(
                                      episodesStr,
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: isMobile ? 14 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                ],
                              ),
                              if (genres.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  genres,
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: isMobile ? 12 : 14,
                                  ),
                                ),
                              ],
                              if (isFullyWatched) ...[
                                const SizedBox(height: 12),
                                const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Watched',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Icon(
                                      Icons.check_circle,
                                      color: Color(0xFF1CE783),
                                      size: 16,
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: isMobile
                                    ? MainAxisAlignment.center
                                    : MainAxisAlignment.start,
                                children: [Expanded(
                                  child: LayoutBuilder(builder: (context, constraints) {
                                    final containerWidth = constraints.maxWidth;
                                    const trailerButtonWidth = 56.0;
                                    final downloadButtonWidth = isTvShow ? 0.0 : 56.0;
                                    const spacing = 12.0;
                                    final downloadSpacing = isTvShow ? 0.0 : spacing;
                                
                                    // Inactive positions (from the right)
                                    const downloadRightInactive = 0.0;
                                    final trailerRightInactive = _trailerKey != null ? (downloadButtonWidth + downloadSpacing) : -100.0;
                                    final playRightInactive = _trailerKey != null
                                        ? (trailerRightInactive + trailerButtonWidth + spacing)
                                        : (downloadButtonWidth + downloadSpacing);
                                
                                    final trailerLeftInactive = _trailerKey != null ? (containerWidth - trailerRightInactive - trailerButtonWidth) : 0.0;
                                
                                    return SizedBox(
                                      height: 56,
                                      child: Stack(
                                        alignment: Alignment.centerRight,
                                        children: [
                                          // Play Button
                                          AnimatedPositioned(
                                            duration: const Duration(milliseconds: 400),
                                            curve: Curves.easeInOut,
                                            left: 0,
                                            right: _isDownloadActive ? containerWidth : playRightInactive,
                                            child: ClipRect(
                                              child: AnimatedOpacity(
                                                duration: const Duration(milliseconds: 200),
                                                opacity: _isDownloadActive ? 0.0 : 1.0,
                                                child: _buildPlayButton(mainResumeSeconds),
                                              ),
                                            ),
                                          ),
                                
                                          // Trailer Button
                                          if (_trailerKey != null)
                                            AnimatedPositioned(
                                              duration: const Duration(milliseconds: 400),
                                              curve: Curves.easeInOut,
                                              left: _isDownloadActive ? -trailerButtonWidth - spacing : trailerLeftInactive,
                                              width: trailerButtonWidth,
                                              height: 56,
                                              child: AnimatedOpacity(
                                                duration: const Duration(milliseconds: 200),
                                                opacity: _isDownloadActive ? 0.0 : 1.0,
                                                child: _buildTrailerButton(),
                                              ),
                                            ),
                                
                                          if (!isTvShow)
                                            // Download Button/UI
                                            AnimatedPositioned(
                                              duration: const Duration(milliseconds: 400),
                                              curve: Curves.easeInOut,
                                              width: _isDownloadActive ? containerWidth : 56.0,
                                              right: downloadRightInactive,
                                              height: 56,
                                              child: AnimatedSwitcher(
                                                duration: const Duration(milliseconds: 200),
                                                layoutBuilder: (currentChild, previousChildren) {
                                                  return Stack(
                                                    alignment: Alignment.center,
                                                    children: <Widget>[
                                                      ...previousChildren,
                                                    // ignore: use_null_aware_elements
                                                    if (currentChild != null) currentChild,
                                                    ],
                                                  );
                                                },
                                                child: _isDownloadActive
                                                    ? _buildDownloadExpanded()
                                                    : _buildDownloadCollapsed(),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  }),
                                ),],
                              ),
                          if (currentProgress > 0 && currentProgress < 1.0)
                            Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    mediaResumeStr,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 100,
                                    height: 4,
                                    child: LinearProgressIndicator(
                                      value: currentProgress,
                                      backgroundColor: Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                              Color(0xFF1CE783)),
                                      borderRadius: BorderRadius.circular(
                                        2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                          
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      overview,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: isMobile ? 14 : 16,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 40),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CAST',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 16),
                        castList.isEmpty
                            ? const Text(
                                'Cast information is unavailable.',
                                style: TextStyle(color: Colors.white70),
                              )
                            : SizedBox(
                                height: 190,
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: castList.length,
                                  itemBuilder: (context, index) {
                                    final actor = castList[index];
                                    if (actor == null || actor is! Map) {
                                      return const SizedBox.shrink();
                                    }

                                    final profilePath = actor['profile_path']
                                        ?.toString();
                                    final actorImageUrl = profilePath != null
                                        ? 'https://image.tmdb.org/t/p/w200$profilePath'
                                        : 'https://via.placeholder.com/200x300?text=No+Image';
                                    final actorName =
                                        actor['name']?.toString() ?? 'Unknown';
                                    final characterName =
                                        actor['character']?.toString() ?? '';
                                    final actorId = actor['id'];

                                    return MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: () {
                                          if (actorId != null) {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ActorDetailsPage(
                                                      actorId: actorId,
                                                      actorName: actorName,
                                                    ),
                                              ),
                                            );
                                          }
                                        },
                                        child: Container(
                                          width: 90,
                                          margin: const EdgeInsets.only(
                                            right: 12.0,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              ClipOval(
                                                child: CachedNetworkImage(
                                                  imageUrl: actorImageUrl,
                                                  width: 70,
                                                  height: 70,
                                                  fit: BoxFit.cover,
                                                  placeholder: (context, url) =>
                                                      Container(
                                                        width: 70,
                                                        height: 70,
                                                        color: Colors.white24,
                                                      ),
                                                  errorWidget:
                                                      (
                                                        context,
                                                        url,
                                                        error,
                                                      ) => Container(
                                                        width: 70,
                                                        height: 70,
                                                        color: Colors.white24,
                                                        child: const Icon(
                                                          Icons.person,
                                                          color: Colors.white54,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                actorName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              if (characterName.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  characterName,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 11,
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

                        if (recommendationsList.isNotEmpty) ...[
                          const SizedBox(height: 40),
                          Text(
                            'RECOMMENDATIONS',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                          ),
                          const SizedBox(height: 16),
                          HorizontalMediaList(
                            categoryTitle: 'recommendations',
                            items: recommendationsList,
                            showTitle: false,
                            listPadding: const EdgeInsets.only(right: 212.0),
                          ),
                        ],

                        if (isTvShow) ...[
                          const SizedBox(height: 40),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(20.0),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                dropdownColor: const Color(0xFF1E1F24),
                                icon: const Icon(
                                  Icons.keyboard_arrow_down,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                value: _selectedSeason,
                                items: availableSeasons.map((int s) {
                                  double progress = _getSeasonProgress(
                                    s,
                                    _getEpisodeCountForSeason(s),
                                  );
                                  Widget? statusIcon;
                                  if (progress >= 1.0) {
                                    statusIcon = const Icon(
                                      Icons.check_circle,
                                      color: Color(0xFF1CE783),
                                      size: 16,
                                    );
                                  } else if (progress > 0.0) {
                                    statusIcon = const Icon(
                                      Icons.brightness_medium,
                                      color: Color(0xFF1CE783),
                                      size: 16,
                                    );
                                  }
                                  return DropdownMenuItem<int>(
                                    value: s,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Season $s',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
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
                              final double progress = _getEpisodeProgress(
                                _selectedSeason,
                                val,
                              );
                              final bool isSelected =
                                  val == _visualSelectedEpisode;

                              String titleText = 'Ep. $val';
                              int? epRuntime;
                              String? epOverview;
                              String? epAirDate;
                              String? epStillPath;

                              if (_seasonEpisodesData.containsKey(
                                _selectedSeason,
                              )) {
                                final epList =
                                    _seasonEpisodesData[_selectedSeason]!
                                        .whereType<Map>()
                                        .toList();
                                final epData = epList.firstWhere(
                                  (e) =>
                                      (int.tryParse(
                                            e['episode_number']?.toString() ??
                                                '',
                                          ) ??
                                          0) ==
                                      val,
                                  orElse: () => <dynamic, dynamic>{},
                                );
                                if (epData.isNotEmpty) {
                                  final name = epData['name']?.toString() ?? '';
                                  if (name.isNotEmpty) {
                                    titleText = 'Ep. $val - $name';
                                  }
                                  epRuntime = epData['runtime'];
                                  epOverview = epData['overview']?.toString();
                                  epAirDate = epData['air_date']?.toString();
                                  epStillPath = epData['still_path']
                                      ?.toString();
                                }
                              }

                              List<Widget> subtitleChildren = [];
                              if (epRuntime != null && epRuntime > 0) {
                                final int hrs = epRuntime ~/ 60;
                                final int mins = epRuntime % 60;
                                final String durationStr = hrs > 0
                                    ? '${hrs}h ${mins}m'
                                    : '${mins}m';
                                subtitleChildren.add(
                                  Text(
                                    durationStr,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                );
                              }
                              if (epOverview != null && epOverview.isNotEmpty) {
                                if (subtitleChildren.isNotEmpty) {
                                  subtitleChildren.add(
                                    const SizedBox(height: 4),
                                  );
                                }
                                subtitleChildren.add(
                                  Text(
                                    epOverview,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              }
                              if (epAirDate != null && epAirDate.isNotEmpty) {
                                if (subtitleChildren.isNotEmpty) {
                                  subtitleChildren.add(
                                    const SizedBox(height: 4),
                                  );
                                }
                                subtitleChildren.add(
                                  Text(
                                    'Aired: ${_formatDate(epAirDate)}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                );
                              }

                              int epResumeSeconds = 0;
                              if (progress > 0 && progress < 1.0) {
                                if (subtitleChildren.isNotEmpty) {
                                  subtitleChildren.add(
                                    const SizedBox(height: 6),
                                  );
                                }
                                final int resumeMins =
                                    ((epRuntime ?? 45) * progress).toInt();
                                epResumeSeconds =
                                    ((epRuntime ?? 45) * 60 * progress).toInt();
                                final int rHr = resumeMins ~/ 60;
                                final int rMin = resumeMins % 60;
                                subtitleChildren.add(
                                  Text(
                                    'Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m',
                                    style: const TextStyle(
                                      color: Color(0xFF1CE783),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                );
                              }

                              Widget? subtitleWidget =
                                  subtitleChildren.isNotEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 4.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: subtitleChildren,
                                      ),
                                    )
                                  : null;

                              bool isInteractionActive = false;

                              return StatefulBuilder(
                                builder: (context, setItemState) {
                                  return MouseRegion(
                                    onEnter: (_) => setItemState(
                                      () => isInteractionActive = true,
                                    ),
                                    onExit: (_) => setItemState(
                                      () => isInteractionActive = false,
                                    ),
                                    child: Container(
                                      margin: const EdgeInsets.only(
                                        bottom: 12.0,
                                      ),
                                      clipBehavior: Clip.hardEdge,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(
                                          8.0,
                                        ),
                                        color: isSelected
                                            ? Colors.white.withOpacity(0.05)
                                            : const Color(0xFF1E1F24),
                                        border: isSelected
                                            ? Border.all(
                                                color: const Color(
                                                  0xFF1CE783,
                                                ).withOpacity(0.5),
                                              )
                                            : Border.all(color: Colors.white12),
                                      ),
                                      child: InkWell(
                                        onTap: () => setState(() {
                                          _visualSelectedEpisode = val;
                                          _selectedEpisode = val;
                                        }),
                                        onHighlightChanged: (highlighted) {
                                          setItemState(
                                            () => isInteractionActive =
                                                highlighted,
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(8.0),
                                          child: Row(
                                            crossAxisAlignment:
                                                (epStillPath == null &&
                                                    subtitleWidget == null)
                                                ? CrossAxisAlignment.center
                                                : CrossAxisAlignment.start,
                                            children: [
                                              GestureDetector(
                                                onTap: () {
                                                  setState(() {
                                                    _visualSelectedEpisode =
                                                        val;
                                                    _selectedEpisode = val;
                                                  });
                                                  final String progressParam =
                                                      '&progress=$epResumeSeconds';
                                                  final String placeholderLink =
                                                      'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$val?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam';
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) =>
                                                          VideoPlayerPage(
                                                            videoUrl:
                                                                placeholderLink,
                                                          ),
                                                    ),
                                                  );
                                                },
                                                child: SizedBox(
                                                  width: epStillPath != null
                                                      ? 150
                                                      : 48,
                                                  height: epStillPath != null
                                                      ? null
                                                      : 48,
                                                  child: epStillPath != null
                                                      ? ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8.0,
                                                              ),
                                                          child: Stack(
                                                            alignment: Alignment
                                                                .center,
                                                            children: [
                                                              AspectRatio(
                                                                aspectRatio:
                                                                    16 / 9,
                                                                child: CachedNetworkImage(
                                                                  imageUrl:
                                                                      'https://image.tmdb.org/t/p/w500$epStillPath',
                                                                  fit: BoxFit
                                                                      .cover,
                                                                ),
                                                              ),
                                                              if (isMobile ||
                                                                  isInteractionActive) ...[
                                                                Positioned.fill(
                                                                  child: Container(
                                                                    color: Colors
                                                                        .black45,
                                                                  ),
                                                                ),
                                                                const Icon(
                                                                  Icons
                                                                      .play_circle_fill,
                                                                  color: Colors
                                                                      .white,
                                                                  size: 36,
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                        )
                                                      : Center(
                                                          child: Icon(
                                                            Icons
                                                                .play_circle_fill,
                                                            color:
                                                                (isMobile ||
                                                                    isInteractionActive)
                                                                ? Colors.white
                                                                : Colors
                                                                      .white54,
                                                            size: 32,
                                                          ),
                                                        ),
                                                ), // closes SizedBox
                                              ), // closes GestureDetector
                                              Expanded(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 16.0,
                                                        right: 8.0,
                                                      ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Row(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .spaceBetween,
                                                        children: [
                                                          Expanded(
                                                            child: Text(
                                                              titleText,
                                                              style: TextStyle(
                                                                color:
                                                                    isSelected
                                                                    ? const Color(
                                                                        0xFF1CE783,
                                                                      )
                                                                    : Colors
                                                                          .white,
                                                                fontWeight:
                                                                    isSelected
                                                                    ? FontWeight
                                                                          .bold
                                                                    : FontWeight
                                                                          .normal,
                                                                fontSize:
                                                                    (epStillPath ==
                                                                            null &&
                                                                        subtitleWidget ==
                                                                            null)
                                                                    ? 16
                                                                    : null,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          _buildProgressIndicator(
                                                            progress,
                                                          ),
                                                        ],
                                                      ),
                                                      // ignore: use_null_aware_elements
                                                      if (subtitleWidget !=
                                                          null)
                                                        subtitleWidget,
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
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
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
                              if (review is! Map) {
                                return const SizedBox.shrink();
                              }

                              final author =
                                  review['author']?.toString() ?? 'Unknown';
                              final content =
                                  review['content']?.toString() ?? '';
                              final authorDetails =
                                  review['author_details'] is Map
                                  ? review['author_details'] as Map
                                  : null;
                              final rating = authorDetails != null
                                  ? authorDetails['rating']?.toString()
                                  : null;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 16.0),
                                padding: const EdgeInsets.all(16.0),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0x0DFFFFFF,
                                  ), // 5% opacity white
                                  borderRadius: BorderRadius.circular(8.0),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          author,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const Spacer(),
                                        if (rating != null) ...[
                                          const Icon(
                                            Icons.star,
                                            color: Color(0xFF1CE783),
                                            size: 16,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            rating,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      content,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        height: 1.4,
                                      ),
                                      maxLines: 5,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
          if (!_showContent)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF1CE783)),
            ),
        ],
      ),
    );
  }
}

class ActorDetailsPage extends StatefulWidget {
  final int actorId;
  final String actorName;
  const ActorDetailsPage({
    super.key,
    required this.actorId,
    required this.actorName,
  });

  @override
  State<ActorDetailsPage> createState() => _ActorDetailsPageState();
}

class _ActorDetailsPageState extends State<ActorDetailsPage> {
  bool isLoading = true;
  Map<String, dynamic>? actorDetails;
  List<dynamic> knownFor = [];

  @override
  void initState() {
    super.initState();
    _fetchActorDetails();
  }

  Future<void> _fetchActorDetails() async {
    try {
      final url =
          'https://api.themoviedb.org/3/person/${widget.actorId}?api_key=$tmdbApiKey&append_to_response=combined_credits';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          actorDetails = data;
          final cast = data['combined_credits']?['cast'] as List? ?? [];
          // Sort by vote count to show the most popular works first
          cast.sort((a, b) {
            final double popA =
                double.tryParse(a['vote_count']?.toString() ?? '0') ?? 0.0;
            final double popB =
                double.tryParse(b['vote_count']?.toString() ?? '0') ?? 0.0;
            return popB.compareTo(popA);
          });
          // Filter out unreleased titles and grab the top 20
          knownFor = cast
              .where((item) => _isReleased(item, strictFilter: true))
              .take(20)
              .toList();
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    if (isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F1014),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFF1CE783)),
        ),
      );
    }

    if (actorDetails == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F1014),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: Text(
            'Failed to load actor details.',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final details = actorDetails!;
    final profilePath = details['profile_path']?.toString();
    final imageUrl = profilePath != null
        ? 'https://image.tmdb.org/t/p/w500$profilePath'
        : 'https://via.placeholder.com/500x750?text=No+Image';
    final biography =
        details['biography']?.toString() ?? 'No biography available.';
    final birthday = details['birthday']?.toString() ?? '';
    final deathday = details['deathday']?.toString() ?? '';
    final placeOfBirth = details['place_of_birth']?.toString() ?? '';
    final knownForDepartment =
        details['known_for_department']?.toString() ?? '';

    String ageStr = '';
    if (birthday.isNotEmpty) {
      try {
        final bDate = DateTime.parse(birthday);
        final eDate = deathday.isNotEmpty
            ? DateTime.parse(deathday)
            : DateTime.now();
        int age = eDate.year - bDate.year;
        if (eDate.month < bDate.month ||
            (eDate.month == bDate.month && eDate.day < bDate.day)) {
          age--;
        }
        ageStr = ' (Age $age)';
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.actorName,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    width: isMobile ? 120 : 200,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      width: isMobile ? 120 : 200,
                      height: isMobile ? 180 : 300,
                      color: Colors.white24,
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: isMobile ? 120 : 200,
                      height: isMobile ? 180 : 300,
                      color: Colors.white24,
                      child: const Icon(
                        Icons.person,
                        color: Colors.white54,
                        size: 50,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.actorName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isMobile ? 24 : 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (knownForDepartment.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Known For: $knownForDepartment',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (birthday.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Born: $birthday${deathday.isEmpty ? ageStr : ''}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (deathday.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Died: $deathday$ageStr',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (placeOfBirth.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Place of Birth: $placeOfBirth',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Text(
              'Biography',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              biography,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            if (knownFor.isNotEmpty)
              HorizontalMediaList(categoryTitle: 'Known For', items: knownFor),
            const SizedBox(height: 40),
          ],
        ),
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
  bool _triedFallbackProxy = false;

  @override
  void initState() {
    super.initState();
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (useWebView) {
      late final PlatformWebViewControllerCreationParams params;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        params = WindowsWebViewControllerCreationParams();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      _webController = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        );

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webController!.platform as dynamic)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      _webController!.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
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
            debugPrint('Webview Resource Error: \${error.description}');
            if (!_triedFallbackProxy &&
                (error.description.toLowerCase().contains('refused') ||
                    error.description.toLowerCase().contains('connection') ||
                    error.description.toLowerCase().contains('failed'))) {
              setState(() => _triedFallbackProxy = true);
              _loadHtml();
              return;
            }
            if (error.isForMainFrame == true) {
              _fallbackToExternal();
            }
          },
          onHttpError: (error) {
            debugPrint('Webview HTTP Error: \${error.response?.statusCode}');
            if (!_triedFallbackProxy &&
                (error.response?.statusCode == 502 ||
                    error.response?.statusCode == 503 ||
                    error.response?.statusCode == 403)) {
              setState(() => _triedFallbackProxy = true);
              _loadHtml();
            }
          },
        ),
      );
      _loadHtml();
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

  void _loadHtml() {
    // ignore: unused_local_variable
    final youtubeUrl =
        'https://www.youtube.com/embed/\${widget.trailerKey}?autoplay=1&playsinline=1&origin=http://localhost';
    // ignore: unused_local_variable
    final proxyUrl = _triedFallbackProxy
        ? 'https://cors-anywhere.com/\$youtubeUrl'
        : 'https://corsproxy.io/?\${Uri.encodeComponent(youtubeUrl)}';

    _webController!.loadHtmlString('''
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
          src="\$proxyUrl" 
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" 
          allowfullscreen>
        </iframe>
      </body>
      </html>
    ''', baseUrl: 'https://localhost:5000');
  }

  Future<void> _fallbackToExternal() async {
    if (!mounted || _hasFailed) return;
    _hasFailed = true;
    setState(() => _isLoading = false);
    final url = Uri.parse(
      'https://www.youtube.com/watch?v=\${widget.trailerKey}',
    );
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
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Dialog(
      backgroundColor: isMobile
          ? Colors.black.withOpacity(0.95)
          : Colors.transparent,
      insetPadding: isMobile
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
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
                        final url = Uri.parse(
                          'https://www.youtube.com/watch?v=\${widget.trailerKey}',
                        );
                        if (await canLaunchUrl(url)) {
                          await launchUrl(
                            url,
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                      icon: const Icon(
                        Icons.open_in_browser,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'Watch Externally',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 30,
                    ),
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
                            const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF1CE783),
                              ),
                            ),
                        ],
                      )
                    : (_ytController != null
                          ? YoutubePlayer(controller: _ytController!)
                          : const SizedBox.shrink()),
              ),
            ),
            if (isMobile) const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class FullscreenTrailerPage extends StatefulWidget {
  final String trailerKey;
  const FullscreenTrailerPage({super.key, required this.trailerKey});

  @override
  State<FullscreenTrailerPage> createState() => _FullscreenTrailerPageState();
}

class _FullscreenTrailerPageState extends State<FullscreenTrailerPage> {
  WebViewController? _webController;
  YoutubePlayerController? _ytController;
  bool _isLoading = true;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _fallbackTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    });

    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (useWebView) {
      late final PlatformWebViewControllerCreationParams params;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        params = WindowsWebViewControllerCreationParams();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      _webController = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..addJavaScriptChannel(
          'FlutterVideo',
          onMessageReceived: (message) {
            if (message.message == 'playing' && mounted) {
              setState(() => _isLoading = false);
            } else if (message.message == 'ended' && mounted) {
              Navigator.of(context).pop();
            }
          },
        );

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webController!.platform as dynamic)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      final html =
          '''
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            body { margin: 0; background: black; overflow: hidden; }
            iframe { border: none; width: 100vw; height: 100vh; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script>
            var tag = document.createElement('script');
            tag.src = "https://www.youtube.com/iframe_api";
            var firstScriptTag = document.getElementsByTagName('script')[0];
            firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
            
            var player;
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                height: '100%',
                width: '100%',
                videoId: '${widget.trailerKey}',
                playerVars: {
                  'autoplay': 1,
                  'controls': 1,
                  'disablekb': 0,
                  'fs': 0,
                  'modestbranding': 1,
                  'playsinline': 1,
                  'rel': 0,
                  'showinfo': 0,
                  'iv_load_policy': 3
                },
                events: {
                  'onReady': function(event) {
                    event.target.playVideo();
                  },
                  'onStateChange': function(event) {
                    if (event.data == YT.PlayerState.PLAYING) {
                      if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage('playing');
                      else if (window.FlutterVideo) window.FlutterVideo.postMessage('playing');
                    } else if (event.data == YT.PlayerState.ENDED) {
                      if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage('ended');
                      else if (window.FlutterVideo) window.FlutterVideo.postMessage('ended');
                    }
                  }
                }
              });
            }
          </script>
        </body>
        </html>
      ''';
      _webController!.loadHtmlString(html, baseUrl: 'http://localhost:5000');
    } else {
      _ytController = YoutubePlayerController.fromVideoId(
        videoId: widget.trailerKey,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
          pointerEvents: PointerEvents.auto,
        ),
      );
      _ytController!.listen((event) {
        if (event.playerState == PlayerState.playing && mounted && _isLoading) {
          setState(() => _isLoading = false);
        } else if (event.playerState == PlayerState.ended && mounted) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _ytController?.close();
    if (_webController != null) {
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (useWebView && _webController != null)
            Positioned.fill(child: WebViewWidget(controller: _webController!))
          else if (!useWebView && _ytController != null)
            Positioned.fill(child: YoutubePlayer(controller: _ytController!)),

          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF1CE783)),
            ),

          Positioned(
            top: 20,
            left: 20,
            child: SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 24),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
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
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _resetControlsTimer();

    final isNativeWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

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
                margin: EdgeInsets.only(
                  bottom: bottomMargin,
                  left: leftMargin,
                  right: 24,
                ),
                dismissDirection: DismissDirection.horizontal,
                padding:
                    EdgeInsets.zero, // Remove default padding to use our own
                content: ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1F24).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(12.0),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      child: const Text(
                        'Having issues loading the video?\nTry switching to the Sage server!',
                        style: TextStyle(
                          color: Color(0xFF1CE783),
                          fontSize: 14,
                        ),
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

      late final PlatformWebViewControllerCreationParams params;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        params = WindowsWebViewControllerCreationParams();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      _webViewController = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'FlutterControls',
          onMessageReceived: (message) {
            if (message.message == 'hover') {
              _resetControlsTimer();
            } else if (message.message == 'pop') {
              _stopAndPop();
            }
          },
        )
        ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        )
        ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        );

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webViewController!.platform as dynamic)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      _webViewController!
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (String url) {
              _resetControlsTimer();
              final isAndroid = defaultTargetPlatform == TargetPlatform.android;
              final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
              final backBtnTop = isIOS
                  ? 'calc(env(safe-area-inset-top, 0px) + 36px)'
                  : 'calc(env(safe-area-inset-top, 0px) + 4px)';
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
                backBtn.style.top = '$backBtnTop';
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
              
                // Inject PiP button
                var pipBtn = document.createElement('div');
                pipBtn.style.position = 'fixed';
                pipBtn.style.top = '$backBtnTop';
                pipBtn.style.right = 'calc(env(safe-area-inset-right, 0px) + 4px)';
                pipBtn.style.width = '48px';
                pipBtn.style.height = '48px';
                pipBtn.style.borderRadius = '50%';
                pipBtn.style.backgroundColor = 'rgba(0, 0, 0, 0.4)';
                pipBtn.style.backdropFilter = 'blur(4px)';
                pipBtn.style.WebkitBackdropFilter = 'blur(4px)';
                pipBtn.style.display = 'flex';
                pipBtn.style.alignItems = 'center';
                pipBtn.style.justifyContent = 'center';
                pipBtn.style.cursor = 'pointer';
                pipBtn.style.zIndex = '2147483647';
                pipBtn.style.transition = 'opacity 0.3s ease';
                pipBtn.style.filter = 'drop-shadow(0px 2px 6px rgba(0,0,0,0.8))';
                pipBtn.style.pointerEvents = 'auto';
                pipBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M19 11h-8v6h8v-6zm4 8V4.98C23 3.88 22.1 3 21 3H3c-1.1 0-2 .88-2 1.98V19c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2zm-2 .02H3V4.97h18v14.05z"/></svg>';
            
                function triggerPip(e) {
                  e.preventDefault();
                  e.stopPropagation();
                  var videos = document.querySelectorAll('video');
                  for (var i = 0; i < videos.length; i++) {
                    if (videos[i].readyState > 0) {
                      if (videos[i].webkitSetPresentationMode && videos[i].webkitPresentationMode !== "picture-in-picture") {
                        videos[i].webkitSetPresentationMode("picture-in-picture");
                      } else if (videos[i].requestPictureInPicture) {
                        videos[i].requestPictureInPicture();
                      }
                      break;
                    }
                  }
                }
                pipBtn.addEventListener('click', triggerPip, true);
                pipBtn.addEventListener('touchstart', triggerPip, true);
                document.body.appendChild(pipBtn);

                // Force playsinline on all videos to ensure it stays inline on iOS
                setInterval(function() {
                  var videos = document.querySelectorAll('video');
                  for (var i = 0; i < videos.length; i++) {
                    if (!videos[i].hasAttribute('playsinline')) {
                      videos[i].setAttribute('playsinline', 'playsinline');
                      videos[i].setAttribute('webkit-playsinline', 'webkit-playsinline');
                    }
                  }
                }, 1000);

                var hideTimeout;
                function resetHideTimer() {
                  if (typeof FlutterControls !== 'undefined') FlutterControls.postMessage('hover');
                  else if (window.FlutterControls) window.FlutterControls.postMessage('hover');
                  if (backBtn) backBtn.style.opacity = '1';
                  if (pipBtn) pipBtn.style.opacity = '1';
                  clearTimeout(hideTimeout);
                  hideTimeout = setTimeout(function() {
                    if (backBtn) backBtn.style.opacity = '0';
                    if (pipBtn) pipBtn.style.opacity = '0';
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
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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
    final isNativeWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

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
            appBar: isNativeWebView
                ? null
                : AppBar(
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
