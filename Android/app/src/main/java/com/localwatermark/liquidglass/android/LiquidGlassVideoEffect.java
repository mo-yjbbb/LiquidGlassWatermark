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
    @Override public BaseGlShaderProgram toGlShaderProgram(Context context, boolean useHdr)
            throws VideoFrameProcessingException {
        return new Program(context, useHdr);
    }

    private static final class Program extends BaseGlShaderProgram {
        private final GlProgram program;
        Program(Context context, boolean useHdr) throws VideoFrameProcessingException {
            super(useHdr, 1);
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
        @Override public Size configure(int width, int height) {
            program.setFloatUniform("uAspect", width/(float)height);
            return new Size(width,height);
        }
        @Override public void drawFrame(int inputTexId, long presentationTimeUs)
                throws VideoFrameProcessingException {
            try {
                program.use();
                program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0);
                program.bindAttributesAndUniforms();
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4);
            } catch (GlUtil.GlException e) {
                throw new VideoFrameProcessingException(e,presentationTimeUs);
            }
        }
        @Override public void release() throws VideoFrameProcessingException {
            super.release();
            try { program.delete(); } catch (GlUtil.GlException e) { throw new VideoFrameProcessingException(e); }
        }
    }
}
