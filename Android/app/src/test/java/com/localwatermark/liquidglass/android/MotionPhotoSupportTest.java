package com.localwatermark.liquidglass.android;

import static org.junit.Assert.*;
import java.util.Arrays;
import org.junit.Test;

public final class MotionPhotoSupportTest {
    private static final byte[] JPEG = {(byte)0xff, (byte)0xd8, 1, 2, 3, (byte)0xff, (byte)0xd9};
    private static final byte[] MP4 = {0,0,0,16,'f','t','y','p','i','s','o','m',0,0,0,0, 4,5,6,7};

    @Test public void motionPhotoRoundTripKeepsVideoExactly() {
        byte[] joined = MotionPhotoSupport.join(JPEG, MP4);
        MotionPhotoSupport.Parts parts = MotionPhotoSupport.split(joined);
        assertTrue(parts.motion);
        assertArrayEquals(JPEG, parts.imageBytes);
        assertArrayEquals(MP4, parts.videoBytes);

        byte[] replacement = {(byte)0xff,(byte)0xd8,9,8,7,6,(byte)0xff,(byte)0xd9};
        byte[] output = MotionPhotoSupport.join(replacement, parts.videoBytes);
        MotionPhotoSupport.Parts verified = MotionPhotoSupport.split(output);
        assertTrue(MotionPhotoSupport.hasVideo(output));
        assertArrayEquals(replacement, verified.imageBytes);
        assertArrayEquals(MP4, verified.videoBytes);
    }

    @Test public void ordinaryJpegStaysStatic() {
        MotionPhotoSupport.Parts parts = MotionPhotoSupport.split(Arrays.copyOf(JPEG, JPEG.length));
        assertFalse(parts.motion);
        assertFalse(MotionPhotoSupport.hasVideo(JPEG));
    }
}
