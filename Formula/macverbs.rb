# Homebrew formula for macverbs.
# Canonical public install (after tap publish):
#
#   brew install pfelrodrigues/macverbs/macverbs
#
class Macverbs < Formula
  desc "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar"
  homepage "https://github.com/pfelrodrigues/macverbs"
  url "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/pfelrodrigues/macverbs.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
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
