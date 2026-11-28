Reloc reference review
======================
Reference: https://github.com/Reukix/Reloc at 2d375a9024379701aa93b1d4c060931b7dca05a1.

Reloc creates a local CoreAccessories virtual accessory, negotiates iAP2, performs MFi-v3 authentication, and streams GPGGA/GPRMC NMEA to iOS. It does not replace CLLocation properties inside Bump. Core Location telemetry, including isProducedByAccessory, is used to confirm actual acceptance; protocol ACK alone does not prove adoption.

Its README requires user-supplied certificate.p7b and identity.pk8, not included in the repository. Existing Apple app distribution signing assets are different from these accessory credentials. The official v1.0.4 IPA was subsequently retrieved and its published SHA256 verified: f22b84a17253b002a1f397e1a675c248496854988c3bfac17599bc7fa7e89a96. It contains bundled MFi resources. No individual credential is extracted or embedded in Bump. Bump now receives iOS Core Location unchanged, with all in-app location injection disabled; the separate official Reloc app controls accessory location. See USAGE.txt. No Reloc code is incorporated into Bump.

Startup fix: accept a single validated 10-character signing-team suffix on the delivery bundle ID, while preserving exact binary version/build/executable guards. Install the app-private original-App-Group fallback before resolving optional location callback classes. Tests cover renamed identities, rejected malformed identities and missing/present/failing group-container resolution using filesystem fixtures.

Device crash fix remains unverified on a real device until a rebuilt candidate is installed.
