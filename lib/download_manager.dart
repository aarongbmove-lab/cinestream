import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';

enum DownloadStatus { none, requesting, downloading, finalizing, done, failed }

class SimpleLock {
  Completer<void>? _completer;

  Future<void> acquire() async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
  }

  void release() {
    final c = _completer;
    _completer = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  Future<T> synchronized<T>(FutureOr<T> Function() computation) async {
    await acquire();
    try {
      return await computation();
    } finally {
      release();
    }
  }
}

class DownloadTask extends ChangeNotifier {
  final String mediaId;
  DownloadStatus _status = DownloadStatus.none;
  DownloadStatus get status => _status;
  double _progress = 0.0;
  double get progress => _progress;

  DownloadTask({required this.mediaId});

  void update({DownloadStatus? newStatus, double? newProgress}) {
    bool changed = false;
    if (newStatus != null && _status != newStatus) {
      _status = newStatus;
      changed = true;
    }
    if (newProgress != null && _progress != newProgress) {
      _progress = newProgress;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }
}

class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, List<http.Client>> _clients = {};
  final Map<String, bool> _cancellations = {};
  final SimpleLock _lock = SimpleLock();

  final StreamController<String> _messageController = StreamController.broadcast();
  Stream<String> get messages => _messageController.stream;

  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  DownloadTask? getTask(String mediaId) => _tasks[mediaId];

  void cancelDownload(String mediaId) {
    if (!_cancellations.containsKey(mediaId) || _cancellations[mediaId] == true) return;
    _cancellations[mediaId] = true;

    final clients = _clients[mediaId];
    if (clients != null) {
      for (var client in clients) {
        client.close();
      }
      clients.clear();
    }

    final task = _tasks[mediaId];
    if (task != null) {
      task.update(newStatus: DownloadStatus.failed);
      _messageController.add('ERROR:Download cancelled.');
      _scheduleTaskCleanup(mediaId);
    }
  }

