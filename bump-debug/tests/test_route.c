#include "../BLDRoute.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const double pi = 3.14159265358979323846;

static void close_to_at(double actual, double expected, double tolerance, int line) {
    if (!(fabs(actual - expected) <= tolerance)) {
        fprintf(stderr, "route test line %d: actual %.17g, expected %.17g (+/- %.17g)\n",
                line, actual, expected, tolerance);
        assert(0);
    }
}

#define close_to(actual, expected, tolerance) \
    close_to_at((actual), (expected), (tolerance), __LINE__)

static void valid_sample(BLDSample sample) {
    assert(BLDPointIsValid(sample.point));
    assert(isfinite(sample.speed) && sample.speed >= 0.0);
    assert(sample.course == -1.0 ||
           (sample.course >= 0.0 && sample.course < 360.0));
}

static void equator_and_arrival(void) {
    BLDPoint points[] = {{0.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}};
    double distance = BLDDistance(points[0], points[1]);
    close_to(distance, 6371008.8 * pi / 180.0, 1e-7);
    BLDSample s;
    assert(BLDRouteSample(points, 3, 10.0, 0.0, &s));
    close_to(s.point.longitude, 0.0, 0.0);
    close_to(s.point.latitude, 0.0, 0.0);
    close_to(s.course, 90.0, 1e-10);
    close_to(s.speed, 10.0, 0.0);
    assert(!s.finished);
    assert(BLDRouteSample(points, 3, 10.0, distance / 20.0, &s));
    close_to(s.point.longitude, 0.5, 1e-10);
    close_to(s.point.latitude, 0.0, 1e-10);
    assert(BLDRouteSample(points, 3, 10.0, distance / 10.0, &s));
    close_to(s.point.longitude, 1.0, 1e-10);
    close_to(s.point.latitude, 0.0, 1e-10);
    close_to(s.course, 0.0, 1e-10);
    double total = distance + BLDDistance(points[1], points[2]);
    assert(BLDRouteSample(points, 3, 10.0, total / 10.0, &s));
    close_to(s.point.latitude, 1.0, 0.0);
    close_to(s.point.longitude, 1.0, 0.0);
    assert(s.finished && s.speed == 0.0 && s.course == -1.0);
    assert(BLDRouteSample(points, 3, DBL_MAX, DBL_MAX, &s));
    assert(s.finished && s.speed == 0.0);
}

static void dateline_and_poles(void) {
    BLDPoint points[] = {{0.0, 179.0}, {0.0, -179.0}};
    double distance = BLDDistance(points[0], points[1]);
    close_to(distance, 2.0 * 6371008.8 * pi / 180.0, 1e-7);
    BLDSample s;
    assert(BLDRouteSample(points, 2, 5.0, distance / 10.0, &s));
    close_to(fabs(s.point.longitude), 180.0, 1e-10);
    close_to(s.point.latitude, 0.0, 1e-10);
    close_to(s.course, 90.0, 1e-10);
    BLDPoint reverse[] = {points[1], points[0]};
    assert(BLDRouteSample(reverse, 2, 5.0, distance / 10.0, &s));
    close_to(s.course, 270.0, 1e-10);

    BLDPoint pole[] = {{80.0, 0.0}, {80.0, 180.0}};
    distance = BLDDistance(pole[0], pole[1]);
    assert(BLDRouteSample(pole, 2, 5.0, distance / 10.0, &s));
    close_to(s.point.latitude, 90.0, 1e-10);
    valid_sample(s);

    BLDPoint antipodal[] = {{0.0, 0.0}, {0.0, 180.0}};
    distance = BLDDistance(antipodal[0], antipodal[1]);
    assert(BLDRouteSample(antipodal, 2, 5.0, distance / 10.0, &s));
    valid_sample(s);
    close_to(BLDDistance(antipodal[0], s.point), distance * 0.5, 1e-6);
}

