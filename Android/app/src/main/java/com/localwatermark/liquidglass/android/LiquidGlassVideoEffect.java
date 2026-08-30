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
    private final float targetAspect;

    /**
     * @param targetAspect 静态图的宽高比。视频分辨率通常和静态图不同，相册播放时会把视频
     *                     拉伸或 centerCrop 到静态图的显示区域；shader 据此算出一个"安全区"
     *                     并把胶囊放进去，这样无论相册用哪种方式都不会变形。
     */
    LiquidGlassVideoEffect(float targetAspect) {
        this.targetAspect = targetAspect > 0f ? targetAspect : 1f;
    }

    @Override public BaseGlShaderProgram toGlShaderProgram(Context context, boolean useHdr)
            throws VideoFrameProcessingException {
        return new Program(context, useHdr, targetAspect);
    }

    private static final class Program extends BaseGlShaderProgram {
        private final GlProgram program;
        private final float targetAspect;

        Program(Context context, boolean useHdr, float targetAspect)
                throws VideoFrameProcessingException {
            super(useHdr, 1);
            this.targetAspect = targetAspect;
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
            program.setFloatUniform("uAspect", inputWidth / (float) Math.max(1, inputHeight));
            program.setFloatUniform("uTargetAspect", targetAspect);
            // 保持输入尺寸：不去赌 Transformer 会不会采用我们返回的输出分辨率。
            // 形状正确性改由 shader 的安全区保证，与输出分辨率无关。
            return new Size(inputWidth, inputHeight);
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
