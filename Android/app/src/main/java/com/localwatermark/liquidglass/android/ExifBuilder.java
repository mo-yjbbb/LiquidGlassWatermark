package com.localwatermark.liquidglass.android;

import androidx.exifinterface.media.ExifInterface;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * 手工构造 EXIF APP1（含小米相册识别动态照片的私有标签 0x8897）并注入 JPEG。
 * androidx ExifInterface 不支持自定义标签，所以这里直接按 TIFF 6.0 规范写字节。
 * 布局：TIFF 头 + IFD0(含 Exif/GPS 指针) + Exif IFD(含 0x8897) + GPS IFD + 数据区。
 */
final class ExifBuilder {
    private ExifBuilder() {}

    private static final int TYPE_BYTE = 1, TYPE_ASCII = 2, TYPE_SHORT = 3, TYPE_LONG = 4, TYPE_RATIONAL = 5;
    private static final int TAG_EXIF_IFD_POINTER = 0x8769, TAG_GPS_IFD_POINTER = 0x8825;
    /** 小米相册（澎湃OS/MIUI）判定动态照片的私有标签，类型 BYTE，值 1。 */
    private static final int TAG_XIAOMI_MOTION = 0x8897;

    private static final class Entry {
        final int tag, type, count;
        final byte[] data; // 长度 = count * 单元大小
        Entry(int tag, int type, int count, byte[] data) {
            this.tag = tag; this.type = type; this.count = count; this.data = data;
        }
    }

    /** 生成动态照片 JPEG：注入 EXIF（含 0x8897）与动态照片 XMP。 */
    static byte[] buildMotionJpeg(byte[] jpeg, ExifInterface src, long videoLength,
                                  long presentationTimestampUs, String originalXmp) {
        byte[] tiff = buildTiff(src, true);
        // XMP 里的 Primary Item 长度必须等于"注入元数据之后"的 JPEG 长度，而这个长度又受
        // 该数字自身的位数影响，所以迭代到两者相等为止（最多差 1 字节，几轮必收敛）。
        long stillLength = jpeg.length;
        String xmp = MotionPhotoSupport.motionXmp(stillLength, videoLength,
                presentationTimestampUs, originalXmp);
        byte[] result = inject(jpeg, tiff, xmp);
        for (int i = 0; i < 8 && result.length != stillLength; i++) {
            stillLength = result.length;
            xmp = MotionPhotoSupport.motionXmp(stillLength, videoLength,
                    presentationTimestampUs, originalXmp);
            result = inject(jpeg, tiff, xmp);
        }
        return result;
    }

    /** 生成静态照片 JPEG：只注入 EXIF 拍摄参数。 */
    static byte[] buildStillJpeg(byte[] jpeg, ExifInterface src) {
        return inject(jpeg, buildTiff(src, false), null);
    }

