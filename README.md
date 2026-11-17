# easiptv-ffmpeg

[Español](#español) · [English](#english)

This software uses libraries from the FFmpeg project under the LGPLv2.1.

---

## Español

Código fuente y scripts de compilación de los dos componentes FFmpeg que usa
EasIPTV Player, compilados con [FFmpeg](https://ffmpeg.org) bajo **LGPL-2.1 o posterior**:
sin `--enable-gpl`, `--enable-nonfree` ni `--enable-version3`.

- El **decodificador de audio**: la extensión oficial `decoder_ffmpeg` de
  [androidx/media](https://github.com/androidx/media) (Media3).
- La **herramienta de línea de comandos para RTSP** (desde `app-1.5.0-2`): el programa
  `ffmpeg`, que la app ejecuta para remultiplexar una sesión RTSP a MPEG-TS
  (`-c copy -f mpegts pipe:1`) o, desde `app-1.5.0-4`, a un fichero MP4 fragmentado para grabar
  audio que MPEG-TS no lleva, como G.711, AMR u Opus (`-f mov`, `-f 3gp` o `-f mp4`; en
  `app-1.5.0-3` era Matroska por pipe, ya retirado). Sin encoders ni decoders: solo los protocolos, demuxers,
  parsers y los muxers que hacen falta. Cada ABI se publica como `libffmpeg_rtsp.so` para que
  Android lo instale en el directorio de bibliotecas nativas de la app, el único desde el
  que puede ejecutar ficheros.

### Qué contiene

| Ruta | Contenido |
|---|---|
| `external/media` | Submódulo de androidx/media fijado en el tag de Media3 que usa la app |
| `external/ffmpeg` | Submódulo de FFmpeg fijado en un tag oficial |
| `versions.env` | Todas las entradas fijadas: commits, NDK, CMake, API mínima, ABIs y decoders |
| `build-decoder.sh` | Compilación reproducible del AAR `lib-decoder-ffmpeg` |
| `build-cli.sh` | Compilación reproducible del AAR `lib-ffmpeg-rtsp` (el ejecutable de cada ABI); se ejecuta tras `build-decoder.sh` |
| `gradle/easiptv-decoder.init.gradle` | Fija NDK, CMake, minSdk, ABIs y rutas sin tocar el código de Media3 |
| `patches/cli` | Parches sobre FFmpeg que solo aplica `build-cli.sh` (publicados en `changes.diff`) |
| `scripts/check-relro.sh` | Comprueba que el RELRO de las `.so` de 64 bits es seguro con páginas de 16 KB |
| `scripts/verify-checksums.sh` | Compara una compilación con los SHA-256 de una release |
| `releases/<tag>/SHA256SUMS` | Hashes publicados de cada release |

Decoders incluidos (solo audio): `aac mp3 ac3 eac3 dca mlp truehd flac alac pcm_mulaw pcm_alaw opus vorbis`.
Ninguno es GPL según el `LICENSE.md` de FFmpeg. ABIs: `armeabi-v7a arm64-v8a x86 x86_64`,
API mínima 29, NDK r28c (las `.so` de 64 bits quedan alineadas a 16 KB).

Herramienta RTSP: protocolos `tcp udp rtp pipe file`, demuxers `rtsp rtp sdp mpegts`, muxers
`mpegts mov mp4 3gp`, parsers `h264 hevc aac aac_latm ac3 mpegaudio mpeg4video mpegvideo amr` y el
filtro de bitstream `setts` (pone a cada paquete las marcas de tiempo que MPEG-TS necesita y RTP
no trae). `build-cli.sh` falla si `config_components.h` activa algún encoder o decoder, o algún
protocolo distinto de esos (más `http`, que arrastra `rtsp`; nada de TLS).

**El protocolo `file` está solo para escribir la grabación.** La app limita la entrada con
`-protocol_whitelist tcp,udp,rtp` (opción de entrada): así la entrada no puede abrir `file:` ni
rutas, `pipe:` ni `http` (tampoco RTSP sobre HTTP), las redirecciones RTSP solo se siguen por
RTSP/TCP, y `concat:`, `subfile:`, `fd:` y TLS no están compilados. `patches/cli` tiene tres
parches pequeños sobre FFmpeg n6.0.1, solo para esta herramienta: el tamaño de imagen desde el
parser, las tramas AMR de RTP de una en una y la duración de un MP4 fragmentado al cerrarlo.

### Releases y tags

Cada versión de EasIPTV Player que incluye este decodificador tiene un tag
`app-<versión de la app>-<n>` (por ejemplo, `app-1.5.0-1`) y una release con:

- el AAR `lib-decoder-ffmpeg-<Media3>-app-<versión>-<n>.aar`;
- desde `app-1.5.0-2`, el AAR `lib-ffmpeg-rtsp-<FFmpeg>-app-<versión>-<n>.aar` con `jni/<abi>/libffmpeg_rtsp.so`;
- `ffmpeg-<tag>-source.tar.gz`: el código fuente **exacto** de FFmpeg compilado;
- `media3-decoder_ffmpeg-<Media3>-source.tar.gz`: el código del envoltorio JNI;
- `changes.diff`: los cambios sobre FFmpeg y Media3 (desde `app-1.5.0-3`, los parches de
  `patches/cli`, que solo usa la herramienta RTSP; el decodificador compila FFmpeg sin cambios);
- desde `app-1.5.0-3`, `COPYING.LGPLv2.1`: el texto de la licencia de FFmpeg;
- `BUILD.md`: líneas de `configure` completas, commits, NDK, decoders y comprobaciones de las `.so`;
- `SHA256SUMS`.

### Compilar en local (Linux x86-64)

```bash
git clone --recurse-submodules --shallow-submodules https://github.com/alpargataman/easiptv-ffmpeg.git
cd easiptv-ffmpeg
source versions.env
sdkmanager --install "ndk;$NDK_VERSION" "cmake;$CMAKE_VERSION"
ANDROID_HOME=~/Android/Sdk JAVA_HOME=/ruta/a/jdk-21 ./build-decoder.sh
ANDROID_HOME=~/Android/Sdk ./build-cli.sh
bash scripts/verify-checksums.sh releases/app-1.5.0-4/SHA256SUMS
```

El resultado queda en `dist/`. La compilación es reproducible: con las mismas
entradas (y un JDK 21) produce el mismo AAR byte a byte, en cualquier ruta.
El workflow `Build FFmpeg` lo recompila en GitHub Actions y lo compara con los
hashes publicados.

### Volver a enlazar con otro FFmpeg (LGPL-2.1, sección 6)

`libffmpegJNI.so` enlaza FFmpeg de forma estática. Para usar un FFmpeg
modificado, sustituye `external/ffmpeg` (o el árbol de `ffmpeg-<tag>-source.tar.gz`)
y ejecuta `./build-decoder.sh`; el AAR resultante sustituye al de la app.
`libffmpeg_rtsp.so` es entero código de FFmpeg con los parches de `patches/cli`:
`./build-cli.sh` lo recompila igual.

### Licencias

- Scripts de este repositorio: [Apache-2.0](LICENSE).
- Media3 (`decoder_ffmpeg`): Apache-2.0.
- FFmpeg: LGPL-2.1 o posterior. Ver `external/ffmpeg/LICENSE.md` y `COPYING.LGPLv2.1`.

---

## English

Source code and build scripts of the two FFmpeg components used by EasIPTV Player,
built with [FFmpeg](https://ffmpeg.org) under the **LGPL-2.1 or later**:
no `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.

- The **audio decoder**: the official `decoder_ffmpeg` extension of
  [androidx/media](https://github.com/androidx/media) (Media3).
- The **command line tool for RTSP** (since `app-1.5.0-2`): the `ffmpeg` program, which the
  app runs to remux an RTSP session into MPEG-TS (`-c copy -f mpegts pipe:1`) or, since
  `app-1.5.0-4`, into a fragmented MP4 file to record audio MPEG-TS does not carry, such as
  G.711, AMR or Opus (`-f mov`, `-f 3gp` or `-f mp4`; `app-1.5.0-3` used Matroska on a pipe,
  now removed). No encoders
  or decoders: only the protocols, demuxers, parsers and the muxers it needs. Each ABI ships
  as `libffmpeg_rtsp.so` so that Android installs it in the app's native library directory,
  the only one it may execute files from.

### Contents

| Path | Content |
|---|---|
| `external/media` | androidx/media submodule pinned to the Media3 tag used by the app |
| `external/ffmpeg` | FFmpeg submodule pinned to an official release tag |
| `versions.env` | Every pinned input: commits, NDK, CMake, minimum API, ABIs and decoders |
| `build-decoder.sh` | Reproducible build of the `lib-decoder-ffmpeg` AAR |
| `build-cli.sh` | Reproducible build of the `lib-ffmpeg-rtsp` AAR (the executable of each ABI); runs after `build-decoder.sh` |
| `gradle/easiptv-decoder.init.gradle` | Pins NDK, CMake, minSdk, ABIs and paths without changing Media3 sources |
| `patches/cli` | Patches to FFmpeg that only `build-cli.sh` applies (published in `changes.diff`) |
| `scripts/check-relro.sh` | Checks that the RELRO of 64-bit `.so` files is safe with 16 KB pages |
| `scripts/verify-checksums.sh` | Compares a build with the SHA-256 sums of a release |
| `releases/<tag>/SHA256SUMS` | Published checksums of each release |

Decoders (audio only): `aac mp3 ac3 eac3 dca mlp truehd flac alac pcm_mulaw pcm_alaw opus vorbis`.
None of them is GPL according to FFmpeg's `LICENSE.md`. ABIs: `armeabi-v7a arm64-v8a x86 x86_64`,
minimum API 29, NDK r28c (64-bit `.so` files are 16 KB aligned).

RTSP tool: protocols `tcp udp rtp pipe file`, demuxers `rtsp rtp sdp mpegts`, muxers
`mpegts mov mp4 3gp`, parsers `h264 hevc aac aac_latm ac3 mpegaudio mpeg4video mpegvideo amr`
and the `setts` bitstream filter (it gives every packet the timestamps MPEG-TS needs and RTP
lacks). `build-cli.sh` fails if `config_components.h` enables any encoder or decoder, or any
protocol other than those (plus `http`, which `rtsp` selects; no TLS).

**The `file` protocol is there to write the recording only.** The app restricts the input with
`-protocol_whitelist tcp,udp,rtp` (an input option): the input then cannot open `file:` or
paths, `pipe:` or `http` (nor RTSP over HTTP), RTSP redirects are only followed over RTSP/TCP,
and `concat:`, `subfile:`, `fd:` and TLS are not built. `patches/cli` holds three small patches
to FFmpeg n6.0.1, for this tool only: the picture size from the parser, the AMR frames of RTP
one by one, and the duration of a fragmented MP4 when it is closed.

### Releases and tags

Every EasIPTV Player version that ships this decoder has a tag
`app-<app version>-<n>` (for example `app-1.5.0-1`) and a release with:

- the AAR `lib-decoder-ffmpeg-<Media3>-app-<version>-<n>.aar`;
- since `app-1.5.0-2`, the AAR `lib-ffmpeg-rtsp-<FFmpeg>-app-<version>-<n>.aar` with `jni/<abi>/libffmpeg_rtsp.so`;
- `ffmpeg-<tag>-source.tar.gz`: the **exact** FFmpeg source code that was built;
- `media3-decoder_ffmpeg-<Media3>-source.tar.gz`: the JNI wrapper sources;
- `changes.diff`: changes to FFmpeg and Media3 (since `app-1.5.0-3`, the patches of
  `patches/cli`, used by the RTSP tool only; the decoder builds FFmpeg unmodified);
- since `app-1.5.0-3`, `COPYING.LGPLv2.1`: the license text of FFmpeg;
- `BUILD.md`: full `configure` lines, commits, NDK, decoders and checks of the `.so` files;
- `SHA256SUMS`.

### Local build (Linux x86-64)

```bash
git clone --recurse-submodules --shallow-submodules https://github.com/alpargataman/easiptv-ffmpeg.git
cd easiptv-ffmpeg
source versions.env
sdkmanager --install "ndk;$NDK_VERSION" "cmake;$CMAKE_VERSION"
ANDROID_HOME=~/Android/Sdk JAVA_HOME=/path/to/jdk-21 ./build-decoder.sh
ANDROID_HOME=~/Android/Sdk ./build-cli.sh
bash scripts/verify-checksums.sh releases/app-1.5.0-4/SHA256SUMS
```

Output goes to `dist/`. The build is reproducible: the same inputs (and a JDK 21)
give a byte-identical AAR in any directory. The `Build FFmpeg` workflow rebuilds
it on GitHub Actions and compares it with the published checksums.

### Relinking with another FFmpeg (LGPL-2.1, section 6)

`libffmpegJNI.so` links FFmpeg statically. To use a modified FFmpeg, replace
`external/ffmpeg` (or the tree from `ffmpeg-<tag>-source.tar.gz`) and run
`./build-decoder.sh`; the resulting AAR replaces the one in the app.
`libffmpeg_rtsp.so` is FFmpeg code only, plus the patches of `patches/cli`:
`./build-cli.sh` rebuilds it the same way.

### Licenses

- Scripts in this repository: [Apache-2.0](LICENSE).
- Media3 (`decoder_ffmpeg`): Apache-2.0.
- FFmpeg: LGPL-2.1 or later. See `external/ffmpeg/LICENSE.md` and `COPYING.LGPLv2.1`.
