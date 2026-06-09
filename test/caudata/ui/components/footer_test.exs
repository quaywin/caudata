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
    for focus <- [:servers, :connection, :containers, :custom_logs] do
      state = %{
        modal_visible: true,
        modal_type: :settings,
        settings_focus: focus,
        settings_input_active: false
      }

      paragraph = Footer.render(state)
      assert %ExRatatui.Widgets.Paragraph{} = paragraph
    end
  end
end
