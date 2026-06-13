import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/outputs/log_stream_output.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:universal_io/io.dart';
import 'package:get_it/get_it.dart';

// ignore: library_prefixes
import 'package:logger/logger.dart' as LoggerFactory;

import 'outputs/debug_console_output.dart';
import 'outputs/file_output_wrapper.dart';
import 'outputs/rotating_file_output.dart';

// ignore: non_constant_identifier_names
BaseLogger get Logger => GetIt.I<BaseLogger>();

enum LogLevel { INFO, WARN, ERROR, DEBUG, TRACE, FATAL }

const Map<Level, bool> defaultExcludeBoxes = {
  LoggerFactory.Level.debug: true,
  LoggerFactory.Level.info: true,
  LoggerFactory.Level.warning: true,
  LoggerFactory.Level.error: false,
  LoggerFactory.Level.trace: false,
  LoggerFactory.Level.fatal: false,
};

class BaseLogger {
  LoggerFactory.Logger _logger = LoggerFactory.Logger();

  final StreamController<String> logStream = StreamController<String>.broadcast();
  final latestLogName = 'bluebubbles-latest.log';

  LoggerFactory.LogOutput get fileOutput {
    final baseFileOutput = RotatingFileOutput(
      dirPath: logDir,
      latestFileName: latestLogName,
      maxFileSizeKB: 1024 * 5, // 5 MB
      maxRotatedFilesCount: 5, // Total: 25 MB of logs before old logs are deleted
      encoding: utf8,
      fileNameFormatter: (_) {
        final now = DateTime.now();
        return 'bluebubbles-${now.toIso8601String().split('T').first}-${now.millisecondsSinceEpoch ~/ 1000}.log';
      },
    );

    // Wrap with ANSI stripper to ensure file is valid UTF-8
    return FileOutputWrapper(baseFileOutput);
  }

  LoggerFactory.LogOutput get defaultOutput {
    List<LogOutput> outputs = kDebugMode ? [DebugConsoleOutput()] : [];
    if (!kIsWeb) outputs.add(fileOutput);
    return LoggerFactory.MultiOutput(outputs);
  }

  LoggerFactory.LogFilter? _currentFilter;
  set currentFilter(LoggerFactory.LogFilter? filter) {
    _currentFilter = filter;
    _logger = createLogger();
  }

  LoggerFactory.LogFilter get currentFilter {
    return _currentFilter ?? LoggerFactory.ProductionFilter();
  }

  LoggerFactory.LogOutput? _currentOutput;
  set currentOutput(LoggerFactory.LogOutput? output) {
    _currentOutput = output;
    _logger = createLogger();
  }

  LoggerFactory.LogOutput get currentOutput {
    return _currentOutput ?? defaultOutput;
  }

  LoggerFactory.Level? _currentLevel;
  set currentLevel(LoggerFactory.Level? level) {
    _currentLevel = level;
    info("Setting log level to $level");
    _logger = createLogger();
  }

  LoggerFactory.Level? get currentLevel {
    return _currentLevel ?? LoggerFactory.Level.info;
  }

  bool? _showColors;
  set showColors(bool show) {
    _showColors = show;
    _logger = createLogger();
  }

  bool get showColors {
    return _showColors ?? kDebugMode;
  }

  Map<Level, bool>? _excludeBoxes;
  set excludeBoxes(Map<Level, bool> boxes) {
    _excludeBoxes = boxes;
    _logger = createLogger();
  }

  Map<Level, bool> get excludeBoxes {
    return _excludeBoxes ?? defaultExcludeBoxes;
  }

  String get logDir {
    return FilesystemSvc.logsPath;
  }

  LoggerFactory.Logger get logger {
    return _logger;
  }

  String _isolateName = "main";

  Future<void> init() async {
    // Ensure log directory and latest log file exist before AdvancedFileOutput
    // initializes — it calls file.length() which throws PathNotFoundException if
    // the file has not been created yet (e.g. first run or after cache clear).
    if (!kIsWeb) {
      final dir = Directory(logDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final latestLog = File(join(logDir, latestLogName));
      if (!latestLog.existsSync()) latestLog.createSync();
    }

    _logger = createLogger();
    _isolateName = isolateNameOverride ?? Isolate.current.debugName ?? "main";

    if (SettingsSvc.initCompleted.isCompleted) {
      currentLevel = SettingsSvc.settings.logLevel.value;
    } else {
      SettingsSvc.initCompleted.future.then((_) {
        currentLevel = SettingsSvc.settings.logLevel.value;
      });
    }

    // Add initial data to logStream
    logStream.sink.add("Logger initialized");
  }

  LoggerFactory.Logger createLogger() {
    return LoggerFactory.Logger(
      filter: currentFilter,
      printer: LoggerFactory.PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 25,
        lineLength: 120,
        colors: showColors,
        printEmojis: false,
        // Don't contain a timestamp, we will add it in ourselves
        dateTimeFormat: LoggerFactory.DateTimeFormat.none,
        excludeBox: excludeBoxes,
        noBoxingByDefault: true,
        levelColors: {
          Level.trace: const AnsiColor.fg(5),
          Level.debug: AnsiColor.fg(AnsiColor.grey(0.5)),
          Level.info: const AnsiColor.fg(12),
          Level.warning: const AnsiColor.fg(208),
          Level.error: const AnsiColor.fg(196),
          Level.fatal: const AnsiColor.fg(199),
        },
      ),
      output: currentOutput,
      level: currentLevel,
    );
  }

