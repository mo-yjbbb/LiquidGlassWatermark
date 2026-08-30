package com.localwatermark.liquidglass.android;

import android.content.Context;
import android.graphics.*;
import com.caverock.androidsvg.SVG;
import java.util.Locale;

final class LiquidGlassRenderer {
    static Bitmap render(Context context, Bitmap source, PhotoMetadata meta) throws Exception {
        Bitmap out = source.copy(Bitmap.Config.ARGB_8888, true);
        Canvas canvas = new Canvas(out);
        float shortSide = Math.min(out.getWidth(), out.getHeight());
        float scale = Math.max(shortSide / 1080f, .35f);
        float margin = Math.max(shortSide * .012f, 8 * scale);
        float h = shortSide * .135f;
        RectF capsule = new RectF(margin, out.getHeight() - margin - h, out.getWidth() - margin, out.getHeight() - margin);
        float radius = h * .5f;         // 正半圆端头（胶囊形），与视频 shader 保持一致

        int left = Math.max(0, Math.round(capsule.left));
        int top = Math.max(0, Math.round(capsule.top));
        int width = Math.min(out.getWidth() - left, Math.round(capsule.width()));
        int height = Math.min(out.getHeight() - top, Math.round(capsule.height()));
        Bitmap band = Bitmap.createBitmap(source, left, top, width, height);

        canvas.save();
        Path clip = new Path(); clip.addRoundRect(capsule, radius, radius, Path.Direction.CW); canvas.clipPath(clip);
        drawLiquidMesh(canvas, band, capsule, h);

        Paint base = new Paint(Paint.ANTI_ALIAS_FLAG); base.setColor(Color.argb(5, 255, 255, 255));
        canvas.drawRoundRect(capsule, radius, radius, base);
        Paint rainbow = new Paint(Paint.ANTI_ALIAS_FLAG);
        rainbow.setShader(new LinearGradient(capsule.left, capsule.bottom, capsule.right, capsule.top,
                new int[]{0x0000BFFF, 0x0900BFFF, 0x0BBE66FF, 0x08FFB347, 0x00FFB347},
                new float[]{0, .22f, .52f, .80f, 1}, Shader.TileMode.CLAMP));
        rainbow.setBlendMode(BlendMode.SCREEN); canvas.drawRoundRect(capsule, radius, radius, rainbow);
        canvas.restore();

        int sampled = averageColor(band);
        int highlight = Color.rgb((Color.red(sampled) + 2 * 255) / 3,
                (Color.green(sampled) + 2 * 255) / 3, (Color.blue(sampled) + 2 * 255) / 3);
        Paint edge = new Paint(Paint.ANTI_ALIAS_FLAG); edge.setStyle(Paint.Style.STROKE);
        edge.setStrokeWidth(Math.max(.92f * scale, .75f));
        edge.setShader(new LinearGradient(0, capsule.top, 0, capsule.bottom,
                new int[]{withAlpha(highlight,.58f), withAlpha(highlight,.20f), withAlpha(highlight,.08f),
                        Color.TRANSPARENT, withAlpha(highlight,.08f), withAlpha(highlight,.18f), withAlpha(highlight,.52f)},
                new float[]{0,.13f,.30f,.50f,.70f,.87f,1}, Shader.TileMode.CLAMP));
        canvas.drawRoundRect(new RectF(capsule.left + edge.getStrokeWidth()/2, capsule.top + edge.getStrokeWidth()/2,
                capsule.right - edge.getStrokeWidth()/2, capsule.bottom - edge.getStrokeWidth()/2),
                radius, radius, edge);

        drawTextAndLogo(context, canvas, capsule, h, meta);
        band.recycle();
        return out;
    }

    /**
     * 生成贴在视频上的文字/Logo 图层。
     *
     * @param targetAspect 静态图宽高比。视频比例往往不同，这里要按同样的"安全区"规则布局，
     *                     文字才能和 shader 画出的胶囊严格对齐。
     */
    static Bitmap createContentOverlay(Context context, int width, int height,
                                       float targetAspect, PhotoMetadata meta) throws Exception {
        Bitmap overlay = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(overlay);

        float aspect = width / (float) height;
        float target = targetAspect > 0f ? targetAspect : aspect;
        float safeW, safeH;
        if (aspect >= target) { safeH = 1f; safeW = target / aspect; }
        else { safeW = 1f; safeH = aspect / target; }

        float left = (1f - safeW) * 0.5f * width;
        float top = (1f - safeH) * 0.5f * height;
        float safeWidth = safeW * width;
        float safeHeight = safeH * height;

        float shortSide = Math.max(1f, Math.min(safeWidth, safeHeight));
        float margin = shortSide * .012f;
        float h = shortSide * .135f;
        RectF capsule = new RectF(left + margin, top + safeHeight - margin - h,
                left + safeWidth - margin, top + safeHeight - margin);
        drawTextAndLogo(context, canvas, capsule, h, meta);
        return overlay;
    }

