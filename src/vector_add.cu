#include "vector_add.cuh"

#include <cuda_runtime.h>

#include <stdexcept>
#include <string>

namespace cuda_playground {

namespace {

void check(cudaError_t err, const char* what) {
    if (err != cudaSuccess) {
        throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(err));
    }
}

__global__ void vector_add_kernel(const float* a, const float* b, float* c, std::size_t n) {
    const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        c[i] = a[i] + b[i];
    }
}

}  // namespace

void vector_add(const float* a, const float* b, float* c, std::size_t n) {
    const std::size_t bytes = n * sizeof(float);

    float *d_a = nullptr, *d_b = nullptr, *d_c = nullptr;
    check(cudaMalloc(&d_a, bytes), "cudaMalloc d_a");
    check(cudaMalloc(&d_b, bytes), "cudaMalloc d_b");
    check(cudaMalloc(&d_c, bytes), "cudaMalloc d_c");

    check(cudaMemcpy(d_a, a, bytes, cudaMemcpyHostToDevice), "cudaMemcpy H2D a");
    check(cudaMemcpy(d_b, b, bytes, cudaMemcpyHostToDevice), "cudaMemcpy H2D b");

    constexpr int threads_per_block = 256;
    const int blocks = static_cast<int>((n + threads_per_block - 1) / threads_per_block);
    vector_add_kernel<<<blocks, threads_per_block>>>(d_a, d_b, d_c, n);
    check(cudaGetLastError(), "kernel launch");
    check(cudaDeviceSynchronize(), "kernel sync");

    check(cudaMemcpy(c, d_c, bytes, cudaMemcpyDeviceToHost), "cudaMemcpy D2H c");

    cudaFree(d_a);
    cudaFree(d_b);
    cudaFree(d_c);
}

}  // namespace cuda_playground
