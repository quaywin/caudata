defmodule CaudataTest do
  use ExUnit.Case
  doctest Caudata

  test "greets the world" do
    assert Caudata.hello() == :world
  end
end