  Future<void> startDownload({
    required String mediaId,
    required String title,
    required String year,
    required String resolution,
  }) async {
    if (_tasks.containsKey(mediaId) &&
        (_tasks[mediaId]!.status == DownloadStatus.downloading ||
            _tasks[mediaId]!.status == DownloadStatus.requesting ||
            _tasks[mediaId]!.status == DownloadStatus.finalizing)) {
      return;
    }

    final task = DownloadTask(mediaId: mediaId);
    _tasks[mediaId] = task;
    _cancellations[mediaId] = false;

    // Check for a previously downloaded file that failed during conversion.
    final docsDir = await getApplicationDocumentsDirectory();
    final pendingDir = Directory('${docsDir.path}/pending_conversions');
    await pendingDir.create(recursive: true);
    final rawFileName = '$mediaId+$title.tmp'.replaceAll(RegExp(r'[^\w\s\.-]+'), '').replaceAll(' ', '_');
    final pendingPath = '${pendingDir.path}/$rawFileName';
    final pendingFile = File(pendingPath);

    if (await pendingFile.exists()) {
      _messageController.add('INFO:Found incomplete download. Retrying finalization...');
      await _processDownload(mediaId, title, null, localFilePath: pendingPath);
      return;
    }

    task.update(newStatus: DownloadStatus.requesting, newProgress: 0.0);

    try {
      final url = Uri.parse('http://162.191.17.178:8088/query');
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Basic ${base64Encode(utf8.encode('cinestream:privateapi'))}',
        'User-Agent': _browserUserAgent,
        'Referer': url.origin,
      };
      final body = json.encode({'text': '$title $year'.trim(), 'resolution': resolution});

      final response = await http.post(url, headers: headers, body: body);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        var downloadUrl = responseData['url'] as String?;

        if (downloadUrl != null && downloadUrl.isNotEmpty) {
          if (downloadUrl.startsWith('//')) {
            downloadUrl = 'https:$downloadUrl';
          }
          await _processDownload(mediaId, title, downloadUrl);
        } else {
          throw Exception('API returned an empty URL.');
        }
      } else {
        throw Exception('API request failed with status: ${response.statusCode}\nBody: ${response.body}');
      }
    } catch (e) {
      task.update(newStatus: DownloadStatus.failed);
      _messageController.add('ERROR:Failed to initiate download: $e');
      _scheduleTaskCleanup(mediaId);
    }
  }

  Future<void> _processDownload(String mediaId, String title, String? downloadUrl, {String? localFilePath}) async {
    final task = _tasks[mediaId]!;

    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      task.update(newStatus: DownloadStatus.failed);
      _messageController.add('ERROR:Photo library permission is required.');
      if (ps == PermissionState.denied) await openAppSettings();
      _scheduleTaskCleanup(mediaId);
      return;
    }

    final rawFileName = '$mediaId+$title.tmp'.replaceAll(RegExp(r'[^\w\s\.-]+'), '').replaceAll(' ', '_');
    final finalFileName = '$mediaId+$title.mp4'.replaceAll(RegExp(r'[^\w\s\.-]+'), '').replaceAll(' ', '_');
    final tempDir = await getTemporaryDirectory();
    final rawTempPath = '${tempDir.path}/$rawFileName';
    final finalTempPath = '${tempDir.path}/$finalFileName';
    final rawTempFile = File(rawTempPath);
    final finalTempFile = File(finalTempPath);

    try {
      if (localFilePath != null) {
        // This is a retry from a saved file. Move it to the temp dir for processing.
        await File(localFilePath).rename(rawTempPath);
      } else if (downloadUrl != null) {
        task.update(newStatus: DownloadStatus.downloading);
        await _downloadFileInParts(mediaId, downloadUrl, rawTempPath);
      } else {
        throw Exception('Process download called without a URL or local file.');
      }

      if (_cancellations[mediaId] == true) throw http.ClientException("Download cancelled by user.");

      task.update(newStatus: DownloadStatus.finalizing, newProgress: 0.0);
      _messageController.add('INFO:Finalizing download...');

      String videoCodec;
      if (Platform.isIOS || Platform.isMacOS) {
        videoCodec = '-c:v h264_videotoolbox';
      } else {
        videoCodec = '-c:v libx264 -preset ultrafast';
      }

      // Use executeAsync to get progress updates during conversion.
      final completer = Completer<ReturnCode?>();
      double totalDurationInMs = 0;

      await FFmpegKit.executeAsync(
        '-y -i "$rawTempPath" -map 0:v? $videoCodec -map 0:a? -c:a aac -map 0:s? -c:s mov_text "$finalTempPath"',
        (session) async {
          final returnCode = await session.getReturnCode();
          completer.complete(returnCode);
        },
        (log) {
          // Parse the total duration from the FFmpeg logs.
          if (totalDurationInMs == 0) {
            final regex = RegExp(r"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d{2})");
            final match = regex.firstMatch(log.getMessage());
            if (match != null) {
              final hours = double.parse(match.group(1)!);
              final minutes = double.parse(match.group(2)!);
              final seconds = double.parse(match.group(3)!);
              final milliseconds = double.parse(match.group(4)!) * 10;
              totalDurationInMs = (hours * 3600 + minutes * 60 + seconds) * 1000 + milliseconds;
            }
          }
        },
        (statistics) {
          // Update progress based on the current time of the statistics callback.
          if (totalDurationInMs > 0) {
            final progress = (statistics.getTime() / totalDurationInMs).clamp(0.0, 1.0);
            task.update(newProgress: progress);
          }
        },
      );

      final returnCode = await completer.future;

      if (returnCode == null || !ReturnCode.isSuccess(returnCode)) {
        // Conversion failed, save the raw file for a later retry.
        final docsDir = await getApplicationDocumentsDirectory();
        final pendingDir = Directory('${docsDir.path}/pending_conversions');
        await pendingDir.create(recursive: true);
        final pendingPath = '${pendingDir.path}/$rawFileName';
        if (await rawTempFile.exists()) {
          await rawTempFile.rename(pendingPath);
        }
        throw Exception('Failed to finalize video. Will retry on next attempt. (FFmpeg Error)');
      }

      // ignore: unnecessary_nullable_for_final_variable_declarations
      final AssetEntity? entity = await PhotoManager.editor.saveVideo(finalTempFile, title: finalFileName, relativePath: "Movies/CineStream");

      if (entity != null) {
        task.update(newStatus: DownloadStatus.done, newProgress: 1.0);
        _messageController.add('SUCCESS:Download complete! Saved to "CineStream" album.');

        // On success, ensure any lingering pending file is deleted.
        final docsDir = await getApplicationDocumentsDirectory();
        final pendingDir = Directory('${docsDir.path}/pending_conversions');
        final pendingPath = '${pendingDir.path}/$rawFileName';
        final pendingFile = File(pendingPath);
        if (await pendingFile.exists()) {
          await pendingFile.delete();
        }
      } else {
        throw Exception('Failed to save video to gallery.');
      }
    } catch (e) {
      if (_cancellations[mediaId] != true) {
        task.update(newStatus: DownloadStatus.failed);
        _messageController.add('ERROR:Download failed: ${e.toString().split(':').last.trim()}');
      }
    } finally {
      _clients.remove(mediaId);
      _cancellations.remove(mediaId);
      _scheduleTaskCleanup(mediaId);

      if (await rawTempFile.exists()) await rawTempFile.delete();
      if (await finalTempFile.exists()) await finalTempFile.delete();
    }
  }

  Future<void> _downloadFileInParts(String mediaId, String url, String savePath) async {
    _clients[mediaId] = [];
    final headClient = http.Client();
    _clients[mediaId]!.add(headClient);

    final headRequest = http.Request('HEAD', Uri.parse(url))..headers['User-Agent'] = _browserUserAgent;
    final headResponse = await headClient.send(headRequest);

    if (headResponse.statusCode != 200) throw Exception('Server responded with ${headResponse.statusCode}');
    final totalSize = headResponse.contentLength ?? 0;
    if (totalSize <= 0) throw Exception('Could not get file size.');

    final supportsRange = headResponse.headers['accept-ranges'] == 'bytes';
    if (!supportsRange) throw Exception('Server does not support parallel downloads.');

    final partCount = 8;
    final partSize = (totalSize / partCount).ceil();
    final parts = List.generate(partCount, (i) => i);
    final file = await File(savePath).open(mode: FileMode.write);
    int totalDownloaded = 0;
    final task = _tasks[mediaId]!;

    try {
      await file.truncate(totalSize);

      Future<void> downloadPart(int i) async {
        const maxRetries = 5;
        int retryCount = 0;
        int bytesDownloadedForPart = 0;
        final partStartByte = i * partSize;
        final partEndByte = min(partStartByte + partSize - 1, totalSize - 1);
        final expectedPartSize = partEndByte - partStartByte + 1;

        if (expectedPartSize <= 0) return;

        while (bytesDownloadedForPart < expectedPartSize) {
          if (_cancellations[mediaId] == true) return;

          final currentRequestStartByte = partStartByte + bytesDownloadedForPart;
          final rangeHeader = 'bytes=$currentRequestStartByte-$partEndByte';
          final partClient = http.Client();
          _clients[mediaId]!.add(partClient);

          try {
            final request = http.Request('GET', Uri.parse(url))..headers['Range'] = rangeHeader..headers['User-Agent'] = _browserUserAgent;
            final response = await partClient.send(request).timeout(const Duration(seconds: 20));

            if (response.statusCode != 206) throw http.ClientException('Server responded with ${response.statusCode} for range $rangeHeader', request.url);

            await for (final chunk in response.stream) {
              if (_cancellations[mediaId] == true) {
                partClient.close();
                return;
              }
              await _lock.synchronized(() async {
                await file.setPosition(partStartByte + bytesDownloadedForPart);
                await file.writeFrom(chunk);
                totalDownloaded += chunk.length;
                task.update(newProgress: (totalDownloaded / totalSize).clamp(0.0, 1.0));
              });
              bytesDownloadedForPart += chunk.length;
            }
            return;
          } catch (e) {
            partClient.close();
            if (e is SocketException || e is http.ClientException || e is TimeoutException || e is HandshakeException) {
              retryCount++;
              if (retryCount > maxRetries) throw Exception('Part $i failed after $maxRetries retries: $e');
              final delay = pow(2, retryCount).toInt();
              await Future.delayed(Duration(seconds: delay));
            } else {
              rethrow;
            }
          }
        }
      }

      await Future.wait(parts.map((i) => downloadPart(i)));
    } finally {
      await file.close();
    }
  }

  void _scheduleTaskCleanup(String mediaId) {
    Timer(const Duration(seconds: 5), () {
      final task = _tasks[mediaId];
      if (task != null && (task.status == DownloadStatus.done || task.status == DownloadStatus.failed)) {
        task.update(newStatus: DownloadStatus.none, newProgress: 0.0);
      }
    });
  }

  void dispose() {
    _messageController.close();
  }
}