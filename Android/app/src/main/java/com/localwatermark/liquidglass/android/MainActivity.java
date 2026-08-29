package com.localwatermark.liquidglass.android;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.provider.MediaStore;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.view.*;
import android.widget.*;
import androidx.exifinterface.media.ExifInterface;
import java.io.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity {
    private static final int PICK_IMAGE = 42;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private ImageView preview;
    private ProgressBar progress;
    private Uri sourceUri;
    private byte[] finishedBytes;
    private boolean sourceWasMotion;

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
        TextView title = new TextView(this); title.setText("液态玻璃水印"); title.setTextSize(27); title.setTextColor(Color.WHITE);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD); title.setGravity(Gravity.CENTER);
        TextView subtitle = new TextView(this); subtitle.setText("小米 · 徕卡动态影像"); subtitle.setTextSize(14);
        subtitle.setTextColor(0xbbffffff); subtitle.setGravity(Gravity.CENTER); subtitle.setPadding(0,dp(5),0,dp(16));
        preview = new ImageView(this); preview.setAdjustViewBounds(true); preview.setScaleType(ImageView.ScaleType.FIT_CENTER);
        GradientDrawable previewBg = new GradientDrawable(); previewBg.setColor(0x22000000); previewBg.setCornerRadius(dp(24));
        previewBg.setStroke(dp(1),0x28ffffff); preview.setBackground(previewBg); preview.setPadding(dp(6),dp(6),dp(6),dp(6));
        progress = new ProgressBar(this); progress.setVisibility(View.GONE);
        Button select = new Button(this); select.setText("从相册选择照片"); select.setTextColor(Color.WHITE);
        select.setTextSize(17); select.setAllCaps(false); select.setTypeface(Typeface.DEFAULT,Typeface.BOLD);
        GradientDrawable glassButton = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0x58ffffff,0x22c9a8ff,0x33ff82a9});
        glassButton.setCornerRadius(dp(30)); glassButton.setStroke(dp(1),0x88ffffff);
        select.setBackground(glassButton); select.setElevation(dp(8)); select.setPadding(dp(24),dp(14),dp(24),dp(14));
        select.setOnClickListener(v -> pick());
        root.addView(title, new LinearLayout.LayoutParams(-1, -2));
        root.addView(subtitle, new LinearLayout.LayoutParams(-1, -2));
        root.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
        root.addView(progress); LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(-1,-2);
        buttonParams.topMargin=dp(12); root.addView(select, buttonParams); setContentView(root);
        handleIntent(getIntent());
    }

    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); }

    private void pick() {
        Intent intent;
        if (Build.VERSION.SDK_INT >= 33) {
            intent = new Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*");
        } else {
            intent = new Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).setType("image/*");
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        startActivityForResult(intent, PICK_IMAGE);
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
            if (uri != null) process(uri);
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
        sourceUri = uri; progress.setVisibility(View.VISIBLE); finishedBytes = null;
        worker.execute(() -> {
            try {
                byte[] all = readAll(uri); MotionPhotoSupport.Parts parts = MotionPhotoSupport.split(all);
                PhotoMetadata metadata = PhotoMetadata.read(new ByteArrayInputStream(parts.imageBytes));
                if (!metadata.complete()) throw new IOException("照片缺少机型、日期、拍摄参数或经纬度，不能添加水印");
                ExifInterface originalExif = new ExifInterface(new ByteArrayInputStream(parts.imageBytes));
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
                    } finally {
                        inputVideo.delete(); outputVideo.delete();
                    }
                }
                File temp = new File(getCacheDir(), "watermarked-" + System.nanoTime() + ".jpg");
                try (OutputStream out = new FileOutputStream(temp)) {
                    if (!rendered.compress(Bitmap.CompressFormat.JPEG, 100, out)) throw new IOException("JPEG 编码失败");
                }
                copyExif(originalExif, new ExifInterface(temp), parts.motion ? renderedVideo.length : 0);
                byte[] still = java.nio.file.Files.readAllBytes(temp.toPath()); temp.delete();
                byte[] result = parts.motion ? MotionPhotoSupport.join(still, renderedVideo) : still;
                if (parts.motion && !MotionPhotoSupport.hasVideo(result)) throw new IOException("动态照片视频资源校验失败");
                finishedBytes = result; sourceWasMotion = parts.motion;
                runOnUiThread(() -> {
                    progress.setVisibility(View.GONE); preview.setImageBitmap(rendered);
                    showSaveChoice();
                });
            } catch (Throwable error) {
                runOnUiThread(() -> { progress.setVisibility(View.GONE); Toast.makeText(this, error.getMessage(), Toast.LENGTH_LONG).show(); });
            }
        });
    }

    private void showSaveChoice() {
        new AlertDialog.Builder(this).setTitle(sourceWasMotion ? "动态照片处理完成" : "照片处理完成")
                .setMessage("请选择保存方式")
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
        worker.execute(() -> { try { write(sourceUri, finishedBytes); verifyAndNotify(sourceUri); } catch (Throwable e) { notifyError(e); } });
    }

    private void verifyAndNotify(Uri uri) throws IOException {
        byte[] check = readAll(uri);
        if (sourceWasMotion && !MotionPhotoSupport.hasVideo(check)) throw new IOException("保存后动态视频资源丢失，已判定失败");
        runOnUiThread(() -> Toast.makeText(this, sourceWasMotion ? "动态照片保存成功" : "照片保存成功", Toast.LENGTH_LONG).show());
    }

    private void notifyError(Throwable e) { runOnUiThread(() -> Toast.makeText(this, "保存失败：" + e.getMessage(), Toast.LENGTH_LONG).show()); }
    private void write(Uri uri, byte[] bytes) throws IOException { try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException("没有写入权限");out.write(bytes);} }
    private byte[] readAll(Uri uri) throws IOException { try(InputStream in=getContentResolver().openInputStream(uri); ByteArrayOutputStream out=new ByteArrayOutputStream()){if(in==null)throw new IOException("无法读取照片");byte[] b=new byte[131072];for(int n;(n=in.read(b))>=0;)out.write(b,0,n);return out.toByteArray();} }

    private static Bitmap orient(Bitmap input, int orientation) {
        Matrix m = new Matrix(); if(orientation==ExifInterface.ORIENTATION_ROTATE_90)m.postRotate(90); else if(orientation==ExifInterface.ORIENTATION_ROTATE_180)m.postRotate(180); else if(orientation==ExifInterface.ORIENTATION_ROTATE_270)m.postRotate(270);
        if(m.isIdentity())return input; Bitmap out=Bitmap.createBitmap(input,0,0,input.getWidth(),input.getHeight(),m,true); if(out!=input)input.recycle(); return out;
    }

    private static void copyExif(ExifInterface src, ExifInterface dst, int motionVideoLength) throws IOException {
        String[] tags={ExifInterface.TAG_MAKE,ExifInterface.TAG_MODEL,ExifInterface.TAG_DATETIME,ExifInterface.TAG_DATETIME_ORIGINAL,ExifInterface.TAG_DATETIME_DIGITIZED,ExifInterface.TAG_F_NUMBER,ExifInterface.TAG_EXPOSURE_TIME,ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,ExifInterface.TAG_FOCAL_LENGTH,ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,ExifInterface.TAG_GPS_LATITUDE,ExifInterface.TAG_GPS_LATITUDE_REF,ExifInterface.TAG_GPS_LONGITUDE,ExifInterface.TAG_GPS_LONGITUDE_REF,ExifInterface.TAG_GPS_ALTITUDE,ExifInterface.TAG_GPS_ALTITUDE_REF};
        for(String tag:tags){String value=src.getAttribute(tag);if(value!=null)dst.setAttribute(tag,value);}
        if (motionVideoLength > 0) dst.setAttribute(ExifInterface.TAG_XMP, motionXmp(motionVideoLength));
        dst.setAttribute(ExifInterface.TAG_ORIENTATION,String.valueOf(ExifInterface.ORIENTATION_NORMAL)); dst.saveAttributes();
    }

    private static String motionXmp(int videoLength) {
        return "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description xmlns:Camera=\"http://ns.google.com/photos/1.0/camera/\" "
                + "Camera:MotionPhoto=\"1\" Camera:MotionPhotoVersion=\"1\" Camera:MotionPhotoPresentationTimestampUs=\"-1\" "
                + "Camera:MicroVideo=\"1\" Camera:MicroVideoVersion=\"1\" Camera:MicroVideoOffset=\"" + videoLength + "\">"
                + "<Container:Directory xmlns:Container=\"http://ns.google.com/photos/1.0/container/\" "
                + "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\"><rdf:Seq>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"image/jpeg\" Item:Semantic=\"Primary\"/></rdf:li>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"" + videoLength + "\"/></rdf:li>"
                + "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    @Override protected void onDestroy(){super.onDestroy();worker.shutdownNow();}
}
