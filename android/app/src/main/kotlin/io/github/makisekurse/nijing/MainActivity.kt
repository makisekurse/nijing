package io.github.makisekurse.nijing

import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val wakelockChannel = "io.github.makisekurse.nijing/wakelock"
    private val fileExportChannel = "io.github.makisekurse.nijing/file_export"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wakelockChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(true)
                }
                "disable" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileExportChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    val fileName = call.argument<String>("fileName") ?: "export_${System.currentTimeMillis()}.txt"
                    val content = call.argument<String>("content") ?: ""
                    val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                    val savedPath = saveFileToPublic(fileName, content, mimeType)
                    if (savedPath != null) {
                        result.success(savedPath)
                    } else {
                        result.error("SAVE_FAILED", "Failed to save file", null)
                    }
                }
                "shareText" -> {
                    val title = call.argument<String>("title") ?: "分享"
                    val text = call.argument<String>("text") ?: ""
                    try {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            this.type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            val shareContent = if (text.length > 100000) {
                                text.substring(0, 100000) + "\n\n(已保存至文件，超出文本分享上限，完整内容请在 Download/nijing/ 查看)"
                            } else {
                                text
                            }
                            putExtra(Intent.EXTRA_TEXT, shareContent)
                        }
                        val chooser = Intent.createChooser(intent, title)
                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }
                "shareFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val title = call.argument<String>("title") ?: "分享文件"
                    val mimeType = call.argument<String>("mimeType") ?: "text/plain"
                    if (filePath.isNullOrEmpty()) {
                        result.error("INVALID_PATH", "File path cannot be null or empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        val contentUri: Uri = if (file.exists()) {
                            FileProvider.getUriForFile(
                                this@MainActivity,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )
                        } else {
                            var targetFile: File? = null
                            val extFile = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), file.name)
                            if (extFile.exists()) {
                                targetFile = extFile
                            } else {
                                val cacheFile = File(cacheDir, file.name)
                                if (cacheFile.exists()) {
                                    targetFile = cacheFile
                                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    val projection = arrayOf(MediaStore.MediaColumns._ID)
                                    val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
                                    val selectionArgs = arrayOf(file.name)
                                    var foundMediaUri: Uri? = null
                                    contentResolver.query(
                                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                        projection,
                                        selection,
                                        selectionArgs,
                                        null
                                    )?.use { cursor ->
                                        if (cursor.moveToFirst()) {
                                            val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                                            foundMediaUri = android.content.ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
                                        }
                                    }
                                    if (foundMediaUri != null) {
                                        contentResolver.openInputStream(foundMediaUri!!)?.use { ins ->
                                            FileOutputStream(cacheFile).use { fos ->
                                                ins.copyTo(fos)
                                            }
                                        }
                                        if (cacheFile.exists()) {
                                            targetFile = cacheFile
                                        }
                                    }
                                }
                            }
                            if (targetFile != null && targetFile.exists()) {
                                FileProvider.getUriForFile(
                                    this@MainActivity,
                                    "${applicationContext.packageName}.fileprovider",
                                    targetFile
                                )
                            } else {
                                throw java.io.FileNotFoundException("File not found at $filePath")
                            }
                        }

                        val intent = Intent(Intent.ACTION_SEND).apply {
                            this.type = mimeType
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            putExtra(Intent.EXTRA_STREAM, contentUri)
                            clipData = ClipData.newRawUri(title, contentUri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(intent, title).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveFileToPublic(fileName: String, content: String, mimeType: String): String? {
        // 1. Android 10+ (API 29+) MediaStore.Downloads
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/nijing")
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri != null) {
                    contentResolver.openOutputStream(uri)?.use { os ->
                        os.write(content.toByteArray(Charsets.UTF_8))
                    }
                    var actualName = fileName
                    try {
                        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) {
                                val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                                if (nameIdx >= 0) {
                                    actualName = cursor.getString(nameIdx) ?: fileName
                                }
                            }
                        }
                    } catch (_: Throwable) {
                        // ignore query error
                    }
                    return "/storage/emulated/0/Download/nijing/$actualName"
                }
            } catch (_: Throwable) {
                // Fallback to direct file system
            }
        }

        // 2. Direct Download/nijing directory
        try {
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val appDir = File(downloadDir, "nijing")
            if (!appDir.exists()) appDir.mkdirs()
            val file = File(appDir, fileName)
            FileOutputStream(file).use { fos ->
                fos.write(content.toByteArray(Charsets.UTF_8))
            }
            return file.absolutePath
        } catch (_: Throwable) {
            // Fallback to app external files dir
        }

        // 3. Fallback to getExternalFilesDir (always writable)
        try {
            val extDir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: getExternalFilesDir(null)
            if (extDir != null) {
                if (!extDir.exists()) extDir.mkdirs()
                val file = File(extDir, fileName)
                FileOutputStream(file).use { fos ->
                    fos.write(content.toByteArray(Charsets.UTF_8))
                }
                return file.absolutePath
            }
        } catch (_: Throwable) {
            // Failed
        }

        return null
    }
}
