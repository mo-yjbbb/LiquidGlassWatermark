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

    /** 视频编码很吃分辨率，静态图动辄 4000px，等比缩到长边 1920 足够相册播放用。 */
    private static final int MAX_LONG_SIDE = 1920;

    /** 等比缩到长边不超过 maxLongSide，并取偶数（H264 编码器要求）。 */
    private static int[] fitResolution(int width, int height, int maxLongSide) {
        int w = Math.max(2, width), h = Math.max(2, height);
        int longSide = Math.max(w, h);
        if (longSide > maxLongSide) {
            float k = maxLongSide / (float) longSide;
            w = Math.round(w * k);
            h = Math.round(h * k);
        }
        w -= w % 2;
        h -= h % 2;
        return new int[]{Math.max(2, w), Math.max(2, h)};
    }

    static void render(Context context, File input, File output, int width, int height,
                       PhotoMetadata metadata) throws Exception {
        int[] target = fitResolution(width, height, MAX_LONG_SIDE);
        int outWidth = target[0], outHeight = target[1];
        Bitmap content = LiquidGlassRenderer.createContentOverlay(context, outWidth, outHeight, metadata);
        CountDownLatch finished = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        new Handler(Looper.getMainLooper()).post(() -> {
            try {
                BitmapOverlay bitmapOverlay = BitmapOverlay.createStaticBitmapOverlay(content);
                List<Effect> videoEffects = new ArrayList<>();
                videoEffects.add(new LiquidGlassVideoEffect(outWidth, outHeight));
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
}
