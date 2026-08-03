defmodule Caudata.BurritoPatch do
  def execute(context) do
    # Make sure HTTP client is started
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    lib_dir = Path.wildcard(Path.join(context.work_dir, "lib/ex_ratatui-*")) |> List.first()

    if lib_dir do
      native_dir = Path.join(lib_dir, "priv/native")
      nif_files = Path.wildcard(Path.join(native_dir, "libex_ratatui-*.so"))

      case nif_files do
        [] ->
          Burrito.Builder.Log.warning(
            :step,
            "No precompiled NIF files found to patch in #{native_dir}"
          )

        [original_nif_path] ->
          original_nif_name = Path.basename(original_nif_path)

          regex =
            ~r/libex_ratatui-v(?<ver>[\d\.]+)-nif-(?<nif>[\d\.]+)-(?<target>[a-zA-Z0-9_\-]+)\.so/

          case Regex.named_captures(regex, original_nif_name) do
            %{"ver" => version, "nif" => nif_version} ->
              # Map Burrito target OS and CPU to Rustler target triple
              rustler_target =
                case {context.target.os, context.target.cpu} do
                  {:darwin, :x86_64} -> "x86_64-apple-darwin"
                  {:darwin, :aarch64} -> "aarch64-apple-darwin"
                  {:linux, :x86_64} -> "x86_64-unknown-linux-gnu"
                  {:linux, :aarch64} -> "aarch64-unknown-linux-gnu"
                  other -> raise "Unsupported Burrito target for NIF patching: #{inspect(other)}"
                end

              repo = System.get_env("EX_RATATUI_REPO") || "quaywin/ex_ratatui"

              url =
                "https://github.com/#{repo}/releases/download/v#{version}/libex_ratatui-v#{version}-nif-#{nif_version}-#{rustler_target}.so.tar.gz"

              Burrito.Builder.Log.info(
                :step,
                "Burrito NIF patch: Downloading NIF for #{rustler_target} from #{url}"
              )

              tar_path = Path.join(System.tmp_dir!(), "libex_ratatui_#{rustler_target}.tar.gz")

              case download_file(url, tar_path) do
                :ok ->
                  case :erl_tar.extract(to_charlist(tar_path), [
                         :compressed,
                         {:cwd, to_charlist(native_dir)}
                       ]) do
                    :ok ->
                      extracted_file_name =
                        "libex_ratatui-v#{version}-nif-#{nif_version}-#{rustler_target}.so"

                      extracted_file_path = Path.join(native_dir, extracted_file_name)

                      if extracted_file_path != original_nif_path do
                        File.rm!(original_nif_path)
                        File.cp!(extracted_file_path, original_nif_path)
                        File.rm!(extracted_file_path)
                      end

                      File.rm!(tar_path)

                      Burrito.Builder.Log.info(
                        :step,
                        "Successfully patched NIF for target #{rustler_target}"
                      )

                    error ->
                      raise "Failed to extract NIF archive: #{inspect(error)}"
                  end

                {:error, reason} ->
                  raise "Failed to download NIF from #{url}: #{inspect(reason)}"
              end

            nil ->
              Burrito.Builder.Log.warning(
                :step,
                "Could not parse version details from NIF filename: #{original_nif_name}"
              )
          end

        multiple ->
          Burrito.Builder.Log.warning(
            :step,
            "Multiple NIF files found in #{native_dir}: #{inspect(multiple)}"
          )
      end
    else
      Burrito.Builder.Log.warning(:step, "ex_ratatui dependency directory not found in release.")
    end

    context
  end

  defp download_file(url, path) do
    headers = [{~c"user-agent", ~c"caudata"}]

    case :httpc.request(:get, {to_charlist(url), headers}, [autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        File.write!(path, body)
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP status #{status}"}

      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
