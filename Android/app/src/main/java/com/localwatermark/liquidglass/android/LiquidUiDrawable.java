package com.localwatermark.liquidglass.android;

import android.graphics.*;
import android.graphics.drawable.Drawable;

/** Lightweight GPU-friendly liquid/frosted glass surface for the app chrome. */
final class LiquidUiDrawable extends Drawable {
    static final int BACKGROUND = 0;
    static final int PANEL = 1;
    static final int BUTTON = 2;
    static final int CHIP = 3;

    private final int style;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private int alpha = 255;

    LiquidUiDrawable(int style) { this.style = style; }

    @Override public void draw(Canvas canvas) {
        Rect b = getBounds();
        if (b.isEmpty()) return;
        float w=b.width(), h=b.height();
        float radius = style==PANEL ? Math.min(w,h)*.075f
                : style==BUTTON ? h*.5f : style==CHIP ? h*.5f : 0f;
        RectF r = new RectF(b.left,b.top,b.right,b.bottom);
        path.reset();
        if (style==BACKGROUND) path.addRect(r,Path.Direction.CW);
        else path.addRoundRect(r,radius,radius,Path.Direction.CW);

        int[] colors;
        float[] stops;
        if (style==BACKGROUND) {
            colors=new int[]{0xff080910,0xff111223,0xff211428,0xff0a101a};
            stops=new float[]{0f,.34f,.72f,1f};
        } else if (style==BUTTON) {
            colors=new int[]{0x72ffffff,0x3b93bfff,0x4de77dad,0x35ff8eb5};
            stops=new float[]{0f,.34f,.72f,1f};
        } else if (style==CHIP) {
            colors=new int[]{0x30ffffff,0x18cdbbff,0x20ff88aa};
            stops=new float[]{0f,.52f,1f};
        } else {
            colors=new int[]{0x32ffffff,0x14bca6ff,0x0c000000,0x1bff81ac};
            stops=new float[]{0f,.26f,.68f,1f};
        }
        paint.setStyle(Paint.Style.FILL);
        paint.setAlpha(alpha);
        paint.setShader(new LinearGradient(r.left,r.top,r.right,r.bottom,colors,stops,Shader.TileMode.CLAMP));
        canvas.drawPath(path,paint);

        if (style!=BACKGROUND) {
            canvas.save();
            canvas.clipPath(path);
            paint.setShader(new RadialGradient(r.left+w*.22f,r.top-h*.05f,
                    Math.max(w,h)*.62f,new int[]{0x36ffffff,0x0affffff,0x00ffffff},
                    new float[]{0f,.45f,1f},Shader.TileMode.CLAMP));
            canvas.drawRect(r,paint);
            paint.setShader(new RadialGradient(r.right+w*.08f,r.bottom+h*.15f,
                    Math.max(w,h)*.72f,new int[]{0x20ff739f,0x083d8cff,0x00000000},
                    new float[]{0f,.48f,1f},Shader.TileMode.CLAMP));
            canvas.drawRect(r,paint);
            canvas.restore();

            paint.setShader(null);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(Math.max(1f,getBounds().height()*.009f));
            paint.setColor(style==BUTTON?0x78ffffff:0x42ffffff);
            paint.setAlpha(alpha);
            canvas.drawRoundRect(new RectF(r.left+.7f,r.top+.7f,r.right-.7f,r.bottom-.7f),
                    radius,radius,paint);

            // Horizontal, edge-bound highlights fade before the side midpoints.
            float inset=Math.max(radius*.52f,12f);
            paint.setStrokeWidth(Math.max(1.1f,getBounds().height()*.014f));
            paint.setShader(new LinearGradient(r.left+inset,r.top,r.right-inset,r.top,
                    new int[]{0x00ffffff,0x8cffffff,0xc8ffffff,0x8cffffff,0x00ffffff},
                    new float[]{0f,.20f,.5f,.80f,1f},Shader.TileMode.CLAMP));
            canvas.drawLine(r.left+inset,r.top+1.2f,r.right-inset,r.top+1.2f,paint);
            paint.setShader(new LinearGradient(r.left+inset,r.bottom,r.right-inset,r.bottom,
                    new int[]{0x00ffffff,0x42ffffff,0x78ffffff,0x42ffffff,0x00ffffff},
                    new float[]{0f,.20f,.5f,.80f,1f},Shader.TileMode.CLAMP));
            canvas.drawLine(r.left+inset,r.bottom-1.2f,r.right-inset,r.bottom-1.2f,paint);
        }
        paint.setShader(null);
        paint.setAlpha(255);
    }

    @Override public void setAlpha(int value){alpha=value;invalidateSelf();}
    @Override public void setColorFilter(ColorFilter filter){paint.setColorFilter(filter);invalidateSelf();}
    @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
}