    private static byte[] buildTiff(ExifInterface src, boolean motion) {
        List<Entry> ifd0 = new ArrayList<>();
        List<Entry> exif = new ArrayList<>();
        addAscii(ifd0, 0x010F, src.getAttribute(ExifInterface.TAG_MAKE));
        addAscii(ifd0, 0x0110, src.getAttribute(ExifInterface.TAG_MODEL));
        ifd0.add(new Entry(0x0112, TYPE_SHORT, 1, shortBytes(1))); // Orientation = Normal
        addAscii(ifd0, 0x0132, src.getAttribute(ExifInterface.TAG_DATETIME));
        addRationalAttr(exif, 0x829A, src.getAttribute(ExifInterface.TAG_EXPOSURE_TIME));
        addRationalAttr(exif, 0x829D, src.getAttribute(ExifInterface.TAG_F_NUMBER));
        int iso = src.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, -1);
        if (iso > 0) exif.add(new Entry(0x8827, TYPE_SHORT, 1, shortBytes(iso)));
        if (motion) exif.add(new Entry(TAG_XIAOMI_MOTION, TYPE_BYTE, 1, new byte[]{1}));
        addAscii(exif, 0x9003, src.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL));
        addAscii(exif, 0x9004, src.getAttribute(ExifInterface.TAG_DATETIME_DIGITIZED));
        addRationalAttr(exif, 0x920A, src.getAttribute(ExifInterface.TAG_FOCAL_LENGTH));
        int focal35 = src.getAttributeInt(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, -1);
        if (focal35 > 0) exif.add(new Entry(0xA405, TYPE_SHORT, 1, shortBytes(focal35)));
        List<Entry> gps = buildGps(src);

        ifd0.sort(Comparator.comparingInt((Entry e) -> e.tag));
        exif.sort(Comparator.comparingInt((Entry e) -> e.tag));

        if (!exif.isEmpty()) {
            ifd0.add(new Entry(TAG_EXIF_IFD_POINTER, TYPE_LONG, 1, intBytes(0))); // 占位，稍后回填
        }
        if (!gps.isEmpty()) {
            gps.sort(Comparator.comparingInt((Entry e) -> e.tag));
            ifd0.add(new Entry(TAG_GPS_IFD_POINTER, TYPE_LONG, 1, intBytes(0)));
        }
        ifd0.sort(Comparator.comparingInt((Entry e) -> e.tag));

        int offset = 8;
        int ifd0Offset = offset;
        offset += 2 + ifd0.size() * 12 + 4;
        int exifOffset = exif.isEmpty() ? 0 : offset;
        if (!exif.isEmpty()) offset += 2 + exif.size() * 12 + 4;
        int gpsOffset = gps.isEmpty() ? 0 : offset;
        if (!gps.isEmpty()) offset += 2 + gps.size() * 12 + 4;
        int dataCursor = offset;

        ByteArrayOutputStream out = new ByteArrayOutputStream(offset + 256);
        writeLong(out, 0x4D4D002A); // "MM" + 42
        writeLong(out, ifd0Offset);
        dataCursor = writeIfd(out, ifd0, dataCursor);
        if (!exif.isEmpty()) dataCursor = writeIfd(out, exif, dataCursor);
        if (!gps.isEmpty()) dataCursor = writeIfd(out, gps, dataCursor);
        appendData(out, ifd0);
        appendData(out, exif);
        appendData(out, gps);

        byte[] tiff = out.toByteArray();
        patchLong(tiff, pointerEntryOffset(ifd0, ifd0Offset, TAG_EXIF_IFD_POINTER), exifOffset);
        patchLong(tiff, pointerEntryOffset(ifd0, ifd0Offset, TAG_GPS_IFD_POINTER), gpsOffset);
        return tiff;
    }

    private static List<Entry> buildGps(ExifInterface src) {
        List<Entry> gps = new ArrayList<>();
        float[] latLng = new float[2];
        boolean hasPosition = false;
        try { hasPosition = src.getLatLong(latLng); } catch (Throwable ignored) { }
        if (!hasPosition || Float.isNaN(latLng[0]) || Float.isNaN(latLng[1])
                || (latLng[0] == 0 && latLng[1] == 0)) return gps;
        float lat = latLng[0], lon = latLng[1];
        gps.add(new Entry(0x0001, TYPE_ASCII, 2, asciiBytes(lat >= 0 ? "N" : "S")));
        gps.add(new Entry(0x0002, TYPE_RATIONAL, 3, dmsBytes(Math.abs(lat))));
        gps.add(new Entry(0x0003, TYPE_ASCII, 2, asciiBytes(lon >= 0 ? "E" : "W")));
        gps.add(new Entry(0x0004, TYPE_RATIONAL, 3, dmsBytes(Math.abs(lon))));
        try {
            double altitude = src.getAltitude(0);
            if (altitude != 0) {
                gps.add(new Entry(0x0005, TYPE_BYTE, 1, new byte[]{(byte) (altitude >= 0 ? 0 : 1)}));
                gps.add(new Entry(0x0006, TYPE_RATIONAL, 1, rationalBytes(Math.round(Math.abs(altitude) * 100), 100)));
            }
        } catch (Throwable ignored) { }
        return gps;
    }

    /** 写入一个 IFD；返回推进后的数据区游标。值 ≤4 字节内联，>4 字节记录到数据区（稍后追加）。 */
    private static int writeIfd(ByteArrayOutputStream out, List<Entry> entries, int dataCursor) {
        writeShort(out, entries.size());
        for (Entry e : entries) {
            writeShort(out, e.tag);
            writeShort(out, e.type);
            writeLong(out, e.count);
            if (e.data.length <= 4) {
                byte[] inline = new byte[4];
                System.arraycopy(e.data, 0, inline, 0, e.data.length);
                write(out, inline);
            } else {
                writeLong(out, dataCursor);
                dataCursor += e.data.length + (e.data.length % 2); // 偶数对齐
            }
        }
        writeLong(out, 0); // next IFD = 0
        return dataCursor;
    }

    private static void appendData(ByteArrayOutputStream out, List<Entry> entries) {
        for (Entry e : entries) {
            if (e.data.length <= 4) continue;
            write(out, e.data);
            if (e.data.length % 2 == 1) out.write(0);
        }
    }

    private static int pointerEntryOffset(List<Entry> ifd0, int ifd0Offset, int pointerTag) {
        int index = -1;
        for (int i = 0; i < ifd0.size(); i++) if (ifd0.get(i).tag == pointerTag) index = i;
        if (index < 0) return -1;
        return ifd0Offset + 2 + index * 12 + 8;
    }

    private static void patchLong(byte[] bytes, int at, int value) {
        if (at < 0) return;
        bytes[at] = (byte) (value >>> 24); bytes[at + 1] = (byte) (value >>> 16);
        bytes[at + 2] = (byte) (value >>> 8); bytes[at + 3] = (byte) value;
    }

    private static byte[] inject(byte[] jpeg, byte[] tiff, String xmp) {
        if (jpeg == null || jpeg.length < 4 || (jpeg[0] & 255) != 0xFF || (jpeg[1] & 255) != 0xD8) return jpeg;
        ByteArrayOutputStream out = new ByteArrayOutputStream(jpeg.length + tiff.length + 512);
        out.write(0xFF); out.write(0xD8);
        appendApp1(out, "Exif".getBytes(StandardCharsets.US_ASCII), new byte[]{0, 0}, tiff);
        if (xmp != null) {
            appendApp1(out, "http://ns.adobe.com/xap/1.0/".getBytes(StandardCharsets.US_ASCII),
                    new byte[]{0}, xmp.getBytes(StandardCharsets.UTF_8));
        }
        out.write(jpeg, 2, jpeg.length - 2);
        return out.toByteArray();
    }

    private static void appendApp1(ByteArrayOutputStream out, byte[] header, byte[] terminator, byte[] payload) {
        int length = 2 + header.length + terminator.length + payload.length;
        out.write(0xFF); out.write(0xE1);
        out.write((length >>> 8) & 255); out.write(length & 255);
        write(out, header); write(out, terminator); write(out, payload);
    }

    // ---------- 值编码辅助 ----------
    private static void addAscii(List<Entry> list, int tag, String value) {
        if (value == null || value.isEmpty()) return;
        list.add(new Entry(tag, TYPE_ASCII, value.length() + 1, asciiBytes(value)));
    }

    private static void addRationalAttr(List<Entry> list, int tag, String rational) {
        if (rational == null) return;
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("^(-?\\d+)/(\\d+)$").matcher(rational.trim());
        if (!m.matches()) return;
        long num = Long.parseLong(m.group(1)), den = Long.parseLong(m.group(2));
        if (den == 0 || num < 0) return;
        list.add(new Entry(tag, TYPE_RATIONAL, 1, rationalBytes(num, den)));
    }

    private static byte[] dmsBytes(double decimalDegrees) {
        int degrees = (int) decimalDegrees;
        double minutesAll = (decimalDegrees - degrees) * 60;
        int minutes = (int) minutesAll;
        double seconds = (minutesAll - minutes) * 60;
        ByteArrayOutputStream out = new ByteArrayOutputStream(24);
        write(out, longBytes(degrees)); write(out, longBytes(1));
        write(out, longBytes(minutes)); write(out, longBytes(1));
        write(out, longBytes(Math.round(seconds * 10000))); write(out, longBytes(10000));
        return out.toByteArray();
    }

    private static byte[] asciiBytes(String s) {
        byte[] bytes = new byte[s.length() + 1];
        System.arraycopy(s.getBytes(StandardCharsets.US_ASCII), 0, bytes, 0, s.length());
        return bytes;
    }

    private static byte[] rationalBytes(long num, long den) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(8);
        write(out, longBytes(num)); write(out, longBytes(den));
        return out.toByteArray();
    }

    private static byte[] shortBytes(int v) {
        return new byte[]{(byte) (v >>> 8), (byte) v};
    }

    private static byte[] intBytes(int v) {
        return new byte[]{(byte) (v >>> 24), (byte) (v >>> 16), (byte) (v >>> 8), (byte) v};
    }

    private static byte[] longBytes(long v) {
        return new byte[]{(byte) (v >>> 24), (byte) (v >>> 16), (byte) (v >>> 8), (byte) v};
    }

    private static void writeShort(ByteArrayOutputStream out, int v) {
        out.write((v >>> 8) & 255); out.write(v & 255);
    }

    private static void writeLong(ByteArrayOutputStream out, int v) {
        out.write((v >>> 24) & 255); out.write((v >>> 16) & 255);
        out.write((v >>> 8) & 255); out.write(v & 255);
    }

    private static void write(ByteArrayOutputStream out, byte[] bytes) {
        out.write(bytes, 0, bytes.length);
    }
}
