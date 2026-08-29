package com.localwatermark.liquidglass.android;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * 构造 EXIF APP1（含小米相册识别动态照片的私有标签 0x8897）并注入 JPEG。
 *
 * <p>androidx ExifInterface 既写不了自定义标签，也读不出未知标签，所以小米相机写在原图里的
 * 私有数据（0x8897 只是已知的一个，还可能有别的动态照片标记）用常规 API 必然丢光。因此这里
 * 有两条路径：
 * <ol>
 *   <li><b>继承</b>（首选）：字节级解析原图 EXIF，原样保留全部标签，只补写 0x8897 后重新
 *       序列化；小米私有数据一条不丢。</li>
 *   <li><b>重建</b>（兜底）：原图没有 EXIF 或解析失败时，按 {@link Fields} 从零拼一份。</li>
 * </ol>
 * 布局：TIFF 头 + IFD0(含 Exif/GPS 指针) + Exif IFD(含 0x8897) + GPS IFD + 数据区，统一大端。
 *
 * <p>字节构造只依赖 {@link Fields}（纯 POJO），与 Android 运行时无关，可在普通 JVM 测试。
 */
final class ExifBuilder {
    private ExifBuilder() {}

    private static final int TYPE_BYTE = 1, TYPE_ASCII = 2, TYPE_SHORT = 3, TYPE_LONG = 4, TYPE_RATIONAL = 5;
    private static final int TAG_EXIF_IFD_POINTER = 0x8769, TAG_GPS_IFD_POINTER = 0x8825;
    private static final int TAG_INTEROP_POINTER = 0xA005;
    /** 小米相册（澎湃OS/MIUI）判定动态照片的私有标签，类型 BYTE，值 1。 */
    static final int TAG_XIAOMI_MOTION = 0x8897;

