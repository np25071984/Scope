class Scope < Formula
  desc "Window switcher for the current macOS Space, with focus that follows you"
  homepage "https://github.com/np25071984/Scope"
  url "https://github.com/np25071984/Scope/releases/download/v2.4.1/scope-macos.tar.gz"
  version "2.4.1"
  sha256 "059cf2508aec0a9fcab33f387609a29f42ef6c28c6eee71f345a7de351fcc103"
  license "MIT"

  depends_on :macos

  # A prebuilt release, not a source build: macOS ties scope's Accessibility
  # permission to its signature, and only the release build carries the
  # release certificate's. Homebrew building it would sign it ad hoc.
  def install
    bin.install "scope"
  end

  # The permission is also tied to the binary's path, and the Cellar path
  # changes with every version. The service runs a copy at a path that does
  # not, so upgrades keep the permission. The old copy is replaced, never
  # rewritten in place.
  post_install_steps do
    copy "bin/scope", "scope/scope.new", target_base: :var
    move "scope/scope.new", "scope/scope", source_base: :var, target_base: :var
  end

  service do
    run [var/"scope/scope", "run"]
    keep_alive successful_exit: false
    process_type :interactive
    log_path var/"log/scope.log"
    error_log_path var/"log/scope.log"
  end

  def caveats
    <<~EOS
      Start scope now and at every login:
        brew services start scope

      Then turn on "scope" in System Settings > Privacy & Security >
      Accessibility. If it is not listed, add this file with +:
        #{var}/scope/scope

      After `brew upgrade scope`, restart it on the new version:
        brew services restart scope

      If you installed scope with install.sh before, remove that copy first:
        ~/.local/bin/scope uninstall

      To remove scope completely:
        brew services stop scope && brew uninstall scope && rm -rf #{var}/scope
    EOS
  end

  test do
    assert_equal "scope #{version}", shell_output("#{bin}/scope version").strip
  end
end
