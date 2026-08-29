{
  description = "Redis with orb fence synthesis";

  nixConfig.extra-sandbox-paths = [ "/scratch" ];

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    clang-orb = {
      url = "git+file:///scratch/sebastian/llvm-orb";
      flake = true;
    };
  };
  outputs = { self, nixpkgs, flake-utils, clang-orb, ...}:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };

      orb-cc = clang-orb.packages.${system}.default;
      orb-wrapped = (pkgs.llvmPackages.clang.override { cc = orb-cc; }).overrideAttrs (prev: {
        extraBuildCommands = (prev.extraBuildCommands or "") + ''
          cp ${pkgs.llvmPackages.clang}/nix-support/libcxx-cxxflags $out/nix-support/libcxx-cxxflags
        '';
      });
      orbstdenv = pkgs.overrideCC pkgs.llvmPackages.stdenv orb-wrapped;

      filteredSrc = builtins.path {
        path = self;
        name = "redis-src";
        filter = path: _type:
          builtins.match ".*\\.(py|json)$" path == null;
      };

      mkRedis = { name, stdenv, cflags ? "", optLevel ? "-O3", synthesis ? false, useClangIR ? false }: stdenv.mkDerivation {
        inherit name;
        src = filteredSrc;
        nativeBuildInputs = with pkgs; [ pkg-config ];
        buildInputs = with pkgs; [ openssl ];

        postPatch = ''
          # Disable NEON intrinsics (ClangIR NYI)
          sed -i '/^#define HAVE_AARCH64_NEON/d' src/config.h
          # Remove persist-settings -> distclean dependency and deps rebuild
          # so our pre-built deps (without ClangIR flags) survive
          sed -i 's/^persist-settings: distclean/persist-settings:/' src/Makefile
          sed -i '/cd \.\.\/deps && \$(MAKE) \$(DEPENDENCY_TARGETS)/d' src/Makefile
        '' + (if useClangIR then ''
          # ClangIR workaround: disable __transparent_union__ on glibc socket APIs.
          # ClangIR passes the union address instead of the pointer value inside it,
          # corrupting sa_family in bind/connect/accept calls.
          mkdir -p .patched-include/sys
          cp $(echo ${pkgs.stdenv.cc.libc.dev}/include/sys/socket.h) .patched-include/sys/socket.h
          sed -i 's/!__GNUC_PREREQ (2, 7)/1/' .patched-include/sys/socket.h
        '' else "");

        dontConfigure = true;

        buildPhase = let
          baseCflags = "-march=armv8.1-a+rcpc -DXXH_VECTOR=0 -U__ARM_NEON -U__ARM_NEON__";
          allCflags = "${baseCflags} ${cflags}";
        in ''
          # CC timing wrapper: logs elapsed time per compilation to .cc-times/
          srcdir="$(pwd)"
          mkdir -p "$srcdir/.cc-times"
          real_cc="$(command -v $CC)"

          cat > "$srcdir/.cc-wrapper" <<EOF
#!${pkgs.bash}/bin/bash
src=""
for arg; do
  case "\$arg" in *.c|*.cc|*.cpp|*.cxx) src="\$arg";; esac
done
t0=\$(date +%s%N)
$real_cc "\$@"
rc=\$?
t1=\$(date +%s%N)
if [ -n "\$src" ]; then
  elapsed_ms=\$(( (t1 - t0) / 1000000 ))
  base=\$(basename "\$src")
  echo "\$base \$elapsed_ms" >> $srcdir/.cc-times/times.log