    private static void drawLiquidMesh(Canvas canvas, Bitmap band, RectF rect, float h) {
        // Fixed optical lens derived from capsule geometry. The source pixels
        // always come from the photograph under the capsule; there is no
        // procedural wave or animation.
        int cols = 72, rows = 18;
        float[] vertices = new float[(cols + 1) * (rows + 1) * 2];
        int k = 0;
        for (int y = 0; y <= rows; y++) {
            float v = y / (float) rows;
            for (int x = 0; x <= cols; x++) {
                float u = x / (float) cols;
                float ny = v * 2f - 1f;
                float endDistance = Math.min(u, 1f-u) * rect.width() / h;
                float endInfluence = clamp01(1f-endDistance/.50f);
                float nx = u < .5f ? -1f : 1f;
                float edgePower = (float) Math.pow(Math.abs(ny), 1.55);
                float dx = nx * endInfluence * Math.max(0f, 1f-ny*ny) * h * .127f;
                float dy = ny * (1f-.28f*endInfluence) * edgePower * h * .079f;
                vertices[k++] = rect.left + u * rect.width() + dx;
                vertices[k++] = rect.top + v * rect.height() + dy;
            }
        }
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        canvas.drawBitmapMesh(band, cols, rows, vertices, 0, null, 0, paint);
    }

    private static float clamp01(float value) {
        return Math.max(0f, Math.min(1f, value));
    }

    private static void drawTextAndLogo(Context context, Canvas canvas, RectF r, float h, PhotoMetadata m) throws Exception {
        Paint text = new Paint(Paint.ANTI_ALIAS_FLAG); text.setColor(Color.WHITE); text.setTypeface(Typeface.create("sans", Typeface.BOLD));
        float pad = h * .34f; text.setTextSize(h * .22f); canvas.drawText(m.device, r.left + pad, r.top + h * .39f, text);
        text.setTypeface(Typeface.create("sans", Typeface.NORMAL)); text.setAlpha(230); text.setTextSize(h * .16f);
        canvas.drawText(m.date, r.left + pad, r.top + h * .75f, text); text.setAlpha(255);

        text.setTypeface(Typeface.create("sans", Typeface.NORMAL)); text.setTextSize(h * .18f);
        float right = r.right - pad; float exposureW = text.measureText(m.exposure); float locationSize = h * .15f;
        Paint locationPaint = new Paint(text); locationPaint.setTextSize(locationSize); float locationW = locationPaint.measureText(m.location);
        float groupW = Math.max(exposureW, locationW); float textX = right - groupW;
        canvas.drawText(m.exposure, textX, r.top + h * .43f, text);
        locationPaint.setAlpha(230); canvas.drawText(m.location, textX, r.top + h * .72f, locationPaint);
        float sepX = textX - h * .18f; Paint separator = new Paint(Paint.ANTI_ALIAS_FLAG); separator.setColor(0x99FFFFFF); separator.setStrokeWidth(Math.max(1, h * .012f));
        canvas.drawLine(sepX, r.top + h * .24f, sepX, r.bottom - h * .24f, separator);

        float logoSize = h * .56f; RectF logoRect = new RectF(sepX - h * .16f - logoSize, r.centerY() - logoSize/2,
                sepX - h * .16f, r.centerY() + logoSize/2);
        SVG logo = SVG.getFromResource(context, com.localwatermark.liquidglass.android.R.raw.leica);
        canvas.save(); canvas.clipRect(logoRect); canvas.translate(logoRect.left, logoRect.top);
        float sx = logoRect.width() / logo.getDocumentWidth(), sy = logoRect.height() / logo.getDocumentHeight();
        float s = Math.min(sx, sy); canvas.translate((logoRect.width() - logo.getDocumentWidth()*s)/2,
                (logoRect.height() - logo.getDocumentHeight()*s)/2); canvas.scale(s, s); logo.renderToCanvas(canvas); canvas.restore();
    }

    private static int averageColor(Bitmap bitmap) {
        long rr=0,gg=0,bb=0,count=0; int step=Math.max(1,Math.min(bitmap.getWidth(),bitmap.getHeight())/40);
        for(int y=0;y<bitmap.getHeight();y+=step) for(int x=0;x<bitmap.getWidth();x+=step){int c=bitmap.getPixel(x,y);rr+=Color.red(c);gg+=Color.green(c);bb+=Color.blue(c);count++;}
        return Color.rgb((int)(rr/count),(int)(gg/count),(int)(bb/count));
    }
    private static int withAlpha(int color,float alpha){return Color.argb(Math.round(alpha*255),Color.red(color),Color.green(color),Color.blue(color));}
}
