# cuda_playground

Starter CUDA + C++20 project. Targets Pascal (sm_61, GTX 1050 Ti) by default.

## Prerequisites

| Tool | Min version | Install |
|---|---|---|
| NVIDIA driver | 560 | `sudo apt install nvidia-driver-560 && sudo reboot` |
| CUDA Toolkit | 12.6 | https://developer.nvidia.com/cuda-12-6-0-download-archive (Linux → x86_64 → Ubuntu → 24.04 → deb local) |
| GCC | 13 | `sudo apt install g++-13` (already on Mint 22.3) |
| CMake | 3.24 | already installed (3.28) |
| Ninja | any | `sudo apt install ninja-build` |

After installing the toolkit, add to `~/.bashrc`:

```bash
export PATH=/usr/local/cuda-12.6/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
```

Verify: `nvcc --version` and `nvidia-smi`.

## Build & run

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/vector_add
```

Override the GPU architecture (e.g. for an Ampere card):

```bash
cmake -S . -B build -G Ninja -DCMAKE_CUDA_ARCHITECTURES=86
```

Common arch values: Pascal `61`, Turing `75`, Ampere `80`/`86`, Ada `89`, Hopper `90`.

## IDE

VS Code with these extensions:
- `NVIDIA.nsight-vscode-edition` — CUDA-GDB debugging, `.cu` syntax
- `ms-vscode.cpptools`
- `ms-vscode.cmake-tools`

Open the folder; CMake Tools will pick up `CMakeLists.txt`. `compile_commands.json` is exported automatically for clangd / IntelliSense.

## Layout

```
include/   public headers (.cuh, .h)
src/       sources (.cpp, .cu)
build/     out-of-source build (gitignored)
```
