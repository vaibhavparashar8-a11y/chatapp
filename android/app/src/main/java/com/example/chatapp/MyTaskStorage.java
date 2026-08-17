package com.example.chatapp;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Exports a downloaded file into a single user-visible folder,
 * Internal storage / Download / MyTask.
 *
 * The app targets SDK 36, where scoped storage means a plain file write outside
 * the app's own sandbox is ignored — the only way into shared storage is
 * MediaStore. Saving everything (images, videos, documents) under Downloads
 * keeps it to one folder the user can find in Files / My Files, and keeps chat
 * media out of the Gallery, which the discreteness requirement wants anyway.
 */
final class MyTaskStorage {

    static final String FOLDER = "MyTask";

    private MyTaskStorage() {}

    /**
     * Copies {@code sourcePath} into Download/MyTask under {@code displayName}.
     *
     * @return a string identifying the saved item — a {@code content://} URI on
     *         API 29+, an absolute path on older releases.
     */
    static String save(Context context, String sourcePath, String displayName, String mimeType)
            throws IOException {
        final File source = new File(sourcePath);
        if (!source.exists()) throw new IOException("source file missing: " + sourcePath);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return saveViaMediaStore(context, source, displayName, mimeType);
        }
        return saveLegacy(context, source, displayName);
    }

    private static String saveViaMediaStore(Context context, File source,
                                            String displayName, String mimeType)
            throws IOException {
        final ContentResolver resolver = context.getContentResolver();
        final ContentValues values = new ContentValues();
        values.put(MediaStore.Downloads.DISPLAY_NAME, displayName);
        if (mimeType != null && !mimeType.isEmpty()) {
            values.put(MediaStore.Downloads.MIME_TYPE, mimeType);
        }
        values.put(MediaStore.Downloads.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + File.separator + FOLDER);
        // Hide the row until the bytes are there, so nothing indexes a
        // half-written file. Cleared in the finally block below.
        values.put(MediaStore.Downloads.IS_PENDING, 1);

        final Uri item = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (item == null) throw new IOException("MediaStore insert returned null");

        try (InputStream in = new FileInputStream(source);
             OutputStream out = resolver.openOutputStream(item)) {
            if (out == null) throw new IOException("could not open MediaStore output stream");
            copy(in, out);
        } catch (IOException e) {
            // A pending row nobody can see would linger forever otherwise.
            resolver.delete(item, null, null);
            throw e;
        }

        final ContentValues done = new ContentValues();
        done.put(MediaStore.Downloads.IS_PENDING, 0);
        resolver.update(item, done, null, null);
        return item.toString();
    }

    /** API 28 and below: a direct write, then a scan so it shows up right away. */
    private static String saveLegacy(Context context, File source, String displayName)
            throws IOException {
        final File dir = new File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                FOLDER);
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IOException("could not create " + dir.getAbsolutePath());
        }
        final File target = uniqueFile(dir, displayName);
        try (InputStream in = new FileInputStream(source);
             OutputStream out = new FileOutputStream(target)) {
            copy(in, out);
        }
        MediaScannerConnection.scanFile(
                context, new String[]{target.getAbsolutePath()}, null, null);
        return target.getAbsolutePath();
    }

    /**
     * "photo.jpg" → "photo (1).jpg" when taken. MediaStore does this itself on
     * API 29+; the legacy path would silently overwrite without it.
     */
    private static File uniqueFile(File dir, String displayName) {
        File candidate = new File(dir, displayName);
        if (!candidate.exists()) return candidate;

        final int dot = displayName.lastIndexOf('.');
        final String base = dot > 0 ? displayName.substring(0, dot) : displayName;
        final String ext  = dot > 0 ? displayName.substring(dot) : "";
        for (int i = 1; i < 1000; i++) {
            candidate = new File(dir, base + " (" + i + ")" + ext);
            if (!candidate.exists()) return candidate;
        }
        return candidate;
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        final byte[] buffer = new byte[8192];
        int read;
        while ((read = in.read(buffer)) != -1) {
            out.write(buffer, 0, read);
        }
        out.flush();
    }
}
