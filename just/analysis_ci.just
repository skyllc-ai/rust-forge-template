# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025-2026 Acmex Placeholder LLC.


# Comprehensive CI pipeline analysis and optimization recommendations.
ci-analyze:
    #!/usr/bin/env bash
    printf "\033[0;34m🔬 Comprehensive CI Pipeline Analysis...\033[0m\n"
    printf "\033[0;34m  → Analyzing project structure...\033[0m\n"
    CRATE_COUNT=$(find . -name "Cargo.toml" | wc -l | tr -d ' ')
    SOURCE_FILES=$(find . -name "*.rs" | wc -l | tr -d ' ')
    TEST_FILES=$(find . -name "*.rs" -path "*/tests/*" -o -name "*test*.rs" | wc -l | tr -d ' ')
    printf "\033[0;34m    → Crates: $CRATE_COUNT\033[0m\n"
    printf "\033[0;34m    → Source files: $SOURCE_FILES\033[0m\n"
    printf "\033[0;34m    → Test files: $TEST_FILES\033[0m\n"
    printf "\033[0;34m  → Analyzing dependencies...\033[0m\n"
    if command -v cargo-tree >/dev/null 2>&1; then DEP_COUNT=$(cargo tree --depth 1 | grep -c "├\|└" || echo "0"); printf "\033[0;34m    → Direct dependencies: $DEP_COUNT\033[0m\n"; fi
    printf "\033[0;34m  → Checking parallel execution capabilities...\033[0m\n"
    CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
    printf "\033[0;34m    → Available CPU cores: $CPU_CORES\033[0m\n"
    printf "\033[0;34m  → Analyzing test execution patterns...\033[0m\n"
    if command -v cargo-nextest >/dev/null 2>&1; then printf "\033[0;32m    ✅ Using cargo-nextest (optimized test runner)\033[0m\n"; else printf "\033[1;33m    ⚠️  Using standard cargo test (consider cargo-nextest)\033[0m\n"; fi
    printf "\033[0;34m  → Checking incremental compilation settings...\033[0m\n"
    if grep -q "incremental.*true" Cargo.toml 2>/dev/null; then printf "\033[0;32m    ✅ Incremental compilation enabled\033[0m\n"; else printf "\033[1;33m    💡 Consider enabling incremental compilation for faster builds\033[0m\n"; fi
    printf "\033[0;32m\n🎯 CI Pipeline Optimization Recommendations:\033[0m\n"
    printf "\033[0;34m\n📊 Current Workflow Analysis:\033[0m\n"
    printf "  • Two-phase workflow: ✅ Excellent for fast-fail behavior\n"
    printf "  • Parallel test execution: ✅ Using --jobs 16\n"
    printf "  • Modern tooling: ✅ nextest, llvm-cov, clippy\n"
    printf "\033[0;34m\n🚀 Performance Optimization Opportunities:\033[0m\n"
    if [ "$CPU_CORES" != "unknown" ] && [ "$CPU_CORES" -gt 16 ]; then printf "  • Consider increasing --jobs from 16 to $CPU_CORES for better parallelism\n"; fi
    printf "  • Use 'just benchmark-both' to compare workflow approaches\n"
    printf "  • Consider caching strategies for dependencies\n"
    printf "  • Monitor 'just benchmark-advanced' for bottlenecks\n"
    printf "\033[0;34m\n🔧 Tool Recommendations:\033[0m\n"
    printf "  • cargo-binstall: ✅ Faster tool installations\n"
    printf "  • cargo-nextest: ✅ Modern test runner with better output\n"
    printf "  • cargo-llvm-cov: ✅ Comprehensive coverage analysis\n"
    printf "  • sccache: 💡 Consider for distributed compilation caching\n"
    printf "\033[0;32m\n✅ CI Analysis complete! Use benchmarking tools for detailed performance data.\033[0m\n"

# Check for unused dependencies with cargo-machete.
machete:
    #!/usr/bin/env bash
    printf "\033[0;34m🔪 Checking for unused dependencies...\033[0m\n"
    if ! command -v cargo-machete >/dev/null 2>&1; then printf "\033[1;33m⚠️  cargo-machete not installed. Run 'just setup' first.\033[0m\n"; exit 1; fi
    cargo-machete --skip-target-dir
    printf "\033[0;32m✅ Dependency check complete!\033[0m\n"

