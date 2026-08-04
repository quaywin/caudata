defmodule Caudata.UI.Renderer do
  @moduledoc """
  Coordinating renderer that splits the frame area and renders individual UI components
  (Sidebar, LogsPane, Footer, Modal) from Caudata.UI.Components.
  """
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.Components.{
    Sidebar,
    LogsPane,
    Footer,
    AddServerModal,
    SettingsModal,
    ContainerActionModal,
    ContainerInspectModal
  }

  @doc """
  Splits the main window vertically and coordinates rendering of all components.
  """
  def render(state, frame) do
    # Update state width and height from frame dimensions to make existing calculations compatible
    state = %{state | width: frame.width, height: frame.height}
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # Split the main area vertically:
    # 0 to frame.height - 3: main content
    # frame.height - 2: divider
    # frame.height - 1: footer
    [main_content_area, divider_area, footer_area] =
      Layout.split(area, :vertical, [
        {:min, 0},
        {:length, 1},
        {:length, 1}
      ])

    # 1. Divider line widget
    divider_widget = %Paragraph{
      text: String.duplicate("─", frame.width),
      style: %Style{fg: :dark_gray}
    }

    # 2. Footer widget
    footer_widget = Footer.render(state)

    # 3. Main row: sidebar + logs
    {sidebar_widgets, logs_area} =
      if Map.get(state, :logs_full_screen, false) do
        {[], main_content_area}
      else
        [sidebar_area, logs_area] =
          Layout.split(main_content_area, :horizontal, [
            {:length, 38},
            {:min, 0}
          ])

        {Sidebar.render(state, sidebar_area), logs_area}
      end

    {logs_widget, logs_content_widgets} = LogsPane.render(state, logs_area)

    base_widgets =
      sidebar_widgets ++
        [
          {logs_widget, logs_area}
        ] ++ logs_content_widgets

    # If modal is visible, draw the modal popup on top of the main content area
    main_widgets =
      if state.modal_visible do
        modal_widget =
          cond do
            state.modal_type == :help ->
              [widget] = Caudata.UI.Components.HelpModal.render(state)
              widget

            state.modal_type == :settings ->
              [widget] = SettingsModal.render(state)
              widget

            state.modal_type == :container_action ->
              [widget] = ContainerActionModal.render(state)
              widget

            state.modal_type in [:confirm_docker_action, :confirm_delete_server] ->
              [widget] = ContainerActionModal.render_confirm(state)
              widget

            state.modal_type == :container_inspect ->
              [widget] = ContainerInspectModal.render(state)
              widget

            true ->
              [widget] = AddServerModal.render(state)
              widget
          end

        base_widgets ++ [{modal_widget, main_content_area}]
      else
        base_widgets
      end

    # Notification toast overlay in top-right corner
    notification_widget =
      case Map.get(state, :notification) do
        {msg, _ticks} ->
          # Calculate notification dimensions
          text = " ℹ #{msg} "
          text_len = String.length(text)
          notif_width = min(text_len, frame.width - 2)
          notif_x = max(0, frame.width - notif_width - 1)

          notif_area = %Rect{x: notif_x, y: 1, width: notif_width, height: 1}

          notif_paragraph = %Paragraph{
            text: [
              ExRatatui.Text.Line.new([
                ExRatatui.Text.Span.new(text,
                  style: %Style{fg: :black, bg: :green, modifiers: [:bold]}
                )
              ])
            ]
          }

          [{notif_paragraph, notif_area}]

        _ ->
          []
      end

    main_widgets ++
      [
        {divider_widget, divider_area},
        {footer_widget, footer_area}
      ] ++ notification_widget
  end
end
