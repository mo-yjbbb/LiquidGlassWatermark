package com.localwatermark.liquidglass.android;

import androidx.exifinterface.media.ExifInterface;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

final class PhotoMetadata {
    final String device, date, exposure, location, brand;

    private PhotoMetadata(String device, String date, String exposure, String location, String brand) {
        this.device = device; this.date = date; this.exposure = exposure; this.location = location; this.brand = brand;
    }

    static PhotoMetadata read(InputStream stream, String fallbackDate) throws IOException {
        ExifInterface exif = new ExifInterface(stream);
        String make = clean(exif.getAttribute(ExifInterface.TAG_MAKE));
        String model = clean(exif.getAttribute(ExifInterface.TAG_MODEL));
        String device = displayDevice(make, model);
        if (device.equals(model) && !make.isEmpty() && !model.toLowerCase(Locale.ROOT).startsWith(make.toLowerCase(Locale.ROOT))) {
            device = make + " " + model;
        }
        String date = first(exif, ExifInterface.TAG_DATETIME_ORIGINAL,
                ExifInterface.TAG_DATETIME_DIGITIZED, ExifInterface.TAG_DATETIME);
        if (date.isEmpty()) date = clean(fallbackDate);
        if (date.length() >= 10) date = date.substring(0, 10).replace(':', '.') + date.substring(10);

        List<String> parts = new ArrayList<>();
        int focal35 = exif.getAttributeInt(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, 0);
        if (focal35 > 0) parts.add(focal35 + "mm");
        else {
            double focal = exif.getAttributeDouble(ExifInterface.TAG_FOCAL_LENGTH, 0);
            if (focal > 0) parts.add(String.format(Locale.US, "%.1fmm", focal));
        }
        double aperture = exif.getAttributeDouble(ExifInterface.TAG_F_NUMBER, 0);
        if (aperture > 0) parts.add(String.format(Locale.US, "F%.2f", aperture));
        double seconds = exif.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, 0);
        if (seconds > 0) parts.add(seconds < 1 ? "1/" + Math.max(1, Math.round(1 / seconds)) + "s" : String.format(Locale.US, "%.1fs", seconds));
        int iso = exif.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
                exif.getAttributeInt(ExifInterface.TAG_ISO_SPEED_RATINGS, 0));
        if (iso > 0) parts.add("ISO" + iso);

        float[] latLong = new float[2];
        String location = exif.getLatLong(latLong) ? coordinate(latLong[0], "N", "S") + "  " + coordinate(latLong[1], "E", "W") : "";
        String identity = (make + " " + model).toLowerCase(Locale.ROOT);
        String brand = (identity.contains("honor") || identity.contains("荣耀") || identity.contains("aak-an00"))
                ? "honor" : "leica";
        return new PhotoMetadata(device, date, String.join("  ", parts), location, brand);
    }

    static PhotoMetadata empty() { return new PhotoMetadata("", "", "", "", ""); }

    PhotoMetadata withFallback(PhotoMetadata other) {
        return new PhotoMetadata(
                device.isEmpty() ? other.device : device,
                date.isEmpty() ? other.date : date,
                exposure.isEmpty() ? other.exposure : exposure,
                location.isEmpty() ? other.location : location,
                brand.isEmpty() ? other.brand : brand);
    }

    boolean usable() { return !device.isEmpty() || !date.isEmpty() || !exposure.isEmpty(); }
    boolean complete() { return !device.isEmpty() && !date.isEmpty() && !exposure.isEmpty() && !location.isEmpty(); }

    String missingFields() {
        List<String> missing = new ArrayList<>();
        if (device.isEmpty()) missing.add("机型");
        if (date.isEmpty()) missing.add("拍摄日期");
        if (exposure.isEmpty()) missing.add("拍摄参数");
        if (location.isEmpty()) missing.add("经纬度");
        return String.join("、", missing);
    }
    boolean isHonor() { return "honor".equals(brand); }

    private static String displayDevice(String make, String model) {
        String joined = (make + " " + model).toLowerCase(Locale.ROOT);
        if (joined.contains("aak-an00")) return "HONOR WIN RT";
        return model;
    }

    private static String clean(String value) { return value == null ? "" : value.trim(); }
    private static String first(ExifInterface exif, String... tags) {
        for (String tag : tags) { String value = clean(exif.getAttribute(tag)); if (!value.isEmpty()) return value; }
        return "";
    }
    private static String coordinate(double value, String positive, String negative) {
        double abs = Math.abs(value); int degrees = (int) abs;
        double minuteValue = (abs - degrees) * 60; int minutes = (int) minuteValue;
        int seconds = (int) Math.round((minuteValue - minutes) * 60);
        return degrees + "°" + minutes + "'" + seconds + "\"" + (value >= 0 ? positive : negative);
    }
}
