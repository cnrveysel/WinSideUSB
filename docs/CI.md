# Source checks

The Windows job checks native helpers and installer transactions. Swift helper checks run in the official Swift 6.0.3 Linux container, matching the supported local WSL helper workflow. These jobs do not produce the distributable Windows app or iPad app.

The first hosted run on the 0.3.10 source commit revealed two environment differences:

- Windows PowerShell supplied a byte-order mark to the C++ display-mode probe's numeric input. The probe wrapper now uses scoped UTF-8 without a BOM and restores the caller's encoding.
- The standalone macOS Swift transport executable exited with SIGPIPE during disconnect testing. The Linux transport suite passes; the cause on macOS and its relevance to the UIKit iPad app remain unverified. CI therefore reports the Linux helper suite explicitly. An iPadOS build alone does not establish safe runtime behavior in that scenario; real-device disconnect tests remain necessary.

The `v0.3.10` tag retains the exact published pre-audio source and setup. Subsequent CI changes on `main` change only the workflow, test wrapper and this note; they do not change the app, embedded Swift client or published installer. Source build and local validation details are in [RELEASE_0.3.10.md](RELEASE_0.3.10.md).
