defmodule Caudata.UI.Components.FooterTest do
  use ExUnit.Case, async: true

  alias Caudata.UI.Components.Footer

  test "renders successfully when modal settings focus is :general" do
    state = %{
      modal_visible: true,
      modal_type: :settings,
      settings_focus: :general,
      settings_input_active: false
    }

    paragraph = Footer.render(state)
    assert %ExRatatui.Widgets.Paragraph{} = paragraph
  end

  test "renders successfully when modal settings focus is other tabs" do
    for focus <- [:servers, :connection, :containers, :services, :custom_logs, :general] do
      state = %{
        modal_visible: true,
        modal_type: :settings,
        settings_focus: focus,
        settings_input_active: false,
        settings_service_search_active: false
      }

      paragraph = Footer.render(state)
      assert %ExRatatui.Widgets.Paragraph{} = paragraph
    end
  end

  test "renders filter shortcuts when services search is active" do
    state = %{
      modal_visible: true,
      modal_type: :settings,
      settings_focus: :services,
      settings_input_active: false,
      settings_service_search_active: true
    }

    paragraph = Footer.render(state)
    assert %ExRatatui.Widgets.Paragraph{} = paragraph

    # Verify search-mode shortcuts are shown
    line = hd(paragraph.text)
    spans_text = Enum.map(line.spans, & &1.content) |> Enum.join()
    assert String.contains?(spans_text, "[Type] Filter")
    assert String.contains?(spans_text, "[Esc] Close")
  end

  test "renders filter shortcut when services focus is active (no search)" do
    state = %{
      modal_visible: true,
      modal_type: :settings,
      settings_focus: :services,
      settings_input_active: false,
      settings_service_search_active: false
    }

    paragraph = Footer.render(state)
    line = hd(paragraph.text)
    spans_text = Enum.map(line.spans, & &1.content) |> Enum.join()
    assert String.contains?(spans_text, "[/] Search/Filter")
  end

  test "renders successfully for container_action, container_inspect and confirm_docker_action modals" do
    for modal_type <- [:container_action, :container_inspect, :confirm_docker_action] do
      state = %{
        modal_visible: true,
        modal_type: modal_type
      }

      paragraph = Footer.render(state)
      assert %ExRatatui.Widgets.Paragraph{} = paragraph
    end
  end
end
