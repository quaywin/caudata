# Set a sandboxed config path for the entire test suite to avoid reading/writing to the user's home directory.
test_config_dir = "test/fixtures"
test_config_path = Path.join(test_config_dir, "test_suite_config.toml")
File.mkdir_p!(test_config_dir)
# Start with a clean/empty configuration for the suite
File.rm_rf!(test_config_path)
System.put_env("CAUDATA_CONFIG_PATH", test_config_path)

Mox.defmock(Caudata.SSHClient.Mock, for: Caudata.SSHClient)
ExUnit.start()

# Clean up after all tests are done
System.at_exit(fn _exit_status ->
  File.rm_rf!(test_config_path)
end)
