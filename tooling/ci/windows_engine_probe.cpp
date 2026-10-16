// Offline runtime qualification only. No Apple code, identity, account or network.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <unicorn/unicorn.h>
#include <unicorn/x86.h>

#define BIND(name) \
    auto p_##name = reinterpret_cast<decltype(&name)>(GetProcAddress(module, #name)); \
    if (!p_##name) { std::fprintf(stderr, "missing export: %s\n", #name); return 2; }
#define CHECK(expr) \
    do { const uc_err err = (expr); if (err != UC_ERR_OK) { \
        std::fprintf(stderr, "%s: %s\n", #expr, p_uc_strerror(err)); return 3; } } while (0)
#define REQUIRE(expr) \
    do { if (!(expr)) { std::fprintf(stderr, "failed: %s\n", #expr); return 4; } } while (0)

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: engine_probe ABSOLUTE_DLL_PATH\n"); return 1; }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::puts("before_library_load");
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    HMODULE module = LoadLibraryExW(argv[1], nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) { std::fprintf(stderr, "LoadLibrary error=%lu\n", GetLastError()); return 2; }
    std::puts("after_library_load");
    BIND(uc_version); BIND(uc_open); BIND(uc_close); BIND(uc_strerror);
    BIND(uc_mem_map); BIND(uc_mem_write); BIND(uc_reg_write); BIND(uc_reg_read);
    BIND(uc_emu_start); BIND(uc_query);
    unsigned major = 0, minor = 0;
    const unsigned version = p_uc_version(&major, &minor);
    std::printf("runtime_version=0x%x major=%u minor=%u host_arm64=%d\n", version, major, minor,
#ifdef _M_ARM64
        1
#else
        0
#endif
    );
    REQUIRE(major == 2 && minor == 1);

    uc_engine* uc = nullptr;
    std::puts("before_engine_open");
    CHECK(p_uc_open(UC_ARCH_X86, UC_MODE_64, &uc));
    std::puts("after_engine_open");
    CHECK(p_uc_mem_map(uc, 0x1000, 0x3000, UC_PROT_ALL));
    CHECK(p_uc_mem_map(uc, 0x7000, 0x3000, UC_PROT_ALL));
    const uint8_t return42[] = {0xb8, 0x2a, 0, 0, 0, 0xc3};
    const uint8_t forever[] = {0xeb, 0xfe};
    const uint8_t readNull[] = {0x48, 0xa1, 0, 0, 0, 0, 0, 0, 0, 0};
    const uint64_t stop = 0x7000;
    uint64_t stack = 0x9ff8;
    CHECK(p_uc_mem_write(uc, 0x1000, return42, sizeof(return42)));
    CHECK(p_uc_mem_write(uc, 0x2000, forever, sizeof(forever)));
    CHECK(p_uc_mem_write(uc, 0x3000, readNull, sizeof(readNull)));
    CHECK(p_uc_mem_write(uc, stack, &stop, sizeof(stop)));
    CHECK(p_uc_reg_write(uc, UC_X86_REG_RSP, &stack));
    std::puts("before_native_call"); std::fflush(stdout);
    CHECK(p_uc_emu_start(uc, 0x1000, stop, 5000000, 1000));
    uint64_t rax = 0, rip = 0, rsp = 0;
    CHECK(p_uc_reg_read(uc, UC_X86_REG_RAX, &rax));
    CHECK(p_uc_reg_read(uc, UC_X86_REG_RIP, &rip));
    CHECK(p_uc_reg_read(uc, UC_X86_REG_RSP, &rsp));
    REQUIRE(rax == 42 && rip == stop && rsp == 0xa000);
    std::puts("PASS expected_return_and_stack"); std::fflush(stdout);

    const ULONGLONG began = GetTickCount64();
    CHECK(p_uc_emu_start(uc, 0x2000, stop, 100000, 0));
    const ULONGLONG elapsed = GetTickCount64() - began;
    size_t timedOut = 0;
    CHECK(p_uc_query(uc, UC_QUERY_TIMEOUT, &timedOut));
    CHECK(p_uc_reg_read(uc, UC_X86_REG_RIP, &rip));
    REQUIRE(timedOut == 1 && rip != stop && elapsed < 5000);
    std::printf("PASS timeout_is_not_a_valid_return elapsed_ms=%llu\n", elapsed);
    std::fflush(stdout);

    const uc_err fault = p_uc_emu_start(uc, 0x3000, stop, 5000000, 1000);
    REQUIRE(fault == UC_ERR_READ_UNMAPPED);
    std::puts("PASS unmapped_read_fails_closed"); std::fflush(stdout);
    CHECK(p_uc_close(uc));
    REQUIRE(FreeLibrary(module) != 0);
    std::puts("passed=3 failed=0 account_access=false");
    return 0;
}
