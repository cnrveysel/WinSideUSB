# iPad Client

The iPad side is currently a Swift source file:

```text
DuetCloneNew/swiftclientcode.swift
```

It can be copied into Swift Playgrounds or moved into a normal iOS app target.

## Runtime Flow

1. The iPad app opens a BSD socket listener.
2. It tries ports in this order:

```text
17326, 17325, 17324, 17323, 17322, 17321
```

3. The Windows app starts `iproxy` and probes the same ports.
4. Windows sends:

```text
WSUSB_HELLO2
```

5. The iPad responds:

```text
WSUSB_READY2
```

6. Windows starts the virtual display and sends the stream.

## Expected iPad Status

Before pressing Start on Windows:

```text
BSD socket listener v2
Port 17326 acik - PC bekleniyor...
```

The port may be any of the fallback ports. That is normal.

After Windows connects:

```text
PC verisi geldi
Yayin aliniyor...
Streaming
```

## Swift Playgrounds Notes

Swift Playgrounds can leave an older run alive long enough to keep a port busy. If the app reports:

```text
Portlar dolu: 48
```

then every fallback port is already in use. Fully close Swift Playgrounds from the iPad app switcher and run the project again.

If the iPad keeps showing `PC bekleniyor`, check Windows:

```text
%LOCALAPPDATA%\WinSideUSB\winsideusb_diag.log
%LOCALAPPDATA%\WinSideUSB\iproxy.log
```

If Windows says it received `READY2`, the USB socket path is working and the problem is likely the Windows virtual display driver.

## Logs

The iPad client creates CSV logs in the app document directory. Use the overlay Share Log button to export them.

The CSV includes:

- received bytes and packet counts
- maximum payload size
- renderer status
- sync drops
- queue refreshes
- total enqueued and dropped frames

## Port Changes

If ports must be changed, update both files:

```text
DuetCloneNew/WinSideUSB.cpp
DuetCloneNew/swiftclientcode.swift
```

Keep the handshake strings versioned when changing transport behavior. That prevents old Playgrounds runs from being mistaken for the current app.