    /** 各 TIFF 类型的单元字节数，下标即 type。 */
    private static final int[] TYPE_SIZE = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};

    /** 从原图抽取出的拍摄参数快照（纯数据，便于测试；仅兜底重建路径使用）。 */
    static final class Fields {
        String make, model;
        String dateTime, dateTimeOriginal, dateTimeDigitized;
        String exposureTime, fNumber, focalLength; // "num/den" 形式
        int iso = -1, focal35 = -1;
        double latitude = Double.NaN, longitude = Double.NaN, altitude = Double.NaN;
    }

    private static final class Entry {
        final int tag, type, count;
        final byte[] data; // 长度 = count * 单元大小
        Entry(int tag, int type, int count, byte[] data) {
            this.tag = tag; this.type = type; this.count = count; this.data = data;
        }
    }

    // ---------- 对外入口 ----------

    static byte[] buildMotionJpeg(byte[] jpeg, Fields fields, long videoLength,
                                  long presentationTimestampUs, String originalXmp) {
        return buildMotionJpeg(jpeg, null, fields, videoLength, presentationTimestampUs, originalXmp);
    }

    static byte[] buildStillJpeg(byte[] jpeg, Fields fields) {
        return buildStillJpeg(jpeg, null, fields);
    }

    /** 生成动态照片 JPEG。传入原图字节时优先继承其完整 EXIF。 */
    static byte[] buildMotionJpeg(byte[] jpeg, byte[] originalJpeg, Fields fields,
                                  long videoLength, long presentationTimestampUs, String originalXmp) {
        byte[] tiff = pickTiff(originalJpeg, fields, true);
        byte[] extra = leadingSegments(originalJpeg);
        // XMP 里的 Primary Item 长度必须等于"注入元数据之后"的 JPEG 长度，而这个长度又受
        // 该数字自身的位数影响，所以迭代到两者相等为止（最多差 1 字节，几轮必收敛）。
        long stillLength = jpeg.length;
        String xmp = MotionPhotoSupport.motionXmp(stillLength, videoLength,
                presentationTimestampUs, originalXmp);
        byte[] result = inject(jpeg, tiff, xmp, extra);
        for (int i = 0; i < 8 && result.length != stillLength; i++) {
            stillLength = result.length;
            xmp = MotionPhotoSupport.motionXmp(stillLength, videoLength,
                    presentationTimestampUs, originalXmp);
            result = inject(jpeg, tiff, xmp, extra);
        }
        return result;
    }

    /** 生成静态照片 JPEG。传入原图字节时优先继承其完整 EXIF（但不含 0x8897）。 */
    static byte[] buildStillJpeg(byte[] jpeg, byte[] originalJpeg, Fields fields) {
        return inject(jpeg, pickTiff(originalJpeg, fields, false), null, leadingSegments(originalJpeg));
    }

    /** 优先继承原图完整 EXIF，失败才按 Fields 重建。 */
    private static byte[] pickTiff(byte[] originalJpeg, Fields fields, boolean motion) {
        byte[] inherited = inheritTiff(originalJpeg, motion);
        if (inherited != null) return inherited;
        return buildTiff(fields == null ? new Fields() : fields, motion);
    }

    // ---------- 继承路径：解析原图 EXIF 并补写 0x8897 ----------

    static byte[] inheritTiff(byte[] jpeg, boolean motion) {
        byte[] tiff = extractExifTiff(jpeg);
        if (tiff == null || tiff.length < 8 || tiff.length > 60000) return null;
        boolean bigEndian = tiff[0] == 'M' && tiff[1] == 'M';
        if (!bigEndian && !(tiff[0] == 'I' && tiff[1] == 'I')) return null;
        // 小米相机拍的实况图本来就带 0x8897：此时原样继承，一个字节都不动，零风险。
        if (hasMotionTag(tiff, bigEndian) == motion) return tiff;
        try {
            List<Entry> ifd0 = readIfd(tiff, (int) u32(tiff, 4, bigEndian), bigEndian);
            if (ifd0 == null || ifd0.isEmpty()) return null;
            List<Entry> exif = readSubIfd(tiff, ifd0, TAG_EXIF_IFD_POINTER, bigEndian);
            List<Entry> gps = readSubIfd(tiff, ifd0, TAG_GPS_IFD_POINTER, bigEndian);
            removePointerEntries(ifd0);   // assemble 会重新生成指针
            removePointerEntries(exif);
            exif.removeIf(e -> e.tag == TAG_XIAOMI_MOTION);
            if (motion) exif.add(new Entry(TAG_XIAOMI_MOTION, TYPE_BYTE, 1, new byte[]{1}));
            return assemble(ifd0, exif, gps);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean hasMotionTag(byte[] tiff, boolean bigEndian) {
        try {
            List<Entry> ifd0 = readIfd(tiff, (int) u32(tiff, 4, bigEndian), bigEndian);
            if (ifd0 == null) return false;
            for (Entry e : readSubIfd(tiff, ifd0, TAG_EXIF_IFD_POINTER, bigEndian)) {
                if (e.tag == TAG_XIAOMI_MOTION) return true;
            }
        } catch (Throwable ignored) { }
        return false;
    }

    private static byte[] extractExifTiff(byte[] jpeg) {
        if (jpeg == null) return null;
        int pos = 2;
        while (pos + 4 <= jpeg.length) {
            if ((jpeg[pos] & 255) != 0xFF) return null;
            int marker = jpeg[pos + 1] & 255;
            if (marker == 0xDA || marker == 0xD9) return null; // 进入熵数据/结束
            if (marker >= 0xD0 && marker <= 0xD7 || marker == 0x01) { pos += 2; continue; }
            int len = ((jpeg[pos + 2] & 255) << 8) | (jpeg[pos + 3] & 255);
            if (len < 2 || pos + 2 + len > jpeg.length) return null;
            if (marker == 0xE1 && len >= 10 && jpeg[pos + 4] == 'E' && jpeg[pos + 5] == 'x'
                    && jpeg[pos + 6] == 'i' && jpeg[pos + 7] == 'f'
                    && jpeg[pos + 8] == 0 && jpeg[pos + 9] == 0) {
                return Arrays.copyOfRange(jpeg, pos + 10, pos + 2 + len);
            }
            pos += 2 + len;
        }
        return null;
    }

    private static List<Entry> readIfd(byte[] tiff, int offset, boolean bigEndian) {
        if (offset < 8 || offset + 2 > tiff.length) return null;
        int n = u16(tiff, offset, bigEndian);
        if (n <= 0 || n > 512 || offset + 2 + n * 12 + 4 > tiff.length) return null;
        List<Entry> entries = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            int e = offset + 2 + i * 12;
            int tag = u16(tiff, e, bigEndian);
            int type = u16(tiff, e + 2, bigEndian);
            long count = u32(tiff, e + 4, bigEndian);
            if (type <= 0 || type >= TYPE_SIZE.length || count <= 0) continue; // 丢弃无法处理的条目
            long size = (long) TYPE_SIZE[type] * count;
            if (size > tiff.length) continue;
            byte[] data;
            if (size <= 4) {
                data = Arrays.copyOfRange(tiff, e + 8, e + 8 + (int) size);
            } else {
                int valueOffset = (int) u32(tiff, e + 8, bigEndian);
                if (valueOffset < 8 || valueOffset + size > tiff.length) continue;
                data = Arrays.copyOfRange(tiff, valueOffset, valueOffset + (int) size);
            }
            entries.add(new Entry(tag, type, (int) count, data));
        }
        return entries;
    }

    private static List<Entry> readSubIfd(byte[] tiff, List<Entry> ifd0, int pointerTag, boolean bigEndian) {
        for (Entry e : ifd0) {
            if (e.tag == pointerTag && e.data.length >= 4) {
                List<Entry> sub = readIfd(tiff, (int) u32(e.data, 0, bigEndian), bigEndian);
                if (sub != null) return sub;
            }
        }
        return new ArrayList<>();
    }

    private static void removePointerEntries(List<Entry> entries) {
        entries.removeIf(e -> e.tag == TAG_EXIF_IFD_POINTER || e.tag == TAG_GPS_IFD_POINTER
                || e.tag == TAG_INTEROP_POINTER);
    }

    /** 原图里值得原样带回的元数据段：JFIF 与 ICC 色彩描述（MPF 等含绝对偏移的段一律丢弃）。 */
    private static byte[] leadingSegments(byte[] jpeg) {
        if (jpeg == null) return null;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int pos = 2;
        while (pos + 4 <= jpeg.length) {
            if ((jpeg[pos] & 255) != 0xFF) break;
            int marker = jpeg[pos + 1] & 255;
            if (marker == 0xDA || marker == 0xD9) break;
            if (marker >= 0xD0 && marker <= 0xD7 || marker == 0x01) { pos += 2; continue; }
            int len = ((jpeg[pos + 2] & 255) << 8) | (jpeg[pos + 3] & 255);
            if (len < 2 || pos + 2 + len > jpeg.length) break;
            boolean keep = marker == 0xE0 // APP0 / JFIF
                    || (marker == 0xE2 && startsWith(jpeg, pos + 4, "ICC_PROFILE"));
            if (keep) out.write(jpeg, pos, 2 + len);
            pos += 2 + len;
        }
        return out.size() == 0 ? null : out.toByteArray();
    }

    private static boolean startsWith(byte[] data, int offset, String prefix) {
        if (offset + prefix.length() > data.length) return false;
        for (int i = 0; i < prefix.length(); i++) {
            if (data[offset + i] != (byte) prefix.charAt(i)) return false;
        }
        return true;
    }

    private static int u16(byte[] b, int o, boolean bigEndian) {
        return bigEndian ? ((b[o] & 255) << 8) | (b[o + 1] & 255)
                         : ((b[o + 1] & 255) << 8) | (b[o] & 255);
    }

    private static long u32(byte[] b, int o, boolean bigEndian) {
        return bigEndian
                ? ((long)(b[o] & 255) << 24) | ((long)(b[o + 1] & 255) << 16)
                  | ((long)(b[o + 2] & 255) << 8) | (b[o + 3] & 255)
                : ((long)(b[o + 3] & 255) << 24) | ((long)(b[o + 2] & 255) << 16)
                  | ((long)(b[o + 1] & 255) << 8) | (b[o] & 255);
    }

    // ---------- 兜底路径：按 Fields 从零构造 ----------

    private static byte[] buildTiff(Fields src, boolean motion) {
        List<Entry> ifd0 = new ArrayList<>();
        List<Entry> exif = new ArrayList<>();
        addAscii(ifd0, 0x010F, src.make);
        addAscii(ifd0, 0x0110, src.model);
        ifd0.add(new Entry(0x0112, TYPE_SHORT, 1, shortBytes(1))); // Orientation = Normal
        addAscii(ifd0, 0x0132, src.dateTime);
        addRationalAttr(exif, 0x829A, src.exposureTime);
        addRationalAttr(exif, 0x829D, src.fNumber);
        if (src.iso > 0) exif.add(new Entry(0x8827, TYPE_SHORT, 1, shortBytes(src.iso)));
        if (motion) exif.add(new Entry(TAG_XIAOMI_MOTION, TYPE_BYTE, 1, new byte[]{1}));
        addAscii(exif, 0x9003, src.dateTimeOriginal);
        addAscii(exif, 0x9004, src.dateTimeDigitized);
        addRationalAttr(exif, 0x920A, src.focalLength);
        if (src.focal35 > 0) exif.add(new Entry(0xA405, TYPE_SHORT, 1, shortBytes(src.focal35)));
        return assemble(ifd0, exif, buildGps(src));
    }

    private static List<Entry> buildGps(Fields src) {
        List<Entry> gps = new ArrayList<>();
        if (Double.isNaN(src.latitude) || Double.isNaN(src.longitude)) return gps;
        if (src.latitude == 0 && src.longitude == 0) return gps;
        double lat = src.latitude, lon = src.longitude;
        gps.add(new Entry(0x0001, TYPE_ASCII, 2, asciiBytes(lat >= 0 ? "N" : "S")));
        gps.add(new Entry(0x0002, TYPE_RATIONAL, 3, dmsBytes(Math.abs(lat))));
        gps.add(new Entry(0x0003, TYPE_ASCII, 2, asciiBytes(lon >= 0 ? "E" : "W")));
        gps.add(new Entry(0x0004, TYPE_RATIONAL, 3, dmsBytes(Math.abs(lon))));
        if (!Double.isNaN(src.altitude) && src.altitude != 0) {
            gps.add(new Entry(0x0005, TYPE_BYTE, 1, new byte[]{(byte) (src.altitude >= 0 ? 0 : 1)}));
            gps.add(new Entry(0x0006, TYPE_RATIONAL, 1,
                    rationalBytes(Math.round(Math.abs(src.altitude) * 100), 100)));
        }
        return gps;
    }

    // ---------- 序列化（两条路径共用） ----------

    private static byte[] assemble(List<Entry> ifd0, List<Entry> exif, List<Entry> gps) {
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

    private static byte[] inject(byte[] jpeg, byte[] tiff, String xmp, byte[] extra) {
        if (jpeg == null || jpeg.length < 4 || (jpeg[0] & 255) != 0xFF || (jpeg[1] & 255) != 0xD8) return jpeg;
        ByteArrayOutputStream out = new ByteArrayOutputStream(jpeg.length + tiff.length + 512);
        out.write(0xFF); out.write(0xD8);
        if (extra != null) write(out, extra); // JFIF / ICC，放在最前最规范
        appendApp1(out, "Exif".getBytes(StandardCharsets.US_ASCII), new byte[]{0, 0}, tiff);
        if (xmp != null) {
            appendApp1(out, "http://ns.adobe.com/xap/1.0/".getBytes(StandardCharsets.US_ASCII),
                    new byte[]{0}, xmp.getBytes(StandardCharsets.UTF_8));
        }
        // 跳过压缩图自身可能残留的 APPn/COM 段，避免与上面写入的元数据重复
        int start = skipMetadataSegments(jpeg);
        out.write(jpeg, start, jpeg.length - start);
        return out.toByteArray();
    }

    /** 跳过前导的 APPn / COM 等元数据段，返回第一个图像段（DQT/SOF/…）的偏移。 */
    private static int skipMetadataSegments(byte[] jpeg) {
        int pos = 2;
        while (pos + 4 <= jpeg.length) {
            if ((jpeg[pos] & 255) != 0xFF) return pos;
            int marker = jpeg[pos + 1] & 255;
            if (marker == 0xDA || marker == 0xD9) return pos;
            if (marker >= 0xD0 && marker <= 0xD7 || marker == 0x01) { pos += 2; continue; }
            int len = ((jpeg[pos + 2] & 255) << 8) | (jpeg[pos + 3] & 255);
            if (len < 2 || pos + 2 + len > jpeg.length) return pos;
            boolean metadata = (marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE;
            if (!metadata) return pos;
            pos += 2 + len;
        }
        return pos;
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
