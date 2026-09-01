defmodule Caudata.UI.Components.AddServerModal do
  @moduledoc """
  Renders modal overlays for adding and configuring new server connections,
  and handles their keyboard event flows.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  alias Caudata.UI.ViewHelper

  @doc """
  Renders the modal widget according to state.modal_type.
  """
  def render(state) do
    case state.modal_type do
      :select_ssh ->
        options = [
          {"+ Manual SSH Connection", :manual},
          {"+ Local Machine Connection", :local}
          | Enum.map(state.ssh_config_profiles || [], &{&1.id, &1})
        ]

        popup_inner_width = max(10, div(Map.get(state, :width, 80) * 70, 100) - 4)
        error_rows = if Map.get(state, :modal_error), do: 2, else: 0
        inner_height = max(3, div(Map.get(state, :height, 24) * 60, 100) - 2)
        display_rows_limit = max(3, inner_height - 2 - error_rows)

        total_options = length(options)
        selected_idx = min(max(0, Map.get(state, :modal_selected_index, 0)), max(0, total_options - 1))
        start_row = ViewHelper.scroll_start_row(selected_idx, display_rows_limit)

        option_lines =
          options
          |> Enum.with_index()
          |> Enum.slice(start_row, display_rows_limit)
          |> Enum.map(fn {option, idx} ->
            selected = selected_idx == idx
            prefix = if selected, do: "> ", else: "  "
            color = if selected, do: :green, else: :white

            label =
              case option do
                {label, :manual} ->
                  label

                {label, :local} ->
                  label

                {id, profile} ->
                  "#{id} (#{profile.user || "root"}@#{profile.host_name}:#{profile.port})"
              end

            Line.new([
              Span.new(prefix, style: %Style{fg: color}),
              Span.new(label, style: %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])})
            ])
          end)

        header_title =
          if total_options > display_rows_limit do
            "Select a server from ~/.ssh/config or enter manually (#{selected_idx + 1}/#{total_options}):"
          else
            "Select a server from ~/.ssh/config or enter manually:"
          end

        header_lines = [
          Line.new([
            Span.new(header_title, style: %Style{fg: :cyan})
          ]),
          Line.new([
            Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
          ])
        ]

        error_lines =
          if Map.get(state, :modal_error) do
            [
              Line.new([]),
              Line.new([Span.new("Error: #{state.modal_error}", style: %Style{fg: :red})])
            ]
          else
            []
          end

        title =
          if total_options > display_rows_limit do
            " Add Connection [#{selected_idx + 1}/#{total_options}] "
          else
            " Add Connection "
          end

        popup_widget = %Popup{
          content: %Paragraph{
            text: header_lines ++ option_lines ++ error_lines
          },
          block: %Block{
            title: title,
            borders: [:all],
            border_type: :rounded
          },
          percent_width: 70,
          percent_height: 60
        }

        [popup_widget]

      :manual_input ->
        fields_config = [
          {"id", "Connection Name/ID (optional):"},
          {"host_name", "Host/IP (required):"},
          {"port", "Port (default 22):"},
          {"user", "User:"},
          {"identity_file", "Identity File (optional path):"},
          {"password", "Password (optional):"}
        ]

        form_lines =
          Enum.with_index(fields_config)
          |> Enum.flat_map(fn {{key, label}, index} ->
            active = state.modal_focus_index == index
            prefix = if active, do: "> ", else: "  "
            label_color = if active, do: :cyan, else: :white
            value_color = if active, do: :green, else: :white
            value = Map.get(state.modal_fields, key, "")

            masked_value =
              if key == "password", do: String.duplicate("*", String.length(value)), else: value

            display_value = if active, do: masked_value <> "█", else: masked_value

            [
              Line.new([Span.new(prefix), Span.new(label, style: %Style{fg: label_color})]),
              Line.new([
                Span.new("    "),
                Span.new(display_value, style: %Style{fg: value_color})
              ])
            ]
          end)

        save_active = state.modal_focus_index == 6
        cancel_active = state.modal_focus_index == 7

        buttons_line =
          Line.new([
            Span.new(
              if(save_active, do: "> [ Save Connection ]   ", else: "  [ Save Connection ]   "),
              style: %Style{fg: if(save_active, do: :green, else: :white)}
            ),
            Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
              style: %Style{fg: if(cancel_active, do: :red, else: :white)}
            )
          ])

        popup_inner_width = max(10, div(Map.get(state, :width, 80) * 80, 100) - 4)

        header_lines = [
          Line.new([Span.new("Configure SSH details:", style: %Style{fg: :cyan})]),
          Line.new([
            Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
          ])
        ]

        error_lines =
          if Map.get(state, :modal_error) do
            [
              Line.new([]),
              Line.new([Span.new("Error: #{state.modal_error}", style: %Style{fg: :red})])
            ]
          else
            []
          end

        popup_widget = %Popup{
          content: %Paragraph{
            text: header_lines ++ form_lines ++ [Line.new([]), buttons_line] ++ error_lines
          },
          block: %Block{
            title: " Add Manual Connection ",
            borders: [:all],
            border_type: :rounded
          },
          percent_width: 80,
          percent_height: 90
        }

        [popup_widget]

      :local_input ->
        fields_config = [
          {"password", "Sudo Password (optional):"}
        ]

        form_lines =
          Enum.with_index(fields_config)
          |> Enum.flat_map(fn {{key, label}, index} ->
            active = state.modal_focus_index == index
            prefix = if active, do: "> ", else: "  "
            label_color = if active, do: :cyan, else: :white
            value_color = if active, do: :green, else: :white
            value = Map.get(state.modal_fields, key, "")

            masked_value =
              if key == "password", do: String.duplicate("*", String.length(value)), else: value

            display_value = if active, do: masked_value <> "█", else: masked_value

            [
              Line.new([Span.new(prefix), Span.new(label, style: %Style{fg: label_color})]),
              Line.new([
                Span.new("    "),
                Span.new(display_value, style: %Style{fg: value_color})
              ])
            ]
          end)

        save_active = state.modal_focus_index == 1
        cancel_active = state.modal_focus_index == 2

        buttons_line =
          Line.new([
            Span.new(
              if(save_active, do: "> [ Save Connection ]   ", else: "  [ Save Connection ]   "),
              style: %Style{fg: if(save_active, do: :green, else: :white)}
            ),
            Span.new(if(cancel_active, do: "> [ Cancel ]", else: "  [ Cancel ]"),
              style: %Style{fg: if(cancel_active, do: :red, else: :white)}
            )
          ])

        popup_inner_width = max(10, div(Map.get(state, :width, 80) * 80, 100) - 4)

        header_lines = [
          Line.new([Span.new("Configure Local Machine details:", style: %Style{fg: :cyan})]),
          Line.new([
            Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
          ])
        ]

        error_lines =
          if Map.get(state, :modal_error) do
            [
              Line.new([]),
              Line.new([Span.new("Error: #{state.modal_error}", style: %Style{fg: :red})])
            ]
          else
            []
          end

        popup_widget = %Popup{
          content: %Paragraph{
            text: header_lines ++ form_lines ++ [Line.new([]), buttons_line] ++ error_lines
          },
          block: %Block{
            title: " Add Local Connection ",
            borders: [:all],
            border_type: :rounded
          },
          percent_width: 80,
          percent_height: 50
        }

        [popup_widget]
    end
  end

  @doc """
  Dispatches key events for connection modals.
  """
  def handle_key(key, key_data, model) do
    case key do
      k when k in [:escape, :esc] ->
        {%{model | modal_visible: false, modal_error: nil}, []}

      _ ->
        case model.modal_type do
          :select_ssh ->
            handle_select_ssh_key(key, key_data, model)

          :manual_input ->
            handle_manual_input_key(key, key_data, model)

          :local_input ->
            handle_local_input_key(key, key_data, model)
        end
    end
  end

  defp handle_select_ssh_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    total_options = 2 + length(Map.get(model, :ssh_config_profiles, []))
    current_index = Map.get(model, :modal_selected_index, 0)
    page_step = max(3, div(Map.get(model, :height, 24) * 60, 100) - 4)

    case norm_key do
      k when k in [:up, :down, :home, :end, :page_up, :page_down, :pageup, :pagedown, "k", "j", "g", "G", "K", "J"] ->
        new_index = ViewHelper.navigate_bounded_index(current_index, k, total_options, page_step)
        {%{model | modal_selected_index: new_index}, []}

      :enter ->
        cond do
          current_index == 0 ->
            # Switch to manual connection input
            {%{
               model
               | modal_type: :manual_input,
                 modal_focus_index: 0,
                 modal_error: nil,
                 modal_fields: %{
                   "id" => "",
                   "host_name" => "",
                   "user" => "",
                   "port" => "22",
                   "identity_file" => "",
                   "password" => ""
                 }
             }, []}

          current_index == 1 ->
            # Switch to local connection input
            {%{
               model
               | modal_type: :local_input,
                 modal_focus_index: 0,
                 modal_error: nil,
                 modal_fields: %{
                   "password" => ""
                 }
             }, []}

          true ->
            # Add the selected profile
            profile = Enum.at(model.ssh_config_profiles, current_index - 2)

            if profile do
              profile_attrs = Map.from_struct(profile)

              case Caudata.ConfigManager.add_manual_profile(profile_attrs) do
                {:ok, added_profile} ->
                  ViewHelper.start_worker_if_needed(added_profile)

                  # Update profile list in the model immediately
                  updated_profiles = model.profiles ++ [added_profile]

                  {%{
                     model
                     | profiles: updated_profiles,
                       selected_profile_id: added_profile.id,
                       selected_container_id: nil,
                       selected_container_name: nil,
                       logs_scroll_y: :bottom,
                       modal_visible: false,
                       modal_error: nil
                   }, []}

                {:error, reason} ->
                  {%{model | modal_error: "Failed to add profile: #{inspect(reason)}"}, []}
              end
            else
              {model, []}
            end
        end

      _ ->
        {model, []}
    end
  end

  defp handle_manual_input_key(key, key_data, model) do
    fields = ["id", "host_name", "port", "user", "identity_file", "password", :save, :cancel]
    num_fields = length(fields)
    active_item = Enum.at(fields, model.modal_focus_index)
    modifiers = Map.get(key_data, :modifiers, [])
    is_shift = Enum.any?(modifiers, &(&1 in ["shift", "Shift"]))

    cond do
      key == :down ->
        new_focus = rem(model.modal_focus_index + 1, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :up ->
        new_focus = rem(model.modal_focus_index - 1 + num_fields, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :tab and is_shift ->
        new_focus = rem(model.modal_focus_index - 1 + num_fields, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :tab ->
        new_focus = rem(model.modal_focus_index + 1, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :enter ->
        case active_item do
          :cancel ->
            {%{model | modal_type: :select_ssh, modal_selected_index: 0, modal_error: nil}, []}

          :save ->
            save_manual_connection(model)

          _input_field ->
            # Enter key on input fields acts as Tab to move to next field
            new_focus = rem(model.modal_focus_index + 1, num_fields)
            {%{model | modal_focus_index: new_focus}, []}
        end

      is_binary(active_item) ->
        case key do
          :paste ->
            text = Map.get(key_data, :content, "")
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = current_val <> text
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          :backspace ->
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = String.slice(current_val, 0..-2//1)
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          :char ->
            char = Map.get(key_data, :char, "")

            if is_binary(char) and char != "" do
              current_val = Map.get(model.modal_fields, active_item, "")
              new_val = current_val <> char
              new_fields = Map.put(model.modal_fields, active_item, new_val)
              {%{model | modal_fields: new_fields}, []}
            else
              {model, []}
            end

          ch when is_binary(ch) and byte_size(ch) == 1 ->
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = current_val <> ch
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          _ ->
            {model, []}
        end

      true ->
        {model, []}
    end
  end

  defp save_manual_connection(model) do
    host_name = String.trim(model.modal_fields["host_name"] || "")
    id = String.trim(model.modal_fields["id"] || "")
    id = if id == "", do: host_name, else: id

    port_str = String.trim(model.modal_fields["port"] || "")

    port =
      case Integer.parse(port_str) do
        {p, _} -> p
        _ -> 22
      end

    user = String.trim(model.modal_fields["user"] || "")
    user = if user == "", do: nil, else: user

    identity_file = String.trim(model.modal_fields["identity_file"] || "")
    identity_file = if identity_file == "", do: nil, else: identity_file

    password = String.trim(model.modal_fields["password"] || "")
    password = if password == "", do: nil, else: password

    id_exists? = Enum.any?(model.profiles, &(&1.id == id))

    cond do
      host_name == "" ->
        {%{model | modal_error: "Host/IP is required"}, []}

      id_exists? ->
        {%{model | modal_error: "Connection Name/ID already exists"}, []}

      true ->
        profile_attrs = %{
          id: id,
          host_pattern: id,
          host_name: host_name,
          user: user,
          port: port,
          identity_file: identity_file,
          password: password
        }

        case Caudata.ConfigManager.add_manual_profile(profile_attrs) do
          {:ok, added_profile} ->
            ViewHelper.start_worker_if_needed(added_profile)

            updated_profiles = model.profiles ++ [added_profile]

            {%{
               model
               | profiles: updated_profiles,
                 selected_profile_id: added_profile.id,
                 selected_container_id: nil,
                 selected_container_name: nil,
                 logs_scroll_y: :bottom,
                 modal_visible: false,
                 modal_error: nil
             }, []}

          {:error, reason} ->
            {%{model | modal_error: "Failed to add profile: #{inspect(reason)}"}, []}
        end
    end
  end

  defp handle_local_input_key(key, key_data, model) do
    fields = ["password", :save, :cancel]
    num_fields = length(fields)
    active_item = Enum.at(fields, model.modal_focus_index)
    modifiers = Map.get(key_data, :modifiers, [])
    is_shift = Enum.any?(modifiers, &(&1 in ["shift", "Shift"]))

    cond do
      key == :down ->
        new_focus = rem(model.modal_focus_index + 1, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :up ->
        new_focus = rem(model.modal_focus_index - 1 + num_fields, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :tab and is_shift ->
        new_focus = rem(model.modal_focus_index - 1 + num_fields, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :tab ->
        new_focus = rem(model.modal_focus_index + 1, num_fields)
        {%{model | modal_focus_index: new_focus}, []}

      key == :enter ->
        case active_item do
          :cancel ->
            {%{model | modal_type: :select_ssh, modal_selected_index: 0, modal_error: nil}, []}

          :save ->
            save_local_connection(model)

          _input_field ->
            # Enter key on input fields acts as Tab to move to next field
            new_focus = rem(model.modal_focus_index + 1, num_fields)
            {%{model | modal_focus_index: new_focus}, []}
        end

      is_binary(active_item) ->
        case key do
          :paste ->
            text = Map.get(key_data, :content, "")
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = current_val <> text
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          :backspace ->
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = String.slice(current_val, 0..-2//1)
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          :char ->
            char = Map.get(key_data, :char, "")

            if is_binary(char) and char != "" do
              current_val = Map.get(model.modal_fields, active_item, "")
              new_val = current_val <> char
              new_fields = Map.put(model.modal_fields, active_item, new_val)
              {%{model | modal_fields: new_fields}, []}
            else
              {model, []}
            end

          ch when is_binary(ch) and byte_size(ch) == 1 ->
            current_val = Map.get(model.modal_fields, active_item, "")
            new_val = current_val <> ch
            new_fields = Map.put(model.modal_fields, active_item, new_val)
            {%{model | modal_fields: new_fields}, []}

          _ ->
            {model, []}
        end

      true ->
        {model, []}
    end
  end

  defp save_local_connection(model) do
    id = "Local"

    password = String.trim(model.modal_fields["password"] || "")
    password = if password == "", do: nil, else: password

    id_exists? = Enum.any?(model.profiles, &(&1.id == id))

    cond do
      id_exists? ->
        {%{model | modal_error: "Local connection already exists"}, []}

      true ->
        profile_attrs = %{
          id: id,
          host_pattern: id,
          host_name: "local",
          user: nil,
          port: 0,
          identity_file: nil,
          password: password,
          is_local: true
        }

        case Caudata.ConfigManager.add_manual_profile(profile_attrs) do
          {:ok, added_profile} ->
            ViewHelper.start_worker_if_needed(added_profile)

            updated_profiles = model.profiles ++ [added_profile]

            {%{
               model
               | profiles: updated_profiles,
                 selected_profile_id: added_profile.id,
                 selected_container_id: nil,
                 selected_container_name: nil,
                 logs_scroll_y: :bottom,
                 modal_visible: false,
                 modal_error: nil
             }, []}

          {:error, reason} ->
            {%{model | modal_error: "Failed to add profile: #{inspect(reason)}"}, []}
        end
    end
  end
end
