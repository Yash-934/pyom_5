package com.pyom

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.apache.commons.compress.archivers.zip.ZipArchiveInputStream
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.pyom/linux_environment"
    private val EVENT_CHANNEL = "com.pyom/process_output"

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentProcess: Process? = null
    private val isSetupCancelled = AtomicBoolean(false)

    private val envRoot get() = File(filesDir, "linux_env")
    private val binDir  get() = File(filesDir, "bin")

    // --- Path to the executable proot binary ---
    private val prootPath: String
        get() = applicationInfo.nativeLibraryDir + "/libproot.so"


    // ─── proot version file (for self-update tracking) ───────────────────────
    private val prootVersionFile get() = File(binDir, "proot.version")
    private val PROOT_CURRENT_VERSION = "5.3.0"  // Version we ship/expect

    // ─── Known working proot sources ─────────────────────────────────────────
    // IMPORTANT: v5.4.0 had no pre-built binaries on proot-me GitHub!
    //            Only source code was released. v5.3.0 is the last stable with binaries.
    //
    // Each entry: Pair(url, format)
    // format = "binary" | "tar.gz" | "zip"
    private fun getProotSources(arch: String): List<Pair<String, String>> {
        val a = if (arch == "x86_64") "x86_64" else "aarch64"
        return listOf(
            // ── proot-me v5.3.0 — LAST version with direct binaries ──────────
            "https://github.com/proot-me/proot/releases/download/v5.3.0/proot-$a" to "binary",

            // ── proot-me v5.1.107 ────────────────────────────────────────────
            "https://github.com/proot-me/proot/releases/download/v5.1.107-android/proot-$a" to "binary",

            // ── Andronix — ships proot binaries for Android, always works ────
            "https://raw.githubusercontent.com/AndronixApp/AndronixOrigin/master/repo/$a/proot" to "binary",

            // ── Termux bootstrap — proot is always available here ────────────
            // The .deb contains data.tar.xz which has usr/bin/proot inside
            // We handle this extraction case specially
            "https://packages.termux.dev/apt/termux-main/pool/stable/main/p/proot/proot_5.3.0-1_$a.deb" to "deb",

            // ── UserLAnd — another Android Linux environment project ──────────
            "https://github.com/CypherpunkArmory/UserLAnd-Assets-Support/raw/main/fs-assets/$a/proot" to "binary",
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result -> handleMethodCall(call, result) }
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
            override fun onCancel(arguments: Any?) { eventSink = null }
        })
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setupEnvironment" -> {
                isSetupCancelled.set(false)
                setupEnvironment(
                    call.argument("distro") ?: "alpine",
                    call.argument("envId")  ?: "alpine-3.19",
                    result
                )
            }
            "cancelSetup" -> {
                isSetupCancelled.set(true)
                currentProcess?.destroyForcibly()
                result.success(true)
            }
            "executeCommand" -> executeCommand(
                call.argument("environmentId") ?: "",
                call.argument("command")        ?: "",
                call.argument("workingDir")     ?: "/",
                call.argument("timeoutMs")      ?: 300000,
                result
            )
            "isEnvironmentInstalled" -> {
                val envId = call.argument<String>("envId") ?: ""
                val dir = File(envRoot, envId)
                result.success(
                    File(dir, "etc/os-release").exists() ||
                    File(dir, "bin/sh").exists() ||
                    File(dir, "usr/bin/sh").exists()
                )
            }
            "checkProotUpdate" -> checkProotUpdate(result)
            "getEnvironmentPath"  -> result.success(envRoot.absolutePath)
            "saveFileToDownloads" -> saveFileToDownloads(
                call.argument("sourcePath") ?: "", call.argument("fileName") ?: "script.py", result
            )
            "shareFile"      -> shareFile(call.argument("filePath") ?: "", result)
            "getStorageInfo" -> result.success(mapOf(
                "filesDir"        to filesDir.absolutePath,
                "envRoot"         to envRoot.absolutePath,
                "freeSpaceMB"     to (filesDir.freeSpace / 1048576L),
                "totalSpaceMB"    to (filesDir.totalSpace / 1048576L),
                "prootVersion"    to (prootVersionFile.takeIf { it.exists() }?.readText()?.trim() ?: "unknown"),
            ))
            "getDeviceArch"  -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
            else             -> result.notImplemented()
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SELF-UPDATE: Check if a newer proot is available and download silently
    // ════════════════════════════════════════════════════════════════════════

    private fun checkProotUpdate(result: MethodChannel.Result) {
        executor.execute {
            try {
                val proot = File(prootPath)
                if (!proot.exists()) { mainHandler.post { result.success(mapOf("updated" to false, "reason" to "proot not installed")) }; return@execute }

                // Query GitHub API for latest release
                val apiUrl = "https://api.github.com/repos/proot-me/proot/releases"
                val conn = URL(apiUrl).openConnection() as HttpURLConnection
                conn.setRequestProperty("Accept", "application/vnd.github+json")
                conn.connectTimeout = 10000; conn.readTimeout = 15000
                conn.connect()
                val json = conn.inputStream.bufferedReader().readText()
                conn.disconnect()

                // Find latest release that has a binary (not just source)
                val arch = getAndroidArch()
                val archName = if (arch == "x86_64") "x86_64" else "aarch64"

                // Simple regex to find asset URLs containing our arch name
                val urlPattern = Regex("\"browser_download_url\":\\s*\"(https://[^\"]*proot[^\"]*$archName[^\"]*)\"")
                val match = urlPattern.find(json)

                if (match != null) {
                    val downloadUrl = match.groupValues[1]
                    val installedVersion = prootVersionFile.takeIf { it.exists() }?.readText()?.trim() ?: "unknown"

                    // Extract version from URL e.g. "v5.3.0" -> "5.3.0"
                    val versionMatch = Regex("download/v([\\d.]+)/").find(downloadUrl)
                    val latestVersion = versionMatch?.groupValues?.get(1) ?: "unknown"

                    if (latestVersion != installedVersion && latestVersion != "unknown") {
                        // NOTE: This will NOT work on Android 10+ as we can't write to nativeLibraryDir.
                        // This logic is kept for older Android versions or future work.
                        mainHandler.post { result.success(mapOf("updated" to false, "reason" to "Auto-update disabled on modern Android. Found version $latestVersion.")) }
                        return@execute
                    }
                }
                mainHandler.post { result.success(mapOf("updated" to false, "version" to (prootVersionFile.takeIf { it.exists() }?.readText()?.trim() ?: "unknown"))) }
            } catch (e: Exception) {
                mainHandler.post { result.success(mapOf("updated" to false, "error" to e.message)) }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ENVIRONMENT SETUP
    // ════════════════════════════════════════════════════════════════════════

    private fun setupEnvironment(distro: String, envId: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                sendProgress("Preparing directories…", 0.02)
                envRoot.mkdirs(); binDir.mkdirs()
                val envDir = File(envRoot, envId); envDir.mkdirs()

                // ── Step 1: proot binary ──────────────────────────────────
                val prootFile = File(prootPath)
                if (!prootFile.exists() || prootFile.length() < 10000) {
                    sendProgress("proot binary not found in native libs. This is a critical error.", 0.04)
                    // On modern Android, we cannot download to an executable location.
                    // The app must be bundled with the proot binary in jniLibs.
                    // We will attempt the legacy download for older Android versions.
                    getProot(File(binDir, "proot")) // Download to legacy path
                     if (!prootFile.exists() && !File(binDir, "proot").exists()) {
                         throw Exception("proot not found in native library dir and download failed. Please reinstall app.")
                     }
                } else {
                    sendProgress("proot already ready ✅", 0.06)
                    prootVersionFile.writeText("bundled-native")
                }


                if (isSetupCancelled.get()) { mainHandler.post { result.error("CANCELLED", "Cancelled", null) }; return@execute }

                // ── Step 2: Download rootfs ───────────────────────────────
                val arch = getAndroidArch()
                val rootfsUrl = if (distro == "ubuntu") getUbuntuUrl(arch) else getAlpineUrl(arch)
                val tarFile = File(filesDir, "rootfs_${envId}.tar.gz")

                sendProgress("Downloading $distro Linux…", 0.10)
                downloadWithProgress(rootfsUrl, tarFile, 0.10, 0.62)

                if (isSetupCancelled.get()) { tarFile.delete(); mainHandler.post { result.error("CANCELLED", "Cancelled", null) }; return@execute }

                // ── Step 3: Extract rootfs ────────────────────────────────
                sendProgress("Extracting rootfs…", 0.62)
                extractTarGz(tarFile, envDir)
                tarFile.delete()

                if (isSetupCancelled.get()) { mainHandler.post { result.error("CANCELLED", "Cancelled", null) }; return@execute }

                // ── Step 4: DNS + Python ──────────────────────────────────
                File(envDir, "etc").mkdirs()
                File(envDir, "etc/resolv.conf").writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n")
                File(envDir, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")

                if (distro == "ubuntu") {
                    sendProgress("Updating apt… (may take a few minutes)", 0.75)
                    runInProot(envId, "apt-get update -qq 2>&1 | tail -3")
                    sendProgress("Installing Python3…", 0.82)
                    runInProot(envId, "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-pip python3-dev build-essential 2>&1")
                } else {
                    sendProgress("Updating apk…", 0.75)
                    runInProot(envId, "apk update -q 2>&1")
                    sendProgress("Installing Python3…", 0.82)
                    runInProot(envId, "apk add --no-cache -q python3 py3-pip gcc musl-dev linux-headers python3-dev 2>&1")
                }

                sendProgress("Upgrading pip…", 0.93)
                runInProot(envId, "pip3 install --upgrade pip setuptools wheel --quiet 2>&1 || true")

                sendProgress("✅ Python environment ready!", 1.0)
                mainHandler.post { result.success(mapOf("success" to true, "path" to envDir.absolutePath)) }

            } catch (e: Exception) {
                mainHandler.post { result.error("SETUP_ERROR", e.message ?: "Unknown error", null) }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // PROOT ACQUISITION — tries multiple sources, handles all formats
    // ════════════════════════════════════════════════════════════════════════

    private fun getProot(dest: File) {
        val arch = getAndroidArch()

        // This function is now a LEGACY FALLBACK for older Android versions.
        // It downloads to a non-native-lib directory.

        // ── 1. Try APK assets first (old bundled location) ───────────────
        val assetName = if (arch == "x86_64") "bin/proot-x86_64" else "bin/proot-arm64"
        try {
            assets.open(assetName).use { input -> FileOutputStream(dest).use { input.copyTo(it) } }
            dest.setExecutable(true, false)
            if (dest.length() > 10000) {
                prootVersionFile.writeText("bundled-legacy")
                sendProgress("✅ proot loaded from app (no download needed)", 0.08)
                return
            }
            dest.delete()
        } catch (_: Exception) { /* not bundled, download below */ }

        // ── 2. Try hardcoded sources with format-aware extraction ───────────
        val sources = getProotSources(arch)
        val errors = mutableListOf<String>()

        for ((index, source) in sources.withIndex()) {
            val (url, format) = source
            sendProgress("Trying source ${index + 1}/${sources.size}…", 0.05 + index * 0.008)
            try {
                val tmp = File(binDir, "proot_download_${index}.tmp")
                downloadFile(url, tmp)

                val success = when (format) {
                    "binary" -> {
                        if (tmp.length() > 10000) { tmp.renameTo(dest); true }
                        else { tmp.delete(); false }
                    }
                    "tar.gz", "tgz" -> extractBinaryFromTarGz(tmp, dest, listOf("proot", "usr/bin/proot", "bin/proot"))
                    "zip" -> extractBinaryFromZip(tmp, dest, listOf("proot", "usr/bin/proot", "bin/proot"))
                    "deb" -> extractBinaryFromDeb(tmp, dest)
                    else -> { tmp.delete(); false }
                }
                tmp.delete()

                if (success && dest.length() > 10000) {
                    dest.setExecutable(true, false)
                    prootVersionFile.writeText(PROOT_CURRENT_VERSION)
                    sendProgress("✅ proot ready! (source ${index + 1})", 0.09)
                    return
                }
                dest.delete()
            } catch (e: Exception) {
                errors.add("Source ${index + 1}: ${e.message?.take(80)}")
            }
        }
        throw Exception("Could not get proot from any source.\nErrors:\n${errors.joinToString("\n")}")
    }

    // ── Background update check (non-blocking) ──────────────────────────────
    private fun tryUpdateProot(prootFile: File) {
       // This function is now mostly disabled on modern Android.
        return
    }

    // ════════════════════════════════════════════════════════════════════════
    // FORMAT EXTRACTORS — tar.gz, zip, deb
    // ════════════════════════════════════════════════════════════════════════

    /** Extract a single file from tar.gz into dest. Returns true on success. */
    private fun extractBinaryFromTarGz(archive: File, dest: File, possiblePaths: List<String>): Boolean {
        try {
            FileInputStream(archive).use { fis ->
                GzipCompressorInputStream(fis).use { gz ->
                    TarArchiveInputStream(gz).use { tar ->
                        var entry = tar.nextTarEntry
                        while (entry != null) {
                            val name = entry.name.trimStart('.', '/')
                            if (!entry.isDirectory && possiblePaths.any { name == it || name.endsWith("/$it") || name.endsWith(it) }) {
                                dest.parentFile?.mkdirs()
                                FileOutputStream(dest).use { tar.copyTo(it) }
                                return true
                            }
                            entry = tar.nextTarEntry
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return false
    }

    /** Extract a single file from zip into dest. Returns true on success. */
    private fun extractBinaryFromZip(archive: File, dest: File, possiblePaths: List<String>): Boolean {
        try {
            ZipInputStream(FileInputStream(archive)).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    val name = entry.name.trimStart('.', '/')
                    if (!entry.isDirectory && possiblePaths.any { name == it || name.endsWith("/$it") || name.endsWith(it) }) {
                        dest.parentFile?.mkdirs()
                        FileOutputStream(dest).use { zip.copyTo(it) }
                        return true
                    }
                    zip.closeEntry()
                    entry = zip.nextEntry
                }
            }
        } catch (_: Exception) {}
        return false
    }

    /**
     * .deb format:
     *   ar archive containing:
     *     - debian-binary (text "2.0")
     *     - control.tar.gz / control.tar.xz
     *     - data.tar.gz / data.tar.xz / data.tar.zst  ← has our binary
     *
     * Android doesn't have `ar`. Strategy: scan file bytes to find tar magic.
     * Simpler: just try to extract any tar.gz embedded in the .deb.
     */
    private fun extractBinaryFromDeb(deb: File, dest: File): Boolean {
        try {
            val bytes = deb.readBytes()
            var offset = -1
            for (i in 0 until bytes.size - 1) {
                if (bytes[i] == 0x1f.toByte() && bytes[i + 1] == 0x8b.toByte()) {
                    val tmpTar = File(binDir, "deb_extract.tmp")
                    tmpTar.writeBytes(bytes.copyOfRange(i, bytes.size))
                    val found = extractBinaryFromTarGz(tmpTar, dest, listOf("proot", "usr/bin/proot", "./usr/bin/proot"))
                    tmpTar.delete()
                    if (found && dest.length() > 10000) return true
                    offset = i
                }
            }
        } catch (_: Exception) {}
        return false
    }

    // ════════════════════════════════════════════════════════════════════════
    // ROOTFS DOWNLOAD & EXTRACTION
    // ════════════════════════════════════════════════════════════════════════

    private fun getAndroidArch(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"
        return if (abi.contains("x86_64")) "x86_64" else "arm64"
    }

    private fun getAlpineUrl(arch: String): String {
        val a = if (arch == "x86_64") "x86_64" else "aarch64"
        return "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/$a/alpine-minirootfs-3.19.1-$a.tar.gz"
    }

    private fun getUbuntuUrl(arch: String): String {
        val a = if (arch == "x86_64") "amd64" else "arm64"
        return "https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-$a.tar.gz"
    }

    private fun extractTarGz(archive: File, destDir: File) {
        destDir.mkdirs(); var count = 0
        FileInputStream(archive).use { fis ->
            GzipCompressorInputStream(fis).use { gz ->
                TarArchiveInputStream(gz).use { tar ->
                    var entry = tar.nextTarEntry
                    while (entry != null) {
                        if (isSetupCancelled.get()) break
                        val dest = File(destDir, entry.name)
                        when {
                            entry.isDirectory  -> dest.mkdirs()
                            entry.isSymbolicLink -> {
                                try { dest.parentFile?.mkdirs(); Runtime.getRuntime().exec(arrayOf("ln", "-sf", entry.linkName, dest.absolutePath)).waitFor() } catch (_: Exception) {}
                            }
                            else -> {
                                dest.parentFile?.mkdirs()
                                FileOutputStream(dest).use { tar.copyTo(it) }
                                if (entry.mode and 0b001001001 != 0) dest.setExecutable(true, false)
                            }
                        }
                        count++
                        if (count % 300 == 0) sendProgress("Extracting… ($count files)", 0.62 + (count.toDouble() / 80000).coerceAtMost(0.12))
                        entry = tar.nextTarEntry
                    }
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // HTTP HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private fun httpGet(urlStr: String): String {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.setRequestProperty("User-Agent", "PyomIDE/1.1")
        conn.setRequestProperty("Accept", "application/json")
        conn.connectTimeout = 10000; conn.readTimeout = 15000
        conn.connect()
        val text = conn.inputStream.bufferedReader().readText()
        conn.disconnect()
        return text
    }

    private fun downloadFile(urlStr: String, dest: File) {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.connectTimeout = 20000; conn.readTimeout = 300000
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("User-Agent", "PyomIDE/1.1 Android")
        conn.connect()
        if (conn.responseCode != 200) { conn.disconnect(); throw Exception("HTTP ${conn.responseCode} for $urlStr") }
        conn.inputStream.use { i -> FileOutputStream(dest).use { o -> i.copyTo(o) } }
        conn.disconnect()
    }

    private fun downloadWithProgress(urlStr: String, dest: File, fromP: Double, toP: Double) {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.connectTimeout = 20000; conn.readTimeout = 600000
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("User-Agent", "PyomIDE/1.1 Android")
        conn.connect()
        if (conn.responseCode != 200) { conn.disconnect(); throw Exception("HTTP ${conn.responseCode} for $urlStr") }
        val total = conn.contentLengthLong.takeIf { it > 0 } ?: 1L
        var done = 0L; val buf = ByteArray(65536)
        conn.inputStream.use { input ->
            FileOutputStream(dest).use { output ->
                var n: Int
                while (input.read(buf).also { n = it } != -1) {
                    if (isSetupCancelled.get()) break
                    output.write(buf, 0, n); done += n
                    val p = fromP + (toP - fromP) * (done.toDouble() / total)
                    sendProgress("Downloading… ${(done * 100 / total).toInt()}% (${done / 1048576}MB / ${total / 1048576}MB)", p)
                }
            }
        }
        conn.disconnect()
    }

    // ════════════════════════════════════════════════════════════════════════
    // COMMAND EXECUTION (via proot chroot)
    // ════════════════════════════════════════════════════════════════════════

    private fun executeCommand(envId: String, command: String, workingDir: String, timeoutMs: Int, result: MethodChannel.Result) {
        executor.execute {
            try {
                mainHandler.post { result.success(runCommandInProot(envId, command, workingDir, timeoutMs)) }
            } catch (e: Exception) {
                mainHandler.post { result.error("EXEC_ERROR", e.message, null) }
            }
        }
    }

    private fun runInProot(envId: String, cmd: String) = runCommandInProot(envId, cmd, "/", 300000).let { "${it["stdout"]}\n${it["stderr"]}" }

    private fun runCommandInProot(envId: String, command: String, workingDir: String, timeoutMs: Int): Map<String, Any> {
        val envDir = File(envRoot, envId)
        val prootExecutable = listOf(
            File(prootPath), // Main, executable path
            File(binDir, "proot")      // Legacy fallback path
        ).firstOrNull { it.exists() }

        val tmpDir = File(envDir, "tmp").also { it.mkdirs() }

        if (prootExecutable == null) return mapOf("stdout" to "", "stderr" to "proot not found — run setup again", "exitCode" to -1)

        val shell = when {
            File(envDir, "bin/bash").exists()     -> "/bin/bash"
            File(envDir, "usr/bin/bash").exists() -> "/usr/bin/bash"
            else -> "/bin/sh"
        }

        val cmd = mutableListOf(
            prootExecutable.absolutePath,
            "--kill-on-exit",
            "-r", envDir.absolutePath,
            "-w", workingDir,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            "-0", // Use as the final option before the command
            shell,
            "-c",
            command
        )

        val pb = ProcessBuilder(cmd).apply {
            directory(filesDir)
            redirectErrorStream(false)

            // Use ProcessBuilder environment map - works on all proot versions
            environment().apply {
                put("HOME", "/root")
                put("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                put("LANG", "C.UTF-8")
                put("TERM", "xterm-256color")
                put("PROOT_TMP_DIR", tmpDir.absolutePath)
                put("PYTHONDONTWRITEBYTECODE", "1")
                put("PIP_NO_CACHE_DIR", "off")
                put("PROOT_NO_SECCOMP", "1") // Fix for seccomp issues on some kernels
            }
        }

        val process = pb.start(); currentProcess = process

        val stdout = StringBuilder(); val stderr = StringBuilder()
        val t1 = Thread { process.inputStream.bufferedReader().lines().forEach { line -> stdout.append(line).append("\n"); mainHandler.post { eventSink?.success(line) } } }
        val t2 = Thread { process.errorStream.bufferedReader().lines().forEach { line -> stderr.append(line).append("\n"); mainHandler.post { eventSink?.success("[err] $line") } } }
        t1.start(); t2.start()
        val done = process.waitFor(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        t1.join(3000); t2.join(3000)

        return if (done) mapOf("stdout" to stdout.toString(), "stderr" to stderr.toString(), "exitCode" to process.exitValue())
               else { process.destroyForcibly(); mapOf("stdout" to stdout.toString(), "stderr" to "Timed out after ${timeoutMs}ms", "exitCode" to -1) }
    }

    // ════════════════════════════════════════════════════════════════════════
    // FILE / GALLERY OPERATIONS
    // ════════════════════════════════════════════════════════════════════════

    private fun saveFileToDownloads(sourcePath: String, fileName: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val src = File(sourcePath)
                if (!src.exists()) { mainHandler.post { result.error("NOT_FOUND", "File not found: $sourcePath", null) }; return@execute }
                val savedPath: String
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val mime = when { fileName.endsWith(".py") -> "text/x-python"; fileName.endsWith(".txt") -> "text/plain"; else -> "application/octet-stream" }
                    val cv = ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME, fileName); put(MediaStore.Downloads.MIME_TYPE, mime); put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Pyom") }
                    val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)!!
                    contentResolver.openOutputStream(uri)!!.use { os -> src.inputStream().use { it.copyTo(os) } }
                    savedPath = "Downloads/Pyom/$fileName"
                } else {
                    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Pyom"); dir.mkdirs()
                    src.copyTo(File(dir, fileName), overwrite = true); savedPath = "${dir.absolutePath}/$fileName"
                }
                mainHandler.post { result.success(mapOf("success" to true, "path" to savedPath)) }
            } catch (e: Exception) { mainHandler.post { result.error("SAVE_ERROR", e.message, null) } }
        }
    }

    private fun shareFile(filePath: String, result: MethodChannel.Result) {
        try {
            val file = File(filePath)
            if (!file.exists()) { result.error("NOT_FOUND", "File not found", null); return }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }, "Share ${file.name}"))
            result.success(true)
        } catch (e: Exception) { result.error("SHARE_ERROR", e.message, null) }
    }

    private fun sendProgress(message: String, progress: Double) {
        mainHandler.post { methodChannel.invokeMethod("onSetupProgress", mapOf("message" to message, "progress" to progress)) }
    }

    override fun onDestroy() {
        super.onDestroy()
        isSetupCancelled.set(true); currentProcess?.destroyForcibly(); executor.shutdown()
    }
}
