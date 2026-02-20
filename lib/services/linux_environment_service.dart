import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../models/linux_environment.dart';
import '../models/python_package.dart';
import '../models/execution_result.dart';

class LinuxEnvironmentService {
  static const _channel = MethodChannel('com.pyom/linux_environment');
  static const _outputChannel = EventChannel('com.pyom/process_output');

  LinuxEnvironment? _currentEnvironment;
  StreamSubscription? _outputSubscription;
  final _outputController = StreamController<String>.broadcast();
  final _statsController  = StreamController<EnvironmentStats>.broadcast();

  // Progress callback from native setup
  final _progressController = StreamController<SetupProgress>.broadcast();

  Stream<String> get outputStream   => _outputController.stream;
  Stream<EnvironmentStats> get statsStream => _statsController.stream;
  Stream<SetupProgress> get progressStream => _progressController.stream;

  LinuxEnvironment? get currentEnvironment => _currentEnvironment;
  bool get isEnvironmentReady => _currentEnvironment?.isReady ?? false;

  // ─── PATHS ────────────────────────────────────────────────────────────────
  // IMPORTANT: Use getApplicationSupportDirectory() which maps to filesDir on Android.
  // This MUST match what Kotlin uses (filesDir).
  String? _appSupportDir;

  Future<String> get _envRoot async {
    _appSupportDir ??= (await getApplicationSupportDirectory()).path;
    return path.join(_appSupportDir!, 'linux_env');
  }

  Future<String> get _projectsDir async {
    _appSupportDir ??= (await getApplicationSupportDirectory()).path;
    return path.join(_appSupportDir!, 'projects');
  }

  // ─── INIT ─────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    _appSupportDir = (await getApplicationSupportDirectory()).path;

    await Directory(path.join(_appSupportDir!, 'linux_env')).create(recursive: true);
    await Directory(path.join(_appSupportDir!, 'projects')).create(recursive: true);
    await Directory(path.join(_appSupportDir!, 'bin')).create(recursive: true);

    // Listen to native output stream
    _outputSubscription = _outputChannel.receiveBroadcastStream().listen(
      (data) => _outputController.add(data.toString()),
      onError: (e)  => _outputController.addError(e),
    );

