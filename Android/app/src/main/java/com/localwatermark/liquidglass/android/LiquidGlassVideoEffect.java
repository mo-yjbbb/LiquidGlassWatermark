package com.localwatermark.liquidglass.android;

import android.content.Context;
import android.opengl.GLES20;
import androidx.media3.common.VideoFrameProcessingException;
import androidx.media3.common.util.GlProgram;
import androidx.media3.common.util.GlUtil;
import androidx.media3.common.util.Size;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.BaseGlShaderProgram;
import androidx.media3.effect.GlEffect;
import java.io.IOException;

@UnstableApi
final class LiquidGlassVideoEffect implements GlEffect {
    private final int outputWidth;
    private final int outputHeight;

    /**
     * @param outputWidth  输出分辨率，必须与静态图同宽高比。相册播放实况图时会把视频
     *                     拉伸去贴合静态图的显示区域，比例不一致会导致水印胶囊变形、
     *                     位置错位（表现为"胶囊内容消失""两头尖尖"）。
     */
    LiquidGlassVideoEffect(int outputWidth, int outputHeight) {
        this.outputWidth = Math.max(2, outputWidth);
        this.outputHeight = Math.max(2, outputHeight);
    }

    @Override public BaseGlShaderProgram toGlShaderProgram(Context context, boolean useHdr)
            throws VideoFrameProcessingException {
        return new Program(context, useHdr, outputWidth, outputHeight);
    }

    private static final class Program extends BaseGlShaderProgram {
        private final GlProgram program;
        private final int outputWidth;
        private final int outputHeight;

        Program(Context context, boolean useHdr, int outputWidth, int outputHeight)
                throws VideoFrameProcessingException {
            super(useHdr, 1);
            this.outputWidth = outputWidth;
            this.outputHeight = outputHeight;
            try {
                program = new GlProgram(context, R.raw.liquid_vertex, R.raw.liquid_fragment);
                program.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(),
                        GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE);
                float[] identity = GlUtil.create4x4IdentityMatrix();
                program.setFloatsUniform("uTransformationMatrix", identity);
                program.setFloatsUniform("uTexTransformationMatrix", identity);
            } catch (IOException | GlUtil.GlException e) {
                throw new VideoFrameProcessingException(e);
            }
        }

        @Override public Size configure(int inputWidth, int inputHeight) {
            program.setFloatUniform("uAspect", outputWidth / (float) outputHeight);
            // Transformer 会把任意比例的输入帧拉伸到 outputWidth x outputHeight。
            // 反算出等比 centerCrop 的采样区域比例，交给 shader 还原，画面才不会变形。
            int inW = Math.max(1, inputWidth);
            int inH = Math.max(1, inputHeight);
            float scale = Math.max(outputWidth / (float) inW, outputHeight / (float) inH);
            program.setFloatUniform("uScaleX", outputWidth / (inW * scale));
            program.setFloatUniform("uScaleY", outputHeight / (inH * scale));
            return new Size(outputWidth, outputHeight);
        }

        @Override public void drawFrame(int inputTexId, long presentationTimeUs)
                throws VideoFrameProcessingException {
            try {
                program.use();
                program.setFloatUniform("uTime", presentationTimeUs / 1_000_000f);
                program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0);
                program.bindAttributesAndUniforms();
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            } catch (GlUtil.GlException e) {
                throw new VideoFrameProcessingException(e, presentationTimeUs);
            }
        }

        @Override public void release() throws VideoFrameProcessingException {
            super.release();
            try { program.delete(); } catch (GlUtil.GlException e) { throw new VideoFrameProcessingException(e); }
        }
    }
}
