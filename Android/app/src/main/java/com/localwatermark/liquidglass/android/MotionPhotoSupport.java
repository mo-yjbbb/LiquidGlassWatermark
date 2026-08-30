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
        if (ftyp < 4) return new Parts(file, new byte[0], new byte[0], false);
        int start = ftyp - 4;
        long boxSize = ((long)(file[start] & 255) << 24) | ((long)(file[start + 1] & 255) << 16)
                | ((long)(file[start + 2] & 255) << 8) | (file[start + 3] & 255);
        if (boxSize < 8 || start + boxSize > file.length) return new Parts(file, new byte[0], new byte[0], false);
        int eoi = lastJpegEoiBefore(file, start);
        if (eoi < 0) return new Parts(file, new byte[0], new byte[0], false);
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

    /** 从 JPEG 字节中提取原始 XMP 包（APP1/xap 段），无则返回 null。 */
    static String extractXmp(byte[] jpeg) {
        if (jpeg == null || jpeg.length < 4) return null;
        int pos = 2;
        while (pos + 4 <= jpeg.length) {
            if ((jpeg[pos] & 255) != 0xFF) return null;
            int marker = jpeg[pos + 1] & 255;
            if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) { pos += 2; continue; }
            if (marker == 0xDA || marker == 0xD9) return null; // 进入熵数据/结束，后面不会再有 APP1
            int len = ((jpeg[pos + 2] & 255) << 8) | (jpeg[pos + 3] & 255);
            if (len < 2 || pos + 2 + len > jpeg.length) return null;
            if (marker == 0xE1 && len >= 31) { // 29 字节 XMP 头 + 至少 1 字节内容
                String header = new String(jpeg, pos + 4, 29, StandardCharsets.ISO_8859_1);
                if (header.equals("http://ns.adobe.com/xap/1.0/\0")) {
                    int start = pos + 4 + 29;
                    return new String(jpeg, start, pos + 2 + len - start, StandardCharsets.UTF_8);
                }
            }
            pos += 2 + len;
        }
        return null;
    }

    /** 生成/更新动态照片 XMP：优先保留原始 XMP（最大限度兼容小米相册），只更新偏移与长度。 */
    static String motionXmp(long stillLength, long videoLength, long presentationTimestampUs, String originalXmp) {
        String offset = Long.toString(videoLength);
        String ts = Long.toString(presentationTimestampUs);
        if (originalXmp != null && (originalXmp.contains("MicroVideo") || originalXmp.contains("MotionPhoto"))) {
            String xml = originalXmp
                    .replaceAll("MicroVideoOffset=\"-?\\d+\"", "MicroVideoOffset=\"" + offset + "\"")
                    .replaceAll("(MicroVideo|MotionPhoto)PresentationTimestampUs=\"-?\\d+\"",
                            "$1PresentationTimestampUs=\"" + ts + "\"")
                    .replaceAll("(Item:Mime=\"video/mp4\"[^>]*?Item:Length=\")\\d+(\")", "$1" + videoLength + "$2")
                    .replaceAll("(Item:Length=\")(\\d+)(\"[^>]*?Item:Mime=\"video/mp4\")", "$1" + videoLength + "$3")
                    .replaceAll("(Item:Mime=\"image/jpeg\"[^>]*?Item:Length=\")\\d+(\")", "$1" + stillLength + "$2")
                    .replaceAll("(Item:Length=\")(\\d+)(\"[^>]*?Item:Mime=\"image/jpeg\")", "$1" + stillLength + "$3");
            if (xml.contains("MicroVideoOffset") || xml.contains("MotionPhoto")) return xml;
        }
        return "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description rdf:about=\"\" xmlns:Camera=\"http://ns.google.com/photos/1.0/camera/\" "
                + "xmlns:Container=\"http://ns.google.com/photos/1.0/container/\" "
                + "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" "
                + "Camera:MotionPhoto=\"1\" Camera:MotionPhotoVersion=\"1\" "
                + "Camera:MotionPhotoPresentationTimestampUs=\"" + ts + "\" "
                + "Camera:MicroVideo=\"1\" Camera:MicroVideoVersion=\"1\" "
                + "Camera:MicroVideoOffset=\"" + offset + "\" Camera:MicroVideoPresentationTimestampUs=\"" + ts + "\">"
                + "<Container:Directory><rdf:Seq>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"image/jpeg\" Item:Semantic=\"Primary\" Item:Length=\"" + stillLength + "\"/></rdf:li>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"" + videoLength + "\"/></rdf:li>"
                + "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
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
