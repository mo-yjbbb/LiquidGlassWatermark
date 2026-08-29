package com.localwatermark.liquidglass.android;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

final class MotionPhotoSupport {
    static final class Parts {
        final byte[] imageBytes;
        final byte[] videoBytes;
        final boolean motion;
        Parts(byte[] imageBytes, byte[] videoBytes, boolean motion) {
            this.imageBytes = imageBytes; this.videoBytes = videoBytes; this.motion = motion;
        }
    }

    static Parts split(byte[] file) {
        int ftyp = indexOf(file, "ftyp".getBytes(StandardCharsets.US_ASCII), 4);
        if (ftyp < 4) return new Parts(file, new byte[0], false);
        int start = ftyp - 4;
        long boxSize = ((long)(file[start] & 255) << 24) | ((long)(file[start + 1] & 255) << 16)
                | ((long)(file[start + 2] & 255) << 8) | (file[start + 3] & 255);
        if (boxSize < 8 || start + boxSize > file.length) return new Parts(file, new byte[0], false);
        int eoi = lastJpegEoiBefore(file, start);
        if (eoi < 0) return new Parts(file, new byte[0], false);
        return new Parts(Arrays.copyOfRange(file, 0, eoi + 2),
                Arrays.copyOfRange(file, start, file.length), true);
    }

    static byte[] join(byte[] renderedJpeg, byte[] videoBytes) {
        byte[] joined = Arrays.copyOf(renderedJpeg, renderedJpeg.length + videoBytes.length);
        System.arraycopy(videoBytes, 0, joined, renderedJpeg.length, videoBytes.length);
        return joined;
    }

    static boolean hasVideo(byte[] file) {
        Parts parts = split(file);
        return parts.motion && parts.videoBytes.length > 16;
    }

    private static int lastJpegEoiBefore(byte[] data, int before) {
        for (int i = Math.min(before - 1, data.length - 1); i > 0; i--) {
            if ((data[i - 1] & 255) == 0xff && (data[i] & 255) == 0xd9) return i - 1;
        }
        return -1;
    }

    private static int indexOf(byte[] data, byte[] needle, int from) {
        outer: for (int i = from; i <= data.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) if (data[i + j] != needle[j]) continue outer;
            return i;
        }
        return -1;
    }
}
