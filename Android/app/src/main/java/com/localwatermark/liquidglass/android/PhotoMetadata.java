package com.localwatermark.liquidglass.android;

import androidx.exifinterface.media.ExifInterface;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

final class PhotoMetadata {
    final String device, date, exposure, location;

    private PhotoMetadata(String device, String date, String exposure, String location) {
        this.device = device; this.date = date; this.exposure = exposure; this.location = location;
    }

    static PhotoMetadata read(InputStream stream) throws IOException {
        ExifInterface exif = new ExifInterface(stream);
        String make = clean(exif.getAttribute(ExifInterface.TAG_MAKE));
        String model = clean(exif.getAttribute(ExifInterface.TAG_MODEL));
        String device = model;
        if (!make.isEmpty() && !model.toLowerCase(Locale.ROOT).startsWith(make.toLowerCase(Locale.ROOT))) {
            device = make + " " + model;
        }
        String date = clean(exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL));
        if (date.length() >= 10) date = date.substring(0, 10).replace(':', '.') + date.substring(10);

        List<String> parts = new ArrayList<>();
        int focal35 = exif.getAttributeInt(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, 0);
        if (focal35 > 0) parts.add(focal35 + "mm");
        double aperture = exif.getAttributeDouble(ExifInterface.TAG_F_NUMBER, 0);
        if (aperture > 0) parts.add(String.format(Locale.US, "F%.2f", aperture));
        double seconds = exif.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, 0);
        if (seconds > 0) parts.add(seconds < 1 ? "1/" + Math.max(1, Math.round(1 / seconds)) + "s" : String.format(Locale.US, "%.1fs", seconds));
        int iso = exif.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, 0);
        if (iso > 0) parts.add("ISO" + iso);

        float[] latLong = new float[2];
        String location = exif.getLatLong(latLong) ? coordinate(latLong[0], "N", "S") + "  " + coordinate(latLong[1], "E", "W") : "";
        return new PhotoMetadata(device, date, String.join("  ", parts), location);
    }

    boolean complete() { return !device.isEmpty() && !date.isEmpty() && !exposure.isEmpty() && !location.isEmpty(); }
    private static String clean(String value) { return value == null ? "" : value.trim(); }
    private static String coordinate(double value, String positive, String negative) {
        double abs = Math.abs(value); int degrees = (int) abs;
        double minuteValue = (abs - degrees) * 60; int minutes = (int) minuteValue;
        int seconds = (int) Math.round((minuteValue - minutes) * 60);
        return degrees + "°" + minutes + "'" + seconds + "\"" + (value >= 0 ? positive : negative);
    }
}
