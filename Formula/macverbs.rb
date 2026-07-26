# Homebrew formula for macverbs.
#
#   brew install pfelrodrigues/macverbs/macverbs
#
class Macverbs < Formula
  desc "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar"
  homepage "https://github.com/pfelrodrigues/macverbs"
  url "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "bb1a76063a1162503cf2bad1aa922b9fca04a70d173e37e81158d95b662cb2e9"
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
    assert_match "0.1.0", shell_output("#{bin}/macverbs --version")
  end
end