static void stationary_and_duplicates(void) {
    BLDSample s;
    BLDPoint single[] = {{35.0, 139.0}};
    assert(BLDRouteSample(single, 1, 10.0, 100.0, &s));
    assert(s.finished && s.speed == 0.0 && s.course == -1.0);
    close_to(s.point.latitude, 35.0, 0.0);
    BLDPoint paused[] = {{35.0, 139.0}, {36.0, 139.0}};
    assert(BLDRouteSample(paused, 2, 0.0, 100.0, &s));
    assert(!s.finished && s.speed == 0.0 && s.course == -1.0);
    close_to(s.point.latitude, 35.0, 0.0);
    BLDPoint same[] = {{90.0, 0.0}, {90.0, 180.0}, {90.0, -180.0}};
    assert(BLDRouteSample(same, 3, 10.0, 0.0, &s));
    assert(s.finished && s.speed == 0.0 && s.course == -1.0);
    BLDPoint duplicates[] = {{0.0, 0.0}, {0.0, 0.0}, {0.0, 1.0}, {0.0, 1.0}};
    double distance = BLDDistance(duplicates[0], duplicates[2]);
    assert(BLDRouteSample(duplicates, 4, 1.0, distance * 0.5, &s));
    close_to(s.point.longitude, 0.5, 1e-10);
    assert(BLDRouteSample(duplicates, 4, 1.0, distance + 1.0, &s));
    assert(s.finished && s.speed == 0.0 && s.course == -1.0);
    close_to(s.point.longitude, 1.0, 0.0);
}

static void reject_invalid(void) {
    BLDPoint points[] = {{0.0, 0.0}, {1.0, 1.0}};
    BLDSample sentinel = {{12.0, 34.0}, 56.0, 78.0, 9}, result;
#define REJECT(call) do { memcpy(&result, &sentinel, sizeof(result)); assert(!(call)); \
                         assert(memcmp(&result, &sentinel, sizeof(result)) == 0); } while (0)
    REJECT(BLDRouteSample(NULL, 1, 1.0, 1.0, &result));
    REJECT(BLDRouteSample(points, 0, 1.0, 1.0, &result));
    REJECT(BLDRouteSample(points, 257, 1.0, 1.0, &result));
    REJECT(BLDRouteSample(points, 2, -1.0, 1.0, &result));
    REJECT(BLDRouteSample(points, 2, NAN, 1.0, &result));
    REJECT(BLDRouteSample(points, 2, INFINITY, 1.0, &result));
    REJECT(BLDRouteSample(points, 2, 1.0, -1.0, &result));
    REJECT(BLDRouteSample(points, 2, 1.0, NAN, &result));
    REJECT(BLDRouteSample(points, 2, 1.0, INFINITY, &result));
    assert(!BLDRouteSample(points, 2, 1.0, 1.0, NULL));
    BLDPoint invalid[] = {{91.0, 0.0}, {-91.0, 0.0}, {0.0, 181.0},
                          {0.0, -181.0}, {NAN, 0.0}, {0.0, INFINITY}};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        assert(!BLDPointIsValid(invalid[i]));
        assert(isnan(BLDDistance(points[0], invalid[i])));
        BLDPoint bad_route[] = {points[0], invalid[i]};
        REJECT(BLDRouteSample(bad_route, 2, 0.0, 0.0, &result));
    }
#undef REJECT
    BLDPoint bounds[] = {{-90.0, -180.0}, {90.0, 180.0}};
    assert(BLDPointIsValid(bounds[0]) && BLDPointIsValid(bounds[1]));
}

static void maximum_path_and_symmetry(void) {
    BLDPoint points[BLD_ROUTE_MAX_POINTS];
    for (size_t i = 0; i < BLD_ROUTE_MAX_POINTS; ++i) {
        points[i].latitude = 0.0;
        points[i].longitude = (double)i / 100.0;
    }
    BLDSample s;
    assert(BLDRouteSample(points, BLD_ROUTE_MAX_POINTS, 10.0, 200.0, &s));
    valid_sample(s);
    assert(s.point.longitude > points[0].longitude &&
           s.point.longitude < points[BLD_ROUTE_MAX_POINTS - 1].longitude);
    BLDPoint a = {35.6581, 139.7017}, b = {40.7128, -74.0060};
    close_to(BLDDistance(a, b), BLDDistance(b, a), 1e-7);
    close_to(BLDDistance(a, a), 0.0, 0.0);
    double distance = BLDDistance(a, b);
    BLDPoint route[] = {a, b};
    assert(BLDRouteSample(route, 2, 10.0, distance / 20.0, &s));
    valid_sample(s);
    close_to(BLDDistance(a, s.point), distance / 2.0, 1e-6);
    close_to(BLDDistance(s.point, b), distance / 2.0, 1e-6);
}

int main(void) {
    equator_and_arrival();
    dateline_and_poles();
    stationary_and_duplicates();
    reject_invalid();
    maximum_path_and_symmetry();
    puts("Route tests passed");
    return 0;
}
