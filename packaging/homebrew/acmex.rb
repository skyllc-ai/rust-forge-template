# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 Acmex Placeholder LLC
#
# Homebrew formula TEMPLATE for the tap (lane:brew). brew-publish.yml
# substitutes the @...@ placeholders from the release assets and pushes
# the result to <tap>/Formula/acmex.rb. Do not fill the placeholders
# by hand; the SHA256s must match the published ZIPs bit for bit.
class Acmex < Formula
  desc "acmex - template placeholder project"
  homepage "https://github.com/acmex-org/acmex"
  version "@VERSION@"
  license "MIT OR Apache-2.0"

  on_macos do
    on_arm do
      url "@BASE@/acmex-macos-arm64.zip"
      sha256 "@ARM_SHA@"
    end
    on_intel do
      url "@BASE@/acmex-macos-x64.zip"
      sha256 "@X64_SHA@"
    end
  end

  on_linux do
    url "@BASE@/acmex-linux-x64.zip"
    sha256 "@LINUX_SHA@"
  end

  def install
    # The ZIP's single root directory holds the binaries plus LICENSE,
    # README and CHANGELOG (release.yml's stage_bundle).
    bin.install "acmex"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/acmex --version")
  end
end
