defmodule Caudata.UI.Renderer do
  @moduledoc """
  Coordinating renderer that splits the frame area and renders individual UI components
  (Sidebar, LogsPane, Footer, Modal) from Caudata.UI.Components.
  """
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  alias Caudata.UI.Components.{Sidebar, LogsPane, Footer, Modal}

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

    # 3. Main row (either modal or sidebar + logs)
    main_widgets =
      if state.modal_visible do
        # Modal mode
        [modal_widget] = Modal.render(state)
        [{modal_widget, main_content_area}]
      else
        # Normal mode: sidebar + logs
        [sidebar_area, logs_area] =
          Layout.split(main_content_area, :horizontal, [
            {:length, 25},
            {:min, 0}
          ])

        sidebar_widget = Sidebar.render(state)
        {logs_widget, logs_content_widgets} = LogsPane.render(state, logs_area)

        [
          {sidebar_widget, sidebar_area},
          {logs_widget, logs_area}
        ] ++ logs_content_widgets
      end

    main_widgets ++
      [
        {divider_widget, divider_area},
        {footer_widget, footer_area}
      ]
  end
end
