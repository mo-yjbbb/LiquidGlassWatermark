package com.localwatermark.liquidglass.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.Effect;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.BitmapOverlay;
import androidx.media3.effect.OverlayEffect;
import androidx.media3.transformer.EditedMediaItem;
import androidx.media3.transformer.Effects;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.Transformer;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

@UnstableApi
final class MotionVideoRenderer {
    private MotionVideoRenderer() {}

    static void render(Context context, File input, File output, int width, int height,
                       PhotoMetadata metadata) throws Exception {
        // 使用内嵌视频自己的编码尺寸；封面尺寸只能用于定位比例，不能拿来
        // 重建视频画布，否则 1080x1440 的竖版视频会被编码成 4096x3072。
        int[] sourceVideo = probeVideoSize(input);
        int outWidth = even(sourceVideo[0] > 0 ? sourceVideo[0] : width);
        int outHeight = even(sourceVideo[1] > 0 ? sourceVideo[1] : height);
        float targetAspect = width / (float)Math.max(1, height);
        Bitmap content = LiquidGlassRenderer.createContentOverlay(
                context, outWidth, outHeight, targetAspect, metadata);
        CountDownLatch finished = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        new Handler(Looper.getMainLooper()).post(() -> {
            try {
                BitmapOverlay bitmapOverlay = BitmapOverlay.createStaticBitmapOverlay(content);
                List<Effect> videoEffects = new ArrayList<>();
                videoEffects.add(new LiquidGlassVideoEffect(targetAspect));
                videoEffects.add(new OverlayEffect(Collections.singletonList(bitmapOverlay)));
                EditedMediaItem item = new EditedMediaItem.Builder(MediaItem.fromUri(input.toURI().toString()))
                        .setEffects(new Effects(Collections.emptyList(), videoEffects)).build();
                Transformer transformer = new Transformer.Builder(context)
                        .setVideoMimeType(MimeTypes.VIDEO_H264)
                        .addListener(new Transformer.Listener() {
                            @Override public void onCompleted(androidx.media3.transformer.Composition composition,
                                                              ExportResult result) { finished.countDown(); }
                            @Override public void onError(androidx.media3.transformer.Composition composition,
                                                          ExportResult result, ExportException exception) {
                                failure.set(exception); finished.countDown();
                            }
                        }).build();
                transformer.start(item, output.getAbsolutePath());
            } catch (Throwable error) {
                failure.set(error); finished.countDown();
            }
        });
        if (!finished.await(3, TimeUnit.MINUTES)) throw new Exception("动态视频逐帧渲染超时");
        content.recycle();
        if (failure.get() != null) throw new Exception("动态视频渲染失败", failure.get());
        if (!output.isFile() || output.length() < 32) throw new Exception("动态视频输出为空");
        verifyDisplayOrientation(output, width, height);
    }

    private static int even(int value) { return value - (value & 1); }

    private static void verifyDisplayOrientation(File output, int coverWidth, int coverHeight)
            throws Exception {
        int[] info = probeVideoDisplay(output);
        if (info[0] <= 0 || info[1] <= 0) return;
        boolean coverPortrait = coverHeight > coverWidth;
        boolean videoPortrait = info[1] > info[0];
        if (coverPortrait != videoPortrait) {
            throw new Exception("动态视频方向校验失败：封面 "
                    + coverWidth + "x" + coverHeight + "，视频显示 " + info[0] + "x" + info[1]);
        }
    }

    private static int[] probeVideoDisplay(File file) {
        android.media.MediaMetadataRetriever r = new android.media.MediaMetadataRetriever();
        try {
            r.setDataSource(file.getAbsolutePath());
            int w = parseInt(r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH));
            int h = parseInt(r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT));
            int rotation = parseInt(r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION));
            if ((Math.abs(rotation) % 180) == 90) { int swap = w; w = h; h = swap; }
            return new int[]{w,h};
        } catch (Throwable ignored) {
            return new int[]{0,0};
        } finally {
            try { r.release(); } catch (Throwable ignored) { }
        }
    }

    /**
     * Media3 在部分 MIUI/荣耀视频上会把旋转烘焙进画面后仍保留 tkhd 的
     * 90/270 度矩阵，图库播放时就会二次旋转。输出已按封面方向编码，因此
     * 将轨道显示矩阵归一化为单位矩阵。
     */
    private static void normalizeTrackMatrices(File file) throws java.io.IOException {
        try (java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "rw")) {
            scanBoxes(raf, 0, raf.length());
        }
    }

    private static void scanBoxes(java.io.RandomAccessFile raf, long start, long end)
            throws java.io.IOException {
        long pos = start;
        while (pos + 8 <= end) {
            raf.seek(pos);
            long size = Integer.toUnsignedLong(raf.readInt());
            int type = raf.readInt();
            int header = 8;
            if (size == 1) { size = raf.readLong(); header = 16; }
            else if (size == 0) size = end - pos;
            if (size < header || pos + size > end) return;
            long payload = pos + header;
            if (type == fourcc("tkhd")) {
                raf.seek(payload);
                int version = raf.readUnsignedByte();
                long matrix = payload + (version == 1 ? 52 : 40);
                if (matrix + 36 <= pos + size) {
                    raf.seek(matrix);
                    int[] identity = {0x00010000,0,0, 0,0x00010000,0, 0,0,0x40000000};
                    for (int value : identity) raf.writeInt(value);
                }
            } else if (isContainer(type)) {
                long child = payload + (type == fourcc("meta") ? 4 : 0);
                scanBoxes(raf, child, pos + size);
            }
            pos += size;
        }
    }

    private static boolean isContainer(int type) {
        return type == fourcc("moov") || type == fourcc("trak") || type == fourcc("mdia")
                || type == fourcc("minf") || type == fourcc("stbl") || type == fourcc("edts")
                || type == fourcc("dinf") || type == fourcc("udta") || type == fourcc("meta");
    }

    private static int fourcc(String value) {
        return (value.charAt(0) << 24) | (value.charAt(1) << 16)
                | (value.charAt(2) << 8) | value.charAt(3);
    }

    /** 探测视频分辨率，用于按视频画布的比例绘制文字图层。失败返回 {0,0}。 */
    private static int[] probeVideoSize(File file) {
        int[] size = new int[]{0, 0};
        android.media.MediaMetadataRetriever retriever = null;
        try {
            retriever = new android.media.MediaMetadataRetriever();
            retriever.setDataSource(file.getAbsolutePath());
            size[0] = parseInt(retriever.extractMetadata(
                    android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH));
            size[1] = parseInt(retriever.extractMetadata(
                    android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT));
        } catch (Throwable ignored) {
            size[0] = 0;
            size[1] = 0;
        } finally {
            if (retriever != null) {
                try { retriever.release(); } catch (Throwable ignored) { }
            }
        }
        return size;
    }

    private static int parseInt(String value) {
        if (value == null) return 0;
        try { return Integer.parseInt(value.trim()); } catch (NumberFormatException e) { return 0; }
    }
}
