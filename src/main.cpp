#include "vector_add.cuh"

#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <vector>

int main() {
    constexpr std::size_t n = 1 << 20;  // ~1M elements

    std::vector<float> a(n), b(n), c(n);
    for (std::size_t i = 0; i < n; ++i) {
        a[i] = static_cast<float>(i);
        b[i] = static_cast<float>(2 * i);
    }

    try {
        cuda_playground::vector_add(a.data(), b.data(), c.data(), n);
    } catch (const std::exception& e) {
        std::cerr << "CUDA error: " << e.what() << '\n';
        return EXIT_FAILURE;
    }

    bool ok = true;
    for (std::size_t i = 0; i < n; ++i) {
        const float expected = a[i] + b[i];
        if (c[i] != expected) {
            std::cerr << "Mismatch at " << i << ": got " << c[i] << ", expected " << expected << '\n';
            ok = false;
            break;
        }
    }

    std::cout << (ok ? "OK: " : "FAIL: ") << n << " elements added on GPU\n";
    return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
