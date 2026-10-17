# sound

Send strings from a Mac's speakers to its microphone (or another Mac's
microphone) and print the decoded text to standard output.

```
$ .build/release/sound listen
hello through the air
```

This is a small acoustic modem: text is encoded as audible 16-tone FSK, played
through the default output device, picked up by the default input device, and
demodulated back into a string.

## Requirements

- macOS 13 or newer
- Swift 6 toolchain (Xcode or the Command Line Tools)
- Microphone permission for the terminal application

## Build

```sh
swift build -c release
```

The executable is `.build/release/sound`.

## Try it

Run the whole loop on one machine:

```sh
.build/release/sound loopback "hello from my speaker"
# stdout: hello from my speaker
```

Or use two terminals. Start the receiver first:

```sh
# terminal 1
.build/release/sound listen
# stderr: sound: listening on the default microphone at 48000 Hz (Ctrl-C to stop)
```

Then transmit from the second terminal:

```sh
# terminal 2
.build/release/sound send "hello through the air"
```

The first terminal prints:

```
hello through the air
```

There is also an in-memory check that does not need any audio hardware:

```sh
.build/release/sound selftest "the modem works"
```

## Commands

```
sound send <message>       Play <message> through the default output.
sound listen               Decode microphone audio; print each string to stdout.
sound loopback <message>   Play and listen at once; print what the mic hears.
sound selftest [message]   In-memory round trip with noise and echo.
sound help                 Show usage.
```

Only decoded strings are written to stdout. Status messages, warnings, and
diagnostics go to stderr, so the output can be piped safely:

```sh
.build/release/sound listen | tee received.txt
```

## How it works

- **Modulation:** 16-FSK. Tone `n` is `1000 + 200n` Hz, from 1 kHz to 4 kHz.
  Each 25 ms symbol carries one nibble, giving 160 bits per second.
- **Frame:** a known 12-symbol preamble, a one-byte UTF-8 length, the payload,
  and a CRC-16/CCITT-FALSE checksum. Payloads are limited to 255 bytes.
- **Transmission:** 400 ms of silence, the modulated frame, then 250 ms of
  silence. Keeping a quiet lead-in gives the receiver time to estimate the
  noise floor and makes the start of the frame easy to detect.
- **Reception:** the microphone stream is scanned for the preamble. Once
  locked, the receiver detects each tone with Goertzel filters, allows a small
  per-symbol timing shift, and verifies the CRC before printing a frame.
- **Rates:** transmitter and receiver can run at different sample rates; all
  frequencies and symbol lengths are defined in seconds and hertz.

## Tips and troubleshooting

- **No microphone permission:** allow the terminal app in
  System Settings → Privacy & Security → Microphone, then run the command
  again. The first run asks for permission.
- **Nothing is decoded:** check the output volume, make sure the transmitter
  and receiver use the intended default audio devices, and start `listen`
  before `send`. The receiver cannot decode a frame that began before it
  started.
- **Interference:** keep the speaker volume moderate and avoid loud music or
  fan noise while receiving. Very close range and a quiet room work best.
- **Long messages:** at 160 bit/s raw, a 20-byte message takes about 2 seconds
  including silence. The 255-byte limit takes roughly 14 seconds.
- **Feedback:** `loopback` deliberately routes speaker audio into the
  microphone. If the result is distorted, lower the system output volume.

## Tests

```sh
swift test
```

The tests cover 48 kHz and 44.1 kHz operation, chunked streaming, Unicode,
maximum-length payloads, resampling between devices, and noisy, band-limited,
echoed channels.
