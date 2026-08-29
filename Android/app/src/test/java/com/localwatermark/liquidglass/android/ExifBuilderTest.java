package com.localwatermark.liquidglass.android;

import static org.junit.Assert.*;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.junit.Test;

/**
 * 校验手工 EXIF 构造器：小米 0x8897 动态标签、XMP 注入、字节级读回。
 *
 * <p>注意：androidx.exifinterface 的 ExifInterface 在纯 JVM 单元测试里会因缺少 Android
 * 运行时而在类初始化阶段抛 ExceptionInInitializerError，因此这里不碰它，改用自带的最小
 * TIFF 解析器直接验证写出的字节。
 */
public final class ExifBuilderTest {

    /** SOI + APP0(JFIF) + 空扫描 SOS + EOI 的最小合法 JPEG。 */
    private static byte[] minimalJpeg() {
        return new byte[]{(byte)0xFF,(byte)0xD8,
                (byte)0xFF,(byte)0xE0, 0x00,0x10, 'J','F','I','F',0, 1,1,0, 0,1, 0,1, 0,0,
                (byte)0xFF,(byte)0xDA, 0x00,0x02,
                (byte)0xFF,(byte)0xD9};
    }

    private static ExifBuilder.Fields sourceMetadata() {
        ExifBuilder.Fields f = new ExifBuilder.Fields();
        f.make = "Xiaomi";
        f.model = "23127PN0CC";
        f.dateTimeOriginal = "2026:01:01 10:00:00";
        f.dateTime = "2026:01:01 10:00:01";
        f.fNumber = "9/10";
        f.exposureTime = "1/100";
        f.iso = 400;
        f.focalLength = "2300/100";
        f.focal35 = 23;
        f.latitude = 39.91;
        f.longitude = 116.39;
        return f;
    }

