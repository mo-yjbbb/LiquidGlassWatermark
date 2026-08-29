package com.localwatermark.liquidglass.android;

import static org.junit.Assert.*;
import androidx.exifinterface.media.ExifInterface;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import org.junit.Test;

/** 校验手工 EXIF 构造器：小米 0x8897 动态标签、XMP 注入、androidx 读回。 */
public final class ExifBuilderTest {

    /** SOI + APP0(JFIF) + 空扫描 SOS + EOI 的最小合法 JPEG。 */
    private static byte[] minimalJpeg() {
        return new byte[]{(byte)0xFF,(byte)0xD8,
                (byte)0xFF,(byte)0xE0, 0x00,0x10, 'J','F','I','F',0, 1,1,0, 0,1, 0,1, 0,0,
                (byte)0xFF,(byte)0xDA, 0x00,0x02,
                (byte)0xFF,(byte)0xD9};
    }

    private static ExifInterface sourceMetadata() throws Exception {
        ExifInterface src = new ExifInterface(new ByteArrayInputStream(minimalJpeg()));
        src.setAttribute(ExifInterface.TAG_MAKE, "Xiaomi");
        src.setAttribute(ExifInterface.TAG_MODEL, "23127PN0CC");
        src.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:01:01 10:00:00");
        src.setAttribute(ExifInterface.TAG_DATETIME, "2026:01:01 10:00:01");
        src.setAttribute(ExifInterface.TAG_F_NUMBER, "9/10");
        src.setAttribute(ExifInterface.TAG_EXPOSURE_TIME, "1/100");
        src.setAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, "400");
        src.setAttribute(ExifInterface.TAG_FOCAL_LENGTH, "2300/100");
        src.setAttribute(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, "23");
        src.setAttribute(ExifInterface.TAG_GPS_LATITUDE, "39/1,54/1,3600/100");
        src.setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N");
        src.setAttribute(ExifInterface.TAG_GPS_LONGITUDE, "116/1,23/1,2400/100");
        src.setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, "E");
        return src;
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

    /** Exif IFD 内 0x8897 条目：tag=0x8897, type=BYTE(1), count=1, 值 1 内联。 */
    private static final byte[] XIAOMI_MOTION_ENTRY = {
            (byte)0x88,(byte)0x97, 0x00,0x01, 0x00,0x00,0x00,0x01, 0x01,0x00,0x00,0x00 };

    @Test public void motionJpegContainsXiaomiMotionTag() throws Exception {
        byte[] out = ExifBuilder.buildMotionJpeg(minimalJpeg(), sourceMetadata(),
                12345, 500000, null);
        assertEquals(0xFF, out[0] & 255);
        assertEquals(0xD8, out[1] & 255);
        assertEquals(0xFF, out[2] & 255); // 紧跟 EXIF APP1
        assertEquals(0xE1, out[3] & 255);
        assertTrue("缺少小米 0x8897 动态照片标签", contains(out, XIAOMI_MOTION_ENTRY));

        String xmp = MotionPhotoSupport.extractXmp(out);
        assertNotNull("缺少 XMP", xmp);
        assertTrue(xmp.contains("MicroVideo=\"1\""));
        assertTrue(xmp.contains("MicroVideoOffset=\"12345\""));
        assertTrue(xmp.contains("MotionPhotoPresentationTimestampUs=\"500000\""));
        assertTrue(xmp.contains("MicroVideoPresentationTimestampUs=\"500000\""));
        assertTrue("视频 Item 长度错误", xmp.contains("Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"12345\""));
        assertTrue("Primary Item 长度应为注入后 JPEG 实际长度 " + out.length,
                xmp.contains("Item:Length=\"" + out.length + "\""));
    }

    @Test public void motionJpegRoundTripsThroughAndroidxExif() throws Exception {
        byte[] out = ExifBuilder.buildMotionJpeg(minimalJpeg(), sourceMetadata(),
                12345, 500000, null);
        ExifInterface readBack = new ExifInterface(new ByteArrayInputStream(out));
        assertEquals("Xiaomi", readBack.getAttribute(ExifInterface.TAG_MAKE));
        assertEquals("23127PN0CC", readBack.getAttribute(ExifInterface.TAG_MODEL));
        assertEquals("2026:01:01 10:00:00", readBack.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL));
        assertEquals(400, readBack.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, -1));
        assertEquals("9/10", readBack.getAttribute(ExifInterface.TAG_F_NUMBER));
        double[] latLng = new double[2];
        assertTrue("GPS 应能读回", readBack.getLatLong(latLng));
        assertEquals(39.91, latLng[0], 0.01);
        assertEquals(116.39, latLng[1], 0.01);
    }

    @Test public void stillJpegHasNoMotionData() throws Exception {
        byte[] out = ExifBuilder.buildStillJpeg(minimalJpeg(), sourceMetadata());
        assertFalse("静态图不应含 0x8897", contains(out, XIAOMI_MOTION_ENTRY));
        assertNull("静态图不应含 XMP", MotionPhotoSupport.extractXmp(out));
        ExifInterface readBack = new ExifInterface(new ByteArrayInputStream(out));
        assertEquals("Xiaomi", readBack.getAttribute(ExifInterface.TAG_MAKE));
        assertEquals("23127PN0CC", readBack.getAttribute(ExifInterface.TAG_MODEL));
        assertEquals(400, readBack.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, -1));
    }

    @Test public void motionXmpUpdatesOriginalOffsets() {
        String original = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description rdf:about=\"\" xmlns:Camera=\"http://ns.google.com/photos/1.0/camera/\" "
                + "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" "
                + "Camera:MotionPhoto=\"1\" Camera:MicroVideoOffset=\"999\" "
                + "Camera:MotionPhotoPresentationTimestampUs=\"111\" Camera:MicroVideoPresentationTimestampUs=\"222\">"
                + "<Container:Directory xmlns:Container=\"http://ns.google.com/photos/1.0/container/\"><rdf:Seq>"
                + "<rdf:li rdf:parseType=\"Resource\"><Item:Item Item:Length=\"777\" Item:Mime=\"image/jpeg\" Item:Semantic=\"Primary\"/></rdf:li>"
                + "<rdf:li rdf:parseType=\"Resource\"><Item:Item Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" Item:Length=\"888\"/></rdf:li>"
                + "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
        String updated = MotionPhotoSupport.motionXmp(650, 4321, 250000, original);
        assertTrue(updated.contains("MicroVideoOffset=\"4321\""));
        assertFalse(updated.contains("MicroVideoOffset=\"999\""));
        assertTrue(updated.contains("MotionPhotoPresentationTimestampUs=\"250000\""));
        assertTrue(updated.contains("MicroVideoPresentationTimestampUs=\"250000\""));
        assertTrue(updated.contains("Item:Length=\"4321\""));
        assertTrue(updated.contains("Item:Length=\"650\""));
        assertFalse(updated.contains("\"888\""));
        assertFalse(updated.contains("\"777\""));
        assertTrue(updated.contains("Camera:MotionPhoto=\"1\""));
    }

    @Test public void extractXmpFindsAndMissesXmpApp1() {
        String xmp = "<x:xmpmeta>hello</x:xmpmeta>";
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0xFF); out.write(0xD8);
        byte[] header = "http://ns.adobe.com/xap/1.0/\0".getBytes(StandardCharsets.US_ASCII);
        int len = 2 + header.length + xmp.getBytes(StandardCharsets.UTF_8).length;
        out.write(0xFF); out.write(0xE1);
        out.write((len >>> 8) & 255); out.write(len & 255);
        out.write(header, 0, header.length);
        out.write(xmp.getBytes(StandardCharsets.UTF_8), 0, xmp.length());
        out.write(0xFF); out.write(0xD9);
        assertEquals(xmp, MotionPhotoSupport.extractXmp(out.toByteArray()));
        assertNull(MotionPhotoSupport.extractXmp(minimalJpeg()));
    }
}
