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

    private static final class MissingMetadataException extends IOException {
        MissingMetadataException(String message) { super(message); }
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(0xff080910);
        if (Build.VERSION.SDK_INT >= 30) getWindow().setDecorFitsSystemWindows(false);

        FrameLayout stage = new FrameLayout(this);
        stage.setBackground(new LiquidUiDrawable(LiquidUiDrawable.BACKGROUND));
        stage.addView(ambientOrb(0x55ff4f91, dp(300), Gravity.BOTTOM|Gravity.RIGHT, -dp(120), -dp(80)));
        stage.addView(ambientOrb(0x443d91ff, dp(260), Gravity.TOP|Gravity.LEFT, -dp(110), dp(70)));
        stage.addView(ambientOrb(0x2bb775ff, dp(210), Gravity.CENTER, dp(120), -dp(30)));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(20),dp(18),dp(20),dp(18));
        root.setOnApplyWindowInsetsListener((view,insets)->{
            android.graphics.Insets bars=Build.VERSION.SDK_INT>=30
                    ? insets.getInsets(WindowInsets.Type.systemBars())
                    : android.graphics.Insets.of(0,insets.getSystemWindowInsetTop(),0,insets.getSystemWindowInsetBottom());
            view.setPadding(dp(20),bars.top+dp(15),dp(20),bars.bottom+dp(16));
            return insets;
        });

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.VERTICAL);
        header.setGravity(Gravity.CENTER);
        header.setPadding(0,dp(2),0,dp(18));
        TextView title = label("小米液态玻璃水印",26,Color.WHITE,Typeface.BOLD);
        title.setGravity(Gravity.CENTER);
        TextView subtitle = label("目前只有徕卡 Logo 水印",13,0xa8ffffff,Typeface.NORMAL);
        subtitle.setGravity(Gravity.CENTER);
        subtitle.setLetterSpacing(.05f);
        subtitle.setPadding(0,dp(4),0,0);
        header.addView(title,new LinearLayout.LayoutParams(-1,-2));
        header.addView(subtitle,new LinearLayout.LayoutParams(-1,-2));

        FrameLayout previewCard = new FrameLayout(this);
        previewCard.setBackground(new LiquidUiDrawable(LiquidUiDrawable.PANEL));
        previewCard.setPadding(dp(7),dp(7),dp(7),dp(7));
        previewCard.setElevation(dp(10));
        previewCard.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View view, Outline outline) {
                outline.setRoundRect(0,0,view.getWidth(),view.getHeight(),dp(28));
            }
        });
        previewCard.setClipToOutline(true);

        preview = new ImageView(this);
        preview.setScaleType(ImageView.ScaleType.FIT_CENTER);
        preview.setAdjustViewBounds(true);
        GradientDrawable previewSurface=new GradientDrawable();
        previewSurface.setColor(0x16000000);
        previewSurface.setCornerRadius(dp(22));
        preview.setBackground(previewSurface);
        preview.setClipToOutline(true);
        previewCard.addView(preview,new FrameLayout.LayoutParams(-1,-1));

        LinearLayout empty = new LinearLayout(this);
        empty.setOrientation(LinearLayout.VERTICAL);
        empty.setGravity(Gravity.CENTER);
        empty.setPadding(dp(28),dp(24),dp(28),dp(24));

        TextView formatChip = label("PHOTO  ·  MOTION",11,0xc9ffffff,Typeface.BOLD);
        formatChip.setLetterSpacing(.12f);
        formatChip.setGravity(Gravity.CENTER);
        formatChip.setBackground(new LiquidUiDrawable(LiquidUiDrawable.CHIP));
        formatChip.setPadding(dp(15),0,dp(15),0);
        empty.addView(formatChip,new LinearLayout.LayoutParams(-2,dp(32)));

        ImageView emptyIcon = new ImageView(this);
        emptyIcon.setImageResource(R.drawable.app_icon);
        emptyIcon.setScaleType(ImageView.ScaleType.CENTER_CROP);
        LinearLayout.LayoutParams emptyIconParams=new LinearLayout.LayoutParams(dp(82),dp(82));
        emptyIconParams.topMargin=dp(22);
        empty.addView(emptyIcon,emptyIconParams);

        TextView emptyTitle = label("让照片拥有流动的光",21,Color.WHITE,Typeface.BOLD);
        emptyTitle.setGravity(Gravity.CENTER);
        emptyTitle.setPadding(0,dp(17),0,0);
        empty.addView(emptyTitle);

        TextView emptyHint = label("选择照片后，自动读取真实拍摄信息\n生成折射、色散与高光构成的液态玻璃水印",14,0x9effffff,Typeface.NORMAL);
        emptyHint.setGravity(Gravity.CENTER);
        emptyHint.setLineSpacing(dp(4),1f);
        emptyHint.setPadding(dp(4),dp(9),dp(4),0);
        empty.addView(emptyHint);
        emptyState=empty;
        previewCard.addView(empty,new FrameLayout.LayoutParams(-1,-1));

        progress=new ProgressBar(this);
        progress.setVisibility(View.GONE);
        FrameLayout.LayoutParams progressParams=new FrameLayout.LayoutParams(dp(44),dp(44),Gravity.CENTER);
        previewCard.addView(progress,progressParams);

        LinearLayout capabilities=new LinearLayout(this);
        capabilities.setOrientation(LinearLayout.HORIZONTAL);
        capabilities.setGravity(Gravity.CENTER);
        capabilities.setPadding(dp(2),dp(13),dp(2),dp(13));
        capabilities.addView(feature("原画质", "不压缩参数"),new LinearLayout.LayoutParams(0,-2,1f));
        capabilities.addView(feature("真实 EXIF", "自动读取"),new LinearLayout.LayoutParams(0,-2,1f));
        capabilities.addView(feature("动态照片", "逐帧渲染"),new LinearLayout.LayoutParams(0,-2,1f));

        TextView select=label("＋  从相册选择照片",17,Color.WHITE,Typeface.BOLD);
        select.setGravity(Gravity.CENTER);
        select.setClickable(true);
        select.setFocusable(true);
        android.graphics.drawable.RippleDrawable ripple=new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(0x35ffffff),
                new LiquidUiDrawable(LiquidUiDrawable.BUTTON),null);
        select.setBackground(ripple);
        select.setElevation(dp(9));
        select.setOnClickListener(vw->pick());

        LinearLayout footer=new LinearLayout(this);
        footer.setOrientation(LinearLayout.HORIZONTAL);
        footer.setGravity(Gravity.CENTER_VERTICAL);
        footer.setPadding(0,dp(11),0,0);
        TextView localFooter=label("操作仅本地处理",12,0x78ffffff,Typeface.NORMAL);
        TextView authorFooter=label("小米社区-呀哈哈我被发现了再见",12,0x78ffffff,Typeface.NORMAL);
        authorFooter.setGravity(Gravity.RIGHT);
        footer.addView(localFooter,new LinearLayout.LayoutParams(0,-2,1f));
        footer.addView(authorFooter,new LinearLayout.LayoutParams(0,-2,1f));

        root.addView(header,new LinearLayout.LayoutParams(-1,-2));
        LinearLayout.LayoutParams cardParams=new LinearLayout.LayoutParams(-1,0,1f);
        cardParams.bottomMargin=dp(1);
        root.addView(previewCard,cardParams);
        root.addView(capabilities,new LinearLayout.LayoutParams(-1,-2));
        root.addView(select,new LinearLayout.LayoutParams(-1,dp(62)));
        root.addView(footer,new LinearLayout.LayoutParams(-1,-2));
        stage.addView(root,new FrameLayout.LayoutParams(-1,-1));
        setContentView(stage);
        handleIntent(getIntent());
    }

    private View ambientOrb(int color,int size,int gravity,int marginX,int marginY){
        View orb=new View(this);
        GradientDrawable glow=new GradientDrawable();
        glow.setShape(GradientDrawable.OVAL);
        glow.setGradientType(GradientDrawable.RADIAL_GRADIENT);
        glow.setGradientRadius(size*.5f);
        glow.setColors(new int[]{color,color&0x00ffffff});
        orb.setBackground(glow);
        orb.setAlpha(.62f);
        FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(size,size,gravity);
        if((gravity&Gravity.RIGHT)!=0)p.rightMargin=marginX; else p.leftMargin=marginX;
        if((gravity&Gravity.BOTTOM)!=0)p.bottomMargin=marginY; else p.topMargin=marginY;
        orb.setLayoutParams(p);
        return orb;
    }

    private TextView label(String value,float size,int color,int style){
        TextView view=new TextView(this);
        view.setText(value); view.setTextSize(size); view.setTextColor(color);
        view.setTypeface(Typeface.create("sans",style));
        view.setIncludeFontPadding(false);
        return view;
    }

    private View feature(String title,String detail){
        LinearLayout box=new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL); box.setGravity(Gravity.CENTER);
        TextView name=label(title,13,0xeaffffff,Typeface.BOLD);
        name.setGravity(Gravity.CENTER);
        TextView hint=label(detail,11,0x72ffffff,Typeface.NORMAL);
        hint.setGravity(Gravity.CENTER); hint.setPadding(0,dp(3),0,0);
        box.addView(name); box.addView(hint);
        return box;
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
            // 刻意不用 ACTION_PICK_IMAGES：系统 Photo Picker 为了保护隐私会剥离
            // EXIF 里的经纬度，且不支持 setRequireOriginal，本应用就拿不到相机
            // 原始字节（位置、私有动态照片标签全丢）。走传统选择器保住这些数据。
            intent = new Intent(Intent.ACTION_GET_CONTENT).setType("image/*")
                    .addCategory(Intent.CATEGORY_OPENABLE);
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
                // readAll 已优先取原始文件，只有位置仍然缺失时才再读一次兜底
                if (metadata.location.isEmpty() && hasMediaLocationPermission()) {
                    metadata = metadata.withFallback(readOriginalMetadata(uri, all));
                }
                if (!metadata.complete()) throw new MissingMetadataException("无法读取完整的照片信息，缺少：" + metadata.missingFields() + "。\n这张图片不能制作水印。");
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
                    byte[] stillWithMeta = ExifBuilder.buildMotionJpeg(still, parts.imageBytes, exifFields,
                            renderedVideo.length, Math.max(presentationTs, 0), originalXmp);
                    result = MotionPhotoSupport.join(stillWithMeta, renderedVideo);
                } else {
                    result = ExifBuilder.buildStillJpeg(still, parts.imageBytes, exifFields);
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
                runOnUiThread(() -> {
                    progress.setVisibility(View.GONE);
                    emptyState.setVisibility(View.VISIBLE);
                    if (error instanceof MissingMetadataException) {
                        showMetadataUnavailable(error.getMessage());
                    } else {
                        showErrorDetail(friendlyMessage(error), detail);
                    }
                });
            }
        });
    }

    private void showMetadataUnavailable(String message) {
        final Dialog dialog=new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel=new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setGravity(Gravity.CENTER_HORIZONTAL);
        panel.setPadding(dp(24),dp(24),dp(24),dp(20));
        panel.setBackground(new LiquidUiDrawable(LiquidUiDrawable.PANEL));

        TextView badge=label("!  METADATA",11,0xffffd7df,Typeface.BOLD);
        badge.setLetterSpacing(.10f); badge.setGravity(Gravity.CENTER);
        badge.setBackground(new LiquidUiDrawable(LiquidUiDrawable.CHIP));
        badge.setPadding(dp(15),0,dp(15),0);
        panel.addView(badge,new LinearLayout.LayoutParams(-2,dp(34)));

        TextView title=label("无法制作水印",21,Color.WHITE,Typeface.BOLD);
        title.setGravity(Gravity.CENTER); title.setPadding(0,dp(18),0,0);
        panel.addView(title);

        TextView description=label(message,14,0xb8ffffff,Typeface.NORMAL);
        description.setGravity(Gravity.CENTER); description.setLineSpacing(dp(4),1f);
        description.setPadding(dp(3),dp(11),dp(3),dp(20));
        panel.addView(description,new LinearLayout.LayoutParams(-1,-2));

        TextView close=dialogButton("我知道了",true);
        close.setOnClickListener(view->dialog.dismiss());
        panel.addView(close,new LinearLayout.LayoutParams(-1,dp(54)));

        FrameLayout shell=new FrameLayout(this);
        shell.setPadding(dp(22),dp(22),dp(22),dp(22));
        shell.addView(panel,new FrameLayout.LayoutParams(-1,-2,Gravity.CENTER));
        dialog.setContentView(shell);
        Window window=dialog.getWindow();
        if(window!=null){
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attributes=window.getAttributes();
            attributes.dimAmount=.72f; window.setAttributes(attributes);
        }
        dialog.show();
        if(dialog.getWindow()!=null) dialog.getWindow().setLayout(
                WindowManager.LayoutParams.MATCH_PARENT,WindowManager.LayoutParams.WRAP_CONTENT);
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
        final Dialog dialog=new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dialog.setCanceledOnTouchOutside(true);

        LinearLayout panel=new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setGravity(Gravity.CENTER_HORIZONTAL);
        panel.setPadding(dp(24),dp(24),dp(24),dp(18));
        panel.setBackground(new LiquidUiDrawable(LiquidUiDrawable.PANEL));
        panel.setElevation(dp(18));

        TextView badge=label(sourceWasMotion ? "◉  MOTION READY" : "✓  PHOTO READY",
                11,0xd8ffffff,Typeface.BOLD);
        badge.setLetterSpacing(.10f); badge.setGravity(Gravity.CENTER);
        badge.setBackground(new LiquidUiDrawable(LiquidUiDrawable.CHIP));
        badge.setPadding(dp(15),0,dp(15),0);
        panel.addView(badge,new LinearLayout.LayoutParams(-2,dp(34)));

        TextView title=label(sourceWasMotion ? "动态照片处理完成" : "照片处理完成",
                22,Color.WHITE,Typeface.BOLD);
        title.setGravity(Gravity.CENTER); title.setPadding(0,dp(19),0,0);
        panel.addView(title);

        String description=sourceWasMotion
                ? "液态玻璃效果已逐帧合成\n请选择保存为新图，或覆盖原始动态照片"
                : "液态玻璃水印已经生成\n请选择保存方式";
        TextView message=label(description,14,0xa8ffffff,Typeface.NORMAL);
        message.setGravity(Gravity.CENTER); message.setLineSpacing(dp(4),1f);
        message.setPadding(dp(4),dp(10),dp(4),dp(21));
        panel.addView(message,new LinearLayout.LayoutParams(-1,-2));

        TextView save=dialogButton("保存新图",true);
        save.setOnClickListener(view->{dialog.dismiss();saveNew();});
        panel.addView(save,new LinearLayout.LayoutParams(-1,dp(56)));

        TextView overwrite=dialogButton("覆盖原图",false);
        overwrite.setOnClickListener(view->{dialog.dismiss();overwrite();});
        LinearLayout.LayoutParams overwriteParams=new LinearLayout.LayoutParams(-1,dp(50));
        overwriteParams.topMargin=dp(10);
        panel.addView(overwrite,overwriteParams);

        TextView cancel=label("取消",14,0x92ffffff,Typeface.BOLD);
        cancel.setGravity(Gravity.CENTER); cancel.setClickable(true); cancel.setFocusable(true);
        cancel.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(0x22ffffff),null,null));
        cancel.setOnClickListener(view->dialog.dismiss());
        LinearLayout.LayoutParams cancelParams=new LinearLayout.LayoutParams(-1,dp(44));
        cancelParams.topMargin=dp(4);
        panel.addView(cancel,cancelParams);

        FrameLayout shell=new FrameLayout(this);
        shell.setPadding(dp(22),dp(22),dp(22),dp(22));
        shell.addView(panel,new FrameLayout.LayoutParams(-1,-2,Gravity.CENTER));
        dialog.setContentView(shell);
        Window window=dialog.getWindow();
        if(window!=null){
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            WindowManager.LayoutParams attributes=window.getAttributes();
            attributes.dimAmount=.72f; window.setAttributes(attributes);
        }
        dialog.show();
        if(dialog.getWindow()!=null) dialog.getWindow().setLayout(
                WindowManager.LayoutParams.MATCH_PARENT,WindowManager.LayoutParams.WRAP_CONTENT);
    }

    private TextView dialogButton(String text,boolean primary){
        TextView button=label(text,primary?16:15,Color.WHITE,Typeface.BOLD);
        button.setGravity(Gravity.CENTER); button.setClickable(true); button.setFocusable(true);
        android.graphics.drawable.Drawable surface=new LiquidUiDrawable(
                primary?LiquidUiDrawable.BUTTON:LiquidUiDrawable.CHIP);
        button.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(0x38ffffff),surface,null));
        if(primary) button.setElevation(dp(7));
        return button;
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
        // 关键：普通 URI 读到的图片会被系统剥离 GPS（Android 10+ 的位置隐私设计），
        // 必须优先走 setRequireOriginal 才能拿到相机原始字节：既有经纬度，也是
        // 原汁原味的 EXIF（ExifBuilder 继承的就是它）。失败再回退普通 URI。
        if (hasMediaLocationPermission()) {
            try { candidates.add(MediaStore.setRequireOriginal(uri)); }
            catch (Throwable ignored) { }
        }
        candidates.add(uri);
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
