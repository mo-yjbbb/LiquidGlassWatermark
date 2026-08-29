package com.localwatermark.liquidglass.android;

import androidx.exifinterface.media.ExifInterface;

/**
 * 把 androidx ExifInterface 里的拍摄参数抽成 {@link ExifBuilder.Fields} 快照。
 *
 * <p>单独成类是为了把 ExifInterface 依赖隔离在真机运行路径上：ExifInterface 在纯 JVM
 * 单元测试里类初始化就会失败，ExifBuilder 及其测试因此完全不引用它。
 */
final class ExifFields {
    private ExifFields() {}

    static ExifBuilder.Fields from(ExifInterface src) {
        ExifBuilder.Fields f = new ExifBuilder.Fields();
        f.make = src.getAttribute(ExifInterface.TAG_MAKE);
        f.model = src.getAttribute(ExifInterface.TAG_MODEL);
        f.dateTime = src.getAttribute(ExifInterface.TAG_DATETIME);
        f.dateTimeOriginal = src.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL);
        f.dateTimeDigitized = src.getAttribute(ExifInterface.TAG_DATETIME_DIGITIZED);
        f.exposureTime = src.getAttribute(ExifInterface.TAG_EXPOSURE_TIME);
        f.fNumber = src.getAttribute(ExifInterface.TAG_F_NUMBER);
        f.focalLength = src.getAttribute(ExifInterface.TAG_FOCAL_LENGTH);
        f.iso = src.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, -1);
        f.focal35 = src.getAttributeInt(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, -1);
        try {
            float[] latLng = new float[2];
            if (src.getLatLong(latLng)) { f.latitude = latLng[0]; f.longitude = latLng[1]; }
        } catch (Throwable ignored) { }
        try {
            double altitude = src.getAltitude(Double.NaN);
            if (!Double.isNaN(altitude)) f.altitude = altitude;
        } catch (Throwable ignored) { }
        return f;
    }
}
