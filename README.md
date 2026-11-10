# easiptv-ffmpeg

[Español](#español) · [English](#english)

This software uses libraries from the FFmpeg project under the LGPLv2.1.

---

## Español

Código fuente y scripts de compilación del decodificador de audio FFmpeg que usa
EasIPTV Player. Es la extensión
oficial `decoder_ffmpeg` de [androidx/media](https://github.com/androidx/media)
(Media3), compilada con [FFmpeg](https://ffmpeg.org) bajo **LGPL-2.1 o posterior**:
sin `--enable-gpl`, `--enable-nonfree` ni `--enable-version3`.

### Qué contiene

| Ruta | Contenido |
|---|---|
| `external/media` | Submódulo de androidx/media fijado en el tag de Media3 que usa la app |
| `external/ffmpeg` | Submódulo de FFmpeg fijado en un tag oficial |
| `versions.env` | Todas las entradas fijadas: commits, NDK, CMake, API mínima, ABIs y decoders |
| `build-decoder.sh` | Compilación reproducible del AAR `lib-decoder-ffmpeg` |
| `gradle/easiptv-decoder.init.gradle` | Fija NDK, CMake, minSdk, ABIs y rutas sin tocar el código de Media3 |
| `scripts/check-relro.sh` | Comprueba que el RELRO de las `.so` de 64 bits es seguro con páginas de 16 KB |
| `scripts/verify-checksums.sh` | Compara una compilación con los SHA-256 de una release |
| `releases/<tag>/SHA256SUMS` | Hashes publicados de cada release |

Decoders incluidos (solo audio): `aac mp3 ac3 eac3 dca mlp truehd flac alac pcm_mulaw pcm_alaw opus vorbis`.
Ninguno es GPL según el `LICENSE.md` de FFmpeg. ABIs: `armeabi-v7a arm64-v8a x86 x86_64`,
API mínima 29, NDK r28c (las `.so` de 64 bits quedan alineadas a 16 KB).

### Releases y tags

Cada versión de EasIPTV Player que incluye este decodificador tiene un tag
`app-<versión de la app>-<n>` (por ejemplo, `app-1.5.0-1`) y una release con:

- el AAR `lib-decoder-ffmpeg-<Media3>-app-<versión>-<n>.aar`;
- `ffmpeg-<tag>-source.tar.gz`: el código fuente **exacto** de FFmpeg compilado;
- `media3-decoder_ffmpeg-<Media3>-source.tar.gz`: el código del envoltorio JNI;
- `changes.diff`: los cambios sobre FFmpeg y Media3 (vacío si no hay ninguno);
- `BUILD.md`: líneas de `configure` completas, commits, NDK, decoders y comprobaciones de las `.so`;
- `SHA256SUMS`.

### Compilar en local (Linux x86-64)

```bash
git clone --recurse-submodules --shallow-submodules https://github.com/alpargataman/easiptv-ffmpeg.git
cd easiptv-ffmpeg
source versions.env
sdkmanager --install "ndk;$NDK_VERSION" "cmake;$CMAKE_VERSION"
ANDROID_HOME=~/Android/Sdk JAVA_HOME=/ruta/a/jdk-21 ./build-decoder.sh
bash scripts/verify-checksums.sh releases/app-1.5.0-1/SHA256SUMS
```

El resultado queda en `dist/`. La compilación es reproducible: con las mismas
entradas (y un JDK 21) produce el mismo AAR byte a byte, en cualquier ruta.
El workflow `Build decoder` lo recompila en GitHub Actions y lo compara con los
hashes publicados.

### Volver a enlazar con otro FFmpeg (LGPL-2.1, sección 6)

`libffmpegJNI.so` enlaza FFmpeg de forma estática. Para usar un FFmpeg
modificado, sustituye `external/ffmpeg` (o el árbol de `ffmpeg-<tag>-source.tar.gz`)
y ejecuta `./build-decoder.sh`; el AAR resultante sustituye al de la app.

### Licencias

- Scripts de este repositorio: [Apache-2.0](LICENSE).
- Media3 (`decoder_ffmpeg`): Apache-2.0.
- FFmpeg: LGPL-2.1 o posterior. Ver `external/ffmpeg/LICENSE.md` y `COPYING.LGPLv2.1`.

---

## English

Source code and build scripts of the FFmpeg audio decoder used by
EasIPTV Player. It is the
official `decoder_ffmpeg` extension of [androidx/media](https://github.com/androidx/media)
(Media3), built with [FFmpeg](https://ffmpeg.org) under the **LGPL-2.1 or later**:
no `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.

### Contents

| Path | Content |
|---|---|
| `external/media` | androidx/media submodule pinned to the Media3 tag used by the app |
| `external/ffmpeg` | FFmpeg submodule pinned to an official release tag |
| `versions.env` | Every pinned input: commits, NDK, CMake, minimum API, ABIs and decoders |
| `build-decoder.sh` | Reproducible build of the `lib-decoder-ffmpeg` AAR |
| `gradle/easiptv-decoder.init.gradle` | Pins NDK, CMake, minSdk, ABIs and paths without changing Media3 sources |
| `scripts/check-relro.sh` | Checks that the RELRO of 64-bit `.so` files is safe with 16 KB pages |
| `scripts/verify-checksums.sh` | Compares a build with the SHA-256 sums of a release |
| `releases/<tag>/SHA256SUMS` | Published checksums of each release |

Decoders (audio only): `aac mp3 ac3 eac3 dca mlp truehd flac alac pcm_mulaw pcm_alaw opus vorbis`.
None of them is GPL according to FFmpeg's `LICENSE.md`. ABIs: `armeabi-v7a arm64-v8a x86 x86_64`,
minimum API 29, NDK r28c (64-bit `.so` files are 16 KB aligned).

### Releases and tags

Every EasIPTV Player version that ships this decoder has a tag
`app-<app version>-<n>` (for example `app-1.5.0-1`) and a release with:

- the AAR `lib-decoder-ffmpeg-<Media3>-app-<version>-<n>.aar`;
- `ffmpeg-<tag>-source.tar.gz`: the **exact** FFmpeg source code that was built;
- `media3-decoder_ffmpeg-<Media3>-source.tar.gz`: the JNI wrapper sources;
- `changes.diff`: changes to FFmpeg and Media3 (empty when there are none);
- `BUILD.md`: full `configure` lines, commits, NDK, decoders and checks of the `.so` files;
- `SHA256SUMS`.

### Local build (Linux x86-64)

```bash
git clone --recurse-submodules --shallow-submodules https://github.com/alpargataman/easiptv-ffmpeg.git
cd easiptv-ffmpeg
source versions.env
sdkmanager --install "ndk;$NDK_VERSION" "cmake;$CMAKE_VERSION"
ANDROID_HOME=~/Android/Sdk JAVA_HOME=/path/to/jdk-21 ./build-decoder.sh
bash scripts/verify-checksums.sh releases/app-1.5.0-1/SHA256SUMS
```

Output goes to `dist/`. The build is reproducible: the same inputs (and a JDK 21)
give a byte-identical AAR in any directory. The `Build decoder` workflow rebuilds
it on GitHub Actions and compares it with the published checksums.

### Relinking with another FFmpeg (LGPL-2.1, section 6)

`libffmpegJNI.so` links FFmpeg statically. To use a modified FFmpeg, replace
`external/ffmpeg` (or the tree from `ffmpeg-<tag>-source.tar.gz`) and run
`./build-decoder.sh`; the resulting AAR replaces the one in the app.

### Licenses

- Scripts in this repository: [Apache-2.0](LICENSE).
- Media3 (`decoder_ffmpeg`): Apache-2.0.
- FFmpeg: LGPL-2.1 or later. See `external/ffmpeg/LICENSE.md` and `COPYING.LGPLv2.1`.
