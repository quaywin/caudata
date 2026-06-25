defmodule Caudata.CLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Caudata.CLI

  describe "compare_versions/2" do
    test "correctly compares semver versions" do
      assert CLI.compare_versions("0.1.14", "0.1.15") == :lt
      assert CLI.compare_versions("0.2.0", "0.1.15") == :gt
      assert CLI.compare_versions("1.0.0", "0.9.9") == :gt
      assert CLI.compare_versions("0.1.14", "0.1.14") == :eq
    end

    test "correctly compares versions with build/prerelease metadata" do
      assert CLI.compare_versions("0.1.29+dev.1.fc377d0", "0.1.30") == :lt
      assert CLI.compare_versions("0.1.30+dev.1.fc377d0", "0.1.30") == :eq
      assert CLI.compare_versions("0.1.30+dev.1.fc377d0", "0.1.29") == :gt
      assert CLI.compare_versions("0.1.29-rc1", "0.1.29") == :eq
    end

    test "handles non-semver fallback strings" do
      assert CLI.compare_versions("abc", "def") == :lt
      assert CLI.compare_versions("xyz", "abc") == :gt
      assert CLI.compare_versions("same", "same") == :eq
    end
  end

  describe "CLI routing and printing" do
    test "print_version outputs version info" do
      io = capture_io(fn -> CLI.print_version() end)
      assert io =~ "Caudata v"
    end

    test "print_help outputs help instructions" do
      io = capture_io(fn -> CLI.print_help() end)
      assert io =~ "Caudata - A collaborative, zero-config"
      assert io =~ "Usage:"
      assert io =~ "upgrade"
    end

    test "handle_args returns :continue for empty args list" do
      assert CLI.handle_args([]) == :continue
    end
  end
end