  void reset() {
    _currentFilter = null;
    _currentOutput = null;
    _currentLevel = null;
    _showColors = null;
    _excludeBoxes = null;

    if (SettingsSvc.initCompleted.isCompleted) {
      _currentLevel = SettingsSvc.settings.logLevel.value;
    }

    _logger = createLogger();
  }

  void enableLiveLogging() {
    List<LogOutput> outputs = [DebugConsoleOutput(), LogStreamOutput()];
    if (!kIsWeb) outputs.add(fileOutput);
    _currentOutput = LoggerFactory.MultiOutput(outputs);
    _showColors = false;
    _logger = createLogger();
  }

  void disableLiveLogging() {
    _currentOutput = null;
    _showColors = null;
    _logger = createLogger();
  }

  Future<String> compressLogs() async {
    try {
      final Directory logDir = Directory(Logger.logDir);
      if (!logDir.existsSync()) {
        throw Exception("Log directory does not exist");
      }

      final date = DateTime.now().toIso8601String().split('T').first;
      final File zippedLogFile = File(join(FilesystemSvc.appDocDir.path, "bluebubbles-logs-$date.zip"));
      if (zippedLogFile.existsSync()) zippedLogFile.deleteSync();

      final List<FileSystemEntity> files = logDir.listSync();
      final List<FileSystemEntity> logFiles = files.where((file) => file.path.endsWith(".log")).toList();

      if (logFiles.isEmpty) {
        throw Exception("No log files found to compress");
      }

      final List<String> logPaths = logFiles.map((file) => file.path).toList();

      final encoder = ZipFileEncoder();
      encoder.create(zippedLogFile.path);
      for (final logPath in logPaths) {
        await encoder.addFile(File(logPath));
      }
      await encoder.close();

      return zippedLogFile.path;
    } catch (e, stackTrace) {
      error("Failed to compress logs", error: e, trace: stackTrace);
      rethrow;
    }
  }

  Future<List<String>> getLogs({maxLines = 1000}) async {
    try {
      final Directory logDir = Directory(Logger.logDir);
      if (!logDir.existsSync()) return [];

      final List<FileSystemEntity> files = logDir.listSync();
      final List<FileSystemEntity> logFiles = files.where((file) => file.path.endsWith(latestLogName)).toList();
      if (logFiles.isEmpty) return [];

      final File logFile = logFiles.first as File;
      if (!logFile.existsSync()) return [];

      final List<String> lines = await logFile
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .toList();

      // Combine lines that are part of the same log message
      List<String> logs = [];
      String currentLog = "";
      for (final log in lines) {
        // Remove ansi colors (defensive, should already be stripped)
        String line = log.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

        // If the log starts with a date, then it's a new log
        if (line.startsWith(RegExp(r"\d{4}-\d{2}-\d{2}"))) {
          if (currentLog.isNotEmpty) logs.add(currentLog);
          currentLog = line;
        } else {
          currentLog += "\n$line";
        }
      }

      // Don't forget to add the last log entry
      if (currentLog.isNotEmpty) logs.add(currentLog);

      // Take the last [maxLines] logs.
      // We only want the logs starting from the end. But we want to keep the order of the logs.
      logs = logs.reversed.take(maxLines).toList().reversed.toList();
      return logs;
    } catch (e, stackTrace) {
      // Log the error but don't use the logger to avoid recursion
      debugPrint("Error reading logs: $e\n$stackTrace");
      return [];
    }
  }

  void clearLogs() {
    try {
      final Directory logDir = Directory(Logger.logDir);
      if (!logDir.existsSync()) return;

      for (final file in logDir.listSync()) {
        if (file is File) {
          file.deleteSync();
        }
      }
    } catch (e, stackTrace) {
      debugPrint("Error clearing logs: $e\n$stackTrace");
    }
  }

  /// Dispose of resources when the logger is no longer needed
  Future<void> dispose() async {
    await logStream.close();
    // Close the underlying logger output if needed
    await currentOutput.destroy();
  }

  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.i("${DateTime.now().toUtc().toIso8601String()} [INFO] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);

  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.w("${DateTime.now().toUtc().toIso8601String()} [WARN] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);

  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.d("${DateTime.now().toUtc().toIso8601String()} [DEBUG] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);

  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.e("${DateTime.now().toUtc().toIso8601String()} [ERROR] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);

  void trace(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.t("${DateTime.now().toUtc().toIso8601String()} [TRACE] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error ?? Traceback(), stackTrace: trace);

  void fatal(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.f("${DateTime.now().toUtc().toIso8601String()} [FATAL] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);

  void test(dynamic log, {String? tag, Object? error, StackTrace? trace}) =>
      logger.f("${DateTime.now().toUtc().toIso8601String()} [TEST] [$_isolateName] [${tag ?? "BlueBubblesApp"}] $log",
          error: error, stackTrace: trace);
}

class Traceback implements Exception {
  final StackTrace? stackTrace;

  Traceback([this.stackTrace]);

  @override
  String toString() {
    return "Traceback";
  }
}
