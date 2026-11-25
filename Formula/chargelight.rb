class Chargelight < Formula
  desc "Use the MagSafe charger LED as a status light for AI coding agents"
  homepage "https://github.com/TaraxioT/chargelight"
  url "https://github.com/TaraxioT/chargelight/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "27386f9558f8b07556b921d64394ff22e4c40c078f46a3a2eaab40bacd736fc0"
  license "MIT"
  head "https://github.com/TaraxioT/chargelight.git", branch: "main"

  depends_on arch: :arm64
  depends_on :macos

  uses_from_macos "swift" => :build

  def install
    args = ["--disable-sandbox", "--configuration", "release"]
    system "swift", "build", *args
    products = Pathname.new(Utils.safe_popen_read("swift", "build", *args, "--show-bin-path").strip)

    bin.install products/"chargelight"
    # Not on PATH: `sudo chargelight setup` copies it to a root-owned location.
    libexec.install products/"chargelight-helper"
  end

  def caveats
    <<~EOS
      Changing the LED needs root. Install the passwordless helper once:
        sudo chargelight setup

      Then try it:
        chargelight demo

      For Claude Code, add the plugin from inside a session:
        /plugin marketplace add TaraxioT/chargelight
        /plugin install chargelight@chargelight
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/chargelight --version")

    # Simulated LED: no hardware and no root.
    ENV["CHARGELIGHT_HOME"] = (testpath/"state").to_s
    ENV["CHARGELIGHT_BACKEND"] = "file"
    ENV["CHARGELIGHT_NO_WATCHER"] = "1"
    system bin/"chargelight", "claim", "test", "working"
    assert_equal "amber", shell_output("#{bin}/chargelight get").strip
    assert_match "0.1.0", shell_output("#{libexec}/chargelight-helper --version")
  end
end
