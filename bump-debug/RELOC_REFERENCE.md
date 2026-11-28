Reloc reference — direct Bump feed
===================================

Reference https://github.com/Reukix/Reloc at2d375a9024379701aa93b1d4c060931b7dca05a1.
Reloc represents a timestamped target using WGS84 coordinates, altitude, speed and course, serializing it into NMEA/iAP2. The current user requirement is direct synthetic data injection into Bump's existing location path, so no virtual accessory, MFi resource or separate app is used. No Reloc source is incorporated. Bump consumes CLLocation values rather than NMEA; its speed unit is m/s rather than knots.

The adapter is scoped to the supplied2.135.0 build's two validated Objective-C callbacks and related manager getter. It preserves native batch order/cardinality/timestamps, marked downstream values and getter/callback fix identity. Explicit periodic input is limited to managers with active app requests and an observed callback run loop. Stop/start generations reject stale queued inputs. Default CLLocation source information is left unspecified by the standard value initializer; sourceInformation methods are not overridden. Synthetic values are not claimed to be hardware GPS measurements.

The startup storage fix accepts a validated installer team suffix and is initialized before optional callback discovery. Real-device launch and scratch/server acceptance remain unverified.
