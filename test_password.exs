defmodule TestPassword do
  @launchd_cmd "echo '===LAUNCHD==='; if command -v launchctl >/dev/null 2>&1; then launchctl list 2>/dev/null; for dir in '/Library/LaunchDaemons' '/Library/LaunchAgents' \"$HOME/Library/LaunchAgents\"; do if [ -d \"$dir\" ]; then find \"$dir\" -name '*.plist' -maxdepth 1 2>/dev/null | while read -r plist; do label=$(basename \"$plist\" .plist); echo \"- 0 $label\"; done; fi; done; fi"

  def wrap_sudo(cmd, password) do
    escaped_cmd = String.replace(cmd, "'", "'\\''")

    inner_script =
      cond do
        password && password != "" ->
          escaped_password = String.replace(password, "'", "'\\''")
          "if command -v sudo >/dev/null 2>&1; then exec 3<&0; echo '#{escaped_password}' | sudo -S -p '' sh -c 'exec 0<&3 3<&-; #{escaped_cmd}'; else sh -c '#{escaped_cmd}'; fi"

        true ->
          "if command -v sudo >/dev/null 2>&1; then sudo -n sh -c '#{escaped_cmd}' 2>/dev/null || sh -c '#{escaped_cmd}'; else sh -c '#{escaped_cmd}'; fi"
      end

    escaped_for_dq =
      inner_script
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    "sh -c \"#{escaped_for_dq}\""
  end

  def test_password(label, password) do
    wrapped = wrap_sudo(@launchd_cmd, password)

    {out, status} = System.cmd("sh", ["-c", wrapped], stderr_to_stdout: true)

    # Check if the command parsed correctly (not a syntax error)
    has_syntax_error = String.contains?(out, "syntax error") or String.contains?(out, "unexpected")
    has_output = String.contains?(out, "===LAUNCHD===") or String.contains?(out, "0 com.")

    result = cond do
      has_syntax_error -> "SYNTAX ERROR"
      has_output -> "OK (services found)"
      true -> "OK (no syntax error, sudo may have failed)"
    end

    IO.puts("[#{result}] #{label}")
  end

  def run do
    IO.puts("=== Testing password escaping ===\n")

    # Test various password types
    test_password("Simple password", "mypassword")
    test_password("Password with $", "my$pass")
    test_password("Password with \"", "my\"pass")
    test_password("Password with '", "my'pass")
    test_password("Password with \\", "my\\pass")
    test_password("Password with `", "my`pass")
    test_password("Password with ;", "my;pass")
    test_password("Password with space", "my pass")
    test_password("Empty password (nil)", nil)
    test_password("Empty password (\"\")", "")

    # Also test no-password case
    IO.puts("\n=== No password case ===")
    test_password("No password", nil)
  end
end

TestPassword.run()