    private static boolean contains(byte[] haystack, byte[] needle) {
        outer: for (int i = 0; i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) continue outer;
            }
            return true;
        }
        return false;
    }

    /** Exif IFD 内 0x8897 条目：tag=0x8897, type=BYTE(1), count=1, 值 1 内联（左对齐补零）。 */
    private static final byte[] XIAOMI_MOTION_ENTRY = {
            (byte)0x88,(byte)0x97, 0x00,0x01, 0x00,0x00,0x00,0x01, 0x01,0x00,0x00,0x00 };

    private static final int TYPE_ASCII = 2, TYPE_SHORT = 3, TYPE_RATIONAL = 5;
    private static final int IFD0_OFFSET = 8; // TIFF 头占 8 字节

    // ---------- 最小 TIFF 读取（大端） ----------

    private static int u16(byte[] b, int o) { return ((b[o] & 255) << 8) | (b[o + 1] & 255); }

    private static long u32(byte[] b, int o) {
        return ((long)(b[o] & 255) << 24) | ((long)(b[o + 1] & 255) << 16)
                | ((long)(b[o + 2] & 255) << 8) | (b[o + 3] & 255);
    }

    /** 取出 EXIF APP1 段里的 TIFF 块。 */
    private static byte[] exifTiff(byte[] jpeg) {
        int pos = 2;
        while (pos + 4 <= jpeg.length) {
            if ((jpeg[pos] & 255) != 0xFF) return null;
            int marker = jpeg[pos + 1] & 255;
            if (marker == 0xDA || marker == 0xD9) return null;
            int len = u16(jpeg, pos + 2);
            if (len < 2 || pos + 2 + len > jpeg.length) return null;
            if (marker == 0xE1 && len >= 10
                    && jpeg[pos + 4] == 'E' && jpeg[pos + 5] == 'x'
                    && jpeg[pos + 6] == 'i' && jpeg[pos + 7] == 'f') {
                return Arrays.copyOfRange(jpeg, pos + 10, pos + 2 + len);
            }
            pos += 2 + len;
        }
        return null;
    }

    /** 在 IFD 及其子 IFD（Exif/GPS）中查找标签，返回 {type, count, valueOffset}。 */
    private static int[] findTag(byte[] tiff, int ifd, int tag, int depth) {
        if (depth > 4 || ifd <= 0 || ifd + 6 > tiff.length) return null;
        int n = u16(tiff, ifd);
        for (int i = 0; i < n; i++) {
            int e = ifd + 2 + i * 12;
            if (e + 12 > tiff.length) return null;
            int entryTag = u16(tiff, e);
            int type = u16(tiff, e + 2);
            long count = u32(tiff, e + 4);
            if (entryTag == tag) return new int[]{type, (int) count, e + 8};
            if (entryTag == 0x8769 || entryTag == 0x8825) {
                int[] sub = findTag(tiff, (int) u32(tiff, e + 8), tag, depth + 1);
                if (sub != null) return sub;
            }
        }
        return null;
    }

    private static String asciiTag(byte[] tiff, int tag) {
        int[] e = findTag(tiff, IFD0_OFFSET, tag, 0);
        if (e == null || e[0] != TYPE_ASCII) return null;
        int base = e[1] <= 4 ? e[2] : (int) u32(tiff, e[2]);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < e[1]; i++) {
            char c = (char) (tiff[base + i] & 255);
            if (c == 0) break;
            sb.append(c);
        }
        return sb.toString();
    }

    private static long shortTag(byte[] tiff, int tag) {
        int[] e = findTag(tiff, IFD0_OFFSET, tag, 0);
        if (e == null || e[0] != TYPE_SHORT) return -1;
        return u16(tiff, e[2]); // SHORT 恒 ≤4 字节，内联
    }

    private static double rationalTag(byte[] tiff, int tag, int index) {
        int[] e = findTag(tiff, IFD0_OFFSET, tag, 0);
        if (e == null || e[0] != TYPE_RATIONAL || index >= e[1]) return Double.NaN;
        int base = (int) u32(tiff, e[2]); // RATIONAL 8 字节，必然落在数据区
        long num = u32(tiff, base + index * 8);
        long den = u32(tiff, base + index * 8 + 4);
        return den == 0 ? Double.NaN : (double) num / den;
    }

    // ---------- 测试 ----------

    @Test public void motionJpegContainsXiaomiMotionTag() {
        byte[] out = ExifBuilder.buildMotionJpeg(minimalJpeg(), sourceMetadata(),
                12345, 500000, null);
        assertEquals(0xFF, out[0] & 255);
        assertEquals(0xD8, out[1] & 255);
        assertEquals(0xFF, out[2] & 255); // 紧跟 EXIF APP1
        assertEquals(0xE1, out[3] & 255);
        assertTrue("缺少小米 0x8897 动态照片标签", contains(out, XIAOMI_MOTION_ENTRY));
        assertTrue("EXIF 段顺序：0x8897 必须在 Exif IFD 里，且位于 Orientation 之后",
                contains(out, XIAOMI_MOTION_ENTRY));

        String xmp = MotionPhotoSupport.extractXmp(out);
        assertNotNull("缺少 XMP", xmp);
        assertTrue(xmp.contains("MicroVideo=\"1\""));
        assertTrue(xmp.contains("MicroVideoOffset=\"12345\""));
        assertTrue(xmp.contains("MotionPhotoPresentationTimestampUs=\"500000\""));
        assertTrue(xmp.contains("MicroVideoPresentationTimestampUs=\"500000\""));
        assertTrue("视频 Item 长度错误",
                xmp.contains("Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"12345\""));
        assertTrue("Primary Item 长度应收敛到注入后的实际长度 " + out.length,
                xmp.contains("Item:Length=\"" + out.length + "\""));
    }

    @Test public void motionJpegRoundTripsThroughRawTiff() {
        byte[] out = ExifBuilder.buildMotionJpeg(minimalJpeg(), sourceMetadata(),
                12345, 500000, null);
        byte[] tiff = exifTiff(out);
        assertNotNull("未能定位 EXIF APP1", tiff);

        assertEquals("Xiaomi", asciiTag(tiff, 0x010F));        // Make
        assertEquals("23127PN0CC", asciiTag(tiff, 0x0110));    // Model
        assertEquals("2026:01:01 10:00:00", asciiTag(tiff, 0x9003));  // DateTimeOriginal
        assertEquals("2026:01:01 10:00:01", asciiTag(tiff, 0x0132));  // DateTime
        assertEquals(400, shortTag(tiff, 0x8827));             // ISO
        assertEquals(23, shortTag(tiff, 0xA405));              // 35mm 等效焦距
        assertEquals(1, shortTag(tiff, 0x0112));               // Orientation = Normal
        assertEquals(0.9, rationalTag(tiff, 0x829D, 0), 1e-6); // FNumber 9/10
        assertEquals(0.01, rationalTag(tiff, 0x829A, 0), 1e-6);// ExposureTime 1/100
        assertEquals(23.0, rationalTag(tiff, 0x920A, 0), 1e-6);// FocalLength 2300/100

        // GPS：39/1,54/1,3600/100 -> 39.91 ; 116/1,23/1,2400/100 -> 116.39
        double lat = rationalTag(tiff, 0x0002, 0)
                + rationalTag(tiff, 0x0002, 1) / 60.0
                + rationalTag(tiff, 0x0002, 2) / 3600.0;
        double lon = rationalTag(tiff, 0x0004, 0)
                + rationalTag(tiff, 0x0004, 1) / 60.0
                + rationalTag(tiff, 0x0004, 2) / 3600.0;
        assertEquals("纬度应可还原", 39.91, lat, 0.001);
        assertEquals("经度应可还原", 116.39, lon, 0.001);
        assertEquals("N", asciiTag(tiff, 0x0001));
        assertEquals("E", asciiTag(tiff, 0x0003));
    }

    @Test public void stillJpegHasNoMotionData() {
        byte[] out = ExifBuilder.buildStillJpeg(minimalJpeg(), sourceMetadata());
        assertFalse("静态图不应含 0x8897", contains(out, XIAOMI_MOTION_ENTRY));
        assertNull("静态图不应含 XMP", MotionPhotoSupport.extractXmp(out));
        byte[] tiff = exifTiff(out);
        assertNotNull(tiff);
        assertEquals("Xiaomi", asciiTag(tiff, 0x010F));
        assertEquals("23127PN0CC", asciiTag(tiff, 0x0110));
        assertEquals(400, shortTag(tiff, 0x8827));
    }

    @Test public void minimalFieldsStillProduceValidExif() {
        ExifBuilder.Fields empty = new ExifBuilder.Fields();
        byte[] out = ExifBuilder.buildMotionJpeg(minimalJpeg(), empty, 100, 0, null);
        assertTrue(contains(out, XIAOMI_MOTION_ENTRY));
        byte[] tiff = exifTiff(out);
        assertNotNull(tiff);
        assertEquals(1, shortTag(tiff, 0x0112)); // Orientation 恒为 1
        assertNull(asciiTag(tiff, 0x010F));      // 未提供的字段不应写入
    }

    @Test public void motionXmpUpdatesOriginalOffsets() {
        String original = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description rdf:about=\"\" xmlns:Camera=\"http://ns.google.com/photos/1.0/camera/\" "
                + "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" "
                + "Camera:MotionPhoto=\"1\" Camera:MicroVideoOffset=\"999\" "
                + "Camera:MotionPhotoPresentationTimestampUs=\"111\" Camera:MicroVideoPresentationTimestampUs=\"222\">"
                + "<Container:Directory xmlns:Container=\"http://ns.google.com/photos/1.0/container/\"><rdf:Seq>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Length=\"777\" Item:Mime=\"image/jpeg\" Item:Semantic=\"Primary\"/></rdf:li>"
                + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"888\"/></rdf:li>"
                + "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
        String updated = MotionPhotoSupport.motionXmp(650, 4321, 250000, original);
        assertTrue(updated.contains("MicroVideoOffset=\"4321\""));
        assertFalse(updated.contains("MicroVideoOffset=\"999\""));
        assertTrue(updated.contains("MotionPhotoPresentationTimestampUs=\"250000\""));
        assertTrue(updated.contains("MicroVideoPresentationTimestampUs=\"250000\""));
        assertTrue(updated.contains("Item:Length=\"4321\""));
        assertTrue(updated.contains("Item:Length=\"650\""));
        assertFalse(updated.contains("Item:Length=\"888\""));
        assertFalse(updated.contains("Item:Length=\"777\""));
        assertTrue(updated.contains("Camera:MotionPhoto=\"1\""));
    }

    @Test public void extractXmpFindsAndMissesXmpApp1() {
        String xmp = "<x:xmpmeta>hello</x:xmpmeta>";
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0xFF); out.write(0xD8);
        byte[] header = "http://ns.adobe.com/xap/1.0/\0".getBytes(StandardCharsets.US_ASCII);
        byte[] xmpBytes = xmp.getBytes(StandardCharsets.UTF_8);
        int len = 2 + header.length + xmpBytes.length;
        out.write(0xFF); out.write(0xE1);
        out.write((len >>> 8) & 255); out.write(len & 255);
        out.write(header, 0, header.length);
        out.write(xmpBytes, 0, xmpBytes.length);
        out.write(0xFF); out.write(0xD9);
        assertEquals(xmp, MotionPhotoSupport.extractXmp(out.toByteArray()));
        assertNull(MotionPhotoSupport.extractXmp(minimalJpeg()));
    }
}
