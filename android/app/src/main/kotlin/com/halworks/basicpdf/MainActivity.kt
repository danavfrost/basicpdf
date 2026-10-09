package com.halworks.basicpdf

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * File access through the Storage Access Framework only (no storage
 * permissions): open/create document pickers, persisted URI grants,
 * read/write via ContentResolver, and "Open with" VIEW intents.
 *
 * File contents never cross the MethodChannel (the codec copies byte arrays
 * several times, which ran large PDFs out of Java heap). Reads stream the
 * document into a temp file under cacheDir/xfer and return its path; writes
 * take the path of a temp file Dart wrote and stream it to the URI. The
 * side that consumes a temp file deletes it.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.halworks.basicpdf/files"
        const val REQ_OPEN = 4101
        const val REQ_CREATE = 4102
        val DOWNLOADS_URI: Uri =
            DocumentsContract.buildDocumentUri("com.android.providers.downloads.documents", "downloads")
        val DOCUMENTS_URI: Uri =
            DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Documents")
    }

    private var channel: MethodChannel? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCreatePath: String? = null
    private var initialIntent: Intent? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialIntent = intent
        // Leftovers from a run that died mid-transfer.
        io.execute { xferDir().listFiles()?.forEach { it.delete() } }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::onCall)
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDocument" -> startPicker(result, REQ_OPEN, null)
            "createDocument" -> startPicker(
                result, REQ_CREATE, call.argument<String>("name") ?: "Untitled.pdf",
                call.argument<String>("path"),
            )
            "read" -> background(result) {
                val uri = Uri.parse(call.argument<String>("ref"))
                mapOf("path" to copyToCache(uri).path, "temp" to true)
            }
            "write" -> background(result) {
                val src = File(call.argument<String>("path")!!)
                try {
                    writeUri(Uri.parse(call.argument<String>("ref")), src)
                } finally {
                    src.delete()
                }
                true
            }
            "exists" -> background(result) {
                try {
                    contentResolver.openFileDescriptor(Uri.parse(call.argument<String>("ref")), "r")
                        ?.use { true } ?: false
                } catch (e: Exception) {
                    false
                }
            }
            "status" -> background(result) { status(Uri.parse(call.argument<String>("ref"))) }
            "initialDoc" -> {
                val i = initialIntent
                initialIntent = null
                if (i == null || (i.action != Intent.ACTION_VIEW && i.action != Intent.ACTION_EDIT) || i.data == null) {
                    result.success(null)
                } else {
                    background(result) { docFromViewIntent(i) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("io", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun startPicker(
        result: MethodChannel.Result, request: Int, name: String?, path: String? = null,
    ) {
        if (pendingResult != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        val intent = Intent(if (request == REQ_OPEN) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("application/pdf")
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        if (name != null) intent.putExtra(Intent.EXTRA_TITLE, name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intent.putExtra(
                DocumentsContract.EXTRA_INITIAL_URI,
                if (request == REQ_OPEN) DOWNLOADS_URI else DOCUMENTS_URI,
            )
        }
        pendingResult = result
        pendingCreatePath = path
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, request)
        } catch (e: Exception) {
            pendingResult = null
            pendingCreatePath?.let { File(it).delete() }
            pendingCreatePath = null
            result.error("picker", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_OPEN && requestCode != REQ_CREATE) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult ?: return
        val src = pendingCreatePath?.let { File(it) }
        pendingResult = null
        pendingCreatePath = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            src?.delete()
            result.success(null)
            return
        }
        val writable = persist(uri)
        background(result) {
            if (requestCode == REQ_OPEN) {
                docMap(uri, writable)
            } else {
                try {
                    if (src != null) writeUri(uri, src)
                } finally {
                    src?.delete()
                }
                locationMap(uri)
            }
        }
    }

    /** Takes a persistable grant (read+write if offered). Returns whether write is held. */
    private fun persist(uri: Uri): Boolean {
        val rw = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        return try {
            contentResolver.takePersistableUriPermission(uri, rw)
            true
        } catch (e: Exception) {
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {
            }
            false
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if ((intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_EDIT) || intent.data == null) return
        io.execute {
            try {
                val doc = docFromViewIntent(intent)
                main.post { channel?.invokeMethod("incoming", doc) }
            } catch (_: Exception) {
            }
        }
    }

    private fun docFromViewIntent(i: Intent): Map<String, Any?> {
        val uri = i.data!!
        if (uri.scheme == "file") {
            val path = uri.path!!
            val f = java.io.File(path)
            return mapOf(
                "kind" to "path", "ref" to path, "name" to f.name,
                "folder" to (f.parentFile?.name ?: ""), "path" to path, "temp" to false,
                "writable" to f.canWrite(),
            )
        }
        val canWrite = (i.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0
        val writable = if ((i.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0) persist(uri) else canWrite
        return docMap(uri, writable)
    }

    /**
     * "ok", "missing" (the file is gone) or "noAccess" (it may still exist but
     * our grant expired, e.g. a non-persistable "Open with" grant).
     */
    private fun status(uri: Uri): String {
        return try {
            contentResolver.openFileDescriptor(uri, "r")?.use { "ok" } ?: "missing"
        } catch (e: Exception) {
            // Providers differ in what they throw for a deleted document
            // (FileNotFound, IllegalArgument, even Security). If we still hold
            // a persisted grant the file is gone; without one, our access
            // expired (e.g. a one-time "Open with" grant) and it may exist.
            val held = contentResolver.persistedUriPermissions.any {
                it.uri.toString() == uri.toString() && it.isReadPermission
            }
            when {
                held -> "missing"
                e is java.io.FileNotFoundException && !isGrantError(e) -> "missing"
                else -> "noAccess"
            }
        }
    }

    private fun isGrantError(e: Exception) =
        (e.message ?: "").contains("permission", ignoreCase = true)

    private fun xferDir(): File = File(cacheDir, "xfer").apply { mkdirs() }

    /** Streams [uri] into a new temp file (deleted by Dart after reading). */
    private fun copyToCache(uri: Uri): File {
        val input = contentResolver.openInputStream(uri)
            ?: throw java.io.FileNotFoundException("Can't open $uri")
        val out = File.createTempFile("in-", ".pdf", xferDir())
        try {
            input.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 16) } }
        } catch (e: Exception) {
            out.delete()
            throw e
        }
        return out
    }

    private fun writeUri(uri: Uri, src: File) {
        val out = contentResolver.openOutputStream(uri, "wt")
            ?: throw java.io.IOException("Can't write $uri")
        out.use { o -> src.inputStream().use { i -> i.copyTo(o, 1 shl 16) }; o.flush() }
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) return c.getString(0)
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Document.pdf"
    }

    /** Best-effort folder label for the History list. */
    private fun folderLabel(uri: Uri): String {
        return try {
            when (uri.authority) {
                "com.android.providers.downloads.documents" -> "Downloads"
                "com.android.externalstorage.documents" -> {
                    val id = DocumentsContract.getDocumentId(uri)
                    val path = id.substringAfter(':', "")
                    val parent = path.substringBeforeLast('/', "")
                    if (parent.isEmpty()) "Internal storage" else parent.substringAfterLast('/')
                }
                "com.google.android.apps.docs.storage" -> "Drive"
                MediaStore.AUTHORITY -> mediaFolder(uri)
                "com.android.providers.media.documents" -> mediaFolder(
                    MediaStore.Files.getContentUri("external")
                        .buildUpon().appendPath(DocumentsContract.getDocumentId(uri).substringAfter(':')).build(),
                )
                else -> ""
            }.ifEmpty { providerLabel(uri) }
        } catch (_: Exception) {
            providerLabel(uri)
        }
    }

    /** Parent folder of a MediaStore item ("Download", "Documents", ...). */
    private fun mediaFolder(uri: Uri): String {
        try {
            val col = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.MediaColumns.RELATIVE_PATH
            } else {
                @Suppress("DEPRECATION") MediaStore.MediaColumns.DATA
            }
            contentResolver.query(uri, arrayOf(col), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) {
                    val v = c.getString(0).trimEnd('/')
                    val dir = if (col == MediaStore.MediaColumns.RELATIVE_PATH) v else v.substringBeforeLast('/', "")
                    val name = dir.substringAfterLast('/')
                    if (name.isNotEmpty()) return name
                }
            }
        } catch (_: Exception) {
        }
        return ""
    }

    /** The name of the app that provides [uri] (e.g. "Files", "Gmail"). */
    private fun providerLabel(uri: Uri): String {
        return try {
            val info = packageManager.resolveContentProvider(uri.authority ?: return "", 0) ?: return ""
            info.loadLabel(packageManager)?.toString() ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun locationMap(uri: Uri): Map<String, Any?> = mapOf(
        "kind" to "contentUri",
        "ref" to uri.toString(),
        "name" to displayName(uri),
        "folder" to folderLabel(uri),
    )

    private fun docMap(uri: Uri, writable: Boolean): Map<String, Any?> =
        locationMap(uri) + mapOf("path" to copyToCache(uri).path, "temp" to true, "writable" to writable)
}
