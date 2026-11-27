#include "BLDRoute.h"

#include <math.h>

static const double BLDRadius = 6371008.8;
static const double BLDPi = 3.14159265358979323846264338327950288;
static const double BLDDuplicateMetres = 0.000001;

typedef struct {
    double x, y, z;
} BLDVector;

static double radians(double degrees) { return degrees * (BLDPi / 180.0); }
static double degrees(double angle) { return angle * (180.0 / BLDPi); }

static double dot(BLDVector a, BLDVector b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

static BLDVector cross(BLDVector a, BLDVector b) {
    BLDVector result = {a.y * b.z - a.z * b.y,
                        a.z * b.x - a.x * b.z,
                        a.x * b.y - a.y * b.x};
    return result;
}

static double length(BLDVector a) { return hypot(hypot(a.x, a.y), a.z); }

static BLDVector scaled(BLDVector a, double factor) {
    BLDVector result = {a.x * factor, a.y * factor, a.z * factor};
    return result;
}

static BLDVector vector(BLDPoint point) {
    double latitude = radians(point.latitude);
    double longitude = radians(point.longitude);
    BLDVector result = {cos(latitude) * cos(longitude),
                        cos(latitude) * sin(longitude), sin(latitude)};
    return result;
}

static double angle(BLDVector a, BLDVector b) {
    return atan2(length(cross(a, b)), dot(a, b));
}

int BLDPointIsValid(BLDPoint point) {
    return isfinite(point.latitude) && isfinite(point.longitude) &&
           point.latitude >= -90.0 && point.latitude <= 90.0 &&
           point.longitude >= -180.0 && point.longitude <= 180.0;
}

double BLDDistance(BLDPoint a, BLDPoint b) {
    if (!BLDPointIsValid(a) || !BLDPointIsValid(b)) return NAN;
    return BLDRadius * angle(vector(a), vector(b));
}

/*
 * Derive a unit tangent at a towards b. Exactly antipodal points have infinitely
 * many shortest arcs, so choose a deterministic great circle through a there.
 */
static BLDVector tangent(BLDVector a, BLDVector b) {
    BLDVector normal = cross(a, b);
    double magnitude = length(normal);
    if (magnitude <= 1e-14) {
        BLDVector basis = {1.0, 0.0, 0.0};
        if (fabs(a.y) <= fabs(a.x) && fabs(a.y) <= fabs(a.z)) {
            basis.x = 0.0;
            basis.y = 1.0;
        } else if (fabs(a.z) <= fabs(a.x)) {
            basis.x = 0.0;
            basis.z = 1.0;
        }
        normal = cross(a, basis);
        magnitude = length(normal);
    }
    return cross(scaled(normal, 1.0 / magnitude), a);
}

static BLDSample interpolate(BLDPoint start, BLDPoint end, double fraction,
                             double speed) {
    BLDVector a = vector(start), b = vector(end);
    BLDVector direction = tangent(a, b);
    double theta = angle(a, b) * fraction;
    double c = cos(theta), s = sin(theta);
    BLDVector position = {a.x * c + direction.x * s,
                          a.y * c + direction.y * s,
                          a.z * c + direction.z * s};
    BLDVector velocity = {-a.x * s + direction.x * c,
                          -a.y * s + direction.y * c,
                          -a.z * s + direction.z * c};
    BLDPoint point = {degrees(atan2(position.z, hypot(position.x, position.y))),
                      degrees(atan2(position.y, position.x))};
    if (fraction <= 0.0) point = start;
    double latitude = radians(point.latitude), longitude = radians(point.longitude);
    BLDVector east = {-sin(longitude), cos(longitude), 0.0};
    BLDVector north = {-sin(latitude) * cos(longitude),
                       -sin(latitude) * sin(longitude), cos(latitude)};
    double course = degrees(atan2(dot(velocity, east), dot(velocity, north)));
    if (course < 0.0) course += 360.0;
    if (course >= 360.0) course = 0.0;
    BLDSample result = {point, speed, course, 0};
    return result;
}

int BLDRouteSample(const BLDPoint *points, size_t count, double speed,
                   double elapsed, BLDSample *sample) {
    if (!points || !sample || count == 0 || count > BLD_ROUTE_MAX_POINTS ||
        !isfinite(speed) || speed < 0.0 || !isfinite(elapsed) || elapsed < 0.0) {
        return 0;
    }
    for (size_t i = 0; i < count; ++i) {
        if (!BLDPointIsValid(points[i])) return 0;
    }

    double distances[BLD_ROUTE_MAX_POINTS - 1];
    double total = 0.0;
    for (size_t i = 1; i < count; ++i) {
        double distance = BLDDistance(points[i - 1], points[i]);
        if (distance <= BLDDuplicateMetres) distance = 0.0;
        distances[i - 1] = distance;
        total += distance;
    }
    if (total == 0.0) {
        BLDSample result = {points[count - 1], 0.0, -1.0, 1};
        *sample = result;
        return 1;
    }
    if (speed == 0.0) {
        BLDSample result = {points[0], 0.0, -1.0, 0};
        *sample = result;
        return 1;
    }

    /* Finite positive inputs may overflow this product; that means arrival. */
    double remaining = speed * elapsed;
    if (remaining >= total) {
        BLDSample result = {points[count - 1], 0.0, -1.0, 1};
        *sample = result;
        return 1;
    }
    for (size_t i = 0; i + 1 < count; ++i) {
        double distance = distances[i];
        if (distance == 0.0) continue;
        if (remaining < distance) {
            *sample = interpolate(points[i], points[i + 1], remaining / distance,
                                  speed);
            return 1;
        }
        remaining -= distance;
    }

    /* Rounding at the last boundary is arrival as well. */
    BLDSample result = {points[count - 1], 0.0, -1.0, 1};
    *sample = result;
    return 1;
}