fi
exit \$rc
EOF

          chmod +x "$srcdir/.cc-wrapper"

          # Build deps with base CFLAGS only (no ClangIR/orb flags — they cause -Werror failures in hiredis)
          CFLAGS="${baseCflags}" make -C deps \
            hiredis linenoise lua hdr_histogram fpconv xxhash tre \
            -j$NIX_BUILD_CORES

          # Now build server with full CFLAGS (including ClangIR/orb) + timing wrapper
          export CFLAGS="${allCflags}"
        '' + (if useClangIR then ''
          export CFLAGS="-isystem $srcdir/.patched-include $CFLAGS"
        '' else "") + ''
          export CC="$srcdir/.cc-wrapper"
        '' + (if synthesis then ''
          export ORB_SYNTH_LOG="$(pwd)/.synth-logs"
          mkdir -p "$ORB_SYNTH_LOG"
        '' else "") + ''

          make -C src redis-server ${if useClangIR then "" else "redis-benchmark redis-cli"} \
            OPTIMIZATION="${optLevel}" \
            MALLOC=libc \
            USE_JEMALLOC=no \
            BUILD_TLS=no \
            ENABLE_LTO="" \
            SKIP_VEC_SETS=yes \
            -j$NIX_BUILD_CORES
        '';

        installPhase = ''
          mkdir -p $out/bin
          cp src/redis-server $out/bin/
          cp src/redis-benchmark $out/bin/ 2>/dev/null || true
          cp src/redis-cli $out/bin/ 2>/dev/null || true
          if [ -f .cc-times/times.log ]; then
            mkdir -p $out/cc-times
            cp .cc-times/times.log $out/cc-times/
          fi
        '' + (if synthesis then ''
          if [ -d .synth-logs ]; then
            mkdir -p $out/synth
            cp .synth-logs/* $out/synth/ 2>/dev/null || true
          fi
        '' else "");

        enableParallelBuilding = true;
      };

      fCosts = [1 333 666 999];

    in
    {
      packages = {
        default       = mkRedis { name = "redis-clang-O3"; stdenv = orbstdenv; };
        clang-O3      = mkRedis { name = "redis-clang-O3"; stdenv = orbstdenv; };
        clang-O0      = mkRedis { name = "redis-clang-O0"; stdenv = orbstdenv; optLevel = "-O0"; };
        clangir-O0    = mkRedis { name = "redis-clangir-O0"; stdenv = orbstdenv; optLevel = "-O0"; useClangIR = true;
                                  cflags = "-fclangir"; };
        clangir-O3    = mkRedis { name = "redis-clangir-O3"; stdenv = orbstdenv; useClangIR = true;
                                  cflags = "-fclangir"; };
        naive-O0      = mkRedis { name = "redis-naive-O0"; stdenv = orbstdenv; optLevel = "-O0"; synthesis = true; useClangIR = true;
                                  cflags = "-fclangir -Xclang -naive-orb"; };
        naive-O3      = mkRedis { name = "redis-naive-O3"; stdenv = orbstdenv; synthesis = true; useClangIR = true;
                                  cflags = "-fclangir -Xclang -naive-orb"; };
        gcc-O3        = mkRedis { name = "redis-gcc-O3"; stdenv = pkgs.stdenv; };
        orb-cc        = orb-wrapped;
      } // (builtins.listToAttrs (builtins.concatMap (fc: [
        { name = "orb-O0-fc${toString fc}";
          value = mkRedis { name = "redis-orb-O0-fc${toString fc}"; stdenv = orbstdenv; optLevel = "-O0"; synthesis = true; useClangIR = true;
                            cflags = "-fclangir -Xclang -orb -Xclang -orb-fence-cost-base=${toString fc}"; }; }
        { name = "orb-O3-fc${toString fc}";
          value = mkRedis { name = "redis-orb-O3-fc${toString fc}"; stdenv = orbstdenv; synthesis = true; useClangIR = true;
                            cflags = "-fclangir -Xclang -orb -Xclang -orb-fence-cost-base=${toString fc}"; }; }
      ]) fCosts));

      devShells.default = pkgs.mkShell {
        packages = [
          (pkgs.python3.withPackages (ps: with ps; [ pandas numpy seaborn matplotlib jupyter ]))
          pkgs.redis        # redis-cli, redis-benchmark from nixpkgs
          pkgs.tcl           # for Redis test suite
          pkgs.gnuplot
          pkgs.numactl
          pkgs.linuxPackages.perf
          pkgs.jq
        ];
      };
    }
  );
}
