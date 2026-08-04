defmodule Caudata.UI.Components.ContainerActionModal do
  @moduledoc """
  Renders popup modal for Docker container actions (Start, Stop, Restart, Kill, Inspect, Remove),
  dynamically filtered according to the container's current state, with confirmation step for high-risk actions.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  alias Caudata.UI.ViewHelper

  @all_actions [
    {"🟢  Start Container", :start},
    {"🔴  Stop Container", :stop},
    {"🔄  Restart Container", :restart},
    {"⚡  Force Kill (SIGKILL)", :kill},
    {"ℹ️   Inspect Details", :inspect},
    {"🗑️  Remove Container", :remove}
  ]

  def actions, do: @all_actions

  def get_available_actions(state) do
    selected_container = get_selected_container(state)

    is_running =
      case selected_container do
        nil ->
          true

        %{state: "running"} ->
          true

        %{status: status} when is_binary(status) ->
          String.starts_with?(status, "Up")

        _ ->
          false
      end

    if is_running do
      [
        {"🔴  Stop Container", :stop},
        {"🔄  Restart Container", :restart},
        {"⚡  Force Kill (SIGKILL)", :kill},
        {"ℹ️   Inspect Details", :inspect}
      ]
    else
      [
        {"🟢  Start Container", :start},
        {"ℹ️   Inspect Details", :inspect},
        {"🗑️  Remove Container", :remove}
      ]
    end
  end

  def get_selected_container(state) do
    ViewHelper.get_selected_container(state)
  end

  def render(state) do
    actions = get_available_actions(state)
    selected_idx = Map.get(state, :container_action_modal_selected_index, 0)
    container_name = Map.get(state, :selected_container_name, "Container")

    option_lines =
      Enum.with_index(actions)
      |> Enum.map(fn {{label, _action}, idx} ->
        selected = selected_idx == idx
        prefix = if selected, do: "> ", else: "  "
        color = if selected, do: :green, else: :white
        style = %Style{fg: color, modifiers: if(selected, do: [:bold], else: [])}

        Line.new([
          Span.new(prefix, style: style),
          Span.new("#{idx + 1}. #{label}", style: style)
        ])
      end)

    header_lines = [
      Line.new([
        Span.new("Select Docker action for: ", style: %Style{fg: :cyan}),
        Span.new(to_string(container_name), style: %Style{fg: :yellow, modifiers: [:bold]})
      ]),
      Line.new([
        Span.new(String.duplicate("─", max(1, state.width - 15)), style: %Style{fg: :dark_gray})
      ])
    ]

    popup_widget = %Popup{
      content: %Paragraph{
        text: header_lines ++ option_lines
      },
      block: %Block{
        title: " 🐳 Docker Container Actions ",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 55,
      percent_height: min(40, max(25, length(actions) * 10 + 15))
    }

    [popup_widget]
  end

  def render_confirm(state) do
    action = Map.get(state, :pending_docker_action, :kill)
    container_name = Map.get(state, :selected_container_name, "Container")

    {action_title, color, prompt} =
      case action do
        :kill ->
          {"FORCE KILL (SIGKILL)", :red, "Are you sure you want to FORCE KILL container?"}

        :remove ->
          {"REMOVE CONTAINER", :red, "Are you sure you want to REMOVE container?"}

        _ ->
          {"CONFIRM ACTION", :yellow, "Are you sure you want to execute this action?"}
      end

    content_lines = [
      Line.new([
        Span.new("⚠️  #{prompt}", style: %Style{fg: :yellow, modifiers: [:bold]})
      ]),
      Line.new([]),
      Line.new([
        Span.new("    Container: ", style: %Style{fg: :dark_gray}),
        Span.new(to_string(container_name), style: %Style{fg: color, modifiers: [:bold]})
      ]),
      Line.new([]),
      Line.new([
        Span.new("This action cannot be undone!", style: %Style{fg: :red})
      ])
    ]

    popup_widget = %Popup{
      content: %Paragraph{text: content_lines},
      block: %Block{
        title: " ⚠️ Confirm #{action_title} ",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 55,
      percent_height: 35
    }

    [popup_widget]
  end

  def handle_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    actions = get_available_actions(model)
    total = length(actions)
    idx = min(Map.get(model, :container_action_modal_selected_index, 0), max(0, total - 1))

    case norm_key do
      k when k in [:up, "k", "K"] ->
        new_idx = if idx > 0, do: idx - 1, else: total - 1
        {Map.put(model, :container_action_modal_selected_index, new_idx), []}

      k when k in [:down, "j", "J"] ->
        new_idx = if idx < total - 1, do: idx + 1, else: 0
        {Map.put(model, :container_action_modal_selected_index, new_idx), []}

      num when num in ["1", "2", "3", "4", "5", "6"] ->
        selected_idx = String.to_integer(num) - 1

        if selected_idx < total do
          execute_action(selected_idx, actions, model)
        else
          {model, []}
        end

      :enter ->
        execute_action(idx, actions, model)

      k when k in [:escape, :esc] ->
        {%{model | modal_visible: false}, []}

      _ ->
        {model, []}
    end
  end

  def handle_key_confirm(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    pending_action = Map.get(model, :pending_docker_action)

    case norm_key do
      k when k in ["y", "Y", :enter] ->
        new_model =
          model
          |> Map.put(:modal_visible, false)
          |> Map.put(:pending_docker_action, nil)

        {new_model, [{:dispatch_docker_action, pending_action}]}

      k when k in ["n", "N", :escape, :esc] ->
        new_model =
          model
          |> Map.put(:modal_visible, false)
          |> Map.put(:pending_docker_action, nil)

        {new_model, []}

      _ ->
        {model, []}
    end
  end

  defp execute_action(idx, actions, model) do
    case Enum.at(actions, idx) do
      {_label, action} when action in [:kill, :remove] ->
        new_model =
          model
          |> Map.put(:modal_visible, true)
          |> Map.put(:modal_type, :confirm_docker_action)
          |> Map.put(:pending_docker_action, action)

        {new_model, []}

      {_label, action} ->
        {
          %{model | modal_visible: false},
          [{:dispatch_docker_action, action}]
        }

      _ ->
        {model, []}
    end
  end
end
