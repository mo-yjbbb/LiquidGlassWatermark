package com.localwatermark.liquidglass.android;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.provider.MediaStore;
import android.graphics.drawable.GradientDrawable;
import android.view.*;
import android.widget.*;
import androidx.exifinterface.media.ExifInterface;
import java.io.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity {
    private static final int PICK_IMAGE = 42;
    private static final int MEDIA_LOCATION_PERMISSION = 43;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private ImageView preview;
    private View emptyState;
    private ProgressBar progress;
    private Uri sourceUri;
    private byte[] finishedBytes;
    private boolean sourceWasMotion;
    private boolean openPickerAfterPermission;
    private Uri pendingSharedUri;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(Color.rgb(9,10,16));
        if (Build.VERSION.SDK_INT >= 30) getWindow().setDecorFitsSystemWindows(false);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(20), dp(20), dp(20), dp(20)); root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setBackground(new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xff090a10,0xff161224,0xff241225}));
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = Build.VERSION.SDK_INT >= 30
                    ? insets.getInsets(WindowInsets.Type.systemBars())
                    : android.graphics.Insets.of(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom());
            view.setPadding(dp(20), bars.top + dp(18), dp(20), bars.bottom + dp(18));
            return insets;
        });
        LinearLayout header = new LinearLayout(this); header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL); header.setPadding(dp(2),0,0,dp(18));
        ImageView brandIcon = new ImageView(this); brandIcon.setImageResource(R.drawable.ic_launcher_legacy);
        GradientDrawable iconPlate = new GradientDrawable(); iconPlate.setColor(0x18ffffff); iconPlate.setCornerRadius(dp(16));
        iconPlate.setStroke(dp(1),0x30ffffff); brandIcon.setBackground(iconPlate); brandIcon.setPadding(dp(5),dp(5),dp(5),dp(5));
        LinearLayout heading = new LinearLayout(this); heading.setOrientation(LinearLayout.VERTICAL); heading.setPadding(dp(13),0,0,0);
        TextView title = new TextView(this); title.setText("液态玻璃水印"); title.setTextSize(25); title.setTextColor(Color.WHITE);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD); title.setGravity(Gravity.START);
        TextView subtitle = new TextView(this); subtitle.setText("小米 · 徕卡动态影像"); subtitle.setTextSize(13);
        subtitle.setTextColor(0xaaffffff); subtitle.setGravity(Gravity.START); subtitle.setPadding(0,dp(3),0,0);
        heading.addView(title); heading.addView(subtitle);
        header.addView(brandIcon,new LinearLayout.LayoutParams(dp(54),dp(54)));
        header.addView(heading,new LinearLayout.LayoutParams(0,-2,1));

        FrameLayout previewCard = new FrameLayout(this);
        GradientDrawable previewBg = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0x20ffffff,0x09000000,0x16ff6d9e});
        previewBg.setCornerRadius(dp(26)); previewBg.setStroke(dp(1),0x3cffffff);
        previewCard.setBackground(previewBg); previewCard.setPadding(dp(7),dp(7),dp(7),dp(7));
        preview = new ImageView(this); preview.setAdjustViewBounds(true); preview.setScaleType(ImageView.ScaleType.FIT_CENTER);
        previewCard.addView(preview,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout empty = new LinearLayout(this); empty.setOrientation(LinearLayout.VERTICAL); empty.setGravity(Gravity.CENTER);
        empty.setPadding(dp(26),dp(28),dp(26),dp(28));
        ImageView emptyIcon = new ImageView(this); emptyIcon.setImageResource(R.drawable.ic_launcher_legacy); emptyIcon.setAlpha(.92f);
        TextView emptyTitle = new TextView(this); emptyTitle.setText("选择一张照片开始"); emptyTitle.setTextColor(Color.WHITE);
        emptyTitle.setTextSize(20); emptyTitle.setTypeface(Typeface.DEFAULT,Typeface.BOLD); emptyTitle.setGravity(Gravity.CENTER);
        emptyTitle.setPadding(0,dp(16),0,dp(7));
        TextView emptyHint = new TextView(this); emptyHint.setText("支持小米静态照片与动态照片\n读取真实拍摄参数 · 原画质输出");
        emptyHint.setTextColor(0x99ffffff); emptyHint.setTextSize(14); emptyHint.setGravity(Gravity.CENTER); emptyHint.setLineSpacing(dp(3),1);
        empty.addView(emptyIcon,new LinearLayout.LayoutParams(dp(78),dp(78))); empty.addView(emptyTitle); empty.addView(emptyHint);
        emptyState = empty; previewCard.addView(empty,new FrameLayout.LayoutParams(-1,-1));
        progress = new ProgressBar(this); progress.setVisibility(View.GONE);
        Button select = new Button(this); select.setText("从相册选择照片"); select.setTextColor(Color.WHITE);
        select.setTextSize(17); select.setAllCaps(false); select.setTypeface(Typeface.DEFAULT,Typeface.BOLD);
        GradientDrawable glassButton = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0x58ffffff,0x22c9a8ff,0x33ff82a9});
        glassButton.setCornerRadius(dp(30)); glassButton.setStroke(dp(1),0x88ffffff);
        select.setBackground(glassButton); select.setElevation(dp(8)); select.setPadding(dp(24),dp(14),dp(24),dp(14));
        select.setOnClickListener(v -> pick());
        root.addView(header, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout.LayoutParams cardParams = new LinearLayout.LayoutParams(-1,0,1); cardParams.bottomMargin=dp(4);
        root.addView(previewCard, cardParams);
        root.addView(progress); LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(-1,-2);
        buttonParams.topMargin=dp(12); root.addView(select, buttonParams); setContentView(root);
        handleIntent(getIntent());
    }

    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); }

    private void pick() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                && checkSelfPermission(android.Manifest.permission.ACCESS_MEDIA_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            openPickerAfterPermission = true;
            requestPermissions(new String[]{android.Manifest.permission.ACCESS_MEDIA_LOCATION}, MEDIA_LOCATION_PERMISSION);
            return;
        }
        openGallery();
    }

    private void openGallery() {
        Intent intent;
        if (Build.VERSION.SDK_INT >= 33) {
            intent = new Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*");
        } else {
            intent = new Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).setType("image/*");
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            startActivityForResult(intent, PICK_IMAGE);
        } catch (android.content.ActivityNotFoundException pickerMissing) {
            Intent fallback = new Intent(Intent.ACTION_GET_CONTENT).setType("image/*")
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivityForResult(fallback, PICK_IMAGE);
        }
    }

    private void handleIntent(Intent intent) {
        if (Intent.ACTION_SEND.equals(intent.getAction()) && intent.getType() != null && intent.getType().startsWith("image/")) {
            Uri uri;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
            } else {
                //noinspection deprecation
                uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            }
            if (uri != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                        && checkSelfPermission(android.Manifest.permission.ACCESS_MEDIA_LOCATION)
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    pendingSharedUri = uri;
                    requestPermissions(new String[]{android.Manifest.permission.ACCESS_MEDIA_LOCATION}, MEDIA_LOCATION_PERMISSION);
                } else process(uri);
            }
        }
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != MEDIA_LOCATION_PERMISSION) return;
        if (pendingSharedUri != null) {
            Uri uri = pendingSharedUri; pendingSharedUri = null; process(uri);
        } else if (openPickerAfterPermission) {
            openPickerAfterPermission = false; openGallery();
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == PICK_IMAGE && result == RESULT_OK && data != null && data.getData() != null) {
            Uri uri = data.getData();
            try { getContentResolver().takePersistableUriPermission(uri, data.getFlags() &
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION)); } catch (Exception ignored) {}
            process(uri);
        }
    }

    private void process(Uri uri) {
        sourceUri = uri; progress.setVisibility(View.VISIBLE); finishedBytes = null; emptyState.setVisibility(View.GONE);
        worker.execute(() -> {
            try {
                byte[] all = readAll(uri); MotionPhotoSupport.Parts parts = MotionPhotoSupport.split(all);
                PhotoMetadata metadata = PhotoMetadata.read(new ByteArrayInputStream(parts.imageBytes), queryDateTaken(uri));
                if (hasMediaLocationPermission()) metadata = metadata.withFallback(readOriginalMetadata(uri, all));
                if (!metadata.usable()) throw new IOException("照片内没有可用的拍摄参数（可能已被聊天软件压缩去除），无法生成水印");
                ExifInterface originalExif = new ExifInterface(new ByteArrayInputStream(parts.imageBytes));
                ExifBuilder.Fields exifFields = ExifFields.from(originalExif);
                String originalXmp = MotionPhotoSupport.extractXmp(parts.imageBytes);
                long presentationTs = parsePresentationTimestampUs(originalXmp);
                Bitmap decoded = BitmapFactory.decodeByteArray(parts.imageBytes, 0, parts.imageBytes.length);
                if (decoded == null) throw new IOException("无法解码照片");
                Bitmap oriented = orient(decoded, originalExif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL));
                Bitmap rendered = LiquidGlassRenderer.render(this, oriented, metadata);
                byte[] renderedVideo = parts.videoBytes;
                if (parts.motion) {
                    File inputVideo = new File(getCacheDir(), "motion-in-" + System.nanoTime() + ".mp4");
                    File outputVideo = new File(getCacheDir(), "motion-out-" + System.nanoTime() + ".mp4");
                    try {
                        try (OutputStream videoOut = new FileOutputStream(inputVideo)) { videoOut.write(parts.videoBytes); }
                        MotionVideoRenderer.render(this, inputVideo, outputVideo,
                                oriented.getWidth(), oriented.getHeight(), metadata);
                        renderedVideo = java.nio.file.Files.readAllBytes(outputVideo.toPath());
                        if (presentationTs < 0) presentationTs = videoDurationUsHalf(inputVideo);
                    } finally {
                        inputVideo.delete(); outputVideo.delete();
                    }
                }
                File temp = new File(getCacheDir(), "watermarked-" + System.nanoTime() + ".jpg");
                try (OutputStream out = new FileOutputStream(temp)) {
                    if (!rendered.compress(Bitmap.CompressFormat.JPEG, 100, out)) throw new IOException("JPEG 编码失败");
                }
                byte[] still = java.nio.file.Files.readAllBytes(temp.toPath()); temp.delete();
                byte[] result;
                if (parts.motion) {
                    byte[] stillWithMeta = ExifBuilder.buildMotionJpeg(still, exifFields,
                            renderedVideo.length, Math.max(presentationTs, 0), originalXmp);
                    result = MotionPhotoSupport.join(stillWithMeta, renderedVideo);
                } else {
                    result = ExifBuilder.buildStillJpeg(still, exifFields);
                }
                if (parts.motion && !MotionPhotoSupport.hasVideo(result)) throw new IOException("动态照片视频资源校验失败");
                finishedBytes = result; sourceWasMotion = parts.motion;
                runOnUiThread(() -> {
                    progress.setVisibility(View.GONE); preview.setImageBitmap(rendered);
                    showSaveChoice();
                });
            } catch (Throwable error) {
                String detail = stackDetail(error);
                try (Writer log = new java.io.FileWriter(new File(getCacheDir(), "last-error.txt"))) { log.write(detail); }
                catch (Throwable ignored) { }
                runOnUiThread(() -> { progress.setVisibility(View.GONE); emptyState.setVisibility(View.VISIBLE);
                    showErrorDetail(friendlyMessage(error), detail); });
            }
        });
    }

    private void showErrorDetail(String summary, String detail) {
        ScrollView scroll = new ScrollView(this);
        TextView text = new TextView(this);
        text.setText(detail); text.setTextSize(11); text.setTypeface(Typeface.MONOSPACE);
        text.setPadding(dp(16), dp(12), dp(16), dp(12)); text.setTextIsSelectable(true);
        scroll.addView(text);
        new AlertDialog.Builder(this).setTitle(summary).setView(scroll)
                .setPositiveButton("复制详情", (d, w) -> {
                    android.content.ClipboardManager clipboard =
                            (android.content.ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    clipboard.setPrimaryClip(android.content.ClipData.newPlainText("error", detail));
                    Toast.makeText(this, "已复制，请发给开发者", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("关闭", null).show();
    }

    private static String stackDetail(Throwable error) {
        StringBuilder sb = new StringBuilder();
        Throwable current = error;
        int depth = 0;
        while (current != null && depth < 5) {
            if (depth > 0) sb.append("\n原因 ").append(depth).append(":\n");
            sb.append(current.getClass().getName()).append(": ").append(current.getMessage()).append("\n");
            StackTraceElement[] frames = current.getStackTrace();
            for (int i = 0; i < Math.min(frames.length, 12); i++) sb.append("  at ").append(frames[i]).append("\n");
            current = current.getCause(); depth++;
        }
        return sb.toString();
    }

    private boolean hasMediaLocationPermission() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                && checkSelfPermission(android.Manifest.permission.ACCESS_MEDIA_LOCATION)
                == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }

    private PhotoMetadata readOriginalMetadata(Uri uri, byte[] fallbackBytes) {
        try {
            byte[] bytes = fallbackBytes;
            if (hasMediaLocationPermission()) {
                try { bytes = readUriBytes(MediaStore.setRequireOriginal(uri)); } catch (Throwable ignored) { }
            }
            if (bytes == null || bytes.length == 0) bytes = fallbackBytes;
            return PhotoMetadata.read(new ByteArrayInputStream(MotionPhotoSupport.split(bytes).imageBytes), "");
        } catch (Throwable ignored) {
            return PhotoMetadata.empty();
        }
    }

    private static String friendlyMessage(Throwable error) {
        if (error instanceof SecurityException) return "系统拒绝了照片访问权限，请返回后重新从相册选择照片";
        if (error instanceof java.io.FileNotFoundException) return "找不到照片文件，照片可能已被移动或删除";
        String message = error.getMessage();
        if (message == null || message.trim().isEmpty()) return "处理失败：" + error.getClass().getSimpleName();
        if (message.contains("content://") || message.toLowerCase(java.util.Locale.ROOT).contains("uri")
                || message.toLowerCase(java.util.Locale.ROOT).contains("url")) {
            return "照片访问被系统限制，请返回后重新从相册选择照片";
        }
        return message;
    }

    private void showSaveChoice() {
        new AlertDialog.Builder(this).setTitle(sourceWasMotion ? "动态照片处理完成" : "照片处理完成")
                .setMessage(sourceWasMotion
                        ? "液态玻璃动态水印已合成，保存后在小米相册长按或下拉即可播放动态效果。"
                        : "已生成静态液态玻璃水印照片。\n提示：如果这张原本是动态照片，请直接在系统相册中选择（不要从微信/QQ等应用转发），否则动态视频数据会丢失。")
                .setPositiveButton("保存新图", (d,w) -> saveNew())
                .setNegativeButton("覆盖原图", (d,w) -> overwrite())
                .setNeutralButton("取消", null).show();
    }

    private void saveNew() {
        worker.execute(() -> {
            try {
                ContentValues values = new ContentValues(); values.put(MediaStore.Images.Media.DISPLAY_NAME,
                        "LGW_" + System.currentTimeMillis() + (sourceWasMotion ? "_MP.jpg" : ".jpg"));
                values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg"); values.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/LiquidGlassWatermark");
                values.put(MediaStore.Images.Media.IS_PENDING, 1);
                Uri output = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
                if (output == null) throw new IOException("无法创建相册文件"); write(output, finishedBytes);
                values.clear(); values.put(MediaStore.Images.Media.IS_PENDING, 0); getContentResolver().update(output, values, null, null);
                verifyAndNotify(output);
            } catch (Throwable e) { notifyError(e); }
        });
    }

    private void overwrite() {
        worker.execute(() -> {
            try { write(sourceUri, finishedBytes); verifyAndNotify(sourceUri); }
            catch (Throwable e) {
                if (e instanceof SecurityException || e instanceof IllegalArgumentException) {
                    runOnUiThread(() -> Toast.makeText(this,
                            "该照片来自受限相册无法覆盖，已改为保存新照片", Toast.LENGTH_LONG).show());
                    saveNew();
                } else notifyError(e);
            }
        });
    }

    private void verifyAndNotify(Uri uri) throws IOException {
        byte[] check = readAll(uri);
        if (sourceWasMotion && !MotionPhotoSupport.hasVideo(check)) throw new IOException("保存后动态视频资源丢失，已判定失败");
        runOnUiThread(() -> Toast.makeText(this, sourceWasMotion ? "动态照片保存成功" : "照片保存成功", Toast.LENGTH_LONG).show());
    }

    private void notifyError(Throwable e) { runOnUiThread(() -> Toast.makeText(this, "保存失败：" + e.getMessage(), Toast.LENGTH_LONG).show()); }
    private void write(Uri uri, byte[] bytes) throws IOException { try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException("没有写入权限");out.write(bytes);} }
    private byte[] readAll(Uri uri) throws IOException {
        java.util.List<Uri> candidates = new java.util.ArrayList<>(2);
        candidates.add(uri);
        if (hasMediaLocationPermission()) {
            try { Uri original = MediaStore.setRequireOriginal(uri); if (!candidates.contains(original)) candidates.add(original); }
            catch (Throwable ignored) { }
        }
        IOException last = null;
        for (Uri candidate : candidates) {
            try {
                byte[] data = readUriBytes(candidate);
                if (data.length > 0) return data;
                last = new IOException("照片内容为空");
            } catch (IOException | SecurityException | IllegalArgumentException | IllegalStateException error) {
                last = error instanceof IOException ? (IOException) error : new IOException(error.getMessage(), error);
            }
        }
        throw new IOException("无法读取照片：" + (last == null ? "未知原因" : last.toString()), last);
    }

    private byte[] readUriBytes(Uri uri) throws IOException {
        IOException streamError = null;
        try {
            byte[] data = slurp(getContentResolver().openInputStream(uri));
            if (data.length > 0) return data;
        } catch (IOException | SecurityException | IllegalArgumentException | IllegalStateException error) {
            streamError = error instanceof IOException ? (IOException) error : new IOException(error.getMessage(), error);
        }
        try (android.content.res.AssetFileDescriptor descriptor = getContentResolver().openAssetFileDescriptor(uri, "r")) {
            if (descriptor != null) {
                try (InputStream in = descriptor.createInputStream()) {
                    byte[] data = slurp(in);
                    if (data.length > 0) return data;
                }
            }
        } catch (IOException | SecurityException | IllegalArgumentException | IllegalStateException ignored) { }
        if (streamError != null) throw streamError;
        throw new IOException("照片内容为空");
    }

    private static byte[] slurp(InputStream in) throws IOException {
        if (in == null) throw new IOException("无法打开照片流");
        try (ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[131072];
            for (int n; (n = in.read(b)) >= 0;) out.write(b, 0, n);
            return out.toByteArray();
        } finally { try { in.close(); } catch (Throwable ignored) { } }
    }

    private String queryDateTaken(Uri uri) {
        if (uri == null) return "";
        try (android.database.Cursor cursor = getContentResolver().query(uri,
                new String[]{MediaStore.Images.Media.DATE_TAKEN}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                long taken = cursor.getLong(0);
                if (taken > 0) {
                    java.text.SimpleDateFormat format = new java.text.SimpleDateFormat("yyyy:MM:dd HH:mm", java.util.Locale.US);
                    return format.format(new java.util.Date(taken));
                }
            }
        } catch (Throwable ignored) { }
        return "";
    }

    private static Bitmap orient(Bitmap input, int orientation) {
        Matrix m = new Matrix(); if(orientation==ExifInterface.ORIENTATION_ROTATE_90)m.postRotate(90); else if(orientation==ExifInterface.ORIENTATION_ROTATE_180)m.postRotate(180); else if(orientation==ExifInterface.ORIENTATION_ROTATE_270)m.postRotate(270);
        if(m.isIdentity())return input; Bitmap out=Bitmap.createBitmap(input,0,0,input.getWidth(),input.getHeight(),m,true); if(out!=input)input.recycle(); return out;
    }

    /** 从原始 XMP 中解析动态照片的关键帧时间戳，没有返回 -1。 */
    private static long parsePresentationTimestampUs(String xmp) {
        if (xmp == null) return -1;
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("(?:MicroVideo|MotionPhoto)PresentationTimestampUs=\"(-?\\d+)\"").matcher(xmp);
        if (m.find()) {
            try { return Long.parseLong(m.group(1)); } catch (NumberFormatException ignored) { }
        }
        return -1;
    }

    /** 兜底：取视频时长的一半作为关键帧时间戳（微秒）。 */
    private static long videoDurationUsHalf(File video) {
        try {
            android.media.MediaMetadataRetriever retriever = new android.media.MediaMetadataRetriever();
            try {
                retriever.setDataSource(video.getAbsolutePath());
                String durationMs = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION);
                if (durationMs != null) return Long.parseLong(durationMs) * 1000L / 2L;
            } finally {
                try { retriever.release(); } catch (Throwable ignored) { }
            }
        } catch (Throwable ignored) { }
        return -1;
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    @Override protected void onDestroy(){super.onDestroy();worker.shutdownNow();}
}
