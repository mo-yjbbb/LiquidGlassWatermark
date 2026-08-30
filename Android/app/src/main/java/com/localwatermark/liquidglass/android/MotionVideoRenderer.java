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
        // 静态图宽高比：视频通常与之不同，靠它算出胶囊应该待的安全区
        float targetAspect = width / (float) Math.max(1, height);
        int[] videoSize = probeVideoSize(input);
        int videoWidth = videoSize[0] > 0 ? videoSize[0] : width;
        int videoHeight = videoSize[1] > 0 ? videoSize[1] : height;

        Bitmap content = LiquidGlassRenderer.createContentOverlay(
                context, videoWidth, videoHeight, targetAspect, metadata);
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
