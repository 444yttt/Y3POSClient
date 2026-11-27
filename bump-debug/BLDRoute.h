#ifndef BLD_ROUTE_H
#define BLD_ROUTE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BLD_ROUTE_MAX_POINTS 256

typedef struct {
    double latitude;
    double longitude;
} BLDPoint;

typedef struct {
    BLDPoint point;
    double speed;  /* Metres per second; zero while stationary. */
    double course; /* Degrees clockwise from north, or -1 while stationary. */
    int finished;
} BLDSample;

int BLDPointIsValid(BLDPoint point);

/* Great-circle metres on a mean-radius sphere. Invalid input returns NAN. */
double BLDDistance(BLDPoint a, BLDPoint b);

/*
 * Sample a path at a nonnegative elapsed number of monotonic seconds.
 * Speed is nonnegative metres per second. A zero speed holds the first point.
 * Paths with one point (or no measurable length) are already finished; otherwise
 * a zero-speed path is stationary but unfinished. Completed paths hold the last
 * point with zero speed and course -1. Segments shorter than 1 micrometre are
 * treated as duplicates. No looping or clock access is performed.
 *
 * Returns 1 on success, 0 for invalid inputs. On failure, *sample is unchanged.
 */
int BLDRouteSample(const BLDPoint *points, size_t count, double speed,
                   double elapsed, BLDSample *sample);

#ifdef __cplusplus
}
#endif

#endif
