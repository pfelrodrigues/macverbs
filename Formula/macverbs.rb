# Homebrew formula (source build).
#
# Not published to a public tap yet. When the tap exists:
#
#   brew install pfelrodrigues/macverbs/macverbs
#
# Local test from a checkout (no tap):
#
#   brew install --build-from-source ./Formula/macverbs.rb
#
# Before first release, replace url/sha256 with a GitHub archive of the tag
# (e.g. v0.1.0) and verify: macverbs --version

class Macverbs < Formula
  desc "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar"
  homepage "https://github.com/pfelrodrigues/macverbs"
  # PRE-RELEASE: point at a tagged archive when cutting v0.1.0
  url "https://github.com/pfelrodrigues/macverbs/archive/refs/heads/main.tar.gz"
  version "0.1.0-dev"
  # sha256 "REPLACE_AFTER_TAGGING"
  license "MIT"
  head "https://github.com/pfelrodrigues/macverbs.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/macverbs"
  end

  test do
    assert_match version.to_s.split("-").first, shell_output("#{bin}/macverbs --version")
  end
end
