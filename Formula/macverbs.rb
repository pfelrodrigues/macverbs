# Homebrew formula for macverbs.
#
#   brew install pfelrodrigues/tap/macverbs
#
# Canonical tap: https://github.com/pfelrodrigues/homebrew-tap
#
class Macverbs < Formula
  desc "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar"
  homepage "https://github.com/pfelrodrigues/macverbs"
  url "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.1.tar.gz"
  # sha256 filled after `git push origin v0.1.1` (see docs/RELEASE.md).
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.1.1"
  license "MIT"
  head "https://github.com/pfelrodrigues/macverbs.git", branch: "main"

  depends_on :macos

  def install
    odie "Swift toolchain not found (install Xcode or Command Line Tools)" unless which("swift")

    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/macverbs"

    bash_completion.install "completions/macverbs.bash" => "macverbs"
    zsh_completion.install "completions/_macverbs"
    fish_completion.install "completions/macverbs.fish"
  end

  test do
    assert_match "0.1.1", shell_output("#{bin}/macverbs --version")
  end
end

