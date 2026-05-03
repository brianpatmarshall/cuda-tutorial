# CUDA + C++ Programming Tutorial

A hands-on tour of CUDA, starting from "what is a GPU?" and ending at warp-level primitives, async pipelines, and library composition. Examples assume CUDA 12.6 + C++20 + the project scaffold from this repo (Pascal sm_61, GTX 1050 Ti). Every snippet is small enough to paste into a `.cu` file and try.

---

## Table of contents

1. [The CUDA mental model](#1-the-cuda-mental-model)
2. [The hardware model](#2-the-hardware-model)
3. [Programming model: grids, blocks, threads](#3-programming-model-grids-blocks-threads)
4. [Your first kernel](#4-your-first-kernel)
5. [Host ↔ device memory](#5-host--device-memory)
6. [The memory hierarchy](#6-the-memory-hierarchy)
7. [Launch configuration & occupancy](#7-launch-configuration--occupancy)
8. [Synchronization](#8-synchronization)
9. [Atomics](#9-atomics)
10. [Streams and concurrency](#10-streams-and-concurrency)
11. [Error handling](#11-error-handling)
12. [Performance fundamentals](#12-performance-fundamentals)
13. [Warp-level primitives & cooperative groups](#13-warp-level-primitives--cooperative-groups)
14. [Unified memory](#14-unified-memory)
15. [Pinned memory & async transfer](#15-pinned-memory--async-transfer)
16. [Libraries: Thrust, CUB, cuBLAS, cuFFT](#16-libraries-thrust-cub-cublas-cufft)
17. [Debugging & profiling](#17-debugging--profiling)
18. [Modern C++ in CUDA](#18-modern-c-in-cuda)
19. [Common pitfalls & checklist](#19-common-pitfalls--checklist)
- [Appendix A: Replicating the setup on Windows 11](#appendix-a-replicating-the-setup-on-windows-11)

---

## 1. The CUDA mental model

### Overview
A GPU is a *throughput* processor: thousands of simple cores running the same instruction in lockstep on different data. CUDA is NVIDIA's C++ extension for writing programs that run partly on the **host** (CPU + system RAM) and partly on the **device** (GPU + GPU RAM, called *device memory* or *VRAM*).

You write a function once, mark it `__global__`, and *launch* it as a **grid** of **threads**. Each thread runs the same code on a different element. This is **SIMT** — Single Instruction, Multiple Threads.

### Details
- **Host code** runs on the CPU and is regular C++.
- **Device code** runs on the GPU. It's mostly C++ with restrictions (no exceptions inside kernels, no virtual functions across host/device boundary, no recursion before sm_20, limited stdlib).
- **Kernels** are device functions launched from the host with the special `<<<grid, block>>>` syntax.
- A kernel launch is **asynchronous** — the host returns immediately while the GPU executes.
- Data must usually be **explicitly copied** between host and device (unless you use unified memory).

### Function-space qualifiers

| Qualifier | Callable from | Runs on |
|---|---|---|
| `__host__`   | host | host (default for plain functions) |
| `__device__` | device | device |
| `__global__` | host (and device, dynamic parallelism) | device — **kernel** |
| `__host__ __device__` | both | both (compiled twice) |

### Sample code
```cpp
#include <cstdio>

__device__ int square(int x) { return x * x; }   // device-only helper

__global__ void hello() {                         // kernel
    printf("hello from thread %d, square(threadIdx.x) = %d\n",
           threadIdx.x, square(threadIdx.x));
}

int main() {
    hello<<<1, 8>>>();        // 1 block of 8 threads
    cudaDeviceSynchronize();  // wait for the GPU to finish
}
```

---

## 2. The hardware model

### Overview
A GPU is divided into **Streaming Multiprocessors (SMs)**. Each SM has many CUDA cores, its own register file, shared memory / L1, warp schedulers, and special-function units. When you launch a kernel, the driver assigns thread *blocks* to SMs; once a block is on an SM it stays there until it finishes.

### Details
- **Warp** = 32 threads executed in lockstep by one SM. The atom of GPU execution.
- **SM** runs many warps concurrently (e.g., 64 on Pascal). When one warp stalls on memory, another runs — this is how GPUs hide latency.
- **Compute capability** (e.g., `6.1` for GTX 1050 Ti, `8.6` for RTX 30-series, `9.0` for H100) defines the feature set: max threads per block, shared mem size, supported instructions.
- **Resources per SM are finite**: registers, shared memory, max resident warps. Using more of any one limits how many blocks/warps the SM can run concurrently → *occupancy*.
- **Branch divergence**: if threads in a warp take different paths through an `if`, the warp executes both paths serially with the inactive lanes masked off. Avoid divergence inside warps for hot loops.

### Sample code: query the device
```cpp
#include <cstdio>
#include <cuda_runtime.h>

int main() {
    int dev = 0;
    cudaDeviceProp p{};
    cudaGetDeviceProperties(&p, dev);

    printf("Device 0: %s\n", p.name);
    printf("  Compute capability: %d.%d\n", p.major, p.minor);
    printf("  SMs:                %d\n", p.multiProcessorCount);
    printf("  Warp size:          %d\n", p.warpSize);
    printf("  Max threads/block:  %d\n", p.maxThreadsPerBlock);
    printf("  Shared mem/block:   %zu KB\n", p.sharedMemPerBlock / 1024);
    printf("  Global mem:         %.1f GB\n",
           p.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
}
```

---

## 3. Programming model: grids, blocks, threads

### Overview
A kernel launch creates a **grid** of **thread blocks**, each block containing some number of **threads**. Grids and blocks can be 1D, 2D, or 3D — convenient for matching your data shape.

```
grid (gridDim)
  └── block (blockDim)
        └── thread (threadIdx)
```

### Details
Inside a kernel you have these built-ins (all of type `dim3` or `uint3`):
- `gridDim`  — shape of the grid (number of blocks per dimension)
- `blockIdx` — this block's coordinates within the grid
- `blockDim` — shape of each block (threads per dimension)
- `threadIdx` — this thread's coordinates within its block
- `warpSize` — always 32 on current hardware

Standard global-thread-index pattern (1D):
```cpp
const int gid = blockIdx.x * blockDim.x + threadIdx.x;
```

For a problem of size `n`, choose a block size (commonly 128, 256, or 512), then compute the grid size with **ceiling division**:
```cpp
const int block = 256;
const int grid  = (n + block - 1) / block;
kernel<<<grid, block>>>(...);
```

The kernel must guard against out-of-range threads since `grid * block >= n`:
```cpp
if (gid < n) { ... }
```

### Sample code: 2D grid for an image
```cpp
__global__ void invert(unsigned char* img, int w, int h) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    img[y * w + x] = 255 - img[y * w + x];
}

void launch_invert(unsigned char* d_img, int w, int h) {
    dim3 block(16, 16);
    dim3 grid((w + 15) / 16, (h + 15) / 16);
    invert<<<grid, block>>>(d_img, w, h);
}
```

---

## 4. Your first kernel

### Overview
Minimal end-to-end: allocate on the device, copy in, launch, copy out, free. Vector add is the "hello world."

### Details
Kernel launches with `<<<grid, block, sharedBytes, stream>>>`. The last two are optional and default to 0 (no dynamic shared memory) and the default stream.

After a launch, two failure modes exist:
- **Launch failure** (bad config): `cudaGetLastError()` returns non-success immediately.
- **Execution failure** (e.g., illegal address mid-kernel): only surfaces on the next sync point.

Always check both.

### Sample code
```cpp
#include <cuda_runtime.h>
#include <cstdio>
#include <vector>

__global__ void add(const float* a, const float* b, float* c, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    constexpr int n = 1 << 20;
    std::vector<float> ha(n, 1.0f), hb(n, 2.0f), hc(n);

    float *da, *db, *dc;
    cudaMalloc(&da, n * sizeof(float));
    cudaMalloc(&db, n * sizeof(float));
    cudaMalloc(&dc, n * sizeof(float));

    cudaMemcpy(da, ha.data(), n * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(db, hb.data(), n * sizeof(float), cudaMemcpyHostToDevice);

    constexpr int block = 256;
    const     int grid  = (n + block - 1) / block;
    add<<<grid, block>>>(da, db, dc, n);

    cudaMemcpy(hc.data(), dc, n * sizeof(float), cudaMemcpyDeviceToHost);

    printf("c[0]=%f c[n-1]=%f\n", hc[0], hc[n - 1]);

    cudaFree(da); cudaFree(db); cudaFree(dc);
}
```

---

## 5. Host ↔ device memory

### Overview
Three classic ways to move data:
1. **Explicit** — `cudaMalloc` + `cudaMemcpy`. Most control, most ceremony.
2. **Unified memory** — `cudaMallocManaged`. Single pointer, system migrates pages as needed.
3. **Pinned (page-locked) host memory** — `cudaMallocHost`. Required for true async transfers.

### Details
- `cudaMemcpy` is **synchronous with the host**: it blocks until done.
- `cudaMemcpyAsync` is async **only** if the host buffer is pinned; otherwise it silently degrades.
- `cudaMemset(ptr, value, bytes)` zeroes/fills device memory.
- Allocations are *expensive*. Reuse buffers across kernel launches.
- Free with `cudaFree` (matches `cudaMalloc` *and* `cudaMallocManaged`); pinned host memory uses `cudaFreeHost`.

| Direction | Enum |
|---|---|
| Host → device | `cudaMemcpyHostToDevice` |
| Device → host | `cudaMemcpyDeviceToHost` |
| Device → device | `cudaMemcpyDeviceToDevice` |
| Auto-detect | `cudaMemcpyDefault` (works only for unified-addressable pointers) |

### Sample code: a tiny RAII wrapper
```cpp
template <typename T>
class DeviceBuffer {
public:
    explicit DeviceBuffer(std::size_t n) : n_(n) {
        cudaMalloc(&p_, n * sizeof(T));
    }
    ~DeviceBuffer() { cudaFree(p_); }

    DeviceBuffer(const DeviceBuffer&) = delete;
    DeviceBuffer& operator=(const DeviceBuffer&) = delete;

    T* data() { return p_; }
    const T* data() const { return p_; }
    std::size_t size() const { return n_; }

    void copy_from_host(const T* src) {
        cudaMemcpy(p_, src, n_ * sizeof(T), cudaMemcpyHostToDevice);
    }
    void copy_to_host(T* dst) const {
        cudaMemcpy(dst, p_, n_ * sizeof(T), cudaMemcpyDeviceToHost);
    }

private:
    T*          p_ = nullptr;
    std::size_t n_ = 0;
};
```

---

## 6. The memory hierarchy

### Overview
GPU memory is a **hierarchy** of speed-vs-size tradeoffs. Fast memory is small and per-thread or per-block; slow memory is huge and global. Performance is overwhelmingly about choosing the right level.

| Space | Size (typical) | Latency | Scope | Lifetime | How to declare |
|---|---|---|---|---|---|
| **Registers** | ~64K 32-bit per SM | 1 cycle | per-thread | thread | local variables |
| **Local memory** | spill area in global | hundreds of cycles | per-thread | thread | compiler spills |
| **Shared memory** | 48–164 KB / SM | ~30 cycles | per-block | block | `__shared__` |
| **L1 / L2 cache** | KB / MB | tens–hundreds | per-SM / chip | hardware | automatic |
| **Constant memory** | 64 KB total | 1 cycle (cached) | grid | program | `__constant__` |
| **Global memory** | GB | 400–800 cycles | grid | program | `cudaMalloc` |
| **Texture / surface** | global, cached | hundreds | grid | program | texture objects |

### Details
- **Registers** are the fastest. Each thread gets its own. Too many → spilling to local memory (slow).
- **Shared memory** is a programmer-managed scratchpad — software-controlled cache shared by threads in a block. Use it to stage data, then reuse.
- **Constant memory** is broadcast-friendly: when all threads in a warp read the same address, it's a single cycle.
- **Global memory** is the big one (your `cudaMalloc` lives here). Access pattern matters enormously — see §12 on coalescing.

### Sample code: tiled matrix multiply with shared memory
```cpp
constexpr int TILE = 16;

__global__ void matmul_tiled(const float* A, const float* B, float* C, int N) {
    __shared__ float As[TILE][TILE];
    __shared__ float Bs[TILE][TILE];

    const int row = blockIdx.y * TILE + threadIdx.y;
    const int col = blockIdx.x * TILE + threadIdx.x;

    float acc = 0.0f;
    for (int t = 0; t < N / TILE; ++t) {
        As[threadIdx.y][threadIdx.x] = A[row * N + t * TILE + threadIdx.x];
        Bs[threadIdx.y][threadIdx.x] = B[(t * TILE + threadIdx.y) * N + col];
        __syncthreads();                       // tile loaded by all threads

        for (int k = 0; k < TILE; ++k) {
            acc += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        }
        __syncthreads();                       // before next tile overwrite
    }
    C[row * N + col] = acc;
}
```
Each element of `A` and `B` is read from global memory **once per tile** instead of once per output — a roughly 16× reduction in global traffic.

---

## 7. Launch configuration & occupancy

### Overview
Picking `<<<grid, block>>>` well is one of the highest-leverage tuning decisions. **Occupancy** = (active warps per SM) / (max possible). Higher occupancy gives the SM more options to hide memory latency, but past a point more occupancy doesn't help and can hurt (more register pressure → spills).

### Details
- **Block size**: pick a multiple of 32 (warp size). Common sweet spots: **128, 256, 512**. 1024 is the hardware max but often hurts occupancy.
- **Grid size**: launch enough blocks to cover your data *and* to keep all SMs busy — typically `>= 4 * SM_count` blocks.
- Use `cudaOccupancyMaxPotentialBlockSize` to let the runtime suggest a block size based on the kernel's register/shared-mem usage.
- Compile with `--ptxas-options=-v` (or CMake's `set_target_properties(... PROPERTIES CUDA_RESOLVE_DEVICE_SYMBOLS ON)` plus `-Xptxas -v`) to see register/shared-mem use per kernel.

### Sample code
```cpp
int min_grid = 0, best_block = 0;
cudaOccupancyMaxPotentialBlockSize(&min_grid, &best_block, my_kernel);
const int grid = (n + best_block - 1) / best_block;
my_kernel<<<grid, best_block>>>(...);
```

To see occupancy for an exact config:
```cpp
int active_blocks = 0;
cudaOccupancyMaxActiveBlocksPerMultiprocessor(
    &active_blocks, my_kernel, /*blockSize*/ 256, /*dynamicSharedMem*/ 0);
```

---

## 8. Synchronization

### Overview
Two scopes matter most:
- **Within a block**: `__syncthreads()` — all threads in the block reach this point before any continues.
- **Across the grid / between kernels**: `cudaDeviceSynchronize()` (host) or stream-level events.

### Details
- `__syncthreads()` must be reached by **all** threads in the block. Putting it inside a divergent `if` causes deadlock.
- `__syncwarp()` synchronizes a single warp (cheaper, needed on Volta+ where warps can diverge independently).
- `cudaStreamSynchronize(stream)` waits only for one stream.
- `cudaEventRecord` + `cudaEventSynchronize` lets you wait for a specific point in a stream — also used for timing.

### Sample code: parallel reduction with a barrier
```cpp
__global__ void reduce_sum(const float* in, float* out, int n) {
    __shared__ float s[256];
    const int tid = threadIdx.x;
    const int gid = blockIdx.x * blockDim.x + tid;

    s[tid] = (gid < n) ? in[gid] : 0.0f;
    __syncthreads();

    for (int stride = blockDim.x / 2; stride > 0; stride /= 2) {
        if (tid < stride) s[tid] += s[tid + stride];
        __syncthreads();                        // every thread must hit this
    }
    if (tid == 0) out[blockIdx.x] = s[0];       // one partial sum per block
}
```
Then either launch a second pass to reduce the partials, or finish on the host.

---

## 9. Atomics

### Overview
When many threads want to update the same location, regular writes race. **Atomic operations** serialize updates safely.

### Details
- `atomicAdd`, `atomicMin`, `atomicMax`, `atomicCAS`, `atomicExch`, `atomicAnd/Or/Xor` — for `int`, `unsigned`, `unsigned long long`, `float` (add only), `double` (add, sm_60+).
- Atomics on **shared** memory are much faster than on global — reduce within a block first, then one atomic to global.
- Heavy contention on a single address kills performance. Restructure to spread writes (e.g., per-block partials).

### Sample code: histogram with shared-memory atomics
```cpp
__global__ void histogram_256(const unsigned char* data, int n, unsigned* out) {
    __shared__ unsigned local[256];
    if (threadIdx.x < 256) local[threadIdx.x] = 0;
    __syncthreads();

    const int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid < n) atomicAdd(&local[data[gid]], 1u);
    __syncthreads();

    if (threadIdx.x < 256) atomicAdd(&out[threadIdx.x], local[threadIdx.x]);
}
```

---

## 10. Streams and concurrency

### Overview
A **stream** is an ordered queue of GPU work. Operations within a stream run in order; operations in *different* streams can overlap — kernel ↔ kernel, kernel ↔ memcpy, even memcpy ↔ memcpy in opposite directions.

### Details
- The "default stream" (stream 0) is implicit and synchronizing — most operations on it serialize against everything else. **Create your own streams for concurrency.**
- For overlap of memcpy with compute, the host buffer **must be pinned** (`cudaMallocHost` / `cudaHostAlloc`).
- Events (`cudaEvent_t`) are the way to synchronize between streams without going through the host.
- Pattern: **double-buffer** input chunks. While stream A computes on chunk *i*, stream B copies chunk *i+1*.

### Sample code: overlap copy and compute
```cpp
cudaStream_t s1, s2;
cudaStreamCreate(&s1);
cudaStreamCreate(&s2);

float *h_a, *h_b, *d_a, *d_b;
cudaMallocHost(&h_a, bytes);  cudaMallocHost(&h_b, bytes);    // pinned
cudaMalloc(&d_a, bytes);      cudaMalloc(&d_b, bytes);

cudaMemcpyAsync(d_a, h_a, bytes, cudaMemcpyHostToDevice, s1);
kernel<<<g, b, 0, s1>>>(d_a);

cudaMemcpyAsync(d_b, h_b, bytes, cudaMemcpyHostToDevice, s2);
kernel<<<g, b, 0, s2>>>(d_b);                                 // runs concurrently with s1

cudaStreamSynchronize(s1);
cudaStreamSynchronize(s2);
cudaStreamDestroy(s1);
cudaStreamDestroy(s2);
```

### Timing with events
```cpp
cudaEvent_t start, stop;
cudaEventCreate(&start);  cudaEventCreate(&stop);
cudaEventRecord(start);
kernel<<<g, b>>>(...);
cudaEventRecord(stop);
cudaEventSynchronize(stop);
float ms = 0.0f;
cudaEventElapsedTime(&ms, start, stop);
```

---

## 11. Error handling

### Overview
The CUDA runtime returns `cudaError_t`. Most bugs surface as `cudaErrorIllegalAddress` or `cudaErrorInvalidConfiguration` — useless without context. Wrap every call.

### Details
- Async kernel errors are reported on the **next** sync point or runtime call. To catch them at the launch site, follow each launch with `cudaGetLastError()` and (in debug builds) `cudaDeviceSynchronize()`.
- `cudaGetErrorString(err)` gives the human-readable name; `cudaGetErrorName(err)` gives the symbol.
- Once a context hits a "sticky" error (illegal address, etc.), **all** subsequent calls fail until you destroy the context. Run under `compute-sanitizer` to find the original cause.

### Sample code: a CHECK macro
```cpp
#include <cuda_runtime.h>
#include <stdexcept>
#include <string>

#define CUDA_CHECK(expr) do {                                                 \
    cudaError_t _e = (expr);                                                  \
    if (_e != cudaSuccess) {                                                  \
        throw std::runtime_error(std::string(#expr) + " failed: " +           \
                                 cudaGetErrorString(_e));                     \
    }                                                                         \
} while (0)

#define CUDA_CHECK_LAST_LAUNCH() do {                                         \
    CUDA_CHECK(cudaGetLastError());          /* catches launch errors */      \
    CUDA_CHECK(cudaDeviceSynchronize());     /* catches in-kernel errors */   \
} while (0)
```
Use in debug builds; drop the `cudaDeviceSynchronize` in release for performance.

---

## 12. Performance fundamentals

### Overview
Three ideas account for most CUDA performance gaps versus naive code:

1. **Memory coalescing** — consecutive threads should access consecutive addresses.
2. **Avoiding warp divergence** — branches inside a warp serialize.
3. **Shared-memory bank conflicts** — multiple threads of a warp hitting the same bank serialize.

### Details

**Coalescing.** Global memory is read in 32/64/128-byte transactions. If thread *i* in a warp reads `a[i]`, the warp's 32 reads coalesce into 1–2 transactions. If it reads `a[i * stride]` with stride > 1, you get up to 32 separate transactions — same instructions, ~32× more memory traffic. Lay out **structures of arrays**, not arrays of structures, for hot loops.

**Divergence.** `if (threadIdx.x % 2)` makes half the warp idle. Restructure data so all threads in a warp take the same branch, or accept the cost on cold paths.

**Bank conflicts.** Shared memory is split into 32 banks of 4 bytes. A warp can read 32 different banks in one cycle. If two threads hit the *same bank* at *different addresses*, they serialize. Padding (`s[TILE][TILE+1]`) is a classic fix.

**Other principles:**
- **Arithmetic intensity** = FLOPs / bytes moved. Low-intensity kernels are *memory-bound*; you can't go faster than the GPU's bandwidth (~250 GB/s on a 1050 Ti, ~3 TB/s on H100).
- **Warm up** before timing; the first launch JITs and pays one-time costs.
- **Use `--use_fast_math`** for ~free speed if you don't need IEEE precision.

### Sample code: AoS vs SoA
```cpp
// Bad: array of structs — strided access
struct Particle { float x, y, z, vx, vy, vz; };
__global__ void step_aos(Particle* p, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p[i].x += p[i].vx;       // each thread reads ~24 strided bytes
}

// Good: struct of arrays — coalesced
struct Particles { float *x, *y, *z, *vx, *vy, *vz; };
__global__ void step_soa(Particles p, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) p.x[i] += p.vx[i];        // contiguous reads, fully coalesced
}
```

---

## 13. Warp-level primitives & cooperative groups

### Overview
Threads within a warp can communicate without going through shared memory using **warp shuffle** intrinsics. **Cooperative groups** wraps these in a typed, composable API.

### Details
- `__shfl_sync(mask, val, src_lane)` — read `val` from another lane.
- `__shfl_down_sync`, `__shfl_up_sync`, `__shfl_xor_sync` — common patterns (reductions, scans, butterflies).
- `__ballot_sync(mask, pred)` — gather a 32-bit mask of which lanes' predicate is true.
- The `mask` argument is which lanes are participating (`0xFFFFFFFF` = all 32).
- **Cooperative groups** (`#include <cooperative_groups.h>`): `thread_block`, `tiled_partition<32>`, `coalesced_threads()`, plus `reduce`, `inclusive_scan`, etc.

### Sample code: warp-level sum reduction
```cpp
__inline__ __device__ float warp_reduce_sum(float val) {
    for (int offset = 16; offset > 0; offset /= 2) {
        val += __shfl_down_sync(0xFFFFFFFF, val, offset);
    }
    return val;       // lane 0 holds the sum
}

__global__ void block_sum(const float* in, float* out, int n) {
    const int gid = blockIdx.x * blockDim.x + threadIdx.x;
    float v = (gid < n) ? in[gid] : 0.0f;
    v = warp_reduce_sum(v);
    if ((threadIdx.x & 31) == 0) {
        atomicAdd(out, v);     // one atomic per warp, not per thread
    }
}
```

### Cooperative groups version
```cpp
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

__global__ void block_sum_cg(const float* in, float* out, int n) {
    auto block = cg::this_thread_block();
    auto warp  = cg::tiled_partition<32>(block);

    const int gid = blockIdx.x * blockDim.x + threadIdx.x;
    float v = (gid < n) ? in[gid] : 0.0f;
    v = cg::reduce(warp, v, cg::plus<float>());
    if (warp.thread_rank() == 0) atomicAdd(out, v);
}
```

---

## 14. Unified memory

### Overview
`cudaMallocManaged` returns a pointer valid on both host and device. The driver migrates pages on demand when either side touches them. Pleasant to write, can be slower than explicit memcpy if you're not careful.

### Details
- Page faults trigger migration — the first touch on each side is expensive.
- `cudaMemPrefetchAsync(ptr, bytes, device, stream)` lets you hint the migration up front.
- `cudaMemAdvise` adds long-lived hints (e.g., `cudaMemAdviseSetPreferredLocation`).
- Great for prototyping, irregular access patterns, and when data structure shape isn't known up front. For dense, predictable workloads, explicit `cudaMemcpy` usually wins.

### Sample code
```cpp
int n = 1 << 20;
float* a;
cudaMallocManaged(&a, n * sizeof(float));

for (int i = 0; i < n; ++i) a[i] = i;            // host writes — pages live on host

cudaMemPrefetchAsync(a, n * sizeof(float), 0);   // hint: move to GPU 0
square<<<(n + 255) / 256, 256>>>(a, n);
cudaDeviceSynchronize();

printf("%f\n", a[42]);                           // read on host — migrates back
cudaFree(a);
```

---

## 15. Pinned memory & async transfer

### Overview
Regular `malloc`'d host memory is pageable — the OS may move it. The DMA engine that copies to the GPU can't tolerate that, so the driver has to copy first to a hidden pinned staging buffer, then to the GPU. Allocating directly with `cudaMallocHost` skips the staging step and unlocks **true async** transfers.

### Details
- 2× faster H↔D copies are common.
- Pinned memory is a system-wide resource; allocating gigabytes hurts the OS.
- `cudaHostAlloc(..., cudaHostAllocMapped)` exposes the pinned host buffer as a device pointer (zero-copy). Useful for small, latency-sensitive transfers; bad for bulk data.
- `cudaHostRegister(ptr, bytes, 0)` pins an existing allocation. Pair with `cudaHostUnregister`.

### Sample code
```cpp
float* h_pinned;
cudaMallocHost(&h_pinned, bytes);            // pinned
// ... fill h_pinned ...

float* d;
cudaMalloc(&d, bytes);

cudaStream_t s; cudaStreamCreate(&s);
cudaMemcpyAsync(d, h_pinned, bytes, cudaMemcpyHostToDevice, s);   // truly async
kernel<<<g, b, 0, s>>>(d);
cudaStreamSynchronize(s);

cudaFreeHost(h_pinned);
cudaFree(d);
cudaStreamDestroy(s);
```

---

## 16. Libraries: Thrust, CUB, cuBLAS, cuFFT

### Overview
Don't roll your own reduction, scan, sort, BLAS, or FFT. NVIDIA ships highly tuned libraries that beat almost any hand-written kernel.

| Library | Use for | Style |
|---|---|---|
| **Thrust** | sort, scan, reduce, transform on vectors | STL-like, header-only, ships with CUDA |
| **CUB** | the same, but lower-level / device-wide / block-level building blocks | header-only, used inside Thrust |
| **cuBLAS** | dense linear algebra (GEMM, GEMV, …) | C API, link `-lcublas` |
| **cuSPARSE** | sparse linear algebra | C API, link `-lcusparse` |
| **cuFFT** | 1D/2D/3D FFTs | C API, link `-lcufft` |
| **cuDNN** | deep-learning primitives (convolutions, etc.) | separate download |
| **cuRAND** | RNGs on the device | C API |

### CMake linking
```cmake
find_package(CUDAToolkit REQUIRED)
target_link_libraries(my_app PRIVATE CUDA::cublas CUDA::cufft CUDA::curand)
```
(Thrust/CUB are headers and need no link.)

### Sample code: Thrust sort
```cpp
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <thrust/sequence.h>
#include <thrust/random.h>

int main() {
    thrust::device_vector<int> d(1 << 20);
    thrust::sequence(d.begin(), d.end());            // 0, 1, 2, ...
    thrust::default_random_engine g;
    thrust::shuffle(d.begin(), d.end(), g);
    thrust::sort(d.begin(), d.end());                // tuned radix sort on GPU
}
```

### Sample code: cuBLAS SGEMM
```cpp
#include <cublas_v2.h>

cublasHandle_t h;
cublasCreate(&h);

const float alpha = 1.0f, beta = 0.0f;
// C = alpha * A * B + beta * C  (column-major, NxN matrices)
cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N,
            N, N, N,
            &alpha, dA, N, dB, N,
            &beta,  dC, N);

cublasDestroy(h);
```

---

## 17. Debugging & profiling

### Overview
Three tools cover almost everything:

| Tool | Use for |
|---|---|
| **`compute-sanitizer`** | Memory errors, race conditions, sync errors. Always run new kernels under it. |
| **`cuda-gdb`** | Step through kernels, set breakpoints in device code. |
| **Nsight Systems** | System-wide timeline: kernels, copies, CPU activity. Where is time going? |
| **Nsight Compute** | Per-kernel deep dive: occupancy, memory throughput, stall reasons. Why is *this* kernel slow? |

### Details
- Compile debug builds with `nvcc -G -g` (device debug info + host debug info). `-G` disables most optimizations — slow but steppable.
- For profiling, use a **release** build but compile with `-lineinfo` so the profiler can map samples to source lines.
- `printf` from inside a kernel works (output flushed at the next sync). Don't ship it — it's slow.

### Sample commands
```bash
# Find memory errors
compute-sanitizer --tool memcheck ./build/vector_add

# Find races on shared memory
compute-sanitizer --tool racecheck ./build/vector_add

# Step through a kernel
cuda-gdb ./build/vector_add
(cuda-gdb) break vector_add_kernel
(cuda-gdb) run

# System-wide timeline (writes a .nsys-rep file; open in Nsight Systems GUI)
nsys profile --stats=true ./build/vector_add

# Per-kernel deep dive (writes .ncu-rep)
ncu --set full ./build/vector_add
```

### CMake for `-lineinfo`
```cmake
target_compile_options(vector_add PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>
)
```

---

## 18. Modern C++ in CUDA

### Overview
nvcc 12.6 supports C++20 in both host and device code (with caveats). Templates, `constexpr`, lambdas, `auto`, fold expressions, structured bindings, ranges (host-only) all work.

### Details
- **Templates** work fully on the device. `__device__` function templates are common.
- **Lambdas** can be `__device__` or `__host__ __device__`. Use `[=] __device__ () { ... }` to capture by value into a kernel-callable lambda. Required `--extended-lambda` flag (CMake: `-DCMAKE_CUDA_FLAGS=--extended-lambda`, or per-target).
- **`constexpr`** functions are implicitly `__host__ __device__` (when compiled with `--expt-relaxed-constexpr`).
- **No virtual dispatch** across host/device. Polymorphism is fine *within* device code if the object was constructed there.
- **No exceptions in device code.** Use status codes / `cuda::std::optional`.
- `cuda::std::` (in `<cuda/std/...>`) is the device-friendly slice of `<std>` — `optional`, `array`, `tuple`, `atomic`, `chrono`, `complex`, etc.

### Sample code: templated kernel + device lambda
```cpp
// Build: nvcc --extended-lambda --expt-relaxed-constexpr
#include <cuda_runtime.h>

template <typename F>
__global__ void apply(float* x, int n, F f) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) x[i] = f(x[i]);
}

void scale(float* d_x, int n, float k) {
    auto times_k = [=] __device__ (float v) { return v * k; };
    apply<<<(n + 255) / 256, 256>>>(d_x, n, times_k);
}
```

### Enabling these flags in CMake
```cmake
target_compile_options(vector_add PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:--extended-lambda>
    $<$<COMPILE_LANGUAGE:CUDA>:--expt-relaxed-constexpr>
)
```

---

## 19. Common pitfalls & checklist

### Pitfalls
- **Forgot to check errors.** A silently-failed launch leaves garbage in output. Wrap every call.
- **Out-of-bounds in the kernel** because `grid * block > n`. Always guard with `if (i < n)`.
- **Sync inside divergent control flow.** `__syncthreads()` in an `if` that not all threads enter = hang.
- **Treating `cudaMemcpyAsync` as async with pageable memory.** It silently degrades to sync. Pin the host buffer.
- **Default-stream serialization.** Mixing default-stream and user-stream operations defeats concurrency.
- **Reading host memory from a kernel.** Plain `malloc`/`new` pointers are *not* device-addressable.
- **Allocating in hot loops.** `cudaMalloc` is expensive. Allocate once, reuse.
- **Strided global access.** Lay out data so consecutive threads touch consecutive bytes.
- **One atomic per thread.** Reduce in shared memory first, then one atomic per block.
- **Tuning blindly.** Profile with Nsight Compute before guessing. The bottleneck is rarely where you think.

### Pre-flight checklist for a new kernel
1. Does each thread compute its global index correctly?
2. Is there an `if (i < n)` bounds guard?
3. Are global memory accesses coalesced?
4. Is shared memory padded to avoid bank conflicts?
5. Are barriers reachable by *every* thread in the block?
6. Are launches followed by `cudaGetLastError` (debug)?
7. Does it run clean under `compute-sanitizer --tool memcheck`?
8. Have you measured before optimizing?

---

## Where to go next

- **Programming Guide** (the canonical reference): https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- **Best Practices Guide**: https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/
- **CUDA samples** repo: https://github.com/NVIDIA/cuda-samples
- **CCCL** (Thrust, CUB, libcu++): https://github.com/NVIDIA/cccl
- **Nsight Compute training**: https://developer.nvidia.com/nsight-compute

For practice in this repo, work through the kernels in §6–§13 by extending the `vector_add` scaffold — replace the kernel, rebuild with `cmake --build build`, and verify with `compute-sanitizer ./build/vector_add`.

---

## Appendix A: Replicating the setup on Windows 11

The project itself is portable — `CMakeLists.txt`, the `.cu` and `.cpp` sources, the `.clang-format`, all of it copies as-is. What changes is the **toolchain around** the project.

### A.1 What stays the same

- `CMakeLists.txt`, `src/`, `include/`, `.clang-format`, `.gitignore`.
- VS Code + the same three extensions (`nvidia.nsight-vscode-edition`, `ms-vscode.cpptools`, `ms-vscode.cmake-tools`).
- Build commands: `cmake -S . -B build -G Ninja ...` then `cmake --build build`.
- The CUDA runtime API and every kernel example in this tutorial.

### A.2 What changes

| Aspect | Linux Mint 22.3 | Windows 11 |
|---|---|---|
| **Host compiler** | GCC 13 | **MSVC** (`cl.exe`) — required by nvcc on Windows. MinGW/Clang are not officially supported. |
| **How to get MSVC** | already installed | **Visual Studio 2022 Community** *or* **Build Tools for Visual Studio 2022** (smaller, no IDE). Pick the *Desktop development with C++* workload. |
| **Driver** | `apt install nvidia-driver-560` | Game Ready / Studio driver from nvidia.com (or via the NVIDIA app). |
| **CUDA Toolkit** | apt + `cuda-keyring` | `.exe` installer from <https://developer.nvidia.com/cuda-downloads> (Windows → x86_64 → 11 → exe local/network). |
| **Package manager** | apt | **winget** (built into Win 11) or Chocolatey. |
| **Shell for build** | any | The **"x64 Native Tools Command Prompt for VS 2022"** — puts `cl.exe` and the Windows SDK on `PATH`. (A plain PowerShell will not work.) |
| **Toolkit path** | `/usr/local/cuda-12.6` | `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.6` |
| **Generator** | Ninja | Ninja still preferred. `-G "Visual Studio 17 2022"` also works (multi-config). |
| **Executable** | `./build/vector_add` | `build\vector_add.exe` |

### A.3 Install steps (winget)

Run from an **elevated** PowerShell:

```powershell
# 1. NVIDIA driver — install via the NVIDIA app, or directly:
#    https://www.nvidia.com/Download/index.aspx
#    Pick a driver compatible with the CUDA toolkit version below.

# 2. Visual Studio Build Tools (MSVC + Windows SDK)
winget install --id Microsoft.VisualStudio.2022.BuildTools --override `
  "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools `
   --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
   --includeRecommended"

# 3. CUDA Toolkit
winget install --id Nvidia.CUDA

# 4. Build tools
winget install --id Kitware.CMake
winget install --id Ninja-build.Ninja
winget install --id Git.Git

# 5. VS Code + extensions
winget install --id Microsoft.VisualStudioCode
code --install-extension nvidia.nsight-vscode-edition
code --install-extension ms-vscode.cpptools
code --install-extension ms-vscode.cmake-tools
```

### A.4 Building the project

Open **Start menu → "x64 Native Tools Command Prompt for VS 2022"**, then:

```cmd
cd C:\path\to\cuda
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
build\vector_add.exe
```

For a different GPU, override the architecture:

```cmd
cmake -S . -B build -G Ninja -DCMAKE_CUDA_ARCHITECTURES=86
```

Look up your card's compute capability with `nvidia-smi` and the table at <https://developer.nvidia.com/cuda-gpus>. Common laptop values: Turing `75`, Ampere `86`, Ada `89`, Blackwell `120`.

### A.5 Windows-specific gotchas

1. **MSVC ↔ CUDA version pairing.** Each CUDA release supports a specific range of MSVC toolset versions. If you install the latest MSVC and an older CUDA, nvcc may bail with *"unsupported Microsoft Visual Studio version."* The CUDA release notes list the supported MSVC range — match them, or pin an older toolset via the VS Installer's *Individual components* tab.
2. **Always build from the x64 Native Tools prompt** (or run `vcvars64.bat` in your shell first). A plain PowerShell or `cmd` will not have `cl.exe` on `PATH`, and CMake's CUDA detection will fail with a confusing error about not finding the host compiler.
3. **Long paths.** Some CUDA include paths exceed Windows' classic 260-character limit. Either keep the project near the drive root (e.g. `C:\src\cuda`) or enable long paths via the registry (`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled = 1`) and Group Policy.
4. **Antivirus on the build directory.** Real-time scanning of `build\` can dramatically slow incremental builds. Add an exclusion for the project's `build` folder if compilation feels sluggish.
5. **`compute-sanitizer` is included** with the Windows toolkit too — same syntax: `compute-sanitizer build\vector_add.exe`.

### A.6 WSL2 alternative

If you'd rather mirror the Linux setup exactly, **WSL2 with Ubuntu 24.04** plus the WSL CUDA driver works well. The `scripts/install.sh` from this repo runs unmodified inside WSL.

| | Native Windows | WSL2 |
|---|---|---|
| Toolchain | MSVC | GCC (same as Linux) |
| Build identical to Linux? | No | Yes |
| GUI debugging via Nsight VSCE | Smoother | Works, slightly more setup |
| GPU access | Direct | Via Microsoft's WSL CUDA driver — install the Windows-side NVIDIA driver, *do not* install a Linux driver inside WSL |
| Performance | Native | Within a few % of native for compute |

For day-to-day kernel work, WSL2 is the lower-friction path if you're already comfortable with the Linux setup. For deep debugging or tight integration with Windows tools (Nsight Systems GUI, Visual Studio), native Windows is better.