    // Listen for progress callbacks from native during setup
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onSetupProgress':
        final message  = call.arguments['message']  as String? ?? '';
        final progress = (call.arguments['progress'] as num?)?.toDouble() ?? 0.0;
        _progressController.add(SetupProgress(message: message, progress: progress));
      case 'onProotUpdated':
        // proot was silently updated in background
        final version = call.arguments['version'] as String? ?? 'unknown';
        _progressController.add(SetupProgress(
          message: '🔄 proot updated to v$version',
          progress: -1, // -1 = informational, not a setup progress
        ));
      case 'onOutput':
        _outputController.add(call.arguments.toString());
      case 'onStatsUpdate':
        if (call.arguments is Map) {
          final m = call.arguments as Map;
          _statsController.add(EnvironmentStats(
            cpuUsage:     (m['cpu']       ?? 0.0).toDouble(),
            memoryUsage:  (m['memory']    ?? 0.0).toDouble(),
            diskUsage:    (m['disk']      ?? 0.0).toDouble(),
            processCount: (m['processes'] ?? 0).toInt(),
            timestamp:    DateTime.now(),
          ));
        }
    }
  }

  // ─── ENVIRONMENT CHECK ────────────────────────────────────────────────────

  Future<bool> checkEnvironmentInstalled(String envId) async {
    try {
      // Ask native side — it checks bin/sh or etc/os-release inside the rootfs
      final result = await _channel.invokeMethod<bool>('isEnvironmentInstalled', {'envId': envId});
      return result ?? false;
    } catch (e) {
      // Fallback: check directory ourselves
      final root = await _envRoot;
      final envDir = Directory(path.join(root, envId));
      return await envDir.exists() && await File(path.join(envDir.path, 'bin', 'sh')).exists();
    }
  }

  // ─── INSTALL ENVIRONMENT ─────────────────────────────────────────────────

  Future<LinuxEnvironment> installEnvironment(LinuxEnvironment env) async {
    try {
      env.status = EnvironmentStatus.downloading;

      final result = await _channel.invokeMethod('setupEnvironment', {
        'distro': env.distribution,
        'envId':  env.id,
      });

      if (result is Map && result['success'] == true) {
        env.status      = EnvironmentStatus.ready;
        env.installedAt = DateTime.now();
        _currentEnvironment = env;
      } else {
        throw Exception('Setup returned no success flag');
      }

      return env;
    } on PlatformException catch (e) {
      env.status       = EnvironmentStatus.error;
      env.errorMessage = e.message ?? 'Unknown platform error';
      rethrow;
    } catch (e) {
      env.status       = EnvironmentStatus.error;
      env.errorMessage = e.toString();
      rethrow;
    }
  }

  // ─── EXECUTE COMMAND ──────────────────────────────────────────────────────

  Future<ExecutionResult> executeInEnvironment(
    LinuxEnvironment env,
    String command, {
    String workingDir = '/',
    Duration timeout  = const Duration(minutes: 10),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod('executeCommand', {
        'environmentId': env.id,
        'command':       command,
        'workingDir':    workingDir,
        'timeoutMs':     timeout.inMilliseconds,
      });
      sw.stop();
      return ExecutionResult(
        output:        result['stdout'] ?? '',
        error:         result['stderr'] ?? '',
        exitCode:      result['exitCode'] ?? -1,
        executionTime: sw.elapsed,
      );
    } on PlatformException catch (e) {
      sw.stop();
      return ExecutionResult(output: '', error: e.message ?? 'Error', exitCode: -1, executionTime: sw.elapsed);
    }
  }

  // ─── PYTHON EXECUTION ─────────────────────────────────────────────────────

  Future<ExecutionResult> executePythonCode(
    String code, {
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 30), // long for TF/PyTorch training
  }) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(
        output: '',
        error: 'No Linux environment configured. Please install an environment from Settings → Linux Environment.',
        exitCode: -1,
        executionTime: Duration.zero,
      );
    }

    final root = await _envRoot;
    final tmpDir = path.join(root, _currentEnvironment!.id, 'tmp');
    await Directory(tmpDir).create(recursive: true);

    final tmpFile = File(path.join(tmpDir, 'script_${DateTime.now().millisecondsSinceEpoch}.py'));
    await tmpFile.writeAsString(code);

    // Path inside proot chroot
    final chrootPath = '/tmp/${path.basename(tmpFile.path)}';

    final result = await executeInEnvironment(
      _currentEnvironment!,
      'python3 "$chrootPath" 2>&1',
      workingDir: '/tmp',
      timeout: timeout,
    );

    try { await tmpFile.delete(); } catch (_) {}
    return result;
  }

  // ─── PACKAGES ─────────────────────────────────────────────────────────────

  Future<List<PythonPackage>> listInstalledPackages() async {
    if (_currentEnvironment == null) return [];
    final result = await executeInEnvironment(_currentEnvironment!, 'pip3 list --format=json 2>/dev/null || pip list --format=json 2>/dev/null');
    if (!result.isSuccess) return [];
    try {
      final List<dynamic> packages = jsonDecode(result.output);
      return packages.map((p) => PythonPackage(name: p['name'], version: p['version'], isInstalled: true)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<ExecutionResult> installPackage(String packageName, {String? version}) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment configured', exitCode: -1, executionTime: Duration.zero);
    }
    final spec = version != null ? '$packageName==$version' : packageName;
    // --break-system-packages needed for Ubuntu 23+, harmless on Alpine
    return executeInEnvironment(
      _currentEnvironment!,
      'pip3 install $spec --break-system-packages 2>&1 || pip3 install $spec 2>&1',
      timeout: const Duration(minutes: 60), // TF/PyTorch can take a while
    );
  }

  Future<ExecutionResult> uninstallPackage(String packageName) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment configured', exitCode: -1, executionTime: Duration.zero);
    }
    return executeInEnvironment(_currentEnvironment!, 'pip3 uninstall -y $packageName');
  }

  // ─── LLM MODELS ───────────────────────────────────────────────────────────

  Future<ExecutionResult> runLlamaModel(
    String modelPath, {
    String prompt     = '',
    int    maxTokens  = 512,
    double temperature = 0.7,
  }) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment configured', exitCode: -1, executionTime: Duration.zero);
    }

    // Install llama-cpp-python if needed
    final checkResult = await executeInEnvironment(_currentEnvironment!, 'pip3 show llama-cpp-python 2>/dev/null | grep -c Name');
    if (checkResult.output.trim() == '0' || checkResult.output.trim().isEmpty) {
      await executeInEnvironment(
        _currentEnvironment!,
        'pip3 install llama-cpp-python --break-system-packages 2>&1 || pip3 install llama-cpp-python 2>&1',
        timeout: const Duration(minutes: 45),
      );
    }

    // Escape the prompt
    final escapedPrompt = prompt.replaceAll('"', '\\"').replaceAll('\n', '\\n');

    final script = '''
from llama_cpp import Llama
import sys
llm = Llama(model_path="$modelPath", n_ctx=2048, verbose=False)
output = llm("$escapedPrompt", max_tokens=$maxTokens, temperature=$temperature, stop=["</s>"])
print(output['choices'][0]['text'], end='')
''';

    return executePythonCode(script, timeout: const Duration(minutes: 30));
  }

  // ─── GALLERY / FILE OPERATIONS ────────────────────────────────────────────

  /// Save a file to the device Downloads/Pyom folder
  Future<String?> saveFileToDownloads(String sourcePath, String fileName) async {
    try {
      final result = await _channel.invokeMethod('saveFileToDownloads', {
        'sourcePath': sourcePath,
        'fileName':   fileName,
      });
      return result['path'] as String?;
    } on PlatformException catch (e) {
      throw Exception('Failed to save to Downloads: ${e.message}');
    }
  }

  /// Share a file using Android share sheet
  Future<void> shareFile(String filePath) async {
    try {
      await _channel.invokeMethod('shareFile', {'filePath': filePath});
    } on PlatformException catch (e) {
      throw Exception('Failed to share: ${e.message}');
    }
  }

  /// Get storage info (paths, free space)
  Future<Map<String, dynamic>> getStorageInfo() async {
    try {
      final result = await _channel.invokeMethod('getStorageInfo');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {};
    }
  }

  // ─── PROJECT FILES ────────────────────────────────────────────────────────

  Future<String> get projectsBasePath async => await _projectsDir;

  Future<void> createProjectDirectory(String projectId) async {
    final dir = Directory(path.join(await _projectsDir, projectId));
    await dir.create(recursive: true);
  }

  Future<void> writeProjectFile(String projectId, String fileName, String content) async {
    final filePath = path.join(await _projectsDir, projectId, fileName);
    await File(filePath).writeAsString(content);
  }

  Future<String> readProjectFile(String projectId, String fileName) async {
    return File(path.join(await _projectsDir, projectId, fileName)).readAsString();
  }

  // ─── PROOT SELF-UPDATE ────────────────────────────────────────────────────

  /// Check if proot has a newer version and update silently.
  /// Called on app start after environment is confirmed ready.
  Future<void> checkProotUpdate() async {
    try {
      await _channel.invokeMethod('checkProotUpdate');
    } catch (_) {
      // Non-critical — silently ignore
    }
  }

  // ─── CLEANUP ──────────────────────────────────────────────────────────────

  void setCurrentEnvironment(LinuxEnvironment env) {
    _currentEnvironment = env;
  }

  void dispose() {
    _outputSubscription?.cancel();
    _outputController.close();
    _statsController.close();
    _progressController.close();
  }
}

class SetupProgress {
  final String message;
  final double progress;
  SetupProgress({required this.message, required this.progress});
}

// Extension — added separately to avoid editing full file
// These methods will be picked up by the class above
