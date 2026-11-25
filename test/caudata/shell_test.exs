defmodule Caudata.ShellTest do
  use ExUnit.Case, async: true

  alias Caudata.Shell

  describe "quote_arg/1" do
    test "prevents command substitution, parameter expansion, and quote breaking" do
      dangerous = ~S|/tmp/a'b"c$(whoami)`id`;echo $HOME\test|
      quoted = Shell.quote_arg(dangerous)

      {out, 0} = System.cmd("sh", ["-c", "printf '%s' #{quoted}"])
      assert out == dangerous
    end

    test "handles nil and empty strings" do
      assert Shell.quote_arg(nil) == "''"
      assert Shell.quote_arg("") == "''"
    end
  end

  describe "wrap_sudo/2 and wrap_supervised_sudo/2" do
    test "executes wrapped commands cleanly without syntax errors across special passwords" do
      cmd = "echo ok"

      for password <- [
            nil,
            "",
            "simple",
            "my$pass",
            "my\"pass",
            "my'pass",
            "my\\pass",
            "my`pass",
            "my;pass",
            "my pass"
          ] do
        wrapped = Shell.wrap_sudo(cmd, password)
        assert String.starts_with?(wrapped, "sh -c \"")
        {out, status} = System.cmd("sh", ["-c", wrapped], stderr_to_stdout: true)
        refute out =~ "syntax error"
        assert is_integer(status)
      end
    end

    test "wrap_supervised_sudo preserves quoted arguments and exits cleanly" do
      quoted_arg = Shell.quote_arg("hello $USER $(whoami) 'world'")
      wrapped = Shell.wrap_supervised_sudo("printf '%s' #{quoted_arg}", nil)
      {out, 0} = System.cmd("sh", ["-c", wrapped], stderr_to_stdout: true)
      assert out == "hello $USER $(whoami) 'world'"
    end
  end
end
