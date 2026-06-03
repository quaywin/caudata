
Application.put_env(:raxol, :mode, :test)
{:ok, _} = Application.ensure_all_started(:caudata)

model = Caudata.UI.App.init(%{})
view = Caudata.UI.App.view(model)
IO.puts("View generated successfully.")
try do
  Raxol.UI.Layout.Engine.apply_layout(view, %{width: 80, height: 24})
  IO.puts("Layout applied successfully.")
rescue
  e ->
    IO.puts("LAYOUT ERROR CAUGHT:")
    IO.puts(Exception.format(:error, e, __STACKTRACE__))
end
